#!/usr/bin/env bash
#
# build_ami.sh — Bake a golden AMI for the NS&B 2026 snRNA-seq workshop.
#
# Run this once on a fresh Ubuntu 24.04 t3.medium EC2 instance (us-east-1).
# When it finishes successfully, snapshot the instance into an AMI and
# terminate the build host. The AMI is then launched as r6i.4xlarge on
# the day of the course (see cloud_init.yaml).
#
# The AMI is intentionally "R environment only": OS + system libs + R 4.4 +
# the locked R package set + RStudio Server + nginx + certbot + AWS CLI v2 +
# provision/refresh scripts. It contains NO lesson content. Workbooks and
# bulk data are delivered at launch (S3 sync + mounted EBS snapshot — see
# cloud_init.yaml). This lets you fix typos in workbooks without rebaking.
#
# Expected env vars (set before running):
#   RENV_LOCK_URL     HTTPS URL to renv.lock, e.g.
#                     https://raw.githubusercontent.com/<user>/<repo>/main/renv.lock
#   GITHUB_PAT        (optional) classic PAT with zero scopes to lift the
#                     GitHub API rate limit so renv can resolve GitHub-sourced
#                     packages like presto without throttling.
#
# Example:
#   sudo RENV_LOCK_URL=https://raw.githubusercontent.com/jrgallant/ss_rnaseq_nsb2026/main/renv.lock \
#        GITHUB_PAT=ghp_... \
#        bash build_ami.sh

set -euo pipefail

: "${RENV_LOCK_URL:?RENV_LOCK_URL must be set (HTTPS URL to renv.lock)}"
GITHUB_PAT="${GITHUB_PAT:-}"
if [[ -z "$GITHUB_PAT" ]]; then
    echo "WARNING: GITHUB_PAT not set. renv may hit GitHub API rate limits." >&2
fi

RENV_LOCK_PATH=/opt/renv.lock
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
# The first block (build-essential through libgeos-dev) covers Seurat/DESeq2/
# Harmony/tidyverse. The second block widens the net for student-installed
# packages during special-projects week (sf, terra, magick, gsl, netCDF,
# cairo) — costs ~5 min of bake time, zero runtime overhead, and saves the
# instructor from sudo apt-installing dev libraries during the workshop.
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
    libudunits2-dev libgdal-dev libproj-dev libgsl-dev \
    libmagick++-dev libgmp-dev libmpfr-dev libnetcdf-dev libcairo2-dev \
    nginx certbot python3-certbot-nginx \
    unzip pwgen

###############################################################################
# 1b. AWS CLI v2 (official installer — noble's apt repo no longer ships awscli)
###############################################################################
log "Installing AWS CLI v2"
AWSCLI_TMP=$(mktemp -d)
curl -fSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" \
    -o "${AWSCLI_TMP}/awscliv2.zip"
unzip -q "${AWSCLI_TMP}/awscliv2.zip" -d "$AWSCLI_TMP"
"${AWSCLI_TMP}/aws/install" --update
rm -rf "$AWSCLI_TMP"
aws --version

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

# Auto-open the ssrnaseq project on first RStudio login. RStudio's
# restore_last_project preference doesn't fire on a true first login (no
# prior session to restore from), so without this hook students land in
# "(None)" and have to click ssrnaseq.Rproj manually. The hook short-
# circuits if a project is already attached, so the openProject-triggered
# session restart doesn't loop.
setHook("rstudio.sessionInit", function(newSession) {
  if (!isTRUE(newSession)) return(invisible())
  proj <- path.expand("~/ssrnaseq")
  if (!dir.exists(proj)) return(invisible())
  if (!requireNamespace("rstudioapi", quietly = TRUE)) return(invisible())
  if (!is.null(rstudioapi::getActiveProject())) return(invisible())
  rstudioapi::openProject(proj, newSession = FALSE)
}, action = "append")
RPROFILE

# Bump the default C++ standard for any source builds. Some packages (notably
# glmGamPoi from Bioconductor, which P3M's CRAN mirror doesn't carry as a
# binary) still declare CXX_STD = CXX11. Those builds fail against modern
# RcppArmadillo, which dropped C++11 and requires C++14+. Overriding
# CXX11STD here makes "C++11 mode" actually compile as gnu++17 — satisfies
# Armadillo without patching every offending package upstream.
MAKEVARS_SITE_PATH="${R_HOME_DIR}/etc/Makevars.site"
log "Writing Makevars.site to ${MAKEVARS_SITE_PATH}"
cat > "$MAKEVARS_SITE_PATH" <<'MAKEVARS'
CXX11STD = -std=gnu++17
MAKEVARS

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

