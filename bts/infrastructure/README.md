# Workshop Infrastructure — NS&B 2026 snRNA-seq Module

End-to-end runbook for the shared RStudio Server used by students June 8–13, 2026.
Architecture and sizing rationale: see [`~/.claude/plans/okay-now-for-some-nifty-alpaca.md`](../../../.claude/plans/okay-now-for-some-nifty-alpaca.md) (instructor only).

| Resource             | Choice                                                                 |
| -------------------- | ---------------------------------------------------------------------- |
| AWS account / region | MSU lab account, `us-east-1`                                           |
| Instance type        | `r6i.4xlarge` (16 vCPU, 128 GB RAM) — kept up 24/7 for the course week |
| OS                   | Ubuntu 24.04 LTS (`noble`)                                             |
| Auth                 | PAM users (`student1`..`student6`, `instructor`)                       |
| URL                  | `https://<your-domain>` (HTTPS via Let's Encrypt)                      |
| Lifecycle            | Disposable — terminated June 14                                        |

---

## How this runbook works

Every command captures its output into a shell variable (`SG_ID`, `BUILDER_ID`, `AMI_ID`, etc.) so that later steps can reference it without copy-pasting IDs by hand. **Run all commands in the same terminal session**, or persist the variables to a file (see the "Resume after losing your shell" tip at the bottom of each phase).

Before starting any phase, paste the **Session setup** block at the top of that phase into your terminal. It sets the constants (region, key name, etc.) that the phase's commands reference.

---

## Phase 0 — One-time prerequisites

You only do this once per AWS account. If you've already created the security group and key pair, skip ahead to Phase 1.

### Session setup

```bash
export REGION=us-east-1
export KEY_NAME=gallant_mbp
export KEY_FILE=~/.ssh/gallant_mbp.pem
```

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
export MY_IP="$(curl -s https://checkip.amazonaws.com)/32"
echo "MY_IP=$MY_IP"

aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$MY_IP"
aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ID" --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --region "$REGION" \
    --group-id "$SG_ID" --protocol tcp --port 443 --cidr 0.0.0.0/0
```

> **Resume after losing your shell:** to recover `$SG_ID` later,
>
> ```bash
> export SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
>     --filters Name=group-name,Values=nsb2026-workshop \
>     --query 'SecurityGroups[0].GroupId' --output text)
> ```

---

## Phase 1 — Build the golden AMI

A "golden AMI" carries the OS, R 4.4, the full `renv` package set, RStudio Server, nginx, and a clone of the lesson repo. Build it once on a cheap t3.medium and snapshot it.

### Session setup

```bash
# Carried forward from Phase 0:
export REGION=us-east-1
export KEY_NAME=gallant_mbp
export KEY_FILE=~/.ssh/gallant_mbp
export SG_ID=sg-0d661b0ecfdeafb41   # or recover via the snippet in 0.2

# Phase 1 specifics:
# - First build of the year: use the Ubuntu base AMI (slow path, ~30-60 min).
# - Rebuilding because something changed (lockfile bump, R version, lesson tweak):
#   set BASE_AMI to last year's $AMI_ID. The script is idempotent: apt-get,
#   rig add, and renv::restore all skip work that's already done, so the
#   rebuild finishes in 10-20 min instead of 30-60.
export BASE_AMI=ami-0fbcf351e82d18381              # Ubuntu 24.04 LTS in us-east-1 (or last year's $AMI_ID)
export LESSON_REPO_URL=https://github.com/jasongallant/ss_rnaseq_nsb2026.git
export RENV_LOCK_URL=                              # leave empty if renv.lock is committed in the repo
export GITHUB_PAT='ghp_REPLACE_ME'                 # zero-scope classic PAT from https://github.com/settings/tokens (lifts the GitHub API rate limit so renv can resolve presto)
```

### 1.1 — Confirm `renv.lock` is reachable

The build script needs `renv.lock` to install the locked R package set. Either:

- It's committed in the repo (preferred), and `LESSON_REPO_URL` will bring it down via `git clone`. Run `git ls-files renv.lock` locally — if you see the path, it's committed.
- **Or** host it at an HTTPS URL and set `RENV_LOCK_URL` to that URL.

### 1.2 — Launch the builder (t3.medium)

```bash
export BUILDER_ID=$(aws ec2 run-instances \
    --image-id "$BASE_AMI" \
    --instance-type t3.medium \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=200,VolumeType=gp3}' \
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

### 1.3 — Copy the build script up and run it

```bash
scp -i "$KEY_FILE" -o StrictHostKeyChecking=accept-new \
    bts/infrastructure/build_ami.sh ubuntu@"$BUILDER_IP":/tmp/

ssh -i "$KEY_FILE" ubuntu@"$BUILDER_IP" \
    "sudo LESSON_REPO_URL='$LESSON_REPO_URL' \
          RENV_LOCK_URL='$RENV_LOCK_URL' \
          GITHUB_PAT='$GITHUB_PAT' \
          bash /tmp/build_ami.sh 2>&1 | tee /tmp/build.log"
```

