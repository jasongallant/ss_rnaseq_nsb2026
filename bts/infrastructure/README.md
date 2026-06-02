# Workshop Infrastructure — NS&B 2026 snRNA-seq Module

End-to-end runbook for the shared RStudio Server used by students June 8–13, 2026.
Architecture and sizing rationale: see [`~/.claude/plans/okay-let-s-work-on-abstract-cocke.md`](../../../.claude/plans/okay-let-s-work-on-abstract-cocke.md) (instructor only).

| Resource             | Choice                                                                 |
| -------------------- | ---------------------------------------------------------------------- |
| AWS account / region | MSU lab account, `us-east-1`                                           |
| Instance type        | `r6i.4xlarge` (16 vCPU, 128 GB RAM) — kept up 24/7 for the course week |
| OS                   | Ubuntu 24.04 LTS (`noble`)                                             |
| Auth                 | PAM users (`student1`..`student6`, `instructor`)                       |
| URL                  | `https://<your-domain>` (HTTPS via Let's Encrypt)                      |
| Lifecycle            | Disposable — terminated June 14                                        |

## Architecture in one diagram

```
+---------------------------------------------------------------+
|  EC2 r6i.4xlarge (one shared instance)                        |
|                                                               |
|   /opt/R/site-library     <- baked into AMI (slow to build)   |
|   /srv/workshop-content/  <- S3 sync at boot (workbooks, etc.)|
|   /srv/workshop-data/     <- RO mount of EBS snapshot         |
|   /home/student[1-6]/     <- provisioned at first boot:       |
|       └── ssrnaseq/                                           |
|           ├── workbook/   <- cp from /srv/workshop-content/   |
|           ├── setup.md                                        |
|           └── data/                                           |
|               ├── ssrnaseq_data -> /srv/workshop-data/...     |
|               ├── raw           -> /srv/workshop-data/raw     |
|               └── checkpoints/  <- writable per-student cp    |
+---------------------------------------------------------------+
       ^                                ^                 ^
       |                                |                 |
  AMI (built in Phase 1)         S3 bucket          EBS snapshot
  R + packages, no content       content/ workbooks data/  bulk data
                                                          (Phase 2)
```

Key property: a workbook fix → push to `s3://${WORKSHOP_BUCKET}/content/` → `sudo refresh-workbooks.sh` on the instance. **No AMI rebuild required for content tweaks.**

## How this runbook works

Every command captures its output into a shell variable (`SG_ID`, `BUILDER_ID`, `AMI_ID`, etc.) so that later steps can reference it without copy-pasting IDs by hand. Inputs and captured outputs both live in `bts/infrastructure/.env` so a fresh terminal can always pick up where you left off.

### Set up your .env

```bash
cp bts/infrastructure/.env.example bts/infrastructure/.env
# Edit .env: fill in your KEY_NAME, WORKSHOP_DOMAIN, WORKSHOP_BUCKET,
# GITHUB_PAT, etc. The example file documents what each variable is for.
```

`bts/infrastructure/.env` is git-ignored — your GitHub PAT and AWS IDs stay local. Don't commit it.

### Load .env at the start of every work session

```bash
set -a; source bts/infrastructure/.env; set +a
```

(The `set -a` toggle auto-exports every variable assigned while it's active, so the file can stay plain `KEY=VALUE` with no `export` lines.)

### Save outputs as you go

When a phase captures a new resource ID (e.g. `SG_ID`, `AMI_ID`, `DATA_SNAPSHOT_ID`), update the same key in `.env` so your next shell session inherits it. The one-liner is:

```bash
# After exporting any variable in a phase, persist it to .env:
sed -i.bak "s|^SG_ID=.*|SG_ID=$SG_ID|" bts/infrastructure/.env
```

(Bash on macOS needs `sed -i.bak` — the `.bak` argument is non-optional. Delete the resulting `.env.bak` afterward if it bugs you.)

---

## Phase 0 — One-time prerequisites

You only do this once per AWS account. If you've already created the security group, key pair, S3 bucket, and IAM instance profile, skip ahead to Phase 1.

### Session setup

```bash
set -a; source bts/infrastructure/.env; set +a
```

This loads `REGION`, `KEY_NAME`, `KEY_FILE`, `WORKSHOP_BUCKET`, and friends from your `.env`.

### 0.1 — Create the SSH key pair

```bash
aws ec2 create-key-pair \
    --key-name "$KEY_NAME" \
    --query 'KeyMaterial' --output text \
    --region "$REGION" \
    > "$KEY_FILE"
chmod 400 "$KEY_FILE"
```

If the key pair already exists (you created it via the console), this will error — that's fine, just confirm your `$KEY_FILE` exists locally.

### 0.2 — Create the workshop security group

```bash
# Find the default VPC
export VPC_ID=$(aws ec2 describe-vpcs \
    --filters Name=is-default,Values=true \
    --query 'Vpcs[0].VpcId' --output text \
    --region "$REGION")
echo "VPC_ID=$VPC_ID"

# Create the SG
export SG_ID=$(aws ec2 create-security-group \
    --group-name nsb2026-workshop \
    --description "NS&B 2026 snRNA-seq workshop server" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' --output text \
    --region "$REGION")
echo "SG_ID=$SG_ID"

# Ingress rules
aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ID" --protocol tcp --port 22 --cidr "0.0.0.0/0
aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0
```

**Save to .env so a fresh terminal can pick this up:**

```bash
sed -i.bak "s|^VPC_ID=.*|VPC_ID=$VPC_ID|; s|^SG_ID=.*|SG_ID=$SG_ID|" bts/infrastructure/.env
```

### 0.3 — Create the S3 bucket and upload content

The bucket holds two prefixes:

- `s3://${WORKSHOP_BUCKET}/content/` — workbooks, `setup.md` (small, frequently updated)
- `s3://${WORKSHOP_BUCKET}/data/` — bulk data (only consumed by `build_data_volume.sh` in Phase 2)

```bash
aws s3 mb "s3://${WORKSHOP_BUCKET}" --region "$REGION"

# Push workbooks + setup.md from the local repo
aws s3 sync episodes/workbook/ "s3://${WORKSHOP_BUCKET}/content/workbooks/"
aws s3 cp   episodes/setup.md  "s3://${WORKSHOP_BUCKET}/content/setup.md"

# Push the bulk data (your existing fastq/cellranger outputs)
#   The exact layout is:
#     s3://${WORKSHOP_BUCKET}/data/ssrnaseq_data/...
#     s3://${WORKSHOP_BUCKET}/data/checkpoints/0[1-4]_*.rds
#     s3://${WORKSHOP_BUCKET}/data/raw/{fastq,fastqc,cellranger}/<sample>/
#     s3://${WORKSHOP_BUCKET}/data/eod_duration/  (optional)
aws s3 sync episodes/data/ssrnaseq_data/  "s3://${WORKSHOP_BUCKET}/data/ssrnaseq_data/" --exclude ".*" --exclude "*/.*"
aws s3 sync episodes/data/checkpoints  "s3://${WORKSHOP_BUCKET}/data/checkpoints/" --exclude ".*" --exclude "*/.*"
aws s3 sync bts/data_generation/qc/          "s3://${WORKSHOP_BUCKET}/data/qc/" --exclude ".*" --exclude "*/.*"
aws s3 sync episodes/data/eod_duration/ "S3://${WORKSHOP_BUCKET}/data/eod_duration" --exclude ".*" --exclude "*/.*"

```

### 0.4 — Create the IAM instance profile

The workshop instance needs read access to the S3 bucket so cloud-init and `refresh-workbooks.sh` can sync content.

```bash
# Trust policy: allow EC2 to assume the role
cat > /tmp/trust.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]
}
JSON

aws iam create-role \
    --role-name "$INSTANCE_PROFILE" \
    --assume-role-policy-document file:///tmp/trust.json

# Permission policy: read the content/ prefix
cat > /tmp/policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::${WORKSHOP_BUCKET}"},
    {"Effect": "Allow", "Action": ["s3:GetObject"], "Resource": "arn:aws:s3:::${WORKSHOP_BUCKET}/content/*"}
  ]
}
JSON

aws iam put-role-policy \
    --role-name "$INSTANCE_PROFILE" \
    --policy-name nsb2026-s3-content-read \
    --policy-document file:///tmp/policy.json

aws iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE"
aws iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE" \
    --role-name "$INSTANCE_PROFILE"
```

(`$INSTANCE_PROFILE` was loaded from `.env` in the session setup — change the name there if you want a different profile name.)

The builder for the data volume (Phase 2) needs broader access (both `content/` and `data/` plus write). Create a separate profile or reuse this one with a wider policy attached during the build only — your call.

---

## Phase 1 — Build the golden AMI

A "golden AMI" carries the OS, R 4.4, the full `renv` package set, RStudio Server, nginx, and the provision/refresh helper scripts. **It does NOT carry any lesson content** — workbooks come from S3 at launch, bulk data comes from a mounted EBS snapshot (Phase 2). Build the AMI once on a cheap t3.medium and snapshot it.

### Session setup

```bash
set -a; source bts/infrastructure/.env; set +a
```

Phase 1 reads `REGION`, `KEY_*`, `SG_ID` (from Phase 0), and the build inputs `BASE_AMI`, `RENV_LOCK_URL`, `GITHUB_PAT`.

**About `BASE_AMI`:**

- First build of the year: use the Ubuntu base AMI (slow path, ~30–60 min).
- Rebuilding because something changed (R package set, dev libs, helper scripts): set `BASE_AMI` in `.env` to last year's `AMI_ID`. The script is idempotent: apt-get, rig add, and renv::restore all skip work that's already done, so the rebuild finishes in 10–20 min instead of 30–60.

### 1.1 — Confirm `renv.lock` is reachable at the URL

```bash
curl -fsS "$RENV_LOCK_URL" | head -5    # should print the JSON header
```

If the file isn't published yet (e.g. you're on a private branch), either merge to `main` first or host the lockfile at any HTTPS URL the builder can reach.

### 1.2 — Keep renv.lock lean (optional, recommended)

Before baking, prune the lockfile to only what the current `.Rmd` files actually use. Every removed package shaves bake time off later.

```bash
Rscript bts/infrastructure/rebuild_renv_lock.R
git diff renv.lock                          # inspect
git add renv.lock && git commit -m "chore: rebuild renv.lock"
git push                                    # so the URL serves the new file
```

### 1.3 — Launch the builder (t3.medium)

```bash
export BUILDER_ID=$(aws ec2 run-instances \
    --image-id "$BASE_AMI" \
    --instance-type t3.medium \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=80,VolumeType=gp3}' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=nsb2026-builder},{Key=Project,Value=nsb2026-workshop}]' \
    --region "$REGION" \
    --query 'Instances[0].InstanceId' --output text)
echo "BUILDER_ID=$BUILDER_ID"

echo "Waiting for instance to be SSH-ready (~2 min)..."
aws ec2 wait instance-status-ok --instance-ids "$BUILDER_ID" --region "$REGION"

export BUILDER_IP=$(aws ec2 describe-instances --instance-ids "$BUILDER_ID" --region "$REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "BUILDER_IP=$BUILDER_IP"
```

The builder's root volume is 80 GB (smaller than before — we're not baking any lesson content into the AMI).

