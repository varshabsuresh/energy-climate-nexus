# =============================================================================
# SCRIPT 04: COMPREHENSIVE ANALYSIS
# RWI + Electrification + Climate Hazards at ADM2 level
# =============================================================================
# This script combines three analytical layers at the department (ADM2) level:
#   1. Population-weighted Relative Wealth Index (RWI)
#   2. Newly electrified communities (2024-2025)
#   3. Population-weighted climate hazard exposure (drought, heat, flood, cyclone)
#
# DEPENDENCIES:
#   This script requires one object produced by a private data pipeline:
#     newly_electrified   sf point object
#       Settlements that moved from non-electrified (2024) to electrified
#       (2025). Required columns: population, total_hazards, geometry.
#       This object is not included in the public repository because the
#       underlying energy survey data is held by a government partner.
#       The full pipeline is maintained in a separate private repository.
#
#   If newly_electrified is not present, the script will still run and
#   produce all departmental-level maps; overlays are simply skipped.
#
#   All other inputs are loaded from open-source files in data/.
#
# DATA SOURCES:
#   - Meta RWI: https://data.humdata.org/dataset/relative-wealth-index
#   - WorldPop 2023 (100m): https://hub.worldpop.org
#   - Climate hazards (World Bank Reproducible Research Repository): https://reproducibility.worldbank.org/catalog/186
#   - World Bank boundaries: https://datacatalog.worldbank.org/dataset/world-bank-official-boundaries
#   - GADM ADM2 boundaries: https://gadm.org
#
# PROJECT STRUCTURE (here::here() anchors to the .Rproj file):
#
#   project_root/
#   ├── scripts/
#   │   └── 04_comprehensive_analysis.R    <- this file
#   ├── data/
#   │   ├── boundaries/
#   │   │   ├── wb_admin0/                 <- World Bank Admin 0 shapefile
#   │   │   └── adm2/                      <- ADM2 shapefile (NAM_0, NAM_1, NAM_2)
#   │   ├── climate/
#   │   │   ├── integrated_climate_hazard.tif
#   │   │   └── dou_haz4_cats.csv
#   │   └── socioeconomic/
#   │       ├── sen_pop_2023_100m.tif      <- WorldPop 2023 (100m resolution)
#   │       └── weighted_rwi/
#   │           └── sen_adm2_rwi_final.csv
#   └── outputs/
# =============================================================================

library(tidyverse)
library(sf)
library(terra)
library(exactextractr)
library(viridis)
library(patchwork)
library(here)
library(kableExtra)

sf_use_s2(FALSE)

cat("\n=== COMPREHENSIVE ELECTRIFICATION + RWI + CLIMATE ANALYSIS ===\n\n")

# =============================================================================
# 1. LOAD DATA
# =============================================================================

cat("Loading data...\n")

# RWI at ADM2 level
adm2_rwi_csv <- read_csv(
  here("data", "socioeconomic", "weighted_rwi", "sen_adm2_rwi_final.csv"),
  show_col_types = FALSE
)
cat(sprintf("  RWI data: %d departments\n", nrow(adm2_rwi_csv)))

# World Bank Admin 0 boundary (for Senegal outline)
wb_boundaries <- st_read(
  here("data", "boundaries", "wb_admin0", "WB_GAD_ADM0.shp"),
  quiet = TRUE
)
senegal_boundary <- wb_boundaries %>% filter(ISO_A3 == "SEN")

# ADM2 boundaries
adm2_files <- list.files(
  here("data", "boundaries", "adm2"),
  pattern = "\\.shp$", full.names = TRUE, ignore.case = TRUE
)
if (length(adm2_files) == 0) stop("No ADM2 shapefile found in data/boundaries/adm2/")

adm2_boundaries <- st_read(adm2_files[1], quiet = TRUE) %>%
  filter(NAM_0 == "Senegal") %>%
  st_transform(4326)

cat(sprintf("  Boundaries: %d departments\n", nrow(adm2_boundaries)))

# Newly electrified communities — optional (from private pipeline)
if (!exists("newly_electrified")) {
  rds_path <- here("outputs", "newly_elec_pop_weighted_rwi.rds")
  if (file.exists(rds_path)) {
    newly_electrified <- readRDS(rds_path)
    cat("  Loaded newly_electrified from outputs/ (local only, not in repo)\n")
  } else {
    cat("  [NOTE] newly_electrified not found — departmental maps will run,\n")
    cat("         electrification overlays and risk matrix will be skipped.\n")
    cat("         See README for details on the private data pipeline.\n")
    newly_electrified <- NULL
  }
} else {
  cat("  Using newly_electrified from environment\n")
}

