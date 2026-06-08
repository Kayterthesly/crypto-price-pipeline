# =============================================================================
# tests/data_tests.R
# Pipeline: crypto-price-pipeline
# Stage: 6 — Data Tests: DuckDB schema + integrity
# Tests PRODUCTION DB (crypto_prices.duckdb) — not test DB
# Run: Rscript tests/data_tests.R
# =============================================================================

library(here)
library(DBI)

source(here::here("r_scripts", "00_utils.R"))

cat("\n=== Running Data Tests (Production DB) ===\n\n")
passed <- 0L
failed <- 0L

run_test <- function(name, expr) {
  result <- tryCatch(expr, error = function(e) FALSE)
  if (isTRUE(result)) {
    cat("✅ PASS:", name, "\n")
    passed <<- passed + 1L
  } else {
    cat("❌ FAIL:", name, "\n")
    failed <<- failed + 1L
  }
}

con <- get_db_connection()
on.exit({ DBI::dbDisconnect(con, shutdown = TRUE); gc() })

# Table existence
run_test("raw_prices table exists",    DBI::dbExistsTable(con, "raw_prices"))
run_test("feature_prices table exists",DBI::dbExistsTable(con, "feature_prices"))
run_test("model_registry table exists",DBI::dbExistsTable(con, "model_registry"))

# Schema
run_test("raw_prices has required columns", {
  cols <- DBI::dbListFields(con, "raw_prices")
  all(c("symbol","date","open","high","low","close","adjusted","volume") %in% cols)
})

run_test("feature_prices has required columns", {
  cols <- DBI::dbListFields(con, "feature_prices")
  all(c("symbol","date","adjusted","log_return",
        "sma_50","sma_200","vol_30","drawdown") %in% cols)
})

# Row counts
run_test("raw_prices has data (> 100 rows)", {
  DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM raw_prices")$n > 100
})

run_test("feature_prices has data (> 100 rows)", {
  DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM feature_prices")$n > 100
})

# Integrity
run_test("No NULL symbols in raw_prices", {
  DBI::dbGetQuery(con,
                  "SELECT COUNT(*) AS n FROM raw_prices WHERE symbol IS NULL")$n == 0
})

run_test("No NULL dates in raw_prices", {
  DBI::dbGetQuery(con,
                  "SELECT COUNT(*) AS n FROM raw_prices WHERE date IS NULL")$n == 0
})

run_test("No negative prices in raw_prices", {
  DBI::dbGetQuery(con,
                  "SELECT COUNT(*) AS n FROM raw_prices WHERE adjusted < 0")$n == 0
})

# Crypto-native: coverage should be 100% (no weekday gaps)
run_test("BTC-USD coverage >= 99% (crypto-native, no weekend gaps)", {
  result <- DBI::dbGetQuery(con, "
    SELECT COUNT(*) AS n,
           DATEDIFF('day', MIN(date), MAX(date)) + 1 AS total_days
    FROM raw_prices WHERE symbol = 'BTC-USD'")
  (result$n / result$total_days) >= 0.99
})

# Symbol-aware feature writes: BTC-USD and ETH-USD both present
run_test("Both BTC-USD and ETH-USD in feature_prices", {
  symbols <- DBI::dbGetQuery(con,
                             "SELECT DISTINCT symbol FROM feature_prices")$symbol
  all(c("BTC-USD","ETH-USD") %in% symbols)
})

run_test("model_registry has at least one entry", {
  DBI::dbGetQuery(con,
                  "SELECT COUNT(*) AS n FROM model_registry")$n > 0
})

run_test("model_registry has UUID versioning (not pure timestamp)", {
  versions <- DBI::dbGetQuery(con,
                              "SELECT model_version FROM model_registry LIMIT 5")$model_version
  # UUID format: arima_BTCUSD_20260608_5ef82c4c (date + 8-char hex)
  all(grepl("_[a-f0-9]{8}$", versions))
})

cat("\n=== Data Test Summary ===\n")
cat("Passed:", passed, "\n")
cat("Failed:", failed, "\n")

if (failed > 0) {
  cat("\n❌ DATA TESTS FAILED\n")
  quit(status = 1)
} else {
  cat("\n✅ All data tests passed\n")
  quit(status = 0)
}