### 1.4 — Copy the build script up and run it

```bash
scp -i "$KEY_FILE" -o StrictHostKeyChecking=accept-new \
    bts/infrastructure/build_ami.sh ubuntu@"$BUILDER_IP":/tmp/

ssh -i "$KEY_FILE" ubuntu@"$BUILDER_IP" \
    "sudo RENV_LOCK_URL='$RENV_LOCK_URL' \
          GITHUB_PAT='$GITHUB_PAT' \
          bash /tmp/build_ami.sh 2>&1 | tee /tmp/build.log"
```

Expect **30–60 minutes** for a first build from Ubuntu base, or **10–20 minutes** when `$BASE_AMI` is last year's AMI.

Watch the early log lines:

- `R version 4.4.3` — confirms rig installed the right R. Anything else (4.6.x in particular) is fatal; abort and investigate.
- `P3M smoke test: jsonlite installed in X.Xs` — must be **under 15 s**, else the script aborts on its own.

### 1.5 — Snapshot the builder into an AMI

```bash
export AMI_ID=$(aws ec2 create-image \
    --instance-id "$BUILDER_ID" \
    --name "ss-rnaseq-nsb2026-$(date +%Y%m%d)" \
    --description "RStudio Server + Seurat/DESeq2 stack for NS&B 2026 (no lesson content)" \
    --tag-specifications 'ResourceType=image,Tags=[{Key=Project,Value=nsb2026-workshop}]' \
    --no-reboot \
    --region "$REGION" \
    --query 'ImageId' --output text)
echo "AMI_ID=$AMI_ID"

echo "Waiting for AMI to finish baking (~5–10 min)..."
aws ec2 wait image-available --image-ids "$AMI_ID" --region "$REGION"
```

