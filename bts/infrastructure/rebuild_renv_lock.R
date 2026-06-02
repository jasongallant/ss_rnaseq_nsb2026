#!/usr/bin/env Rscript
#
# rebuild_renv_lock.R — Rebuild renv.lock from scratch based on what the
# current .Rmd files actually use.
#
# Run on your Mac in the project root:
#   Rscript bts/infrastructure/rebuild_renv_lock.R
#
# What it does:
#   1. Bootstraps renv into a temp library OUTSIDE the project. This lets us
#      safely wipe renv/library/ without pulling the rug out from under the
#      running renv process (otherwise renv::init -> renv_imbue_self fails
#      with "could not find where 'renv' is installed").
#   2. Backs up the existing renv.lock to renv.lock.bak-<timestamp>.
#   3. Wipes renv/library/ so init builds a fresh closure.
#   4. Runs renv::init() — parses every .R/.Rmd/.qmd/.Rnw file in the
#      project, builds the dependency closure, installs into a new project
#      library, and writes a clean renv.lock.
#
# Why: renv.lock can accumulate orphan dependencies from deleted episodes
# and exploratory installs. A bloated lockfile directly increases AMI
# bake time (build_ami.sh restores every locked package). This script
# is the "clean reset".
#
# After it finishes:
#   - Inspect the diff: `git diff renv.lock` (expect a lot of removals)
#   - Run renv::status() to confirm clean
#   - Commit renv.lock
#   - Next AMI bake will be faster

# Project-root sanity check. Look for any marker that this is the right cwd
# rather than insisting renv.lock already exists (this script may be invoked
# specifically to recreate a missing lockfile).
if (!any(file.exists(c("renv.lock", "renv/activate.R", ".Rprofile", "_quarto.yml")))) {
  stop("Run from project root — none of renv.lock, renv/activate.R, .Rprofile, _quarto.yml found in cwd.")
}

# ---------------------------------------------------------------------------
# Step 0: bootstrap renv into a temp library outside the project.
#
# When R starts in a renv project, .Rprofile auto-sources renv/activate.R,
# which loads renv FROM renv/library/. If we later `unlink("renv/library")`,
# the loaded renv loses its own install path, and renv::init() fails inside
# renv_imbue_self() with "could not find where 'renv' is installed".
#
# Fix: install renv into a temp library, detach the in-project renv, reload
# from temp. Then wiping renv/library/ is safe.
# ---------------------------------------------------------------------------

bootstrap_lib <- tempfile("renv-bootstrap-")
dir.create(bootstrap_lib, recursive = TRUE)
cat(sprintf("Bootstrapping renv into %s ...\n", bootstrap_lib))

# Install renv into the temp lib. Use a clean repo (no Posit linux User-Agent
# fiddling needed on a Mac).
install.packages(
  "renv",
  lib   = bootstrap_lib,
  repos = "https://cloud.r-project.org",
  quiet = TRUE
)

# Drop any project-loaded renv so the next library() picks up the temp copy.
if ("renv" %in% loadedNamespaces()) {
  try(unloadNamespace("renv"), silent = TRUE)
}

# Put bootstrap lib first on the search path, then load.
.libPaths(c(bootstrap_lib, .libPaths()))
suppressPackageStartupMessages(library(renv, lib.loc = bootstrap_lib))

# Confirm renv is now resolved from the temp lib (not from renv/library/).
imbue_src <- find.package("renv")
cat(sprintf("renv loaded from: %s\n\n", imbue_src))

# ---------------------------------------------------------------------------
# Step 1: sanity check — show what dependencies() finds in the current files.
# ---------------------------------------------------------------------------
cat("=== Dependencies discovered in current .R/.Rmd files ===\n")
deps <- tryCatch(renv::dependencies(progress = FALSE), error = function(e) NULL)
if (is.null(deps) || nrow(deps) == 0) {
  cat("(no dependencies discovered — make sure you're in the project root)\n")
} else {
  pkgs <- sort(unique(deps$Package))
  cat(sprintf("%d direct packages referenced:\n", length(pkgs)))
  cat(paste("  -", pkgs), sep = "\n")
}
cat("=========================================================\n\n")

if (interactive()) {
  ans <- readline("Proceed with renv.lock rebuild? [y/N] ")
  if (!tolower(ans) %in% c("y", "yes")) {
    cat("Aborted.\n")
    quit(save = "no", status = 1)
  }
}

# ---------------------------------------------------------------------------
# Step 2: back up the existing lockfile, then nuke it and the project library.
# Now safe because renv is loaded from bootstrap_lib, not from renv/library/.
# ---------------------------------------------------------------------------
if (file.exists("renv.lock")) {
  bak <- sprintf("renv.lock.bak-%s", format(Sys.time(), "%Y%m%dT%H%M%S"))
  file.copy("renv.lock", bak)
  cat(sprintf("Backed up renv.lock -> %s\n", bak))
  unlink("renv.lock")
}

if (dir.exists("renv/library")) {
  unlink("renv/library", recursive = TRUE)
  cat("Removed renv/library/\n")
}

# ---------------------------------------------------------------------------
# Step 3: init from scratch.
# ---------------------------------------------------------------------------
cat("\nRunning renv::init() — this can take 20-60 min on first run...\n\n")
renv::init(bare = FALSE, restart = FALSE, force = TRUE)

# ---------------------------------------------------------------------------
# Step 4: install packages renv::init() can't resolve on its own.
#
# - `presto` is GitHub-only (immunogenomics/presto). install.packages() can't
#   find it. Needs renv::install("user/repo") which uses GITHUB_PAT.
# - "Recommended" packages (MASS, Matrix, cluster, codetools, KernSmooth,
#   lattice, nlme, survival) ship with base R and are normally provided by
#   the system R install. renv's library isolation hides the system copies
#   from the project, so renv flags them as missing even though they're
#   right there. Installing them into the project library makes the lockfile
#   self-contained (important for the AMI bake, which runs against a fresh R).
# ---------------------------------------------------------------------------
cat("\n=== Step 4: patching deps renv::init can't resolve ===\n")

cat("Installing presto from GitHub (immunogenomics/presto)...\n")
if (Sys.getenv("GITHUB_PAT") == "") {
  warning("GITHUB_PAT not set — GitHub API may rate-limit; presto install may fail.")
}
try(renv::install("immunogenomics/presto", prompt = FALSE), silent = FALSE)

recommended_pkgs <- c(
  "cluster", "codetools", "KernSmooth", "lattice",
  "MASS", "Matrix", "nlme", "survival"
)
cat(sprintf("Installing recommended packages (%s)...\n",
            paste(recommended_pkgs, collapse = ", ")))
try(renv::install(recommended_pkgs, prompt = FALSE), silent = FALSE)

# Re-snapshot to capture presto + recommended in the lockfile.
cat("\nRe-snapshotting to capture all installed packages in renv.lock...\n")
renv::snapshot(prompt = FALSE)

# Final status check — should report "synchronized".
cat("\n=== Final renv::status() ===\n")
renv::status()

cat("\n=== Done ===\n")
cat("Inspect the result:\n")
cat("  git diff renv.lock\n")
cat("\nThen commit renv.lock and rebake the AMI.\n")

# Clean up bootstrap lib — the new project library has its own renv now.
unlink(bootstrap_lib, recursive = TRUE)
