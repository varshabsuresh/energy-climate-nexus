# =============================================================================
# SCRIPT 03: POVERTY ANALYSIS
# Using population-weighted RWI at ADM1 / ADM2 level
# =============================================================================
# This script analyses whether newly electrified communities in Senegal are
# located in poorer or wealthier departments, using Meta's Relative Wealth
# Index (RWI) aggregated to administrative boundaries and weighted by
# population.
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
#   All other inputs are loaded directly from open-source files in data/.
#
# DATA SOURCES:
#   - Meta Relative Wealth Index: https://data.humdata.org/dataset/relative-wealth-index
#   - GADM / SALB admin boundaries: https://gadm.org
#
# PROJECT STRUCTURE (here::here() anchors to the .Rproj file):
#
#   project_root/
#   ├── scripts/
#   │   └── 03_poverty_analysis.R      <- this file
#   ├── data/
#   │   ├── boundaries/
#   │   │   ├── adm1/                  <- ADM1 shapefile (NAM_0, NAM_1 columns)
#   │   │   └── adm2/                  <- ADM2 shapefile (NAM_0, NAM_1, NAM_2)
#   │   └── socioeconomic/
#   │       └── weighted_rwi/
#   │           ├── sen_adm1_rwi.csv   <- pop-weighted RWI at region level
#   │           └── sen_adm2_rwi.csv   <- pop-weighted RWI at dept level
#   └── outputs/
# =============================================================================

library(tidyverse)
library(sf)
library(here)
library(kableExtra)
library(patchwork)

sf_use_s2(FALSE)

# =============================================================================
# GUARD: confirm private object exists
# =============================================================================

if (!exists("newly_electrified")) {
  stop(
    "\n\n",
    "===========================================================\n",
    "  MISSING OBJECT: newly_electrified\n",
    "===========================================================\n",
    "  This object is produced by a private data pipeline that\n",
    "  uses restricted government energy survey data.\n",
    "  It is not included in this public repository.\n",
    "  See the README for details.\n",
    "===========================================================\n\n"
  )
}

# =============================================================================
# 1. LOAD POPULATION-WEIGHTED RWI DATA
# =============================================================================

cat("\n=== LOADING POPULATION-WEIGHTED RWI DATA ===\n")

adm1_rwi_csv <- read_csv(
  here("data", "socioeconomic", "weighted_rwi", "sen_adm1_rwi.csv"),
  show_col_types = FALSE
)

adm2_rwi_csv <- read_csv(
  here("data", "socioeconomic", "weighted_rwi", "sen_adm2_rwi.csv"),
  show_col_types = FALSE
)

cat(sprintf("Loaded ADM1 RWI data: %d regions\n",    nrow(adm1_rwi_csv)))
cat(sprintf("Loaded ADM2 RWI data: %d departments\n", nrow(adm2_rwi_csv)))

# =============================================================================
# 2. LOAD ADMINISTRATIVE BOUNDARIES
# =============================================================================

cat("\nLoading boundary shapefiles...\n")

# ADM1 (regions)
adm1_files <- list.files(
  here("data", "boundaries", "adm1"),
  pattern = "\\.shp$", full.names = TRUE, ignore.case = TRUE
)
if (length(adm1_files) == 0) stop("No ADM1 shapefile found in data/boundaries/adm1/")

adm1_boundaries <- st_read(adm1_files[1], quiet = TRUE) %>%
  filter(NAM_0 == "Senegal") %>%
  st_transform(4326)

# ADM2 (departments)
adm2_files <- list.files(
  here("data", "boundaries", "adm2"),
  pattern = "\\.shp$", full.names = TRUE, ignore.case = TRUE
)
if (length(adm2_files) == 0) stop("No ADM2 shapefile found in data/boundaries/adm2/")

adm2_boundaries <- st_read(adm2_files[1], quiet = TRUE) %>%
  filter(NAM_0 == "Senegal") %>%
  st_transform(4326)

cat(sprintf("Loaded ADM1 boundaries: %d regions\n",    nrow(adm1_boundaries)))
cat(sprintf("Loaded ADM2 boundaries: %d departments\n", nrow(adm2_boundaries)))

# Join RWI to boundaries
adm1_rwi <- adm1_boundaries %>% left_join(adm1_rwi_csv, by = "NAM_1")
adm2_rwi <- adm2_boundaries %>% left_join(adm2_rwi_csv, by = c("NAM_1", "NAM_2"))

senegal_boundary <- st_union(adm1_boundaries)