if (!is.null(newly_electrified)) {
  newly_electrified <- st_transform(newly_electrified, 4326)
  cat(sprintf("  Newly electrified: %d communities\n", nrow(newly_electrified)))
}

# Climate hazard raster
climate_hazard <- rast(here("data", "climate", "integrated_climate_hazard.tif"))
climate_hazard <- crop(climate_hazard, senegal_boundary)
climate_hazard <- mask(climate_hazard, senegal_boundary)

# Hazard category lookup
hazard_cats <- read_csv(
  here("data", "climate", "dou_haz4_cats.csv"),
  show_col_types = FALSE
)

# Population raster (WorldPop 2023, 100m)
# Source: https://hub.worldpop.org
population_raster <- rast(
  here("data", "socioeconomic", "sen_pop_2023_100m.tif")
)
population_raster <- crop(population_raster, senegal_boundary)
population_raster <- mask(population_raster, senegal_boundary)

cat("  All data loaded\n")

# =============================================================================
# 2. PARSE HAZARD CATEGORIES AND CREATE BINARY RASTERS
# =============================================================================

cat("\nParsing climate hazard categories...\n")

hazard_parsed <- hazard_cats %>%
  mutate(
    hazard_pattern = str_extract(hazard, "(cyclone|0)_(drought|0)_(flood|0)_(heat|0)$"),
    hazard_parts   = str_split(hazard_pattern, "_"),
    has_cyclone    = map_lgl(hazard_parts, ~ .x[1] == "cyclone"),
    has_drought    = map_lgl(hazard_parts, ~ .x[2] == "drought"),
    has_flood      = map_lgl(hazard_parts, ~ .x[3] == "flood"),
    has_heat       = map_lgl(hazard_parts, ~ .x[4] == "heat"),
    dou_category   = str_remove(hazard, paste0("_", hazard_pattern, "$"))
  ) %>%
  select(-hazard_parts, -hazard_pattern)

create_hazard_raster <- function(hazard_df, hazard_type, base_raster) {
  hazard_col <- paste0("has_", hazard_type)
  reclass <- hazard_df %>%
    select(value, all_of(hazard_col)) %>%
    mutate(new_value = as.integer(.[[hazard_col]])) %>%
    select(value, value, new_value) %>%
    as.matrix()
  r <- classify(base_raster, reclass)
  names(r) <- paste0(hazard_type, "_exposure")
  return(r)
}

drought_raster <- create_hazard_raster(hazard_parsed, "drought", climate_hazard)
heat_raster    <- create_hazard_raster(hazard_parsed, "heat",    climate_hazard)
flood_raster   <- create_hazard_raster(hazard_parsed, "flood",   climate_hazard)
cyclone_raster <- create_hazard_raster(hazard_parsed, "cyclone", climate_hazard)

# climate_hazard and population_raster are not on the same grid (confirmed
# against real data: e.g. 5263x7419 vs 5262x7420 for Senegal) despite matching
# nominal resolution, so align the binary hazard layers onto the population
# grid before extraction. Nearest-neighbour preserves the 0/1 values exactly.
drought_raster <- resample(drought_raster, population_raster, method = "near")
heat_raster    <- resample(heat_raster,    population_raster, method = "near")
flood_raster   <- resample(flood_raster,   population_raster, method = "near")
cyclone_raster <- resample(cyclone_raster, population_raster, method = "near")

# =============================================================================
# 3. CALCULATE POPULATION-WEIGHTED HAZARD EXPOSURE AT ADM2
# =============================================================================

cat("\nCalculating climate hazard exposure at ADM2 level...\n")
cat("(vectorised via exactextractr — one pass over all departments)\n")

