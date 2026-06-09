# =============================================================================
# tests/integration/test_full_pipeline.R
# Verifies the full pipeline chain: ingest → features → forecast → registry
# Uses isolated test DB — never touches production crypto_prices.duckdb
# Run: testthat::test_file(here::here("tests/integration/test_full_pipeline.R"))
# =============================================================================

library(testthat)
library(withr)
library(here)

source(here::here("r_scripts", "00_utils.R"))
source(here::here("r_scripts", "01_ingestion.R"))
source(here::here("r_scripts", "02_features.R"))
source(here::here("r_scripts", "03_modeling.R"))

# Test DB isolation
test_db <- here::here("data", "integration_test.duckdb")
Sys.setenv(DB_PATH = test_db)

withr::defer({
  gc(); Sys.sleep(0.3)
  for (f in c(test_db, paste0(test_db, ".wal"))) {
    if (file.exists(f)) file.remove(f)
  }
  Sys.setenv(DB_PATH = "data/crypto_prices.duckdb")
}, envir = parent.frame())

test_that("full pipeline: ingest → features → forecast → registry", {
  
  # Stage 1: Ingest
  fetch_and_store_history("INT-TEST", years_back = 2, overwrite = TRUE)
  
  con <- get_db_connection()
  n_raw <- DBI::dbGetQuery(con,
                           "SELECT COUNT(*) AS n FROM raw_prices WHERE symbol='INT-TEST'")$n
  DBI::dbDisconnect(con, shutdown = TRUE); gc()
  expect_gt(n_raw, 100, label = "raw_prices must have data after ingest")
  
  # Stage 2: Features
  generate_pipeline_features("INT-TEST")
  
  con <- get_db_connection()
  n_feat <- DBI::dbGetQuery(con,
                            "SELECT COUNT(*) AS n FROM feature_prices WHERE symbol='INT-TEST'")$n
  DBI::dbDisconnect(con, shutdown = TRUE); gc()
  expect_equal(n_raw, n_feat, label = "feature_prices must match raw_prices count")
  
  # Stage 3: Forecast
  result <- compute_asset_forecasts("INT-TEST", forecast_horizon = 14)
  gc(); Sys.sleep(0.2)
  
  expect_true(!is.null(result), label = "forecast must return a result")
  expect_equal(nrow(result$forecast_df), 14L)
  expect_true(is.finite(result$rmse_test))
  
  # Stage 4: Registry
  con <- get_db_connection()
  registry <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM model_registry WHERE model_version='%s'",
    result$model_version))
  DBI::dbDisconnect(con, shutdown = TRUE); gc()
  
  expect_equal(nrow(registry), 1L,
               label = "model run must be recorded in registry")
  
  cat("\n✅ Full pipeline integration test PASSED\n")
  cat("   Ingest → Features → Forecast → Registry — all verified\n")
})