**Write `$AMI_ID` down somewhere durable.**

### 1.6 — Terminate the builder

```bash
aws ec2 terminate-instances --instance-ids "$BUILDER_ID" --region "$REGION"
unset BUILDER_ID BUILDER_IP
```

**Save the AMI ID to .env:**

```bash
sed -i.bak "s|^AMI_ID=.*|AMI_ID=$AMI_ID|" bts/infrastructure/.env
```

---

## Phase 2 — Build the data volume snapshot

One-time (or whenever the bulk data changes). Populates a fresh EBS volume from S3, snapshots it. The snapshot is what gets attached to the workshop instance at launch.

### Session setup

```bash
set -a; source bts/infrastructure/.env; set +a
```

Phase 2 reads `REGION`, `KEY_*`, `SG_ID`, `WORKSHOP_BUCKET`, and `INSTANCE_PROFILE`.

The instance profile from Phase 0.4 only allows reading `content/*`. Before this phase, temporarily widen its policy to also allow `s3:GetObject` on `arn:aws:s3:::${WORKSHOP_BUCKET}/data/*`, or use a separate "builder" role.

### 2.1 — Launch a builder t3.medium with an empty 500 GB EBS volume attached

```bash
export BUILDER_ID=$(aws ec2 run-instances \
    --image-id ami-0fbcf351e82d18381 \
    --instance-type t3.medium \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=$INSTANCE_PROFILE" \
    --block-device-mappings \
        'DeviceName=/dev/sda1,Ebs={VolumeSize=20,VolumeType=gp3}' \
        'DeviceName=/dev/sdf,Ebs={VolumeSize=500,VolumeType=gp3,DeleteOnTermination=false}' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=nsb2026-data-builder},{Key=Project,Value=nsb2026-workshop}]' \
    --region "$REGION" \
    --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-status-ok --instance-ids "$BUILDER_ID" --region "$REGION"

export BUILDER_IP=$(aws ec2 describe-instances --instance-ids "$BUILDER_ID" --region "$REGION" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

# Find the volume ID of the 500 GB data volume (we'll snapshot it later)
export DATA_VOL_ID=$(aws ec2 describe-instances --instance-ids "$BUILDER_ID" --region "$REGION" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/sdf`].Ebs.VolumeId' \
    --output text)
