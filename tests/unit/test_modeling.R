# =============================================================================
# tests/unit/test_modeling.R
# Pipeline: crypto-price-pipeline
# Stage: 6 — Unit Tests: Modeling
# ISOLATION: uses data/test_crypto.duckdb — never production DB
# Run: testthat::test_file(here::here("tests/unit/test_modeling.R"))
# =============================================================================

library(testthat)
library(here)
library(withr)

source(here::here("r_scripts", "00_utils.R"))
source(here::here("r_scripts", "01_ingestion.R"))
source(here::here("r_scripts", "02_features.R"))
source(here::here("r_scripts", "03_modeling.R"))

# ── Test DB isolation ─────────────────────────────────────────────────────────
test_db <- here::here("data", "test_crypto.duckdb")
Sys.setenv(DB_PATH = test_db)

withr::defer({
  gc()
  Sys.sleep(0.2)
  for (f in c(test_db, paste0(test_db, ".wal"))) {
    if (file.exists(f)) file.remove(f)
  }
  Sys.setenv(DB_PATH = "data/crypto_prices.duckdb")
}, envir = parent.frame())

# ── Setup ─────────────────────────────────────────────────────────────────────
fetch_and_store_history("TEST-CRYPTO", years_back = 2, overwrite = TRUE)
generate_pipeline_features("TEST-CRYPTO")

# ── Input validation tests (no DB needed) ─────────────────────────────────────
test_that("rejects empty symbol", {
  expect_error(
    compute_asset_forecasts(""),
    regexp = "non-empty string"
  )
})

test_that("rejects horizon > 365", {
  expect_error(
    compute_asset_forecasts("TEST-CRYPTO", forecast_horizon = 400),
    regexp = "between 1 and 365"
  )
})

test_that("rejects horizon < 1", {
  expect_error(
    compute_asset_forecasts("TEST-CRYPTO", forecast_horizon = 0),
    regexp = "between 1 and 365"
  )
})

# ── Functional tests (each gets its own connection, gc() after) ───────────────
test_that("forecast result has required fields", {
  result <- compute_asset_forecasts("TEST-CRYPTO", forecast_horizon = 10)
  gc(); Sys.sleep(0.1)
  
  expect_true(is.list(result))
  expect_true(all(c("forecast_df","model_meta",
                    "model_version","rmse_test") %in% names(result)))
})

test_that("forecast_df has correct row count", {
  result <- compute_asset_forecasts("TEST-CRYPTO", forecast_horizon = 10)
  gc(); Sys.sleep(0.1)
  
  expect_equal(nrow(result$forecast_df), 10L)
})

test_that("model_meta has all required keys", {
  result <- compute_asset_forecasts("TEST-CRYPTO", forecast_horizon = 10)
  gc(); Sys.sleep(0.1)
  
  required_keys <- c("model_version","symbol","model_type","n_train",
                     "n_test","rmse_test","data_hash","last_price","last_date")
  expect_true(all(required_keys %in% names(result$model_meta)))
})

test_that("RMSE is positive and finite", {
  result <- compute_asset_forecasts("TEST-CRYPTO", forecast_horizon = 10)
  gc(); Sys.sleep(0.1)
  
  expect_true(is.finite(result$rmse_test))
  expect_gt(result$rmse_test, 0)
})

test_that("model_version uses UUID format (date_xxxxxxxx)", {
  result <- compute_asset_forecasts("TEST-CRYPTO", forecast_horizon = 10)
  gc(); Sys.sleep(0.1)
  
  # Format: arima_TESTCRYPTO_20260608_5ef82c4c
  expect_match(result$model_version, "^[a-z]+_[A-Z0-9]+_\\d{8}_[a-f0-9]{8}$")
})

test_that("model run recorded in model_registry", {
  result <- compute_asset_forecasts("TEST-CRYPTO", forecast_horizon = 10)
  gc(); Sys.sleep(0.2)  # slightly longer — registry write + file handle release
  
  con <- get_db_connection()
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); gc() })
  
  registry <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM model_registry WHERE model_version = '%s'",
    result$model_version))
  
  expect_equal(nrow(registry), 1L)
})