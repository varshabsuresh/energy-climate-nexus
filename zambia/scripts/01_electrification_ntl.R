# ============================================================================
# ZAMBIA: NTL + ELECTRIFICATION ANALYSIS
# Sources:
# - World Bank MPM 2022 Census (ward deprivation)
# - VIIRS NTL 2021-2023 (GEE exports)
# - World Bank Official Boundaries
# ============================================================================

library(sf)
library(terra)
library(tidyverse)
library(patchwork)

sf_use_s2(FALSE)
target_crs      <- 4326
years_available <- 2021:2023

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

zambia_boundary <- wb_boundaries %>%
  filter(ISO_A3 == "ZMB") %>%
  st_transform(target_crs)

zambia_adm2 <- st_read(
  file.path(base_dir, "01-data/04-boundaries/World Bank Official Boundaries - Admin 2/WB_GAD_ADM2.shp"),
  quiet = TRUE
) %>%
  filter(NAM_0 == "Zambia") %>%
  st_transform(target_crs)

cat(sprintf("ADM0 loaded: %s\n", class(zambia_boundary)[1]))
cat(sprintf("ADM2 loaded: %d districts\n", nrow(zambia_adm2)))

# ============================================================================
# STEP 2: NTL RASTERS
# ============================================================================

ntl_files <- list.files(
  file.path(base_dir, "01-data/03-climate/climate_hazards/"),
  pattern    = "ntl_20[0-9]{2}\\.tif",
  full.names = TRUE
)
ntl_annual <- rast(ntl_files)
names(ntl_annual) <- paste0("ntl_", years_available)
ntl_annual <- mask(ntl_annual, zambia_boundary)
ntl_log    <- log(ntl_annual + 1)
names(ntl_log) <- paste0("ntl_log_", years_available)

cat(sprintf("NTL loaded: %d layers\n", nlyr(ntl_annual)))

# ============================================================================
# STEP 3: WARD DEPRIVATION DATA
# ============================================================================

zambia_wards <- st_read(
  file.path(base_dir, "01-data/05-infra/Zambia_Ward_Deprivation_Indicators/Zambia_Ward_Deprivation.shp"),
  quiet = TRUE
) %>%
  st_transform(target_crs) %>%
  mutate(
    elec_status = case_when(
      pct_dpr_el < 50  ~ "Electrified",
      pct_dpr_el >= 50 ~ "Non-electrified"
    ),
    elec_status = factor(elec_status,
                         levels = c("Electrified", "Non-electrified"))
  )

cat(sprintf("Wards loaded: %d\n", nrow(zambia_wards)))

# ============================================================================
# STEP 4: ALIGN NTL TO WARD GRID & EXTRACT
# ============================================================================

ward_vect <- vect(zambia_wards)

cat("Extracting NTL per ward...\n")
ntl_ward_2021 <- terra::extract(ntl_annual[[1]], ward_vect, fun = mean, na.rm = TRUE)
ntl_ward_2022 <- terra::extract(ntl_annual[[2]], ward_vect, fun = mean, na.rm = TRUE)
ntl_ward_2023 <- terra::extract(ntl_annual[[3]], ward_vect, fun = mean, na.rm = TRUE)

zambia_wards <- zambia_wards %>%
  mutate(
    ntl_2021     = ntl_ward_2021[, 2],
    ntl_2022     = ntl_ward_2022[, 2],
    ntl_2023     = ntl_ward_2023[, 2],
    ntl_mean     = rowMeans(cbind(ntl_2021, ntl_2022, ntl_2023), na.rm = TRUE),
    ntl_log_2021 = log(ntl_2021 + 1),
    ntl_log_2022 = log(ntl_2022 + 1),
    ntl_log_2023 = log(ntl_2023 + 1),
    ntl_log_mean = rowMeans(cbind(ntl_log_2021, ntl_log_2022, ntl_log_2023),
                            na.rm = TRUE)
  )

cat("Extraction done!\n")

# ============================================================================
# STEP 5: ELECTRIFICATION SUMMARY
# ============================================================================

elec_summary <- zambia_wards %>%
  st_drop_geometry() %>%
  group_by(elec_status) %>%
  summarise(
    n_wards   = n(),
    pct_wards = round(100 * n() / nrow(zambia_wards), 1),
    total_pop = sum(T_POP, na.rm = TRUE),
    rural_pop = sum(Tota_rural, na.rm = TRUE)
  ) %>%
  mutate(pct_pop = round(100 * total_pop / sum(total_pop), 1))

cat("\n=== ELECTRIFICATION STATUS (World Bank MPM, 2022 Census) ===\n")
print(elec_summary)

