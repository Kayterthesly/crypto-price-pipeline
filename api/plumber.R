# =============================================================================
# api/plumber.R
# Pipeline: crypto-price-pipeline
# Stage: 4 — REST API (Plumber)
# Purpose: expose forecast pipeline as HTTP endpoints
# Launch with: source(here::here("api", "run_api.R"))
# DO NOT add pr_run() here — definitions separate from launcher
# =============================================================================

library(here)

source(here::here("r_scripts", "03_modeling.R"))

#* @apiTitle crypto-price-pipeline Forecast API
#* @apiDescription ARIMA/ETS crypto price forecasting — BTC, ETH, and more
#* @apiVersion 1.0.0

# -----------------------------------------------------------------------------
# GET /health
# Liveness check. Returns environment state and R version.
# -----------------------------------------------------------------------------
#* Health check
#* @tag utility
#* @get /health
function() {
  list(
    status    = "ok",
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
    env_mode  = Sys.getenv("ENV_MODE", unset = "synthetic"),
    r_version = paste(R.version$major, R.version$minor, sep = "."),
    pipeline  = "crypto-price-pipeline"
  )
}

# -----------------------------------------------------------------------------
# POST /predict/price
# Runs full ARIMA forecast for a given crypto symbol and horizon.
#
# Request body (JSON):
#   { "symbol": "BTC-USD", "horizon": 30 }
#
# Response (JSON):
#   { symbol, horizon, forecast, model_meta, trace_id, data_source }
#   OR on error:
#   { error, trace_id }
# -----------------------------------------------------------------------------
#* Generate crypto price forecast
#* @tag forecast
#* @post /predict/price
function(req, res) {
  
  # Parse request body
  body <- tryCatch(
    jsonlite::fromJSON(req$postBody),
    error = function(e) NULL
  )
  
  if (is.null(body)) {
    res$status <- 400
    return(list(
      error    = "Invalid or missing JSON body",
      example  = '{"symbol": "BTC-USD", "horizon": 30}',
      trace_id = uuid::UUIDgenerate()
    ))
  }
  
  # Validate symbol
  symbol <- body$symbol
  if (is.null(symbol) || nchar(trimws(symbol)) == 0) {
    res$status <- 400
    return(list(
      error    = "Missing or empty 'symbol' field",
      trace_id = uuid::UUIDgenerate()
    ))
  }
  
  # Validate horizon (default 30, clamp 1–365)
  horizon <- if (is.null(body$horizon)) 30L else as.integer(body$horizon)
  if (is.na(horizon) || horizon < 1 || horizon > 365) {
    res$status <- 400
    return(list(
      error    = "'horizon' must be an integer between 1 and 365",
      trace_id = uuid::UUIDgenerate()
    ))
  }
  
  trace_id <- uuid::UUIDgenerate()
  log_info("API request | trace_id={trace_id} | symbol={symbol} | horizon={horizon}")
  
  # Run forecast with full error capture
  forecast_result <- tryCatch({
    compute_asset_forecasts(
      target_symbol    = symbol,
      forecast_horizon = horizon
    )
  }, error = function(e) {
    log_error("Forecast failed | trace_id={trace_id} | {conditionMessage(e)}")
    NULL
  })
  
  if (is.null(forecast_result)) {
    res$status <- 500
    return(list(
      error    = paste0(
        "Forecast failed for '", symbol, "'. ",
        "Ensure fetch_and_store_history() and generate_pipeline_features() ",
        "have been run for this symbol."
      ),
      trace_id = trace_id
    ))
  }
  
  log_info("API response sent | trace_id={trace_id} | symbol={symbol}")
  
  list(
    symbol      = symbol,
    horizon     = horizon,
    forecast    = forecast_result$forecast_df,
    model_meta  = forecast_result$model_meta,
    trace_id    = trace_id,
    data_source = Sys.getenv("ENV_MODE", unset = "synthetic")
  )
}