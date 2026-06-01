#!/usr/bin/env bash
#
# build_ami.sh — Bake a golden AMI for the NS&B 2026 snRNA-seq workshop.
#
# Run this once on a fresh Ubuntu 24.04 t3.medium EC2 instance (us-east-1).
# When it finishes successfully, snapshot the instance into an AMI and
# terminate the build host. The AMI is then launched as r6i.4xlarge on
# the day of the course (see cloud_init.yaml).
#
# Expected env vars (set before running):
#   LESSON_REPO_URL   git URL for the ss_rnaseq_nsb2026 repo (HTTPS or SSH)
#   RENV_LOCK_URL     (optional) HTTPS URL to renv.lock if it isn't committed
#                     in the repo yet. If unset, the script expects
#                     /opt/lesson/renv.lock to exist after `git clone`.
#
# Example:
#   sudo LESSON_REPO_URL=https://github.com/jrgallant/ss_rnaseq_nsb2026.git \
#        RENV_LOCK_URL=https://example.com/renv.lock \
#        bash build_ami.sh

set -euo pipefail

: "${LESSON_REPO_URL:?LESSON_REPO_URL must be set}"
RENV_LOCK_URL="${RENV_LOCK_URL:-}"
# GITHUB_PAT lifts the GitHub API rate limit (60/hr anonymous -> 5000/hr) so
# renv can resolve GitHub-sourced packages like presto without throttling.
# Generate a classic PAT with zero scopes — auth alone is enough.
GITHUB_PAT="${GITHUB_PAT:-}"
if [[ -z "$GITHUB_PAT" ]]; then
    echo "WARNING: GITHUB_PAT not set. renv may hit GitHub API rate limits." >&2
fi

LESSON_DIR=/opt/lesson
R_SITE_LIB=/opt/R/site-library
UBUNTU_CODENAME=noble
R_VERSION=4.4.3
# Pin to a P3M snapshot that has R 4.4 binaries for noble. "latest" would
# work too, but a dated snapshot gives reproducible builds across reruns.
P3M_CRAN_URL="https://packagemanager.posit.co/cran/__linux__/${UBUNTU_CODENAME}/2025-04-01"

log() { printf '[build_ami] %s\n' "$*"; }

###############################################################################
# 1. System libraries needed by the R package set
###############################################################################
log "Installing system libraries"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y --no-install-recommends \
    build-essential gfortran cmake \
    ca-certificates curl wget gnupg dirmngr software-properties-common \
    git rsync \
    libcurl4-openssl-dev libxml2-dev libssl-dev \
    libfontconfig1-dev libfreetype-dev libharfbuzz-dev libfribidi-dev \
    libpng-dev libtiff5-dev libjpeg-dev \
    libhdf5-dev libglpk-dev libbz2-dev liblzma-dev zlib1g-dev \
    libgit2-dev libsodium-dev libgeos-dev \
    nginx certbot python3-certbot-nginx \
    pwgen

###############################################################################
# 2. R ${R_VERSION} via rig (NOT the CRAN apt repo)
###############################################################################
# Ubuntu's CRAN apt repo serves whatever R version is current — as of late 2025
# that's R 4.6.x. The lockfile pins package versions that were authored against
# R 4.4 and use C symbols (R_NamespaceRegistry, old Rf_findVar signature) that
# R 4.6 removed. Installing R 4.4.x explicitly avoids that source-compilation
# mismatch and lets P3M serve binaries.
log "Installing R ${R_VERSION} via rig"
curl -Ls https://github.com/r-lib/rig/releases/download/latest/rig-linux-latest.tar.gz \
    | tar xz -C /usr/local
rig add "${R_VERSION}"
rig default "${R_VERSION}"

# Sanity check: confirm we have the version we asked for.
R --version | head -1
test "$(R --version | head -1 | awk '{print $3}')" = "${R_VERSION}" \
    || { echo "ERROR: R ${R_VERSION} did not install correctly"; exit 1; }

###############################################################################
# 3. Site-wide library + Rprofile pointing at Posit binary mirror
###############################################################################
log "Configuring system-wide R library and P3M binary mirror"
mkdir -p "$R_SITE_LIB"
chmod 0755 "$R_SITE_LIB"

# Write Rprofile.site to R_HOME/etc/Rprofile.site (the canonical location R
# reads on startup with no extra env vars). For rig-installed R this is
# /opt/R/${R_VERSION}/lib/R/etc/Rprofile.site.
R_HOME_DIR=$(R RHOME)
RPROFILE_SITE_PATH="${R_HOME_DIR}/etc/Rprofile.site"
log "Writing Rprofile.site to ${RPROFILE_SITE_PATH}"

cat > "$RPROFILE_SITE_PATH" <<RPROFILE
# Site-wide R configuration for the NS&B snRNA-seq workshop.
.libPaths(c("${R_SITE_LIB}", .libPaths()))