# =============================================================================
# 3. OVERALL SENEGAL RWI STATISTICS
# =============================================================================

cat("\n=== OVERALL SENEGAL RWI DISTRIBUTION ===\n")

overall_stats <- adm1_rwi %>%
  st_drop_geometry() %>%
  summarise(
    Total_Regions         = n(),
    Total_Population      = sum(total_population, na.rm = TRUE),
    Mean_Pop_Weighted_RWI = weighted.mean(pop_weighted_rwi, total_population, na.rm = TRUE),
    Median_RWI            = median(pop_weighted_rwi, na.rm = TRUE),
    Regions_Below_Zero    = sum(pop_weighted_rwi < 0, na.rm = TRUE),
    Pct_Regions_Poor      = 100 * sum(pop_weighted_rwi < 0, na.rm = TRUE) / n()
  ) %>%
  mutate(across(where(is.numeric), ~ round(., 3)))

print(overall_stats)

pop_in_poor_regions <- adm1_rwi %>%
  st_drop_geometry() %>%
  filter(pop_weighted_rwi < 0) %>%
  summarise(pop = sum(total_population, na.rm = TRUE)) %>%
  pull(pop)

pct_pop_in_poor_regions <- 100 * pop_in_poor_regions / overall_stats$Total_Population

cat(sprintf(
  "\n%.1f%% of Senegal's population lives in below-average wealth regions\n",
  pct_pop_in_poor_regions
))

# =============================================================================
# 4. SPATIAL MATCHING — JOIN NEWLY ELECTRIFIED TO ADM2
# =============================================================================

cat("\n=== SPATIAL MATCHING (ADM2 LEVEL) ===\n")

newly_electrified_wgs84 <- newly_electrified %>% st_transform(4326)

newly_electrified_rwi <- st_join(
  newly_electrified_wgs84,
  adm2_rwi %>% select(
    admin1           = NAM_1,
    admin2           = NAM_2,
    rwi_score        = pop_weighted_rwi,
    dept_population  = total_population,
    dept_settlements = n_settlements
  ),
  join = st_intersects,
  left = TRUE
)

matched_count <- sum(!is.na(newly_electrified_rwi$rwi_score))
match_rate    <- 100 * matched_count / nrow(newly_electrified_rwi)

cat(sprintf("Newly electrified communities: %d\n",       nrow(newly_electrified)))
cat(sprintf("Matched to departments: %d (%.1f%%)\n",     matched_count, match_rate))

# Assign wealth categories
# RWI interpretation: < 0 = below average, > 0 = above average
newly_electrified_rwi <- newly_electrified_rwi %>%
  mutate(
    wealth_category = case_when(
      is.na(rwi_score)  ~ "Unknown",
      rwi_score < 0     ~ "Below Average (Poor)",
      rwi_score == 0    ~ "Average",
      rwi_score > 0     ~ "Above Average (Wealthy)"
    )
  ) %>%
  filter(!is.na(rwi_score))

cat(sprintf("Using %d communities for analysis\n", nrow(newly_electrified_rwi)))

# =============================================================================
# 5. POVERTY TARGETING SUMMARY
# =============================================================================

cat("\n=== POVERTY TARGETING RESULTS ===\n")

poverty_summary <- newly_electrified_rwi %>%
  st_drop_geometry() %>%
  group_by(wealth_category) %>%
  summarise(
    Communities        = n(),
    Population         = sum(population, na.rm = TRUE),
    `High Climate Risk` = sum(total_hazards >= 2, na.rm = TRUE),
    `Avg RWI`          = round(mean(rwi_score, na.rm = TRUE), 3),
    .groups = "drop"
  ) %>%
  mutate(
    `% Communities` = round(100 * Communities / sum(Communities), 1),
    `% Population`  = round(100 * Population  / sum(Population),  1),
    `% High Risk`   = round(100 * `High Climate Risk` / Communities, 1)
  )

print(poverty_summary %>%
        kable(format = "simple") %>%
        kable_styling(bootstrap_options = "striped", full_width = FALSE))

# =============================================================================
# 6. VISUALISATIONS
# =============================================================================

cat("\n=== CREATING VISUALISATIONS ===\n")

viridis_palette <- c("#440154", "#414487", "#2a788e", "#22a884", "#7ad151", "#fde725")

