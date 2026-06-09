# =============================================================================
# api/plumber.R
# Pipeline: crypto-price-pipeline
# Stage: 7B — API Security, CORS, Rate Limiting
# Endpoints: GET /health | POST /predict/price
# Auth: X-API-Key header (set API_SECRET_KEY in .Renviron)
# =============================================================================

library(here)
source(here::here("r_scripts", "03_modeling.R"))

#* @apiTitle crypto-price-pipeline Forecast API
#* @apiDescription Secured ARIMA/ETS crypto price forecasting
#* @apiVersion 2.0.0

# ── In-memory rate limiter ────────────────────────────────────────────────────
# Tracks request timestamps per IP. Resets on server restart.
.rate_store <- new.env(parent = emptyenv())
RATE_LIMIT_MAX     <- 10L   # max requests per window
RATE_LIMIT_WINDOW  <- 60L   # window in seconds

check_rate_limit <- function(client_ip) {
  now   <- as.numeric(Sys.time())
  key   <- gsub("[^a-zA-Z0-9]", "_", client_ip)
  
  if (!exists(key, envir = .rate_store)) {
    assign(key, numeric(0), envir = .rate_store)
  }
  
  timestamps <- get(key, envir = .rate_store)
  # Keep only timestamps within the current window
  timestamps <- timestamps[timestamps > (now - RATE_LIMIT_WINDOW)]
  assign(key, c(timestamps, now), envir = .rate_store)
  
  length(timestamps) < RATE_LIMIT_MAX
}

# ── CORS filter — allows browser calls from shinyapps.io ─────────────────────
#* @filter cors
function(req, res) {
  res$setHeader("Access-Control-Allow-Origin",  "*")
  res$setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
  res$setHeader("Access-Control-Allow-Headers",
                "Content-Type, X-API-Key, Authorization")
  
  if (req$REQUEST_METHOD == "OPTIONS") {
    res$status <- 200
    return(list())
  }
  plumber::forward()
}

# ── API key authentication filter ────────────────────────────────────────────
#* @filter authenticate
function(req, res) {
  # Skip auth for health check — always public
  if (grepl("^/health", req$PATH_INFO)) {
    plumber::forward()
    return()
  }
  
  valid_key <- Sys.getenv("API_SECRET_KEY")
  
  # If no key configured (development mode) — allow all requests
  if (nchar(valid_key) == 0) {
    log_warn("API_SECRET_KEY not set — running in OPEN mode (development only)")
    plumber::forward()
    return()
  }
  
  client_key <- req$HTTP_X_API_KEY
  if (is.null(client_key) || client_key != valid_key) {
    res$status <- 401
    return(list(
      error    = "Unauthorized — include your API key as X-API-Key header",
      trace_id = uuid::UUIDgenerate()
    ))
  }
  
  plumber::forward()
}

# ── Rate limit filter ─────────────────────────────────────────────────────────
#* @filter rate-limit
function(req, res) {
  # Skip for health check
  if (grepl("^/health", req$PATH_INFO)) {
    plumber::forward()
    return()
  }
  
  client_ip <- req$REMOTE_ADDR %||% "unknown"
  if (!check_rate_limit(client_ip)) {
    res$status <- 429
    return(list(
      error    = paste0("Rate limit exceeded — max ", RATE_LIMIT_MAX,
                        " requests per ", RATE_LIMIT_WINDOW, " seconds"),
      trace_id = uuid::UUIDgenerate()
    ))
  }
  
  plumber::forward()
}

# ── GET /health ───────────────────────────────────────────────────────────────
#* Health check (public — no auth required)
#* @tag utility
#* @get /health
function() {
  list(
    status    = "ok",
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%S"),
    env_mode  = Sys.getenv("ENV_MODE", "synthetic"),
    r_version = paste(R.version$major, R.version$minor, sep = "."),
    pipeline  = "crypto-price-pipeline",
    version   = "2.0.0"
  )
}

# ── POST /predict/price ───────────────────────────────────────────────────────
#* Generate crypto price forecast (requires X-API-Key header)
#* @tag forecast
#* @post /predict/price
function(req, res) {
  
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
  
  symbol  <- body$symbol
  horizon <- if (is.null(body$horizon)) 30L else as.integer(body$horizon)
  
  if (is.null(symbol) || nchar(trimws(symbol)) == 0) {
    res$status <- 400
    return(list(error = "Missing or empty 'symbol'", trace_id = uuid::UUIDgenerate()))
  }
  
  if (is.na(horizon) || horizon < 1 || horizon > 365) {
    res$status <- 400
    return(list(error = "'horizon' must be 1–365", trace_id = uuid::UUIDgenerate()))
  }
  
  trace_id <- uuid::UUIDgenerate()
  log_info("API request | trace={trace_id} | symbol={symbol} | horizon={horizon}")
  
  result <- tryCatch({
    compute_asset_forecasts(symbol, forecast_horizon = horizon)
  }, error = function(e) {
    log_error("Forecast failed | trace={trace_id} | {conditionMessage(e)}")
    NULL
  })
  
  if (is.null(result)) {
    res$status <- 500
    return(list(
      error    = paste0("Forecast failed for '", symbol,
                        "'. Ensure data has been ingested and features generated."),
      trace_id = trace_id
    ))
  }
  
  log_info("Response sent | trace={trace_id}")
  
  list(
    symbol      = symbol,
    horizon     = horizon,
    forecast    = result$forecast_df,
    model_meta  = result$model_meta,
    trace_id    = trace_id,
    data_source = Sys.getenv("ENV_MODE", "synthetic")
  )
}

# Helper: null-coalescing operator
`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0) a else b