# session-default-working-dir is read by rsession (per-R-session), NOT by
# rserver — putting it in rserver.conf makes the server refuse to start.
# Relative path resolves against each user's $HOME.
cat > /etc/rstudio/rsession.conf <<'RSESSION'
session-default-working-dir=ssrnaseq
RSESSION

# System-wide RStudio user preference: chunks evaluate in the project root
# (i.e., ~/ssrnaseq/) instead of the document directory. Without this, a
# chunk inside ~/ssrnaseq/workbook/foo.Rmd executes with CWD = workbook/,
# breaking relative paths like "data/ssrnaseq_data/...". Per-user prefs
# in ~/.config/rstudio/ override this if a student tweaks them.
cat > /etc/rstudio/rstudio-prefs.json <<'PREFS'
{
  "knit_working_dir": "project",
  "save_workspace": "never",
  "load_workspace": false
}
PREFS

systemctl enable rstudio-server
systemctl restart rstudio-server

###############################################################################
# 5. Fetch renv.lock (no full repo clone — content is delivered at launch)
###############################################################################
log "Fetching renv.lock from ${RENV_LOCK_URL}"
curl -fSL -o "$RENV_LOCK_PATH" "$RENV_LOCK_URL"
test -s "$RENV_LOCK_PATH" || { echo "ERROR: ${RENV_LOCK_PATH} empty"; exit 1; }

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
# renv::restore needs a project dir; we pass /opt as a throwaway since
# everything we care about is the lockfile + the target library.
renv::restore(
  project  = "/opt",
  library  = "${R_SITE_LIB}",
  lockfile = "${RENV_LOCK_PATH}",
  prompt   = FALSE
)

# --- Sanity check: every required package loads -----------------------------
# Keep this list aligned with what the current .Rmd files actually `library()`.
# When you delete an episode and rebuild renv.lock, also prune from this list
# (clusterProfiler, GO.db, hdf5r used to live here for episodes that no longer
# exist).
required <- c("Seurat", "DESeq2", "harmony", "speckle", "limma",
              "tidyverse", "patchwork", "glmGamPoi", "presto")
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
# domain, which isn't known until launch.
log "Removing nginx default site"
rm -f /etc/nginx/sites-enabled/default

###############################################################################
# 8. Per-user provisioning hook (runs once per student account at first login)
###############################################################################
# Layout this script produces in each student's home:
#   ~/ssrnaseq/
#   ├── workbook/                            (writable copy from /srv/workshop-content/workbooks/)
#   ├── setup.md                             (writable copy from /srv/workshop-content/setup.md)
#   └── data/
#       ├── ssrnaseq_data → /srv/workshop-data/ssrnaseq_data    (symlink, RO mount)
#       ├── raw           → /srv/workshop-data/raw              (symlink, RO mount)
#       ├── eod_duration  → /srv/workshop-data/eod_duration     (symlink, RO mount; if present)
#       └── checkpoints/                                          (writable per-student copy)
#
# Why copy workbooks and checkpoints but symlink ssrnaseq_data and raw:
# students edit workbooks (fill in `___` gaps) and overwrite checkpoints
# (saveRDS), so those need to be writable per-student. The bulk read-only
# data is shared via symlinks to avoid duplicating hundreds of GB.
log "Installing per-user provisioning hook"
cat > /usr/local/sbin/provision-student.sh <<'PROV'
#!/usr/bin/env bash
# Usage: provision-student.sh <username>
# Populates ~/ssrnaseq/ from the mounted data volume and synced content.
set -euo pipefail
user="$1"
home="/home/${user}"
target="${home}/ssrnaseq"

# Idempotent: never clobber an existing home. Mid-week updates go through
# refresh-workbooks.sh instead, which preserves student edits via --backup.
[[ -d "$target" ]] && exit 0

CONTENT=/srv/workshop-content
DATA=/srv/workshop-data

# Sanity check: both must be populated before we provision anyone.
[[ -d "$CONTENT/workbooks" ]] || { echo "ERROR: $CONTENT/workbooks missing — content S3 sync didn't run?"; exit 1; }
[[ -d "$DATA/ssrnaseq_data" ]] || { echo "ERROR: $DATA/ssrnaseq_data missing — data volume not mounted?"; exit 1; }

mkdir -p "$target/data"

# Workbooks + setup.md: per-student writable copies.
cp -r "$CONTENT/workbooks" "$target/workbook"
[[ -f "$CONTENT/setup.md" ]] && cp "$CONTENT/setup.md" "$target/setup.md"

# Read-only data: symlinks into the mounted volume.
ln -s "$DATA/ssrnaseq_data" "$target/data/ssrnaseq_data"
[[ -d "$DATA/raw" ]]          && ln -s "$DATA/raw"          "$target/data/raw"
[[ -d "$DATA/eod_duration" ]] && ln -s "$DATA/eod_duration" "$target/data/eod_duration"

