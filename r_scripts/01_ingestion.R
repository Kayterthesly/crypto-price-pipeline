# =============================================================================
# 01_ingestion.R
# Pipeline: crypto-price-pipeline
# Stage: 1 — Data Ingestion
# CRYPTO-NATIVE: no weekday filter, sqrt(365) annualization
# Usage: source this file, then call fetch_and_store_history("BTC-USD")
# =============================================================================

source(here::here("r_scripts", "00_utils.R"))

library(dplyr)
library(tidyquant)
library(logger)
library(here)

# -----------------------------------------------------------------------------
# ensure_raw_prices_table()
# Creates raw_prices if it doesn't exist. Safe to call multiple times.
# -----------------------------------------------------------------------------
ensure_raw_prices_table <- function(con) {
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS raw_prices (
      symbol   VARCHAR NOT NULL,
      date     DATE    NOT NULL,
      open     DOUBLE,
      high     DOUBLE,
      low      DOUBLE,
      close    DOUBLE,
      adjusted DOUBLE,
      volume   DOUBLE,
      PRIMARY KEY (symbol, date)
    );
  ")
  log_info("raw_prices table verified/created")
}

# -----------------------------------------------------------------------------
# upsert_prices()
# Insert new rows, update existing — safe to run multiple times.
# -----------------------------------------------------------------------------
upsert_prices <- function(con, prices_df) {
  dbWriteTable(con, "tmp_prices", prices_df, overwrite = TRUE)
  dbExecute(con, "
    INSERT INTO raw_prices
    SELECT * FROM tmp_prices
    ON CONFLICT (symbol, date) DO UPDATE SET
      open     = excluded.open,
      high     = excluded.high,
      low      = excluded.low,
      close    = excluded.close,
      adjusted = excluded.adjusted,
      volume   = excluded.volume;
  ")
  dbExecute(con, "DROP TABLE IF EXISTS tmp_prices;")
  log_info("Upsert complete | rows={nrow(prices_df)}")
}

# -----------------------------------------------------------------------------
# fetch_and_store_history()
# Pulls crypto price data (synthetic or Yahoo) → stores in DuckDB.
#
# CRYPTO NOTE: No weekday filter applied. Crypto trades 365 days/year.
# Annualization in downstream features uses sqrt(365), not sqrt(252).
#
# Args:
#   symbol     : ticker e.g. "BTC-USD", "ETH-USD", "BNB-USD"
#   years_back : years of history (default 5 — crypto data often sparse >5yr)
#   overwrite  : if TRUE, deletes existing rows for symbol before inserting
# -----------------------------------------------------------------------------
fetch_and_store_history <- function(symbol,
                                    years_back = 5,
                                    overwrite  = FALSE) {
  
  if (!is.character(symbol) || nchar(trimws(symbol)) == 0) {
    stop("[INGEST ABORT] symbol must be a non-empty string", call. = FALSE)
  }
  if (!is.numeric(years_back) || years_back <= 0) {
    stop("[INGEST ABORT] years_back must be a positive number", call. = FALSE)
  }
  
  mode <- Sys.getenv("ENV_MODE", unset = "synthetic")
  log_info("Starting ingestion | symbol={symbol} | mode={mode} | years_back={years_back}")
  
  con <- get_db_connection()
  on.exit(dbDisconnect(con, shutdown = TRUE))
  
  ensure_raw_prices_table(con)
  
  if (overwrite) {
    deleted <- dbExecute(con,
                         "DELETE FROM raw_prices WHERE symbol = ?",
                         params = list(symbol))
    log_info("Overwrite: deleted {deleted} existing rows for {symbol}")
  }
  
  # ── SYNTHETIC MODE ──────────────────────────────────────────────────────────
  if (mode == "synthetic") {
    
    # CRYPTO: use calendar days — no weekday filter
    total_days    <- as.integer(years_back * 365)
    all_dates     <- seq(Sys.Date() - total_days + 1, Sys.Date(), by = "day")
    n             <- length(all_dates)
    
    set.seed(42)
    base_price <- 30000  # BTC-like starting price
    
    synthetic_df <- data.frame(
      symbol   = rep(symbol, n),
      date     = all_dates,
      open     = base_price * exp(cumsum(rnorm(n, 0, 0.02))) * runif(n, 0.98, 1.00),
      high     = base_price * exp(cumsum(rnorm(n, 0, 0.02))) * runif(n, 1.01, 1.04),
      low      = base_price * exp(cumsum(rnorm(n, 0, 0.02))) * runif(n, 0.96, 0.99),
      close    = base_price * exp(cumsum(rnorm(n, 0.0002, 0.025))),
      adjusted = base_price * exp(cumsum(rnorm(n, 0.0002, 0.025))),
      volume   = sample(1e9:5e10, n, replace = TRUE)
    )
    
    upsert_prices(con, synthetic_df)
    log_info("Synthetic ingestion complete | symbol={symbol} | rows={n}")
    
    # ── LIVE YAHOO MODE ─────────────────────────────────────────────────────────
  } else if (mode %in% c("live_yahoo", "production")) {
    
    start_date <- Sys.Date() - as.integer(years_back * 365)
    log_info("Fetching from Yahoo Finance | from={start_date} | to={Sys.Date()}")
    
    prices_raw <- tryCatch({
      tq_get(symbol,
             from = as.character(start_date),
             to   = as.character(Sys.Date()),
             get  = "stock.prices")
    }, error = function(e) {
      stop("[INGEST ABORT] Yahoo Finance fetch failed for '", symbol, "': ",
           conditionMessage(e), call. = FALSE)
    })
    
    if (is.null(prices_raw) || nrow(prices_raw) == 0) {
      stop("[INGEST ABORT] No data returned for '", symbol,
           "'. Verify ticker is valid on Yahoo Finance.", call. = FALSE)
    }
    
    prices_clean <- prices_raw |>
      transmute(
        symbol   = !!symbol,
        date     = as.Date(date),
        open     = as.double(open),
        high     = as.double(high),
        low      = as.double(low),
        close    = as.double(close),
        # Coalesce: if Yahoo returns NA for adjusted, use close as fallback
        # Yahoo Finance sometimes omits adjusted for the most recent trading day
        adjusted = dplyr::coalesce(as.double(adjusted), as.double(close)),
        volume   = as.double(volume)
      )
    
    upsert_prices(con, prices_clean)
    log_info("Live ingestion complete | symbol={symbol} | rows={nrow(prices_clean)}")
  }
}

# -----------------------------------------------------------------------------
# inspect_raw_prices()
# Quick audit of what's in DuckDB.
# -----------------------------------------------------------------------------
inspect_raw_prices <- function(symbol = NULL) {
  con <- get_db_connection()
  on.exit(dbDisconnect(con, shutdown = TRUE))
  
  query <- if (!is.null(symbol)) {
    paste0("SELECT symbol,
            MIN(date) AS earliest, MAX(date) AS latest,
            COUNT(*) AS total_rows,
            ROUND(COUNT(*) * 100.0 /
              (DATEDIFF('day', MIN(date), MAX(date)) + 1), 1) AS coverage_pct
            FROM raw_prices WHERE symbol = '", symbol, "'
            GROUP BY symbol")
  } else {
    "SELECT symbol,
     MIN(date) AS earliest, MAX(date) AS latest,
     COUNT(*) AS total_rows
     FROM raw_prices GROUP BY symbol ORDER BY symbol"
  }
  
  result <- dbGetQuery(con, query)
  print(result)
  invisible(result)
}