# NOTE: requires population_raster and the hazard rasters to share a grid —
# same assumption the previous crop/mask implementation made implicitly by
# concatenating values() vectors positionally. exact_extract() enforces this
# explicitly: c() on mismatched grids errors instead of silently misaligning.
calculate_adm2_hazards <- function(boundaries, hazard_rasters, pop_raster) {

  boundaries_proj <- st_transform(boundaries, crs(pop_raster))

  hazard_stack <- c(pop_raster, hazard_rasters$drought, hazard_rasters$heat,
                     hazard_rasters$flood, hazard_rasters$cyclone)
  names(hazard_stack) <- c("pop", "drought", "heat", "flood", "cyclone")

  summarise_dept <- function(values_df) {
    # a hazard value can be NA at population-covered edge cells introduced by
    # resampling; treat those as not-exposed rather than letting NA propagate
    # through sum() and silently blank out the whole department's percentage
    values_df <- values_df %>%
      filter(!is.na(pop), pop > 0) %>%
      mutate(across(c(drought, heat, flood, cyclone), ~ replace_na(.x, 0)))

    if (nrow(values_df) == 0) {
      return(data.frame(
        dept_population = 0,
        drought_exposed_pop = 0, heat_exposed_pop = 0,
        flood_exposed_pop = 0, cyclone_exposed_pop = 0,
        pct_drought = 0, pct_heat = 0, pct_flood = 0, pct_cyclone = 0,
        n_hazards = 0
      ))
    }

    total_pop <- sum(values_df$pop)
    data.frame(
      dept_population     = total_pop,
      drought_exposed_pop = sum(values_df$pop[values_df$drought == 1]),
      heat_exposed_pop    = sum(values_df$pop[values_df$heat    == 1]),
      flood_exposed_pop   = sum(values_df$pop[values_df$flood   == 1]),
      cyclone_exposed_pop = sum(values_df$pop[values_df$cyclone == 1]),
      pct_drought  = 100 * sum(values_df$pop[values_df$drought == 1]) / total_pop,
      pct_heat     = 100 * sum(values_df$pop[values_df$heat    == 1]) / total_pop,
      pct_flood    = 100 * sum(values_df$pop[values_df$flood   == 1]) / total_pop,
      pct_cyclone  = 100 * sum(values_df$pop[values_df$cyclone == 1]) / total_pop,
      n_hazards    = sum(values_df$drought == 1 | values_df$heat == 1 |
                           values_df$flood == 1 | values_df$cyclone == 1) / nrow(values_df)
    )
  }

  exact_extract(hazard_stack, boundaries_proj,
                fun = summarise_dept, summarize_df = TRUE, progress = TRUE)
}

adm2_hazards <- calculate_adm2_hazards(
  adm2_boundaries,
  list(drought = drought_raster, heat = heat_raster,
       flood = flood_raster,    cyclone = cyclone_raster),
  population_raster
)

cat("  Climate hazards calculated\n")

# =============================================================================
# 4. COMBINE ALL DATASETS
# =============================================================================

cat("\nCombining all datasets...\n")

adm2_combined <- adm2_boundaries %>%
  left_join(adm2_rwi_csv, by = c("NAM_1", "NAM_2")) %>%
  bind_cols(adm2_hazards) %>%
  mutate(
    wealth_category = case_when(
      is.na(pop_weighted_rwi)                                    ~ "No RWI Data",
      pop_weighted_rwi < -0.3                                    ~ "Low Wealth",
      pop_weighted_rwi >= -0.3 & pop_weighted_rwi < 0           ~ "Below Average",
      pop_weighted_rwi >= 0    & pop_weighted_rwi < 0.3         ~ "Above Average",
      pop_weighted_rwi >= 0.3                                    ~ "High Wealth"
    ),
    wealth_category = factor(wealth_category,
                             levels = c("Low Wealth", "Below Average",
                                        "Above Average", "High Wealth", "No RWI Data")),
    climate_risk = case_when(
      n_hazards >= 0.5 ~ "High Risk",
      n_hazards >= 0.3 ~ "Medium Risk",
      TRUE             ~ "Low Risk"
    ),
    climate_risk = factor(climate_risk, levels = c("Low Risk", "Medium Risk", "High Risk"))
  )

# Spatial join newly electrified to ADM2 context (if available)
if (!is.null(newly_electrified)) {
  newly_elec_adm2 <- st_join(
    newly_electrified,
    adm2_combined %>% select(NAM_1, NAM_2, pop_weighted_rwi,
                             pct_drought, pct_heat, pct_flood,
                             wealth_category, climate_risk),
    join = st_intersects,
    left = TRUE
  )
  cat(sprintf("  Matched %d newly electrified communities to departments\n",
              sum(!is.na(newly_elec_adm2$NAM_2))))
}

# =============================================================================
# 5. VISUALISATIONS
# =============================================================================