echo "DATA_VOL_ID=$DATA_VOL_ID"
```

Note `DeleteOnTermination=false` on the data volume — we want it to persist after we terminate the builder so we can snapshot it.

### 2.2 — Run the populate script

On Nitro instance types, `/dev/sdf` shows up as `/dev/nvme1n1`. Confirm with `lsblk` on the builder first.

```bash
ssh -i "$KEY_FILE" -o StrictHostKeyChecking=accept-new ubuntu@"$BUILDER_IP" 'lsblk'
# Verify /dev/nvme1n1 is the 500 GB device with no FS, then:

scp -i "$KEY_FILE" bts/infrastructure/build_data_volume.sh ubuntu@"$BUILDER_IP":/tmp/

# Install AWS CLI v2 via the official installer (noble's apt no longer ships
# awscli), then run the populate script. The unzip + curl utilities ARE in apt.
ssh -i "$KEY_FILE" ubuntu@"$BUILDER_IP" "bash -s" <<'REMOTE'
set -euo pipefail
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends curl unzip
curl -fSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
sudo /tmp/aws/install --update
aws --version
REMOTE

ssh -i "$KEY_FILE" ubuntu@"$BUILDER_IP" \
    "sudo WORKSHOP_BUCKET='$WORKSHOP_BUCKET' DEVICE=/dev/nvme1n1 \
          bash /tmp/build_data_volume.sh"
