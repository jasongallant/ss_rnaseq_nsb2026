#!/usr/bin/env bash
#
# Rebuild the marker-explorer shinylive app and publish it to the public course
# CDN (S3 bucket "efish-nsb-data" behind d18e7eu8nurr5a.cloudfront.net).
#
# This is the one command to run after the source data or app.R changes. The
# bundle (~86 MB WASM runtime) is NOT committed to git; the live copy lives only
# on the CDN, and the lesson iframe in episodes/marker-explorer.qmd points at it.
#
# Usage (from the repo root):
#   bash bts/deploy_marker_explorer.sh           # re-export bundle + sync + invalidate
#   REGEN_CSVS=1 bash bts/deploy_marker_explorer.sh   # also rebuild the CSVs first
#
# Prereqs: aws CLI configured with write access to the bucket + CloudFront, and
# R with the `shinylive` package installed. Config (LECTURES_BUCKET,
# LECTURES_CF_DOMAIN) is read from bts/infrastructure/.env.

set -euo pipefail

# --- locate the repo root (this script lives in bts/) ------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${REPO_ROOT}"

# --- load config -------------------------------------------------------------
ENV_FILE="bts/infrastructure/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Copy the template and set LECTURES_BUCKET." >&2
  exit 1
fi
set -a; source "${ENV_FILE}"; set +a

: "${LECTURES_BUCKET:?Set LECTURES_BUCKET in ${ENV_FILE}}"
: "${LECTURES_CF_DOMAIN:?Set LECTURES_CF_DOMAIN in ${ENV_FILE}}"

SRC="episodes/files/marker-explorer"
APP_SRC="shiny/marker-explorer"
DEST="s3://${LECTURES_BUCKET}/apps/marker-explorer"

# --- (optional) regenerate the CSVs from the checkpoint ----------------------
if [[ "${REGEN_CSVS:-0}" == "1" ]]; then
  echo ">> Regenerating CSVs from the post-Harmony checkpoint..."
  Rscript bts/data_generation/export_marker_explorer.R
fi

# --- rebuild the shinylive bundle --------------------------------------------
echo ">> Exporting shinylive bundle (${APP_SRC} -> ${SRC})..."
Rscript -e "shinylive::export('${APP_SRC}', '${SRC}')"

# --- upload to S3 ------------------------------------------------------------
# --delete keeps the prefix in sync with the local build; exclude the unused
# shinylive editor build to save space.
echo ">> Syncing ${SRC} -> ${DEST} ..."
aws s3 sync "${SRC}" "${DEST}" --delete --exclude "edit/*"

# WASM needs the right content-type for streaming compilation; aws s3 sync does
# not always guess it. Re-stamp just the .wasm objects.
#
# NOTE: do NOT set Content-Encoding: gzip on library.data.gz — it is a literal
# file the webR runtime decompresses itself, not HTTP-gzip. aws s3 leaves
# Content-Encoding unset by default, which is correct; nothing to do here.
echo ">> Fixing content-type on .wasm objects..."
aws s3 cp "${DEST}" "${DEST}" --recursive --metadata-directive REPLACE \
  --exclude "*" --include "*.wasm" --content-type "application/wasm"

# --- invalidate CloudFront ---------------------------------------------------
# Resolve the distribution ID from the domain so there is no ID to maintain.
CF_HOST="${LECTURES_CF_DOMAIN%%.*}"   # e.g. d18e7eu8nurr5a
echo ">> Resolving CloudFront distribution for ${LECTURES_CF_DOMAIN} ..."
DIST_ID="$(aws cloudfront list-distributions \
  --query "DistributionList.Items[?contains(DomainName, '${CF_HOST}')].Id | [0]" \
  --output text)"

if [[ -z "${DIST_ID}" || "${DIST_ID}" == "None" ]]; then
  echo "ERROR: could not resolve a CloudFront distribution for ${LECTURES_CF_DOMAIN}." >&2
  echo "       Check LECTURES_CF_DOMAIN and your aws credentials/permissions." >&2
  exit 1
fi

echo ">> Invalidating /apps/marker-explorer/* on ${DIST_ID} ..."
aws cloudfront create-invalidation --distribution-id "${DIST_ID}" \
  --paths "/apps/marker-explorer/*" >/dev/null

echo ">> Done. Live at: https://${LECTURES_CF_DOMAIN}/apps/marker-explorer/index.html"