# Pin renv's package cache to a stable, root-owned path so it doesn't
# move based on which user (or sudo flag) launched R. The default
# location (~/.cache/R/renv) silently relocates when HOME changes.
Sys.setenv(RENV_PATHS_CACHE = "/opt/renv-cache")

# Posit Public Package Manager binary mirror. On Linux, P3M doesn't use
# R's binary repo machinery (which only supports macOS/Windows). Instead
# P3M serves PRE-COMPILED tarballs at the same src/contrib/ path that
# raw source tarballs live at, and identifies clients by User-Agent to
# decide which build to hand over. So the recipe is:
#   1. repos URL with the __linux__/<distro> path segment
#   2. HTTPUserAgent that tells P3M our OS (otherwise P3M sees "curl/X.Y"
#      and serves raw source)
# Do NOT set pkgType = "binary" — that throws "type 'binary' is not
# supported on this platform" on Linux. Leave pkgType at its default;
# R's source-install path will receive the pre-compiled tarball and
# install it without a compile step.
local({
  options(
    repos = c(CRAN = "${P3M_CRAN_URL}"),
    HTTPUserAgent = sprintf(
      "R/%s R (%s)",
      getRversion(),
      paste(getRversion(), R.version[["platform"]], R.version[["arch"]], R.version[["os"]])
    ),
    Ncpus = max(1L, parallel::detectCores() - 1L)
  )
})
RPROFILE

###############################################################################
# 4. RStudio Server Open Source
###############################################################################
log "Installing RStudio Server"
RSTUDIO_DEB_URL="https://download2.rstudio.org/server/jammy/amd64/rstudio-server-2024.12.1-563-amd64.deb"
# 2024.12.1 ships a jammy build that is forward-compatible with noble's libc.
# When a noble-native build is published, update this URL.
TMP_DEB=$(mktemp --suffix=.deb)
curl -fSL -o "$TMP_DEB" "$RSTUDIO_DEB_URL"
apt-get install -y "$TMP_DEB"
rm -f "$TMP_DEB"

# RStudio Server listens on 127.0.0.1:8787 only; nginx will reverse-proxy
# from :443 with HTTPS. This avoids exposing :8787 to the public internet.
# rsession-which-r pins RStudio to rig's R 4.4.x instead of any apt-installed R.
cat > /etc/rstudio/rserver.conf <<RSERVER
www-port=8787
www-address=127.0.0.1
auth-minimum-user-id=1000
rsession-which-r=/opt/R/${R_VERSION}/bin/R
RSERVER

systemctl enable rstudio-server
systemctl restart rstudio-server

###############################################################################
# 5. Clone the lesson repo into /opt/lesson
###############################################################################
log "Syncing lesson repo into ${LESSON_DIR}"
if [[ -d "${LESSON_DIR}/.git" ]]; then
    # Re-running on an AMI-baked instance: pull the latest commit.
    git -C "$LESSON_DIR" fetch --depth=1 origin
    git -C "$LESSON_DIR" reset --hard origin/HEAD
else
    rm -rf "$LESSON_DIR"
    git clone --depth=1 "$LESSON_REPO_URL" "$LESSON_DIR"
fi

# renv.lock may not be committed yet — fetch from URL if provided.
if [[ -n "$RENV_LOCK_URL" ]]; then
    log "Downloading renv.lock from ${RENV_LOCK_URL}"
    curl -fSL -o "${LESSON_DIR}/renv.lock" "$RENV_LOCK_URL"
fi

if [[ ! -f "${LESSON_DIR}/renv.lock" ]]; then
    echo "ERROR: ${LESSON_DIR}/renv.lock not found. Commit it to the repo or set RENV_LOCK_URL." >&2
    exit 1
fi

###############################################################################
# 6. Install the locked R package set into the system library
###############################################################################
log "Installing renv and restoring lockfile into ${R_SITE_LIB} (this is the slow step)"

# Pre-create the cache so the perms are root-owned and stable.
mkdir -p /opt/renv-cache
chmod 0755 /opt/renv-cache

# Env vars passed into R:
#   HOME=/root                          stable cache fallback
#   RENV_PATHS_CACHE=/opt/renv-cache    explicit cache location
#   RENV_CONFIG_INSTALL_STAGED=FALSE    finalize each package into the cache
#                                       as it installs, so a mid-run abort
#                                       doesn't waste hours of compile work
#   GITHUB_PAT                          GitHub API rate-limit lift
HOME=/root \
RENV_PATHS_CACHE=/opt/renv-cache \
RENV_CONFIG_INSTALL_STAGED=FALSE \
GITHUB_PAT="$GITHUB_PAT" \
R --no-save <<RSCRIPT
# --- Pre-flight: verify Rprofile.site options actually loaded ----------------
cat("=== R startup options ===\n")
cat("  repos           :", getOption("repos"), "\n")
cat("  HTTPUserAgent   :", getOption("HTTPUserAgent"), "\n")
cat("  RENV_PATHS_CACHE:", Sys.getenv("RENV_PATHS_CACHE"), "\n")
cat("=========================\n")