```

When done, the volume is unmounted and ready to snapshot.

### 2.3 — Snapshot the data volume

```bash
export DATA_SNAPSHOT_ID=$(aws ec2 create-snapshot \
    --volume-id "$DATA_VOL_ID" \
    --description "ss-rnaseq-data $(date +%Y%m%d)" \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=ss-rnaseq-data},{Key=Project,Value=nsb2026-workshop}]' \
    --region "$REGION" \
    --query 'SnapshotId' --output text)
echo "DATA_SNAPSHOT_ID=$DATA_SNAPSHOT_ID"

aws ec2 wait snapshot-completed --snapshot-ids "$DATA_SNAPSHOT_ID" --region "$REGION"
```

**Save to .env:**

```bash
sed -i.bak "s|^DATA_SNAPSHOT_ID=.*|DATA_SNAPSHOT_ID=$DATA_SNAPSHOT_ID|" bts/infrastructure/.env
```

### 2.4 — Tear down the builder

```bash
aws ec2 terminate-instances --instance-ids "$BUILDER_ID" --region "$REGION"
aws ec2 wait instance-terminated --instance-ids "$BUILDER_ID" --region "$REGION"
aws ec2 delete-volume --volume-id "$DATA_VOL_ID" --region "$REGION"
unset BUILDER_ID BUILDER_IP DATA_VOL_ID
```

---

## Phase 3 — Day-of launch

Do this **June 7 evening** so there's a day to fix anything before students arrive.

### Session setup

```bash
set -a; source bts/infrastructure/.env; set +a
```

Phase 3 needs `AMI_ID` (Phase 1.5), `DATA_SNAPSHOT_ID` (Phase 2.3), `INSTANCE_PROFILE`, `WORKSHOP_BUCKET`, `WORKSHOP_DOMAIN`, `ADMIN_EMAIL`, and `DATA_DEVICE` — all of which should already be set in `.env`. If you skipped a save step, set the missing values now and re-run the `source` line.

### 3.1 — Look up the persistent Elastic IP

The workshop uses a **permanent** Elastic IP that DNS (`workshop.efishgenomics.com → 32.197.26.59`) is already wired to. It survives across workshop years — don't release it in teardown. `EIP_PUBLIC_IP` should already be set in your `.env` to the persistent address.

```bash
# Recover the allocation ID for the persistent EIP (needed for the associate step).
export EIP_ALLOC_ID=$(aws ec2 describe-addresses --region "$REGION" \
    --public-ips "$EIP_PUBLIC_IP" \
    --query 'Addresses[0].AllocationId' --output text)