# Checkpoints: per-student writable copy, pre-populated from the volume's baselines.
if [[ -d "$DATA/checkpoints" ]]; then
    cp -r "$DATA/checkpoints" "$target/data/checkpoints"
else
    mkdir -p "$target/data/checkpoints"
fi

# Drop an RStudio project file so chunks in any Rmd under ~/ssrnaseq/
# execute with CWD = ~/ssrnaseq/. Combined with the system-wide
# "knit_working_dir: project" pref, this makes paths like
# "data/ssrnaseq_data/..." work uniformly from console and chunk.
cat > "$target/ssrnaseq.Rproj" <<'RPROJ'
Version: 1.0

RestoreWorkspace: No
SaveWorkspace: No
AlwaysSaveHistory: Default

EnableCodeIndexing: Yes
UseSpacesForTab: Yes
NumSpacesForTab: 2
Encoding: UTF-8

RnwWeave: knitr
LaTeX: pdfLaTeX

AutoAppendNewline: Yes
StripTrailingWhitespace: Yes

KnitWorkingDir: Project
RPROJ

# Seed the project MRU so RStudio's restore_last_project (default true)
# auto-attaches the project on first login. Without this, students land in
# (None) and have to click ssrnaseq.Rproj in the Files pane themselves.
state_dir="/home/${user}/.local/share/rstudio/monitored/lists"
mkdir -p "$state_dir"
echo '~/ssrnaseq/ssrnaseq.Rproj' > "$state_dir/project_mru"
chown -R "${user}:${user}" "/home/${user}/.local"

chown -R "${user}:${user}" "$target"
PROV
chmod 0755 /usr/local/sbin/provision-student.sh

###############################################################################
# 9. Mid-week refresh hook (instructor runs this to push workbook fixes)
###############################################################################
# Pulls latest content from S3 and rsyncs into each student's ~/ssrnaseq/
# with --backup so any local edits are preserved in ~/ssrnaseq/.workbook-backups/.
log "Installing refresh-workbooks hook"
cat > /usr/local/sbin/refresh-workbooks.sh <<'REFRESH'
#!/usr/bin/env bash
# /usr/local/sbin/refresh-workbooks.sh — push workbook updates to all students.
# Reads WORKSHOP_BUCKET from /etc/workshop.env (set by cloud-init).
set -euo pipefail

if [[ ! -f /etc/workshop.env ]]; then
    echo "ERROR: /etc/workshop.env not found (set by cloud-init at first boot)" >&2
    exit 1
fi
# shellcheck disable=SC1091
source /etc/workshop.env
: "${WORKSHOP_BUCKET:?WORKSHOP_BUCKET not set in /etc/workshop.env}"

CONTENT=/srv/workshop-content
mkdir -p "$CONTENT"

aws s3 sync "s3://${WORKSHOP_BUCKET}/content/" "$CONTENT/" --delete

stamp=$(date +%Y%m%dT%H%M%S)
for user in student1 student2 student3 student4 student5 student6 instructor; do
    home="/home/${user}/ssrnaseq"
    [[ -d "$home" ]] || continue
    backup="${home}/.workbook-backups/${stamp}"
    mkdir -p "$backup"
    # rsync --backup moves overwritten/deleted files into the backup dir;
    # student work in progress is never silently lost.
    rsync -a --backup --backup-dir="$backup" \
        "$CONTENT/workbooks/" "$home/workbook/"
    if [[ -f "$CONTENT/setup.md" ]]; then
        rsync -a --backup --backup-dir="$backup" \
            "$CONTENT/setup.md" "$home/setup.md"
    fi
    chown -R "${user}:${user}" "$home/workbook" "$home/.workbook-backups"
    [[ -f "$home/setup.md" ]] && chown "${user}:${user}" "$home/setup.md"
    echo "refreshed: $user (backups: $backup if any)"
done
REFRESH
chmod 0755 /usr/local/sbin/refresh-workbooks.sh

###############################################################################
# 10. Cleanup
###############################################################################
log "Cleaning up apt caches and renv staging"
apt-get clean
rm -rf /var/lib/apt/lists/*
# Keep /opt/renv-cache so future rebuilds against this AMI (e.g. for a
# lockfile bump) restore from cache in seconds instead of redownloading
# every tarball. Costs a few GB of EBS snapshot — worth it.
rm -rf /root/.cache /tmp/Rtmp* || true

log "Build complete. Now: snapshot this instance via 'aws ec2 create-image'."
log "Recommended AMI name: ss-rnaseq-nsb2026-$(date +%Y%m%d)"