# Plot 1: Regional RWI (ADM1)
p1 <- ggplot() +
  geom_sf(data = adm1_rwi, aes(fill = pop_weighted_rwi), color = "white", size = 0.5) +
  scale_fill_gradientn(colors = viridis_palette, name = "Pop-Weighted\nRWI", na.value = "grey80") +
  labs(
    title    = "Wealth Distribution Across Senegal (Regional Level)",
    subtitle = sprintf("%d regions | Population-weighted RWI", nrow(adm1_rwi))
  ) +
  theme_void() +
  theme(plot.title    = element_text(face = "bold", hjust = 0.5, size = 14),
        plot.subtitle = element_text(hjust = 0.5, size = 11),
        legend.position = "right")

print(p1)

# Plot 2: Department RWI (ADM2)
p2 <- ggplot() +
  geom_sf(data = adm2_rwi, aes(fill = pop_weighted_rwi), color = "white", size = 0.3) +
  scale_fill_gradientn(colors = viridis_palette, name = "Pop-Weighted\nRWI", na.value = "grey80") +
  labs(
    title    = "Wealth Distribution by Department (ADM2)",
    subtitle = sprintf("%d departments | Population-weighted RWI", nrow(adm2_rwi))
  ) +
  theme_void() +
  theme(plot.title    = element_text(face = "bold", hjust = 0.5, size = 14),
        plot.subtitle = element_text(hjust = 0.5, size = 11),
        legend.position = "right")

print(p2)

# Plot 3: Newly electrified communities overlaid on department RWI
p3 <- ggplot() +
  geom_sf(data = adm2_rwi, fill = "grey95", color = "grey70", size = 0.3) +
  geom_sf(data = newly_electrified_rwi,
          aes(color = rwi_score, size = population), alpha = 0.8) +
  scale_color_gradientn(colors = viridis_palette, name = "Department\nRWI",
                        limits = c(-0.5, 1.5)) +
  scale_size_continuous(range = c(1, 6), name = "Population", labels = scales::comma) +
  labs(
    title    = "Newly Electrified Communities by Department Wealth",
    subtitle = paste0("n = ", nrow(newly_electrified_rwi), " matched communities")
  ) +
  theme_void() +
  theme(plot.title    = element_text(face = "bold", hjust = 0.5, size = 14),
        plot.subtitle = element_text(hjust = 0.5, size = 11),
        legend.position = "right")

print(p3)

# Plot 4: RWI distribution histogram
p4 <- newly_electrified_rwi %>%
  st_drop_geometry() %>%
  ggplot(aes(x = rwi_score)) +
  geom_histogram(bins = 30, fill = "#ff7f0e", alpha = 0.7, color = "white") +
  geom_vline(xintercept = 0,
             color = "red", linetype = "dashed", linewidth = 1) +
  geom_vline(xintercept = overall_stats$Mean_Pop_Weighted_RWI,
             color = "blue", linetype = "dashed", linewidth = 1) +
  annotate("text", x = 0, y = Inf,
           label = "Zero", vjust = 2, hjust = -0.1, color = "red", size = 3) +
  annotate("text", x = overall_stats$Mean_Pop_Weighted_RWI, y = Inf,
           label = paste("National mean:", round(overall_stats$Mean_Pop_Weighted_RWI, 2)),
           vjust = 4, hjust = -0.1, color = "blue", size = 3) +
  labs(
    title    = "RWI Distribution of Newly Electrified Communities",
    subtitle = paste0("Department-level pop-weighted RWI | n = ", nrow(newly_electrified_rwi)),
    x = "Department Pop-Weighted RWI",
    y = "Number of Communities"
  ) +
  theme_minimal() +
  theme(plot.title    = element_text(face = "bold", hjust = 0.5, size = 14),
        plot.subtitle = element_text(hjust = 0.5, size = 10))

print(p4)

# Plot 5: Wealth category bar chart
p5 <- newly_electrified_rwi %>%
  st_drop_geometry() %>%
  count(wealth_category) %>%
  mutate(wealth_category = factor(wealth_category,
                                  levels = c("Below Average (Poor)",
                                             "Average",
                                             "Above Average (Wealthy)"))) %>%
  ggplot(aes(x = wealth_category, y = n, fill = wealth_category)) +
  geom_bar(stat = "identity", show.legend = FALSE) +
  geom_text(aes(label = paste0(n, "\n(", round(100 * n / sum(n), 1), "%)")),
            vjust = 1.5, color = "white", fontface = "bold", size = 5) +
  scale_fill_manual(values = c("Below Average (Poor)"    = "#d62728",
                               "Average"                 = "#ff7f0e",
                               "Above Average (Wealthy)" = "#2ca02c")) +
  labs(
    title    = "Poverty Targeting in Newly Electrified Communities",
    subtitle = "Department-level population-weighted RWI",
    x = "",
    y = "Number of Communities"
  ) +
  theme_minimal() +
  theme(plot.title    = element_text(face = "bold", hjust = 0.5, size = 14),
        plot.subtitle = element_text(hjust = 0.5, size = 10))

