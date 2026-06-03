---
title: Setup
---

::: {.callout-note title="Questions"}

- How do I connect to the workshop RStudio server?
- Where do the workbook, the rendered episode, the data, and the checkpoints live in my session?
- How do I work in a notebook with `___` gaps without breaking everything?
- What do I do if I make a mistake mid-pipeline — re-run from scratch, or load a checkpoint?

:::

::: {.callout-tip title="Objectives"}

- Log in to the workshop RStudio server at `workshop.efishgenomics.com`.
- Locate the workshop project, workbooks, data, and checkpoints on the server.
- Open and run an R notebook workbook chunk by chunk.
- Recognize the `___` gap convention and the predict-first prompts.
- Load a pre-built checkpoint to skip past a slow step (or to recover from a broken state).

:::

## Connect to the workshop server

All hands-on work in this workshop happens on a shared RStudio Server that we run for the week. You do **not** need to install R, RStudio, or any packages on your laptop, and you do not need to download any data. Everything is pre-installed and pre-loaded on the server.

To connect:

1. Open a modern desktop browser (Chrome, Firefox, Safari, or Edge) on a stable wifi connection.
2. Open the **[workshop RStudio server](https://workshop.efishgenomics.com)**.
3. Log in with the username and one-time password the instructor hands out in person on Day 1. Usernames are of the form `student1`, `student2`, …, `student6`.
4. The first time you log in, you will be prompted to change your password. Pick something you can remember for the week — your account is wiped when the server is torn down on June 14.

::: {.callout-warning title="Trouble logging in?"}

- If the login page won't load at all, double-check the URL spelling and your network connection.
- If your username and password are rejected, ask the instructor — passwords can be reset on the spot.
- There is nothing to install locally, so if a teammate's browser works and yours doesn't, the problem is almost always a typo in the URL or a captive-portal wifi.

:::

## Welcome to the workshop server

Once you're logged in, you're inside a full RStudio session running on a shared Linux server. Seurat, DESeq2, Harmony, propeller, and everything else you'll need are pre-installed. You'll do all of Friday's and Saturday's hands-on work here — no need to install anything on your laptop.

Each of you has a personal home directory (`~/ssrnaseq/`) populated from the workshop's golden image. The same lesson content sits in every student's home; what you change in yours stays in yours.

When you log in, RStudio starts in `~/ssrnaseq/` and you should see **ssrnaseq** in the project indicator at the top-right of the window. If you don't (e.g. you switched projects earlier), open the **Files pane** and click `ssrnaseq.Rproj`. Working inside the project means relative paths like `data/checkpoints/02_harmony_clustered.rds` resolve from `~/ssrnaseq/` no matter which workbook chunk you're running — without the project context, a chunk inside `workbook/snrnaseq-preprocessing.Rmd` would look for `workbook/data/...` and fail.

## The Files pane: where everything lives

Open the **Files pane** (bottom-right) and navigate to `~/ssrnaseq/`. You should see:

```
~/ssrnaseq/
├── workbook/
│   ├── snrnaseq-preprocessing.Rmd      ← Friday's working surface (today)
│   └── snrnaseq-annotation-and-de.Rmd  ← Saturday's working surface
├── setup.md                            ← this document (writable local copy)
└── data/
    ├── ssrnaseq_data/                  ← Cell Ranger filtered counts + gtf (read-only)
    │   ├── EO/
    │   │   ├── BB48/ BB49INJ/ BB50/ BB50INJ/
    │   │   └── losilla_et_al_data.csv
    │   ├── Skin/  Midbrain/  Hindbrain/   ← extra tissues for special projects
    │   ├── genes.gtf.gz
    │   └── gene_ontology.gaf.gz
    ├── qc/                             ← Per-pool QC reports (read-only)
    │   ├── pool1_hindbrain/
    │   │   ├── outs/qc_report.html         ← Cell Ranger web summary
    │   │   ├── fastqc_fcA/                 ← FastQC HTMLs, flow cell A
    │   │   └── fastqc_fcB/                 ← FastQC HTMLs, flow cell B
    │   ├── pool2_midbrain/  pool3_eo/  pool4_skin/   ← same layout
    └── checkpoints/                    ← Pre-built .rds checkpoints (writable; per-student)
        ├── 01_merged_sct.rds
        ├── 02_harmony_clustered.rds    ← Saturday's entry state
        ├── 03_annotated.rds
        └── 04_pseudobulk_dds.rds
```

`data/ssrnaseq_data/` and `data/qc/` are symlinks into a shared read-only volume — anything in there is the same for everyone and cannot be modified. `data/checkpoints/` is your own writable copy, so you can overwrite the shipped `.rds` files freely as you progress.

::: {.callout-warning title="The website and the workbook are different files"}

The **rendered episodes** live at [tutorials.efishgenomics.com](https://tutorials.efishgenomics.com) — they are the **answer keys** with complete code and full explanations. Keep that tab open while you work.

The **workbooks** (`workbook/*.Rmd` on this server) are **your working surface**. They have the same overall structure as the rendered episodes, but with key decision points gapped out (`___`) and predict-first prompts before each one. **You work in the workbook on the server; you consult the rendered episode in your browser.**

:::

## Open the workbook

In the Files pane, navigate to `workbook/` and double-click `snrnaseq-preprocessing.Rmd`. It opens as an R Notebook in the Source pane.

::: {.callout-warning title="Don't click 'Render' or 'Knit' on the workbook"}

Workbooks are R Notebooks — they're meant to be **run chunk by chunk**, interactively. Clicking the **Render** or **Knit** button tries to execute every chunk in sequence, which will fail at the first `___` gap. Instead:

- Run a single chunk with the green ▶ button (top-right of the chunk) or **Cmd-Shift-Enter** / **Ctrl-Shift-Enter**.
- Run all chunks up to here with the small downward triangle to the left of the ▶.
- Output appears inline below the chunk.

:::

## The `___` gap convention

When you see `___` in a workbook chunk, that's a decision point you have to fill in:

```r
n_pcs <- ___
merged_seurat <- RunUMAP(merged_seurat, dims = 1:n_pcs)
```

If you run the chunk with `___` left in place, R errors out — by design. The error reminds you that this line is a place to think, not a line to skim.

The chunks with `___` also have `eval=FALSE` set in their chunk options. That means they're skipped if you try to render the whole notebook in one go — another guardrail against accidental "I clicked Knit and now everything broke" moments.

## The predict-first prompts

Before most gapped chunks there's a blockquote like this:

> **Predict first.** Looking at the elbow plot, where do you think the curve flattens — around PC 15? PC 25? Write your guess before running any code.
>
> _Your prediction:_

These exist because the analytical skill we're building is **judgment**, not typing. Predict, run, compare. If your prediction was wrong, the discrepancy is the most valuable feedback in the lesson.

## The checkpoint-load idiom

Each major preprocessing step is slow (SCTransform takes a few minutes; Harmony takes about a minute). If you make a mistake mid-pipeline and want to recover without re-running everything, **load the previous checkpoint**:

```r
merged_seurat <- readRDS("data/checkpoints/01_merged_sct.rds")
```

The checkpoints shipped on the server are the canonical state. If you've been making progress and want to save your own checkpoint mid-session, write to a different name so you don't overwrite the shipped ones:

```r
saveRDS(merged_seurat, "data/checkpoints/my_temp_state.rds")
```

::: {.callout-tip title="If Saturday catches you cold"}

If you missed Friday entirely, the first chunk of `workbook/snrnaseq-annotation-and-de.Rmd` loads the shipped `02_harmony_clustered.rds` and you can join Saturday's session with a known-good entry state. The same trick works mid-Saturday: if your annotation gets tangled, load `03_annotated.rds`.

:::

## Quick smoke test (5 min)

Once you're logged in, paste the following into the R console to confirm everything works end-to-end:

```r
# 1. Load Seurat
library(Seurat)

# 2. Load the shipped Friday checkpoint
seu <- readRDS("data/checkpoints/02_harmony_clustered.rds")

# 3. Confirm it loaded and inspect basic metadata
seu
table(seu$treatment)
```

If you see a Seurat object with 4 samples (`BB48`, `BB49INJ`, `BB50`, `BB50INJ`), ~2,900 nuclei total, and treatment labels (`11kt`, `vehicle`) splitting roughly evenly, you're good to go. If you see an error, raise a hand — we'll fix it before starting the Friday code episode.

## Installing your own packages for special projects

The "on rails" sessions use the pre-installed package set (Seurat, DESeq2, Harmony, propeller, tidyverse, and friends). For special-project work later in the week, you may want to install other packages. This is fully supported.

```r
install.packages("ggrepel")         # CRAN packages
BiocManager::install("scater")      # Bioconductor packages
```

The first time you run `install.packages()`, RStudio asks "Would you like to use a personal library?" — say **yes**. Your packages go into `~/R/x86_64-pc-linux-gnu-library/4.4/`, which is your own and doesn't affect anyone else. Subsequent installs go there automatically.

::: {.callout-tip title="If your package overrides a workshop one"}

The system library is searched before your personal library, so `library(Seurat)` always loads the locked workshop version (good — guarantees the on-rails sessions stay reproducible). If you specifically want **your** newer version to win:

```r
.libPaths(c(Sys.getenv("R_LIBS_USER"), .libPaths()))   # personal library first
library(Seurat)
```

This only affects the current R session.
:::

::: {.callout-warning title="If install fails with 'cannot find -lwhatever'"}

The R package needs a system library that isn't installed. Ask the instructor — they have `sudo` and can `apt install` what you need in 30 seconds. This is rare for the common Bioconductor packages but does come up occasionally for spatial/imaging/Stan packages.
:::

## Keypoints

1. You connect to the **[workshop RStudio server](https://workshop.efishgenomics.com)** with the username and password the instructor hands out. Nothing to install locally.
2. Your working surface is `workbook/*.Rmd` on the server. The rendered episodes at [tutorials.efishgenomics.com](https://tutorials.efishgenomics.com) are the answer keys you consult when stuck.
3. Run chunks one at a time — **never click "Render" or "Knit" on a workbook.**
4. `___` is a decision point. Fill it in based on the prediction prompt above it.
5. Checkpoints in `data/checkpoints/` let you skip past slow steps or recover from mistakes — load with `readRDS()`.