viridis_palette <- c("#440154", "#414487", "#2a788e", "#22a884", "#7ad151", "#fde725")

# Map 1: RWI by department (+ electrification overlay if available)
p1 <- ggplot() +
  geom_sf(data = adm2_combined, aes(fill = pop_weighted_rwi),
          color = "white", size = 0.2) +
  scale_fill_gradientn(colors = viridis_palette, name = "RWI",
                       na.value = "grey80", limits = c(-1, 1)) +
  labs(title    = "Population-Weighted Wealth Index by Department",
       subtitle = sprintf("%d departments | ADM2 level", nrow(adm2_combined))) +
  theme_void() +
  theme(plot.title    = element_text(face = "bold", hjust = 0.5, size = 14),
        plot.subtitle = element_text(hjust = 0.5, size = 10),
        legend.position = "right")

if (!is.null(newly_electrified)) {
  p1 <- p1 +
    geom_sf(data = newly_elec_adm2, aes(size = population),
            color = "red", alpha = 0.6, shape = 16) +
    scale_size_continuous(range = c(0.5, 3), name = "Newly Electrified\nPopulation") +
    labs(subtitle = sprintf("%d departments | %d newly electrified communities",
                            nrow(adm2_combined), nrow(newly_electrified)))
}

print(p1)

# Map 2: Climate risk by department (+ electrification overlay if available)
p2 <- ggplot() +
  geom_sf(data = adm2_combined, aes(fill = climate_risk),
          color = "white", size = 0.2) +
  scale_fill_manual(
    values = c("Low Risk" = "#2ca02c", "Medium Risk" = "#ff7f0e", "High Risk" = "#d62728"),
    name   = "Climate Risk",
    na.value = "grey80"
  ) +
  labs(title    = "Climate Risk by Department",
       subtitle = "Population exposure to multiple hazards") +
  theme_void() +
  theme(plot.title    = element_text(face = "bold", hjust = 0.5, size = 14),
        plot.subtitle = element_text(hjust = 0.5, size = 10),
        legend.position = "right")

if (!is.null(newly_electrified)) {
  p2 <- p2 +
    geom_sf(data = newly_elec_adm2, aes(size = population),
            color = "darkblue", alpha = 0.6, shape = 16) +
    scale_size_continuous(range = c(0.5, 3), name = "Newly Electrified\nPopulation")
}

print(p2)

# Maps 3a-c: Individual hazard exposure
p3a <- ggplot() +
  geom_sf(data = adm2_combined, aes(fill = pct_drought), color = "white", size = 0.2) +
  scale_fill_gradient(low = "white", high = "darkorange",
                      name = "% Pop\nExposed", limits = c(0, 100)) +
  labs(title = "Drought Exposure") +
  theme_void() +
  theme(plot.title = element_text(face = "bold", hjust = 0.5, size = 12))

p3b <- ggplot() +
  geom_sf(data = adm2_combined, aes(fill = pct_heat), color = "white", size = 0.2) +
  scale_fill_gradient(low = "white", high = "darkred",
                      name = "% Pop\nExposed", limits = c(0, 100)) +
  labs(title = "Heat Exposure") +
  theme_void() +
  theme(plot.title = element_text(face = "bold", hjust = 0.5, size = 12))

p3c <- ggplot() +
  geom_sf(data = adm2_combined, aes(fill = pct_flood), color = "white", size = 0.2) +
  scale_fill_gradient(low = "white", high = "darkblue",
                      name = "% Pop\nExposed", limits = c(0, 100)) +
  labs(title = "Flood Exposure") +
  theme_void() +
  theme(plot.title = element_text(face = "bold", hjust = 0.5, size = 12))

print((p3a | p3b | p3c) +
        plot_annotation(
          title    = "Climate Hazard Exposure by Department (ADM2)",
          subtitle = "Population-weighted exposure percentages",
          theme    = theme(
            plot.title    = element_text(face = "bold", hjust = 0.5, size = 14),
            plot.subtitle = element_text(hjust = 0.5, size = 10)
          )
        ))

