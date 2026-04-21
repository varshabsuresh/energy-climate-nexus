# Energy Access and Climate Vulnerability — Senegal

Analysing the intersection of rural electrification progress and climate risk in Senegal, using panel data from 2024–2025 energy surveys, open-source climate hazard rasters, and Meta's Relative Wealth Index.

## Research questions

1. Are communities that remain non-electrified disproportionately exposed to climate hazards (drought, heat, flood)?
2. Are newly electrified communities (2024–2025) located in poorer or wealthier departments?
3. Does electrification mode (grid, mini solar, solar home systems) correlate with climate risk?

## What this repository contains

| File | Description |
|------|-------------|
| `scripts/03_poverty_analysis.R` | Population-weighted RWI analysis at ADM1/ADM2 level; poverty targeting assessment for newly electrified communities |
| `scripts/04_comprehensive_analysis.R` | Combines RWI, climate hazard exposure, and electrification data at department level; produces the wealth × climate risk matrix |
| `outputs/adm2_combined_analysis.csv` | Aggregated departmental dataset (RWI + hazard exposure) — no private data |
| `data/README.md` | Data sources, licences, and download instructions |

## What is not included

Scripts 01 and 02 (data loading and cleaning) were built collaboratively and are maintained in a separate private repository. They process energy access survey data held by a government partner that cannot be shared publicly.

The object those scripts produce — `newly_electrified`, a set of ~N communities that transitioned from non-electrified to electrified between 2024 and 2025 — is the key input to scripts 03 and 04. Both scripts include a guard that explains what is needed if you want to run them with your own equivalent data.

All other inputs (climate hazards, population, RWI, boundaries) are open source. See `data/README.md` for sources.

## Data sources

| Dataset | Source | Licence |
|---------|--------|---------|
| Meta High Resolution Settlement Layer (population) | [HDX](https://data.humdata.org/dataset/highresolutionpopulationdensitymaps-sen) | CC BY |
| Meta Relative Wealth Index | [HDX](https://data.humdata.org/dataset/relative-wealth-index) | CC BY |
| WorldPop 2023 population (100m) | [WorldPop Hub](https://hub.worldpop.org) | CC BY |
| Integrated climate hazard raster | [ThinkHazard / GIRI](https://thinkhazard.org) | Open |
| Flood depth raster | [ThinkHazard](https://thinkhazard.org) | Open |
| DRE Atlas settlements | [DREA Senegal](https://www.drea.gouv.sn/) | Public download |
| World Bank Admin 0 boundaries | [World Bank](https://datacatalog.worldbank.org/dataset/world-bank-official-boundaries) | CC BY |
| GADM Admin 1/2 boundaries | [GADM](https://gadm.org) | Non-commercial |

## Setup

### Prerequisites

```r
install.packages(c(
  "tidyverse", "sf", "terra", "here",
  "viridis", "patchwork", "knitr", "kableExtra"
))
```

### Folder structure

```
energy-climate-vulnerability-africa/
├── energy-climate-vulnerability-africa.Rproj
├── scripts/
├── data/
│   ├── boundaries/
│   │   ├── wb_admin0/
│   │   ├── adm1/
│   │   └── adm2/
│   ├── climate/
│   └── socioeconomic/
│       └── weighted_rwi/
└── outputs/
```

Download the open-source datasets listed above and place them in the corresponding `data/` subdirectories. See `data/README.md` for exact filenames expected.

### Running the scripts

Open the `.Rproj` file in RStudio, then source the scripts in order:

```r
source(here::here("scripts", "03_poverty_analysis.R"))
source(here::here("scripts", "04_comprehensive_analysis.R"))
```

Scripts 03 and 04 will run fully for all departmental-level analysis. Visualisations that overlay newly electrified communities will be skipped if `newly_electrified` is not present in the environment.

## Methods note

RWI is aggregated from settlement-level point data to administrative boundaries using population weighting, so that the resulting score reflects where people live rather than a simple spatial average. Climate hazard exposure is similarly population-weighted: for each department, the percentage reported is the share of the modelled population living in an exposed pixel, not the share of land area.

## Contact

Questions or collaboration: open an issue or reach out via [LinkedIn]
