# ============================================================================
# ZAMBIA: CLIMATE HAZARD EXPOSURE BY DISTRICT
# Source: World Bank Reproducible Research Repository (dou_haz4 composite),
#         pre-decomposed into per-hazard binary rasters.
# ============================================================================

library(sf)
library(terra)
library(exactextractr)
library(tidyverse)
library(patchwork)

sf_use_s2(FALSE)

base_dir <- "/Users/varsha/Documents/Github Analysis/Zambia"
out_dir  <- "/Users/varsha/Documents/Github Analysis/zambia-energy-climate/assets/img"
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

# ============================================================================
# STEP 1: BOUNDARIES
# ============================================================================

wb_boundaries <- st_read(
  file.path(base_dir, "01-data/04-boundaries/World Bank Official Boundaries - Admin 0/WB_GAD_ADM0.shp"),
  quiet = TRUE
)
zambia_boundary <- wb_boundaries %>% filter(ISO_A3 == "ZMB") %>% st_transform(4326)

zambia_adm2 <- st_read(
  file.path(base_dir, "01-data/04-boundaries/World Bank Official Boundaries - Admin 2/WB_GAD_ADM2.shp"),
  quiet = TRUE
) %>% filter(NAM_0 == "Zambia") %>% st_transform(4326)

cat(sprintf("ADM2 loaded: %d districts\n", nrow(zambia_adm2)))

# ============================================================================
# STEP 2: HAZARD RASTERS (pre-decomposed, already cropped to Zambia)
# ============================================================================

hazard_dir <- file.path(base_dir, "01-data/03-climate/climate_hazards")

drought_raster <- rast(file.path(hazard_dir, "zambia_drought_exposure.tif"))
heat_raster    <- rast(file.path(hazard_dir, "zambia_heat_exposure.tif"))
flood_raster   <- rast(file.path(hazard_dir, "zambia_flood_exposure.tif"))
cyclone_raster <- rast(file.path(hazard_dir, "zambia_cyclone_exposure.tif"))

cat("Hazard rasters loaded (drought, heat, flood, cyclone)\n")

# ============================================================================
# STEP 3: DISTRICT-LEVEL EXPOSURE (% of district area exposed)
# ============================================================================

cat("Calculating district-level exposure (exactextractr)...\n")

zambia_adm2 <- zambia_adm2 %>%
  mutate(
    pct_drought = 100 * exact_extract(drought_raster, ., "mean"),
    pct_heat    = 100 * exact_extract(heat_raster,    ., "mean"),
    pct_flood   = 100 * exact_extract(flood_raster,   ., "mean"),
    pct_cyclone = 100 * exact_extract(cyclone_raster, ., "mean"),
    # heat excluded from the risk score: near-zero nationally (0.1%) under
    # this hazard methodology, likely due to Zambia's plateau elevation --
    # kept as a reported stat but not shown as its own map/included in risk
    max_hazard_pct = pmax(pct_drought, pct_flood, pct_cyclone, na.rm = TRUE),
    climate_risk = case_when(
      max_hazard_pct >= 66 ~ "High Risk",
      max_hazard_pct >= 33 ~ "Medium Risk",
      TRUE                 ~ "Low Risk"
    ),
    climate_risk = factor(climate_risk, levels = c("Low Risk", "Medium Risk", "High Risk"))
  )

cat("\n=== CLIMATE RISK DISTRIBUTION ===\n")
print(table(zambia_adm2$climate_risk, useNA = "always"))

# National area-weighted exposure (whole-country pixel fractions)
drought_pct_nat <- 100 * exact_extract(drought_raster, zambia_boundary, "mean")
heat_pct_nat    <- 100 * exact_extract(heat_raster,    zambia_boundary, "mean")
flood_pct_nat   <- 100 * exact_extract(flood_raster,   zambia_boundary, "mean")
cyclone_pct_nat <- 100 * exact_extract(cyclone_raster, zambia_boundary, "mean")

cat(sprintf("\nNational exposure (%% of land area):\n  Drought: %.1f%%\n  Heat: %.1f%%\n  Flood: %.1f%%\n  Cyclone: %.1f%%\n",
            drought_pct_nat, heat_pct_nat, flood_pct_nat, cyclone_pct_nat))

# ============================================================================
# STEP 4: MAPS
# ============================================================================

cat("\nRendering maps...\n")

p_risk <- ggplot() +
  geom_sf(data = zambia_adm2, aes(fill = climate_risk), color = "grey50", linewidth = 0.15) +
  scale_fill_manual(
    values = c("Low Risk" = "#2ca02c", "Medium Risk" = "#ff7f0e", "High Risk" = "#d62728"),
    name = "Climate Risk", na.value = "grey80"
  ) +
  labs(title = "Climate Risk by District",
       subtitle = "Max of drought/heat/flood/cyclone area-exposure %, thresholded at 33%/66%") +
  theme_void() +
  theme(plot.title = element_text(face = "bold", hjust = 0.5, size = 14),
        plot.subtitle = element_text(hjust = 0.5, size = 9),
        legend.position = "right")

ggsave(file.path(out_dir, "zambia_climate_risk_by_district.png"), p_risk, width = 9, height = 8, dpi = 200, bg = "white")

p3a <- ggplot() +
  geom_sf(data = zambia_adm2, aes(fill = pct_drought), color = "grey50", linewidth = 0.1) +
  scale_fill_gradient(low = "white", high = "darkorange", name = "% Area\nExposed", limits = c(0, 100)) +
  labs(title = "Drought Exposure") + theme_void() +
  theme(plot.title = element_text(face = "bold", hjust = 0.5, size = 12))

p3c <- ggplot() +
  geom_sf(data = zambia_adm2, aes(fill = pct_flood), color = "grey50", linewidth = 0.1) +
  scale_fill_gradient(low = "white", high = "darkblue", name = "% Area\nExposed", limits = c(0, 100)) +
  labs(title = "Flood Exposure") + theme_void() +
  theme(plot.title = element_text(face = "bold", hjust = 0.5, size = 12))

p3 <- (p3a | p3c) +
  plot_annotation(title = "Climate Hazard Exposure by District",
                   subtitle = "% of district land area exposed. Heat (0.1% national) and cyclone (0.0%) omitted -- negligible under this hazard methodology.",
                   theme = theme(plot.title = element_text(face = "bold", hjust = 0.5, size = 14),
                                 plot.subtitle = element_text(hjust = 0.5, size = 9)))

ggsave(file.path(out_dir, "zambia_hazard_exposure_panel.png"), p3, width = 11, height = 6, dpi = 200, bg = "white")

cat("\nSaved:\n - zambia_climate_risk_by_district.png\n - zambia_hazard_exposure_panel.png\n")