Expect **30–60 minutes** for a first build from Ubuntu base, or **10–20 minutes** when `$BASE_AMI` is last year's AMI (most steps are no-ops; only changed packages reinstall).

Watch the early log lines:
- `R version 4.4.3` — confirms rig installed the right R. Anything else (4.6.x in particular) is fatal; abort and investigate.
- `P3M smoke test: jsonlite installed in X.Xs` — must be **under 15 s**, else the script aborts on its own (the User-Agent handshake to Posit Package Manager isn't working and every package would compile from raw source, taking hours).

### 1.4 — Snapshot the builder into an AMI

```bash
export AMI_ID=$(aws ec2 create-image \
    --instance-id "$BUILDER_ID" \
    --name "ss-rnaseq-nsb2026-$(date +%Y%m%d)" \
    --description "RStudio Server + Seurat/DESeq2 stack for NS&B 2026" \
    --tag-specifications 'ResourceType=image,Tags=[{Key=Project,Value=nsb2026-workshop}]' \
    --no-reboot \
    --region "$REGION" \
    --query 'ImageId' --output text)
echo "AMI_ID=$AMI_ID"

echo "Waiting for AMI to finish baking (~5–10 min)..."
aws ec2 wait image-available --image-ids "$AMI_ID" --region "$REGION"
```

**Write `$AMI_ID` down somewhere durable** (password manager, Notion, sticky note) — it's the only artifact from this phase you need to keep.

### 1.5 — Terminate the builder

```bash
aws ec2 terminate-instances --instance-ids "$BUILDER_ID" --region "$REGION"
unset BUILDER_ID BUILDER_IP
```

> **Resume after losing your shell:** to recover `$AMI_ID` later,
>
> ```bash
> export AMI_ID=$(aws ec2 describe-images --owners self --region "$REGION" \
>     --filters "Name=tag:Project,Values=nsb2026-workshop" \
>     --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
> ```

---

## Phase 2 — Day-of launch

Do this **June 7 evening** so there's a day to fix anything before students arrive.

### Session setup

```bash
# Carried forward:
export REGION=us-east-1
export KEY_NAME=gallant_mbp
export KEY_FILE=~/.ssh/gallant_mbp.pem
export SG_ID=sg-0d661b0ecfdeafb41
export AMI_ID=ami-082b5901888c9cc4d   # from Phase 1.4

# Phase 2 specifics:
export WORKSHOP_DOMAIN=workshop.efishgenomics.com   # the FQDN students will type into the browser
export ADMIN_EMAIL=jgallant@msu.edu  # for Let's Encrypt
```

### 2.1 — Allocate the Elastic IP and point DNS at it

```bash
# Allocate the EIP
EIP_JSON=$(aws ec2 allocate-address --domain vpc --region "$REGION" \
    --tag-specifications 'ResourceType=elastic-ip,Tags=[{Key=Project,Value=nsb2026-workshop}]')
export EIP_ALLOC_ID=$(echo "$EIP_JSON" | jq -r '.AllocationId')
export EIP_PUBLIC_IP=$(echo "$EIP_JSON" | jq -r '.PublicIp')
echo "EIP_ALLOC_ID=$EIP_ALLOC_ID"
echo "EIP_PUBLIC_IP=$EIP_PUBLIC_IP"
```

**Now go set your DNS A record**: `$WORKSHOP_DOMAIN` → `$EIP_PUBLIC_IP`. Then wait for propagation:

```bash
# Should return $EIP_PUBLIC_IP. Re-run every 30 sec until it does.
dig +short "$WORKSHOP_DOMAIN"
```

Don't move on until `dig` returns the right IP — `certbot` will fail if DNS isn't resolving yet.

### 2.2 — Personalize the cloud-init file

The cloud-init template has two placeholders that must be replaced before launch. This creates a one-shot personalized copy without modifying the source file:

```bash
sed -e "s/__WORKSHOP_DOMAIN__/$WORKSHOP_DOMAIN/g" \
    -e "s/__ADMIN_EMAIL__/$ADMIN_EMAIL/g" \
    bts/infrastructure/cloud_init.yaml \
    > /tmp/cloud_init_personalized.yaml
```

### 2.3 — Launch the workshop instance

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type r6i.4xlarge \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=300,VolumeType=gp3}' \
    --user-data file:///tmp/cloud_init_personalized.yaml \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=nsb2026-workshop},{Key=Project,Value=nsb2026-workshop}]' \
    --region "$REGION" \
    --query 'Instances[0].InstanceId' --output text)
echo "INSTANCE_ID=$INSTANCE_ID"

