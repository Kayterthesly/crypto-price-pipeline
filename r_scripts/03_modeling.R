# =============================================================================
# 03_modeling.R
# Pipeline: crypto-price-pipeline
# Stage: 3 — Modeling & Forecasting
# CRYPTO-NATIVE:
#   - ts(frequency=1) — no forced annual seasonality
#   - sqrt(365) for volatility context (inherited from features)
#   - UUID model versioning — no timestamp collision in tests
# Usage: source this file, then call compute_asset_forecasts("BTC-USD")
# =============================================================================

source(here::here("r_scripts", "00_utils.R"))

library(forecast)
library(digest)
library(jsonlite)
library(uuid)
library(dplyr)
library(logger)
library(here)

# -----------------------------------------------------------------------------
# ensure_model_registry_table()
# Creates model_registry audit table if it doesn't exist.
# -----------------------------------------------------------------------------
ensure_model_registry_table <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS model_registry (
      model_version    VARCHAR PRIMARY KEY,
      symbol           VARCHAR NOT NULL,
      model_type       VARCHAR NOT NULL,
      n_train          INTEGER,
      n_test           INTEGER,
      forecast_horizon INTEGER,
      data_hash        VARCHAR,
      rmse_test        DOUBLE,
      created_at       TIMESTAMP
    );
  ")
  log_info("model_registry table verified/created")
}

# -----------------------------------------------------------------------------
# compute_asset_forecasts()
# Full pipeline: load features → temporal split → hash → fit ARIMA/ETS
#   → evaluate → refit on all data → forecast → convert to prices → save
#
# CRYPTO NOTE:
#   ts(frequency=1) — each day is independent, no forced seasonality
#   UUID suffix on model_version — collision-proof for concurrent test runs
#
# Args:
#   target_symbol    : ticker string e.g. "BTC-USD", "ETH-USD"
#   forecast_horizon : days ahead to forecast (default 30)
#   train_ratio      : proportion for training (default 0.8)
# -----------------------------------------------------------------------------
compute_asset_forecasts <- function(target_symbol,
                                    forecast_horizon = 30L,
                                    train_ratio      = 0.8) {
  
  # Input validation
  if (!is.character(target_symbol) || nchar(trimws(target_symbol)) == 0) {
    stop("[MODEL ABORT] target_symbol must be a non-empty string", call. = FALSE)
  }
  if (!is.numeric(forecast_horizon) ||
      forecast_horizon < 1 || forecast_horizon > 365) {
    stop("[MODEL ABORT] forecast_horizon must be between 1 and 365", call. = FALSE)
  }
  if (!is.numeric(train_ratio) ||
      train_ratio <= 0 || train_ratio >= 1) {
    stop("[MODEL ABORT] train_ratio must be between 0 and 1 exclusive", call. = FALSE)
  }
  
  log_info("Starting forecast | symbol={target_symbol} | horizon={forecast_horizon}")
  
  con <- get_db_connection()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  
  ensure_model_registry_table(con)
  
  # ── Load features, drop NA warm-up rows ─────────────────────────────────────
  df_raw <- tbl(con, "feature_prices") |>
    dplyr::filter(symbol == !!target_symbol) |>
    dplyr::arrange(date) |>
    dplyr::collect()
  
  if (nrow(df_raw) == 0) {
    stop("[MODEL ABORT] No feature data for '", target_symbol,
         "'. Run generate_pipeline_features() first.", call. = FALSE)
  }
  
  # Drop rows where any key feature is NA (SMA-200 warm-up = 200 rows)
  df <- df_raw |>
    dplyr::filter(
      !is.na(log_return),
      !is.na(sma_50),
      !is.na(sma_200),
      !is.na(vol_30)
    )
  
  log_info("Rows after NA drop | symbol={target_symbol} | rows={nrow(df)}")
  
  if (nrow(df) < 100) {
    stop("[MODEL ABORT] Only ", nrow(df),
         " rows after NA removal. Minimum 100 required.", call. = FALSE)
  }
  
  # ── Temporal train/test split — NEVER random for time series ────────────────
  n_total <- nrow(df)
  n_train <- floor(n_total * train_ratio)
  n_test  <- n_total - n_train
  
  df_train <- df[seq_len(n_train), ]
  df_test  <- df[seq(n_train + 1, n_total), ]
  
  log_info("Temporal split | train={n_train} | test={n_test}")
  
  # ── Data lineage hash ────────────────────────────────────────────────────────
  set.seed(101)
  data_hash <- digest::digest(df_train, algo = "md5")
  log_info("Data lineage hash | {data_hash}")
  
  # ── Fit model on training log returns ───────────────────────────────────────
  # CRYPTO: frequency=1 — no forced annual seasonality
  train_ts <- ts(df_train$log_return, frequency = 1)
  
  model_type    <- "ARIMA"
  fitted_model  <- tryCatch({
    log_info("Fitting auto.arima | frequency=1 | no seasonal forcing")
    auto.arima(train_ts, stepwise = TRUE, approximation = TRUE)
  }, error = function(e) {
    log_warn("ARIMA failed: {conditionMessage(e)} — switching to ETS")
    model_type <<- "ETS"
    ets(train_ts)
  })
  
  log_info("Model fitted | type={model_type}")
  
  # ── Evaluate on test set ─────────────────────────────────────────────────────
  test_fc   <- forecast(fitted_model, h = n_test)
  test_rmse <- sqrt(mean((df_test$log_return -
                            as.numeric(test_fc$mean))^2, na.rm = TRUE))
  log_info("Test RMSE (log return scale) | {round(test_rmse, 6)}")
  
  # ── Refit on ALL data for production forecast ────────────────────────────────
  full_ts    <- ts(df$log_return, frequency = 1)
  full_model <- tryCatch(
    auto.arima(full_ts, stepwise = TRUE, approximation = TRUE),
    error = function(e) { log_warn("Full refit failed — using ETS"); ets(full_ts) }
  )
  
  future_fc      <- forecast(full_model, h = forecast_horizon)
  fc_returns     <- as.numeric(future_fc$mean)
  fc_lower       <- as.numeric(future_fc$lower[, 2])  # 95% CI
  fc_upper       <- as.numeric(future_fc$upper[, 2])
  
  # ── Convert log returns to price levels ─────────────────────────────────────
  last_price <- tail(df$adjusted, 1)
  last_date  <- tail(df$date, 1)
  
  price_hat   <- last_price * exp(cumsum(fc_returns))
  price_lower <- last_price * exp(cumsum(fc_lower))
  price_upper <- last_price * exp(cumsum(fc_upper))
  
  forecast_dates <- seq(last_date + 1,
                        by = "day",
                        length.out = forecast_horizon)
  
  forecast_df <- data.frame(
    symbol         = target_symbol,
    forecast_date  = forecast_dates,
    log_return_hat = fc_returns,
    price_hat      = price_hat,
    price_lower    = price_lower,
    price_upper    = price_upper
  )
  
  log_info("Prices computed | last_price={round(last_price, 2)} | last_date={last_date}")
  
  # ── UUID-based model version (collision-proof for concurrent test calls) ─────
  model_version <- paste0(
    tolower(model_type), "_",
    gsub("[^a-zA-Z0-9]", "", target_symbol), "_",
    format(Sys.time(), "%Y%m%d"), "_",
    substr(uuid::UUIDgenerate(), 1, 8)
  )
  
  # ── Save model artifact ──────────────────────────────────────────────────────
  model_path <- here("models", paste0(model_version, ".rds"))
  saveRDS(full_model, file = model_path)
  
  meta <- list(
    model_version    = model_version,
    symbol           = target_symbol,
    model_type       = model_type,
    n_train          = n_train,
    n_test           = n_test,
    forecast_horizon = as.integer(forecast_horizon),
    data_hash        = data_hash,
    rmse_test        = round(test_rmse, 8),
    last_price       = round(last_price, 4),
    last_date        = format(last_date),
    created_at       = format(Sys.time())
  )
  
  meta_path <- here("models", paste0("metadata_", model_version, ".json"))
  jsonlite::write_json(meta, path = meta_path,
                       auto_unbox = TRUE, pretty = TRUE)
  
  # ── Write to model_registry in DuckDB ───────────────────────────────────────
  registry_row <- data.frame(
    model_version    = model_version,
    symbol           = target_symbol,
    model_type       = model_type,
    n_train          = n_train,
    n_test           = n_test,
    forecast_horizon = as.integer(forecast_horizon),
    data_hash        = data_hash,
    rmse_test        = test_rmse,
    created_at       = Sys.time()
  )
  
  DBI::dbWriteTable(con, "model_registry", registry_row, append = TRUE)
  log_info("Model registered | version={model_version} | RMSE={round(test_rmse,6)}")
  log_info("Forecast complete | symbol={target_symbol} | horizon={forecast_horizon}")
  
  list(
    forecast_df   = forecast_df,
    model_meta    = meta,
    model_version = model_version,
    rmse_test     = test_rmse
  )
}