echo "EIP_ALLOC_ID=$EIP_ALLOC_ID"

# Cache the allocation ID in .env so future launches skip the lookup:
sed -i.bak "s|^EIP_ALLOC_ID=.*|EIP_ALLOC_ID=$EIP_ALLOC_ID|" bts/infrastructure/.env

# Sanity check DNS still points at the EIP (should print $EIP_PUBLIC_IP):
dig +short "$WORKSHOP_DOMAIN"
```

If `dig` returns the wrong IP or nothing, fix the DNS A record before continuing — `certbot` will fail otherwise. If the lookup returns `None` for `EIP_ALLOC_ID`, the EIP isn't allocated in `$REGION` (or under your account). Recreating it requires re-allocating and updating DNS — out of scope for this runbook.

### 3.2 — Personalize the cloud-init file

The template has four placeholders to substitute:

```bash
sed -e "s/__WORKSHOP_DOMAIN__/$WORKSHOP_DOMAIN/g" \
    -e "s/__ADMIN_EMAIL__/$ADMIN_EMAIL/g" \
    -e "s|__WORKSHOP_BUCKET__|$WORKSHOP_BUCKET|g" \
    -e "s|__DATA_DEVICE__|$DATA_DEVICE|g" \
    bts/infrastructure/cloud_init.yaml \
    > /tmp/cloud_init_personalized.yaml
```

### 3.3 — Launch the workshop instance with the data volume attached from snapshot

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type r6i.4xlarge \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=$INSTANCE_PROFILE" \
    --block-device-mappings \
        'DeviceName=/dev/sda1,Ebs={VolumeSize=120,VolumeType=gp3}' \
        "DeviceName=/dev/sdf,Ebs={SnapshotId=$DATA_SNAPSHOT_ID,VolumeType=gp3,DeleteOnTermination=true}" \
    --user-data file:///tmp/cloud_init_personalized.yaml \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=nsb2026-workshop},{Key=Project,Value=nsb2026-workshop}]' \
    --region "$REGION" \
    --query 'Instances[0].InstanceId' --output text)
echo "INSTANCE_ID=$INSTANCE_ID"

echo "Waiting for instance to start..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

# Save to .env so teardown later can find it:
sed -i.bak "s|^INSTANCE_ID=.*|INSTANCE_ID=$INSTANCE_ID|" bts/infrastructure/.env
```

The root volume is 120 GB (down from 300 — no bulk data on root anymore). The data volume restored from the snapshot is attached as `/dev/sdf` → appears as `$DATA_DEVICE` to cloud-init.

### 3.4 — Associate the Elastic IP

```bash
aws ec2 associate-address \
    --instance-id "$INSTANCE_ID" \
    --allocation-id "$EIP_ALLOC_ID" \
    --region "$REGION"
```

### 3.5 — Wait for cloud-init to finish

```bash
sleep 30

ssh -i "$KEY_FILE" -o StrictHostKeyChecking=accept-new \
    ubuntu@"$WORKSHOP_DOMAIN" 'sudo cloud-init status --wait'
```

When this returns `status: done`, the data volume is mounted RO at `/srv/workshop-data/`, content is synced to `/srv/workshop-content/`, all 7 PAM users exist, each has a populated `~/ssrnaseq/`, and TLS is live.

### 3.6 — Retrieve credentials

```bash
ssh -i "$KEY_FILE" ubuntu@"$WORKSHOP_DOMAIN" 'sudo cat /root/credentials.txt' \
    > workshop-creds.txt

ssh -i "$KEY_FILE" ubuntu@"$WORKSHOP_DOMAIN" 'sudo shred -u /root/credentials.txt'

cat workshop-creds.txt
```

Distribute the per-user passwords through a secure channel. To force a password change at first login:

```bash
for u in student1 student2 student3 student4 student5 student6; do
    ssh -i "$KEY_FILE" ubuntu@"$WORKSHOP_DOMAIN" "sudo chage -d 0 $u"
done
```

