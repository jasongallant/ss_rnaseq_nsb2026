#!/usr/bin/env bash
#
# build_data_volume.sh — Populate a fresh EBS volume with the workshop's
# bulk data (ssrnaseq_data + checkpoints + raw fastq/fastqc/cellranger),
# unmount it, and tell you the snapshot command to run.
#
# Run this ONCE on a builder t3.medium with:
#   * A fresh 500 GB EBS volume attached at DEVICE
#   * An IAM instance profile with s3:GetObject + s3:ListBucket on the bucket
#   * awscli installed (`apt install awscli`)
#
# The bucket should look like:
#   s3://${WORKSHOP_BUCKET}/data/
#     ├── ssrnaseq_data/...
#     ├── checkpoints/...
#     ├── raw/...
#     └── eod_duration/...    (optional)
#
# After the volume is populated, snapshot it; the snapshot ID is what
# cloud_init.yaml's mount step consumes (via volumes attached at launch).
#
# Example:
#   sudo WORKSHOP_BUCKET=efishgenomics-workshop \
#        DEVICE=/dev/nvme1n1 \
#        bash build_data_volume.sh

set -euo pipefail

: "${WORKSHOP_BUCKET:?WORKSHOP_BUCKET must be set}"
DEVICE="${DEVICE:-/dev/nvme1n1}"
MNT="${MNT:-/mnt/workshop-data}"

log() { printf '[build_data_volume] %s\n' "$*"; }

if [[ ! -b "$DEVICE" ]]; then
    echo "ERROR: ${DEVICE} is not a block device. Run \`lsblk\` and set DEVICE accordingly." >&2
    exit 1
fi

# Refuse to wipe a device that already has a filesystem unless explicitly forced.
if blkid "$DEVICE" >/dev/null 2>&1 && [[ "${FORCE:-}" != "1" ]]; then
    echo "ERROR: ${DEVICE} already has a filesystem:"
    blkid "$DEVICE"
    echo "Set FORCE=1 to overwrite (destroys all data on the device)." >&2
    exit 1
fi

log "Formatting ${DEVICE} as ext4"
mkfs.ext4 -L workshop-data "$DEVICE"

log "Mounting ${DEVICE} at ${MNT}"
mkdir -p "$MNT"
mount "$DEVICE" "$MNT"

log "Syncing s3://${WORKSHOP_BUCKET}/data/ -> ${MNT}/"
aws s3 sync "s3://${WORKSHOP_BUCKET}/data/" "$MNT/" --no-progress

log "Top-level contents:"
ls -la "$MNT/"

# Sanity check the expected top-level dirs.
missing=()
for d in ssrnaseq_data checkpoints; do
    [[ -d "$MNT/$d" ]] || missing+=("$d")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    echo "WARNING: missing expected top-level dirs: ${missing[*]}" >&2
    echo "         the workshop will fail to launch with this snapshot." >&2
fi

log "Unmounting ${MNT}"
sync
umount "$MNT"

cat <<NEXT

==========================================================================
Volume populated. To snapshot:

  # Find the volume ID (NOT the device name):
  aws ec2 describe-volumes \\
      --filters Name=attachment.instance-id,Values=\$(curl -s http://169.254.169.254/latest/meta-data/instance-id) \\
      --query 'Volumes[?Attachments[0].Device==\`${DEVICE}\`].VolumeId' \\
      --output text

  # Create snapshot:
  aws ec2 create-snapshot \\
      --volume-id <vol-id> \\
      --description "ss-rnaseq-data \$(date +%Y%m%d)" \\
      --tag-specifications 'ResourceType=snapshot,Tags=[{Key=Name,Value=ss-rnaseq-data}]'

When the snapshot is 'completed', detach + delete the source volume and
record the snapshot ID for cloud_init's launch flow.
==========================================================================
NEXT