print(p5)

# Plot 6: Side-by-side — all Senegal vs newly electrified
p6_left <- ggplot() +
  geom_sf(data = adm2_rwi, aes(fill = pop_weighted_rwi), color = "white", size = 0.2) +
  scale_fill_gradientn(colors = viridis_palette, name = "RWI", limits = c(-0.5, 1.5)) +
  labs(title = "All Senegal\n(Department-level RWI)") +
  theme_void() +
  theme(plot.title       = element_text(face = "bold", hjust = 0.5, size = 12),
        legend.position  = "bottom",
        legend.key.width  = unit(1.5, "cm"),
        legend.key.height = unit(0.3, "cm"))

p6_right <- ggplot() +
  geom_sf(data = adm2_rwi, fill = "grey95", color = "grey70", size = 0.2) +
  geom_sf(data = newly_electrified_rwi,
          aes(color = rwi_score, size = population), alpha = 0.8) +
  scale_color_gradientn(colors = viridis_palette, name = "RWI", limits = c(-0.5, 1.5)) +
  scale_size_continuous(range = c(0.5, 4), name = "Pop", labels = scales::comma) +
  labs(title = sprintf("Newly Electrified\n(%s communities)",
                       format(nrow(newly_electrified_rwi), big.mark = ","))) +
  theme_void() +
  theme(plot.title       = element_text(face = "bold", hjust = 0.5, size = 12),
        legend.position  = "bottom",
        legend.key.width  = unit(1.5, "cm"),
        legend.key.height = unit(0.3, "cm"))

p6_combined <- p6_left + p6_right +
  plot_annotation(
    title    = "Wealth Distribution: All Senegal vs Newly Electrified Communities",
    subtitle = "Population-Weighted RWI at Department Level",
    theme    = theme(
      plot.title    = element_text(face = "bold", hjust = 0.5, size = 16),
      plot.subtitle = element_text(hjust = 0.5, size = 12)
    )
  )

print(p6_combined)

# =============================================================================
# 7. KEY FINDINGS
# =============================================================================

cat("\n=== KEY FINDINGS ===\n")

poor_count_new <- sum(newly_electrified_rwi$wealth_category == "Below Average (Poor)")
poor_pct_new   <- round(100 * poor_count_new / nrow(newly_electrified_rwi), 1)

cat(sprintf("OVERALL SENEGAL:    %.1f%% of population in below-average wealth regions (RWI < 0)\n",
            pct_pop_in_poor_regions))
cat(sprintf("NEWLY ELECTRIFIED:  %d communities matched, %.1f%% in poor departments\n",
            nrow(newly_electrified_rwi), poor_pct_new))
cat(sprintf("Average RWI — Overall: %.3f | Newly Electrified: %.3f\n",
            overall_stats$Mean_Pop_Weighted_RWI,
            mean(newly_electrified_rwi$rwi_score, na.rm = TRUE)))

targeting_msg <- if (poor_pct_new > pct_pop_in_poor_regions) {
  sprintf("Over-targeted poor by %.1f percentage points", poor_pct_new - pct_pop_in_poor_regions)
} else if (poor_pct_new < pct_pop_in_poor_regions) {
  sprintf("Under-targeted poor by %.1f percentage points", pct_pop_in_poor_regions - poor_pct_new)
} else {
  "Matched national distribution"
}

cat(sprintf("\nTARGETING ASSESSMENT: %s\n", targeting_msg))

# =============================================================================
# 8. SAVE OUTPUTS
# =============================================================================

# NOTE: newly_elec_pop_weighted_rwi.rds is listed in .gitignore because it
# contains location data derived from the private energy survey.
dir.create(here("outputs"), showWarnings = FALSE)

saveRDS(newly_electrified_rwi, here("outputs", "newly_elec_pop_weighted_rwi.rds"))
cat("\nSaved: outputs/newly_elec_pop_weighted_rwi.rds  [excluded from repo via .gitignore]\n")

cat("\n=== ANALYSIS COMPLETE ===\n")
cat("RWI interpretation:\n")
cat("  < 0  = Below average wealth\n")
cat("  = 0  = Average wealth\n")
cat("  > 0  = Above average wealth\n")