If you ever lose your shell mid-workshop, `set -a; source bts/infrastructure/.env; set +a` recovers every ID you saved. As a last-resort fallback if `.env` got out of sync, you can re-query AWS:

```bash
export INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=nsb2026-workshop" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
export EIP_ALLOC_ID=$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=tag:Project,Values=nsb2026-workshop" \
    --query 'Addresses[0].AllocationId' --output text)
```

---

## Phase 4 — Smoke test (run before Friday June 12)

1. Browser → `https://$WORKSHOP_DOMAIN/` → RStudio login screen with a valid green padlock.
2. Log in as `student1` with the password from `workshop-creds.txt`.
3. In the Files pane, navigate to `~/ssrnaseq/`. Confirm the layout:
   - `workbook/` (with the two `.Rmd` files)
   - `setup.md`
   - `data/ssrnaseq_data` (with a chain symbol — symlink to `/srv/workshop-data/...`)
   - `data/raw` (symlink)
   - `data/checkpoints/` (actual dir, with the 4 `.rds` files inside)
4. In the R console, paste the smoke test:
   ```r
   library(Seurat)
   stopifnot(file.exists("data/ssrnaseq_data/EO/BB48/barcodes.tsv.gz"))
   stopifnot(file.exists("data/checkpoints/02_harmony_clustered.rds"))
   seu <- readRDS("data/checkpoints/02_harmony_clustered.rds")
   seu
   table(seu$treatment)
   ```
   Expect a Seurat object with 4 samples, ~10,000 nuclei, and treatment labels (`11kt`, `vehicle`).
5. Confirm read-only enforcement on the mount:
   ```r
   file.create("data/ssrnaseq_data/test.txt")   # should return FALSE (EROFS)
   saveRDS(1, "data/checkpoints/scratch.rds")    # should succeed (writable copy)
   ```
6. Open `workbook/snrnaseq-preprocessing.Rmd` and run the chunks from `load-libraries` through `sctransform`. In a parallel SSH session, watch peak RSS:
   ```bash
   ssh -i "$KEY_FILE" ubuntu@"$WORKSHOP_DOMAIN" htop
   ```
   Should hit ~10 GB and stay well below the 128 GB ceiling.
7. As a second student (open a new private browser window), log in as `student2`. Confirm `student1`'s `scratch.rds` in step 5 is **not** visible — each student has their own writable `data/checkpoints/`.

If anything fails, fix in `build_ami.sh` (for environment issues) or in S3/`workbook/` (for content issues), then either rebake (Phase 1) or `refresh-workbooks.sh` (mid-week update — see below).

---

## Mid-week workbook updates (no AMI rebuild)

Workflow for fixing a typo or tweaking a workbook during the workshop:

```bash
# 1. Edit locally
vim episodes/workbook/snrnaseq-preprocessing.Rmd

# 2. Push to S3
aws s3 sync episodes/workbook/ "s3://${WORKSHOP_BUCKET}/content/workbooks/"

# 3. Apply to the running instance (preserves student edits via --backup)
ssh -i "$KEY_FILE" ubuntu@"$WORKSHOP_DOMAIN" 'sudo /usr/local/sbin/refresh-workbooks.sh'
```

Students who had local edits will find their previous versions in `~/ssrnaseq/.workbook-backups/<timestamp>/`. They can `diff` against the new copy to merge changes themselves.

Don't push to the workbook S3 during a chunk-running session unless you're prepared to do step 3 immediately — the new instance launch path always syncs from S3, but a running instance only sees changes after `refresh-workbooks.sh` runs.

---

## Keeping `renv.lock` lean

The AMI bake time is dominated by the renv restore step. Every package in `renv.lock` adds 10s–60s of install time. The lockfile accumulates orphan dependencies whenever you delete or refactor episodes, so before each AMI rebake:

```bash
Rscript bts/infrastructure/rebuild_renv_lock.R
git diff renv.lock                         # expect removals
git add renv.lock && git commit -m "..."
git push                                   # so RENV_LOCK_URL serves the new file
```

The script re-runs `renv::dependencies()` on the current `.Rmd` files, nukes `renv/library/` and `renv.lock`, then `renv::init()` rebuilds a clean closure. Backs up the old lockfile to `renv.lock.bak-<timestamp>` first.

---

## Phase 5 — Tear-down (June 14)

### Session setup

```bash
set -a; source bts/infrastructure/.env; set +a
```

Reads `INSTANCE_ID`, `EIP_ALLOC_ID`, `AMI_ID`, and `DATA_SNAPSHOT_ID` from `.env`.

### 5.1 — (Optional) snapshot student work

If a student wants their working directory preserved, snapshot the root volume before terminating:

```bash
export ROOT_VOLUME_ID=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/sda1`].Ebs.VolumeId' \
    --output text)
echo "ROOT_VOLUME_ID=$ROOT_VOLUME_ID"

export SNAPSHOT_ID=$(aws ec2 create-snapshot \
    --volume-id "$ROOT_VOLUME_ID" \
    --description "nsb2026 workshop final state $(date +%Y%m%d)" \
    --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Project,Value=nsb2026-workshop}]' \
    --region "$REGION" \
    --query 'SnapshotId' --output text)
echo "SNAPSHOT_ID=$SNAPSHOT_ID"
```

### 5.2 — Terminate the instance

```bash
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
```

The attached data volume (restored from `$DATA_SNAPSHOT_ID`) is deleted automatically because we launched it with `DeleteOnTermination=true`. The underlying snapshot is preserved.

### 5.3 — Disassociate (but DO NOT release) the Elastic IP

The EIP is **persistent across workshop years** — `workshop.efishgenomics.com` DNS is wired to it permanently. Disassociating it from the now-terminated instance is automatic when the instance terminates, so no command is required. **Do not** run `aws ec2 release-address` — that would deallocate it and break DNS for next year.

If you ever truly want to retire the workshop infrastructure for good (no more years), then and only then:

```bash
# DESTRUCTIVE — breaks DNS until you re-point it. Only run if retiring the workshop.
# aws ec2 release-address --allocation-id "$EIP_ALLOC_ID" --region "$REGION"
```

### 5.4 — Leave the DNS record alone

DNS (`workshop.efishgenomics.com → 32.197.26.59`) stays pointed at the persistent EIP so next year's instance reuses it. Only delete the DNS record if you're retiring the workshop permanently (see 5.3 note).

### 5.5 — Deregister the AMI

Wait until you're sure you won't relaunch:

```bash
export AMI_SNAPSHOT_ID=$(aws ec2 describe-images --image-ids "$AMI_ID" --region "$REGION" \
    --query 'Images[0].BlockDeviceMappings[?DeviceName==`/dev/sda1`].Ebs.SnapshotId' \
    --output text)

aws ec2 deregister-image --image-id "$AMI_ID" --region "$REGION"
aws ec2 delete-snapshot --snapshot-id "$AMI_SNAPSHOT_ID" --region "$REGION"
```

### 5.6 — Decide about the data snapshot

The data snapshot (`$DATA_SNAPSHOT_ID`) costs ~$5–$25/month depending on size. Keep it if next year's workshop will reuse the same dataset; delete it if regenerating from S3 next year is fine.

```bash
# To delete:
aws ec2 delete-snapshot --snapshot-id "$DATA_SNAPSHOT_ID" --region "$REGION"
```

---

## Cost guardrail

Set an **AWS Budgets alarm at $250** for the month, scoped to `Tag:Project=nsb2026-workshop`, notifying your email. Disposable infra is forgiving until it isn't.

```bash
# Quick check: what's currently tagged for this project?
aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Project,Values=nsb2026-workshop" \
    --query 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,LaunchTime]' \
    --output table
```