stopifnot(
  grepl("__linux__/", getOption("repos")[["CRAN"]], fixed = TRUE),
  !is.null(getOption("HTTPUserAgent"))
)

# --- Smoke test: P3M must serve pre-compiled tarballs, not raw source -------
# On Linux, P3M's "binaries" are pre-compiled tarballs delivered at the
# normal src/contrib path; the only way to tell from outside is timing.
# jsonlite has enough C code that a real source compile takes ~30-60s,
# while a P3M pre-built tarball installs in 1-3s.
smoke_lib <- tempfile("smoke-lib-"); dir.create(smoke_lib)
t0 <- Sys.time()
install.packages("jsonlite", lib = smoke_lib, quiet = TRUE)
elapsed <- as.numeric(Sys.time() - t0, units = "secs")
cat(sprintf("P3M smoke test: jsonlite installed in %.1fs\n", elapsed))
if (elapsed > 15) {
  stop(sprintf(
    "FATAL: jsonlite took %.1fs — too slow for a pre-compiled tarball. P3M is serving raw source. Check User-Agent and repos URL.",
    elapsed))
}
unlink(smoke_lib, recursive = TRUE)

# --- Install renv + BiocManager (these should now arrive as binaries) -------
install.packages("renv",        lib = "${R_SITE_LIB}")
install.packages("BiocManager", lib = "${R_SITE_LIB}")

# --- Restore into the system library so every PAM user inherits it ----------
renv::restore(
  project  = "${LESSON_DIR}",
  library  = "${R_SITE_LIB}",
  lockfile = "${LESSON_DIR}/renv.lock",
  prompt   = FALSE
)

# harmony and speckle are not in the lockfile per setup.md Step 3.
# Pre-installing them here means students never see the manual install step.
install.packages("harmony", lib = "${R_SITE_LIB}")
BiocManager::install("speckle", lib = "${R_SITE_LIB}", update = FALSE, ask = FALSE)

# --- Sanity check: every required package loads -----------------------------
required <- c("Seurat", "DESeq2", "harmony", "speckle", "limma",
              "clusterProfiler", "GO.db", "tidyverse", "patchwork",
              "glmGamPoi", "presto", "hdf5r")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) stop("Missing packages after restore: ", paste(missing, collapse = ", "))
message("All required packages installed.")
RSCRIPT

# Make the system library world-readable.
chmod -R a+rX "$R_SITE_LIB"

###############################################################################
# 7. nginx: drop the default site only
###############################################################################
# The actual rstudio site config is written by cloud-init at boot
# (in setup-nginx-tls.sh) because the server_name needs the workshop
# domain, which isn't known until launch. Earlier versions baked a
# template here and used a sentinel like __WORKSHOP_DOMAIN__; that
# collided with the same sentinel used by the launch-time sed pass
# over cloud_init.yaml, so the substitution silently no-op'd. Avoid.
log "Removing nginx default site"
rm -f /etc/nginx/sites-enabled/default

###############################################################################
# 8. Per-user setup hook (runs once per student account at first login of cloud-init)
###############################################################################
log "Installing per-user provisioning hook"
cat > /usr/local/sbin/provision-student.sh <<'PROV'
#!/usr/bin/env bash
# Usage: provision-student.sh <username>
# Copies the lesson into the user's home dir if not already there.
set -euo pipefail
user="$1"
home="/home/${user}"
target="${home}/ssrnaseq"

if [[ ! -d "$target" ]]; then
    rsync -a --exclude='renv/library' --exclude='_freeze' --exclude='.git' \
        /opt/lesson/ "$target/"
    chown -R "${user}:${user}" "$target"
fi
PROV
chmod 0755 /usr/local/sbin/provision-student.sh

###############################################################################
# 9. Cleanup
###############################################################################
log "Cleaning up apt caches and renv staging"
apt-get clean
rm -rf /var/lib/apt/lists/*
# Keep /opt/renv-cache so future rebuilds against this AMI (e.g. for a
# lockfile bump) restore from cache in seconds instead of redownloading
# every tarball. Costs a few GB of EBS snapshot — worth it.
rm -rf /root/.cache /tmp/Rtmp* "${LESSON_DIR}/renv/library" || true

log "Build complete. Now: snapshot this instance via 'aws ec2 create-image'."
log "Recommended AMI name: ss-rnaseq-nsb2026-$(date +%Y%m%d)"
