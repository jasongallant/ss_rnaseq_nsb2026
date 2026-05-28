---
title: Setup
---

## Data

All data for this lesson are included in the lesson repository under `episodes/data/`.
No separate download is required if you have cloned or downloaded the repository.

Key data directories:

| Path | Contents |
|------|----------|
| `episodes/data/ssrnaseq_data/EO/` | 10X Cell Ranger filtered matrices for four electric organ samples (BB48, BB49INJ, BB50, BB50INJ) |
| `episodes/data/ssrnaseq_data/genes.gtf.gz` | *B. brachyistius* RefSeq GTF for gene annotation |
| `episodes/data/ssrnaseq_data/gene_ontology.gaf.gz` | GO annotation file for *B. brachyistius* |
| `episodes/data/eod_duration/` | JSON files of electric organ discharge recordings |

## Software Setup

This lesson requires **R** (≥ 4.3) and **RStudio** (≥ 2023.06). All R packages
are managed with `renv`; most will install automatically when you open the project.
Two packages need to be installed manually before running the final episode.

### Step 1 — Install R and RStudio

- [Download R](https://cran.r-project.org) for your operating system
- [Download RStudio Desktop](https://posit.co/download/rstudio-desktop/)

### Step 2 — Open the project and restore the renv environment

Open the `ss_rnaseq_nsb2026.Rproj` file in RStudio. When prompted, run:

```r
renv::restore()
```

This installs all packages recorded in the lockfile. It may take several minutes the
first time.

### Step 3 — Install harmony and speckle (for the final episode)

Two packages used in the "Hormone-Driven Gene Expression Changes" episode are not yet
in the default lockfile and must be installed once before running that episode:

```r
# harmony — batch correction (CRAN)
install.packages("harmony")

# speckle — differential cell-type abundance / propeller (Bioconductor)
if (!requireNamespace("BiocManager", quietly = TRUE))
  install.packages("BiocManager")
BiocManager::install("speckle")

# Record in renv after installing
renv::snapshot()
```

If `speckle` does not install cleanly in your environment, the differential abundance
section of the episode includes an automatic fallback to `limma` (already installed),
so the episode will still render without it.

### Step 4 — Verify the installation

Run the following in the R console to confirm key packages are available:

```r
required_pkgs <- c(
  "Seurat", "DESeq2", "harmony", "limma",
  "clusterProfiler", "GO.db", "tidyverse", "patchwork"
)
missing_pkgs <- required_pkgs[!sapply(required_pkgs, requireNamespace,
                                       quietly = TRUE)]
if (length(missing_pkgs) == 0) {
  message("All required packages are installed.")
} else {
  message("Missing packages: ", paste(missing_pkgs, collapse = ", "))
}
```

### Package version reference

| Package | Version used | Source |
|---------|-------------|--------|
| Seurat | 5.4.0 | CRAN |
| DESeq2 | 1.46.0 | Bioconductor |
| harmony | ≥ 1.2.0 | CRAN |
| speckle | ≥ 1.0.0 | Bioconductor |
| limma | 3.62.2 | Bioconductor |
| clusterProfiler | ≥ 4.10 | Bioconductor |
| GO.db | ≥ 3.18 | Bioconductor |
| tidyverse | ≥ 2.0 | CRAN |
| patchwork | ≥ 1.2 | CRAN |
| glmGamPoi | ≥ 1.14 | Bioconductor |
| presto | ≥ 1.0 | GitHub (immunogenomics/presto) |
