# =============================================================================
# tests/unit/test_features.R
# Pipeline: crypto-price-pipeline
# Stage: 6 — Unit Tests: Feature Engineering
# ISOLATION: uses a dedicated test DB (data/test_crypto.duckdb)
#            never touches the production crypto_prices.duckdb
# Run: testthat::test_file(here::here("tests/unit/test_features.R"))
# =============================================================================

library(testthat)
library(here)
library(dplyr)
library(withr)

source(here::here("r_scripts", "00_utils.R"))
source(here::here("r_scripts", "01_ingestion.R"))
source(here::here("r_scripts", "02_features.R"))

# ── Test DB isolation ─────────────────────────────────────────────────────────
# Point ALL pipeline functions at a test-specific DB file.
# withr::defer() removes the test DB after all tests in this file complete.
test_db <- here::here("data", "test_crypto.duckdb")
Sys.setenv(DB_PATH = test_db)

withr::defer({
  # Force DuckDB to release the file handle before deleting
  gc()
  Sys.sleep(0.2)
  for (f in c(test_db, paste0(test_db, ".wal"))) {
    if (file.exists(f)) file.remove(f)
  }
  # Restore production DB path
  Sys.setenv(DB_PATH = "data/crypto_prices.duckdb")
}, envir = parent.frame())

# ── Setup: populate test DB ───────────────────────────────────────────────────
fetch_and_store_history("TEST-CRYPTO", years_back = 2, overwrite = TRUE)
generate_pipeline_features("TEST-CRYPTO")

# ── Tests ─────────────────────────────────────────────────────────────────────
test_that("feature table has required columns", {
  con <- get_db_connection()
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); gc() })
  
  df <- tbl(con, "feature_prices") |>
    dplyr::filter(symbol == "TEST-CRYPTO") |>
    dplyr::collect()
  
  required <- c("symbol","date","adjusted","log_return",
                "sma_50","sma_200","vol_30","rsi_14",
                "rolling_max","drawdown")
  
  expect_true(all(required %in% names(df)),
              info = paste("Missing:", paste(setdiff(required, names(df)), collapse=", ")))
})

test_that("log_return has exactly 1 NA", {
  con <- get_db_connection()
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); gc() })
  
  df <- tbl(con, "feature_prices") |>
    dplyr::filter(symbol == "TEST-CRYPTO") |>
    dplyr::collect()
  
  expect_equal(sum(is.na(df$log_return)), 1L)
})

test_that("sma_50 has fewer NAs than sma_200", {
  con <- get_db_connection()
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); gc() })
  
  df <- tbl(con, "feature_prices") |>
    dplyr::filter(symbol == "TEST-CRYPTO") |>
    dplyr::collect()
  
  expect_lt(sum(is.na(df$sma_50)), sum(is.na(df$sma_200)))
})

test_that("drawdown is always <= 0", {
  con <- get_db_connection()
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); gc() })
  
  df <- tbl(con, "feature_prices") |>
    dplyr::filter(symbol == "TEST-CRYPTO") |>
    dplyr::collect() |>
    dplyr::filter(!is.na(drawdown))
  
  expect_true(all(df$drawdown <= 0),
              info = "Drawdown must always be <= 0")
})

test_that("leakage check passes for TEST-CRYPTO", {
  con <- get_db_connection()
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); gc() })
  
  df <- tbl(con, "feature_prices") |>
    dplyr::filter(symbol == "TEST-CRYPTO") |>
    dplyr::arrange(date) |>
    dplyr::collect()
  
  sma50_recomputed <- TTR::SMA(df$adjusted, n = 50)
  sma50_expected   <- dplyr::lag(sma50_recomputed, 1)
  flags <- sum(abs(df$sma_50 - sma50_expected) > 1e-8, na.rm = TRUE)
  
  expect_equal(flags, 0L,
               info = paste("Leakage detected in", flags, "rows"))
})

test_that("feature row count matches raw_prices for TEST-CRYPTO", {
  con <- get_db_connection()
  on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); gc() })
  
  n_raw  <- DBI::dbGetQuery(con,
                            "SELECT COUNT(*) AS n FROM raw_prices WHERE symbol='TEST-CRYPTO'")$n
  n_feat <- DBI::dbGetQuery(con,
                            "SELECT COUNT(*) AS n FROM feature_prices WHERE symbol='TEST-CRYPTO'")$n
  
  expect_equal(n_raw, n_feat)
})