ntl_summary <- zambia_wards %>%
  st_drop_geometry() %>%
  group_by(elec_status) %>%
  summarise(
    n_wards  = n(),
    ntl_2021 = round(mean(ntl_2021, na.rm = TRUE), 3),
    ntl_2022 = round(mean(ntl_2022, na.rm = TRUE), 3),
    ntl_2023 = round(mean(ntl_2023, na.rm = TRUE), 3),
    ntl_mean = round(mean(ntl_mean, na.rm = TRUE), 3),
    .groups  = "drop"
  )

cat("\n=== NTL BY ELECTRIFICATION STATUS ===\n")
print(ntl_summary)

write_csv(elec_summary, file.path(out_dir, "..", "..", "electrification_summary.csv"))

# ============================================================================
# STEP 6: MAPS
# ============================================================================

p_ntl <- ggplot() +
  geom_sf(data = zambia_wards, aes(fill = ntl_log_mean),
          color = NA) +
  scale_fill_gradientn(
    colors = c("gray90", "lightblue", "steelblue", "midnightblue", "black"),
    limits = c(0, 3),
    oob    = scales::squish,
    name   = "NTL\n(log scale)"
  ) +
  geom_sf(data = zambia_adm2, fill = NA,
          color = "gray60", linewidth = 0.1) +
  geom_sf(data = zambia_boundary, fill = NA,
          color = "gray30", linewidth = 0.6) +
  labs(title = "Nighttime Light Radiance", subtitle = "Ward level | Mean 2021–2023") +
  theme_void() +
  theme(
    plot.background = element_rect(fill = "white", color = NA),
    plot.title      = element_text(color = "gray20", face = "bold", hjust = 0.5, size = 13),
    plot.subtitle   = element_text(color = "gray40", hjust = 0.5, size = 9),
    legend.text     = element_text(color = "gray20"),
    legend.title    = element_text(color = "gray20")
  )

ggsave(file.path(out_dir, "zambia_ntl_by_ward.png"), p_ntl, width = 8, height = 8, dpi = 200, bg = "white")

p_elec <- ggplot() +
  geom_sf(data = zambia_wards, aes(fill = elec_status),
          color = NA) +
  scale_fill_manual(
    values = c("Electrified"     = "#2a9d8f",
               "Non-electrified" = "#e9ecef"),
    name = NULL
  ) +
  geom_sf(data = zambia_adm2, fill = NA,
          color = "gray70", linewidth = 0.1) +
  geom_sf(data = zambia_boundary, fill = NA,
          color = "gray30", linewidth = 0.6) +
  labs(title = "Electrification Status", subtitle = "Ward level | World Bank MPM 2022 Census") +
  theme_void() +
  theme(
    plot.background = element_rect(fill = "white", color = NA),
    plot.title      = element_text(color = "gray20", face = "bold", hjust = 0.5, size = 13),
    plot.subtitle   = element_text(color = "gray40", hjust = 0.5, size = 9),
    legend.text     = element_text(color = "gray20"),
    legend.position = "bottom"
  )

ggsave(file.path(out_dir, "zambia_electrification_status.png"), p_elec, width = 8, height = 8, dpi = 200, bg = "white")

p_ntl_trend <- zambia_wards %>%
  st_drop_geometry() %>%
  group_by(elec_status) %>%
  summarise(
    `2021` = mean(ntl_2021, na.rm = TRUE),
    `2022` = mean(ntl_2022, na.rm = TRUE),
    `2023` = mean(ntl_2023, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  pivot_longer(cols      = c(`2021`, `2022`, `2023`),
               names_to  = "year",
               values_to = "ntl_mean") %>%
  ggplot(aes(x = year, y = ntl_mean,
             color = elec_status, group = elec_status)) +
  geom_line(linewidth = 1.5) +
  geom_point(size = 4) +
  geom_text(aes(label = round(ntl_mean, 2)),
            vjust = -1, size = 4, fontface = "bold", show.legend = FALSE) +
  scale_color_manual(values = c("Electrified"     = "#2a9d8f",
                                "Non-electrified" = "gray50")) +
  scale_y_continuous(limits = c(0, 6)) +
  labs(title    = "NTL Radiance Trend by Electrification Status",
       subtitle = "Zambia 2021–2023 | Ward-level means (nW/cm²/sr)",
       x = "Year", y = "Mean NTL Radiance",
       color = NULL) +
  theme_minimal() +
  theme(
    plot.title      = element_text(face = "bold", hjust = 0.5),
    plot.subtitle   = element_text(hjust = 0.5, color = "gray40"),
    legend.position = "top"
  )

ggsave(file.path(out_dir, "zambia_ntl_trend.png"), p_ntl_trend, width = 8, height = 6, dpi = 200, bg = "white")

cat("\nSaved maps to:", out_dir, "\n")
cat(" - zambia_ntl_by_ward.png\n")
cat(" - zambia_electrification_status.png\n")
cat(" - zambia_ntl_trend.png\n")