echo "Waiting for instance to start..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
```

### 2.4 — Associate the Elastic IP

```bash
aws ec2 associate-address \
    --instance-id "$INSTANCE_ID" \
    --allocation-id "$EIP_ALLOC_ID" \
    --region "$REGION"
```

The instance's public IP is now `$EIP_PUBLIC_IP`, matching the DNS record you set in 2.1.

### 2.5 — Wait for cloud-init to finish

```bash
# Give SSH a moment to come up after EIP association
sleep 30

ssh -i "$KEY_FILE" -o StrictHostKeyChecking=accept-new \
    ubuntu@"$WORKSHOP_DOMAIN" 'sudo cloud-init status --wait'
```

When this returns `status: done`, the student accounts have been created, the TLS cert has been issued, and nginx is live.

### 2.6 — Retrieve credentials

```bash
ssh -i "$KEY_FILE" ubuntu@"$WORKSHOP_DOMAIN" 'sudo cat /root/credentials.txt' \
    > workshop-creds.txt

ssh -i "$KEY_FILE" ubuntu@"$WORKSHOP_DOMAIN" 'sudo shred -u /root/credentials.txt'

cat workshop-creds.txt
```

Distribute the per-user passwords through a secure channel (in person, Signal, 1Password share). To force a password change at first login:

```bash
for u in student1 student2 student3 student4 student5 student6; do
    ssh -i "$KEY_FILE" ubuntu@"$WORKSHOP_DOMAIN" "sudo chage -d 0 $u"
done
```

> **Resume after losing your shell:** to recover `$INSTANCE_ID` and `$EIP_ALLOC_ID` later,
>
> ```bash
> export INSTANCE_ID=$(aws ec2 describe-instances --region "$REGION" \
>     --filters "Name=tag:Name,Values=nsb2026-workshop" "Name=instance-state-name,Values=running" \
>     --query 'Reservations[0].Instances[0].InstanceId' --output text)
> export EIP_ALLOC_ID=$(aws ec2 describe-addresses --region "$REGION" \
>     --filters "Name=tag:Project,Values=nsb2026-workshop" \
>     --query 'Addresses[0].AllocationId' --output text)
> ```

---

## Phase 3 — Smoke test (run before Friday June 12)

1. Browser → `https://$WORKSHOP_DOMAIN/` → RStudio login screen with a valid green padlock.
2. Log in as `student1` with the password from `workshop-creds.txt`.
3. In the Files pane, navigate to `~/ssrnaseq/`. Open `episodes/snrnaseq-qc.Rmd`.
4. In the R console, run:
   ```r
   renv::status()   # expect "synchronized with the lockfile"
   library(Seurat); library(harmony); library(speckle); library(DESeq2)
   ```
   No errors = good.
5. Open `episodes/normalize-reduce-cluster.Rmd` and run the first three chunks (load → SCTransform → PCA). In a parallel SSH session, watch peak RSS:
   ```bash
   ssh -i "$KEY_FILE" ubuntu@"$WORKSHOP_DOMAIN" htop
   ```
   Should hit ~10 GB and stay well below the 128 GB ceiling.
6. Open a second browser as `student2`; run the same chunks. Both finish without slowdown.

If anything fails, fix in `build_ami.sh`, rebuild the AMI (Phase 1), relaunch (Phase 2) — don't patch the running box.

---

## Phase 4 — Tear-down (June 14)

### Session setup

```bash
export REGION=us-east-1
export INSTANCE_ID=i-xxxxxxxxxxxxxxxxx   # or recover from the Phase 2 snippet
export EIP_ALLOC_ID=eipalloc-xxxxxxxxxxxxxxxxx
export AMI_ID=ami-xxxxxxxxxxxxxxxxx
```

### 4.1 — (Optional) snapshot student work

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

### 4.2 — Terminate the instance

```bash
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --region "$REGION"
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID" --region "$REGION"
```

### 4.3 — Release the Elastic IP

(Unattached EIPs cost $0.005/hr.)

```bash
aws ec2 release-address --allocation-id "$EIP_ALLOC_ID" --region "$REGION"
```

### 4.4 — Delete the DNS record

(Manual step in your DNS provider's console.)

### 4.5 — Deregister the AMI

Wait until you're sure you won't relaunch:

```bash
# Find the AMI's underlying snapshot first (so we can delete it after deregister)
export AMI_SNAPSHOT_ID=$(aws ec2 describe-images --image-ids "$AMI_ID" --region "$REGION" \
    --query 'Images[0].BlockDeviceMappings[?DeviceName==`/dev/sda1`].Ebs.SnapshotId' \
    --output text)
echo "AMI_SNAPSHOT_ID=$AMI_SNAPSHOT_ID"

aws ec2 deregister-image --image-id "$AMI_ID" --region "$REGION"
aws ec2 delete-snapshot --snapshot-id "$AMI_SNAPSHOT_ID" --region "$REGION"
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