# -----------------------------------------------------------------------------
# inspect_model_registry()
# Shows all model runs recorded in DuckDB.
# -----------------------------------------------------------------------------
inspect_model_registry <- function() {
  con <- get_db_connection()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  
  result <- DBI::dbGetQuery(con,
                            "SELECT model_version, symbol, model_type,
            n_train, n_test, forecast_horizon,
            ROUND(rmse_test, 6) AS rmse_test, created_at
     FROM model_registry
     ORDER BY created_at DESC
     LIMIT 10")
  
  print(result)
  invisible(result)
}

# -----------------------------------------------------------------------------
# print_forecast_summary()
# Human-readable summary of a forecast result.
# -----------------------------------------------------------------------------
print_forecast_summary <- function(forecast_result) {
  meta <- forecast_result$model_meta
  df   <- forecast_result$forecast_df
  
  cat("\n=== Forecast Summary ===\n")
  cat("Symbol        :", meta$symbol, "\n")
  cat("Model type    :", meta$model_type, "\n")
  cat("Model version :", meta$model_version, "\n")
  cat("Train rows    :", meta$n_train, "\n")
  cat("Test rows     :", meta$n_test, "\n")
  cat("Test RMSE     :", round(meta$rmse_test, 6),
      "(log return scale)\n")
  cat("Last price    :", meta$last_price, "\n")
  cat("Last date     :", meta$last_date, "\n")
  cat("Horizon       :", meta$forecast_horizon, "days\n")
  cat("Data hash     :", meta$data_hash, "\n\n")
  
  cat("Price forecast (first 10 days):\n")
  print(head(df[, c("forecast_date","price_hat",
                    "price_lower","price_upper")], 10))
  
  cat("\nPrice forecast (last 5 days):\n")
  print(tail(df[, c("forecast_date","price_hat",
                    "price_lower","price_upper")], 5))
}