# Map 4: Wealth vs climate risk matrix (only if newly electrified available)
if (!is.null(newly_electrified)) {

  risk_matrix <- newly_elec_adm2 %>%
    st_drop_geometry() %>%
    filter(!is.na(wealth_category), !is.na(climate_risk)) %>%
    group_by(wealth_category, climate_risk) %>%
    summarise(
      n_communities    = n(),
      total_population = sum(population, na.rm = TRUE),
      .groups = "drop"
    )

  p4 <- ggplot(risk_matrix,
               aes(x = wealth_category, y = climate_risk, fill = n_communities)) +
    geom_tile(color = "white", linewidth = 1) +
    geom_text(aes(label = paste0(n_communities, "\n(",
                                 format(total_population, big.mark = ","), " pop)")),
              size = 3.5, fontface = "bold") +
    scale_fill_gradient(low = "#fff7bc", high = "#d95f0e", name = "Communities") +
    labs(title = "Newly Electrified Communities: Wealth vs Climate Risk",
         x = "Wealth Level (RWI)", y = "Climate Risk Level") +
    theme_minimal() +
    theme(plot.title   = element_text(face = "bold", hjust = 0.5, size = 14),
          axis.text.x  = element_text(angle = 30, hjust = 1),
          legend.position = "right")

  print(p4)
}

# =============================================================================
# 6. STATISTICAL SUMMARIES
# =============================================================================

cat("\n=== STATISTICAL SUMMARIES ===\n\n")

cat("ADM2 LEVEL STATISTICS:\n")
cat(sprintf("  Total departments: %d\n", nrow(adm2_combined)))
cat(sprintf("  Total population:  %s\n",
            format(round(sum(adm2_combined$dept_population, na.rm = TRUE)), big.mark = ",")))

cat("\nCLIMATE EXPOSURE (POPULATION-WEIGHTED):\n")
total_pop <- sum(adm2_combined$dept_population, na.rm = TRUE)
cat(sprintf("  Drought: %.1f%% of population\n",
            100 * sum(adm2_combined$drought_exposed_pop, na.rm = TRUE) / total_pop))
cat(sprintf("  Heat:    %.1f%% of population\n",
            100 * sum(adm2_combined$heat_exposed_pop,    na.rm = TRUE) / total_pop))
cat(sprintf("  Flood:   %.1f%% of population\n",
            100 * sum(adm2_combined$flood_exposed_pop,   na.rm = TRUE) / total_pop))

if (!is.null(newly_electrified)) {
  cat("\nNEWLY ELECTRIFIED COMMUNITIES:\n")
  cat(sprintf("  Total communities: %d\n", nrow(newly_electrified)))
  cat(sprintf("  Total population:  %s\n",
              format(round(sum(newly_electrified$population, na.rm = TRUE)), big.mark = ",")))

  cat("\nBy Wealth Level:\n")
  print(newly_elec_adm2 %>%
          st_drop_geometry() %>%
          filter(!is.na(wealth_category)) %>%
          count(wealth_category) %>%
          mutate(pct = round(100 * n / sum(n), 1)))

  cat("\nBy Climate Risk:\n")
  print(newly_elec_adm2 %>%
          st_drop_geometry() %>%
          filter(!is.na(climate_risk)) %>%
          count(climate_risk) %>%
          mutate(pct = round(100 * n / sum(n), 1)))
}

# =============================================================================
# 7. SAVE OUTPUTS
# =============================================================================

dir.create(here("outputs"), showWarnings = FALSE)

# ADM2 combined dataset (no private data — safe to commit)
combined_csv <- here("outputs", "adm2_combined_analysis.csv")
adm2_combined %>%
  st_drop_geometry() %>%
  select(NAM_1, NAM_2, pop_weighted_rwi, wealth_category,
         dept_population, drought_exposed_pop, heat_exposed_pop, flood_exposed_pop,
         pct_drought, pct_heat, pct_flood, pct_cyclone,
         climate_risk, n_hazards) %>%
  write_csv(combined_csv)
cat(sprintf("\nSaved: %s\n", combined_csv))

# Newly electrified with context — excluded from repo (contains location data
# from private survey). Listed in .gitignore.
if (!is.null(newly_electrified)) {
  newly_elec_file <- here("outputs", "newly_electrified_with_context.csv")
  newly_elec_adm2 %>%
    st_drop_geometry() %>%
    select(population, total_hazards,
           NAM_1, NAM_2, pop_weighted_rwi, wealth_category,
           pct_drought, pct_heat, pct_flood, climate_risk) %>%
    write_csv(newly_elec_file)
  cat(sprintf("Saved: %s  [excluded from repo via .gitignore]\n", newly_elec_file))
}

cat("\n=== ANALYSIS COMPLETE ===\n")
