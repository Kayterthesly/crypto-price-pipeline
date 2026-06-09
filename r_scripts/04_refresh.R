# =============================================================================
# 04_refresh.R
# Pipeline: crypto-price-pipeline
# Stage: 7C — Automated Refresh + Drift Detection
# Usage: Rscript r_scripts/04_refresh.R
#        Called by GitHub Actions cron daily at 02:00 UTC
# =============================================================================

library(here)
library(logger)

source(here::here("r_scripts", "00_utils.R"))
source(here::here("r_scripts", "01_ingestion.R"))
source(here::here("r_scripts", "02_features.R"))
source(here::here("r_scripts", "03_modeling.R"))

# ── Configuration ─────────────────────────────────────────────────────────────
SYMBOLS_TO_REFRESH  <- c("BTC-USD", "ETH-USD")
FORECAST_HORIZON    <- 30L
DRIFT_RMSE_THRESHOLD <- 0.05  # flag if RMSE > this (5% daily error)
DRIFT_DEGRADATION   <- 1.25   # flag if new RMSE > 125% of previous best

log_info("=== Daily Refresh Starting ===")
log_info("Symbols: {paste(SYMBOLS_TO_REFRESH, collapse=', ')}")
log_info("ENV_MODE: {Sys.getenv('ENV_MODE', 'synthetic')}")

refresh_report <- list(
  timestamp   = format(Sys.time()),
  env_mode    = Sys.getenv("ENV_MODE", "synthetic"),
  symbols     = list()
)

for (sym in SYMBOLS_TO_REFRESH) {
  log_info("── Refreshing {sym} ──")
  sym_report <- list(symbol = sym, status = "unknown")
  
  # ── Step 1: Fetch latest prices ───────────────────────────────────────────
  tryCatch({
    fetch_and_store_history(sym, years_back = 5)
    sym_report$ingestion <- "success"
    log_info("{sym}: ingestion complete")
  }, error = function(e) {
    log_error("{sym}: ingestion failed — {conditionMessage(e)}")
    sym_report$ingestion <<- paste("FAILED:", conditionMessage(e))
  })
  
  # ── Step 2: Regenerate features ───────────────────────────────────────────
  tryCatch({
    generate_pipeline_features(sym)
    sym_report$features <- "success"
    log_info("{sym}: features regenerated")
  }, error = function(e) {
    log_error("{sym}: feature generation failed — {conditionMessage(e)}")
    sym_report$features <<- paste("FAILED:", conditionMessage(e))
  })
  
  # ── Step 3: Retrain model ─────────────────────────────────────────────────
  new_result <- tryCatch({
    compute_asset_forecasts(sym, forecast_horizon = FORECAST_HORIZON)
  }, error = function(e) {
    log_error("{sym}: model training failed — {conditionMessage(e)}")
    NULL
  })
  gc(); Sys.sleep(0.1)
  
  if (!is.null(new_result)) {
    sym_report$model_version <- new_result$model_version
    sym_report$new_rmse      <- new_result$rmse_test
    log_info("{sym}: model trained | version={new_result$model_version} | RMSE={round(new_result$rmse_test, 6)}")
    
    # ── Step 4: Drift detection ─────────────────────────────────────────────
    con <- get_db_connection()
    prev_models <- DBI::dbGetQuery(con, sprintf("
      SELECT rmse_test FROM model_registry
      WHERE symbol = '%s'
      ORDER BY created_at DESC
      LIMIT 10", sym))
    DBI::dbDisconnect(con, shutdown = TRUE); gc()
    
    if (nrow(prev_models) > 1) {
      best_historical_rmse <- min(prev_models$rmse_test[-1], na.rm = TRUE)
      rmse_ratio <- new_result$rmse_test / best_historical_rmse
      
      if (new_result$rmse_test > DRIFT_RMSE_THRESHOLD) {
        log_warn("{sym}: ABSOLUTE DRIFT — RMSE={round(new_result$rmse_test,4)} exceeds threshold {DRIFT_RMSE_THRESHOLD}")
        sym_report$drift_flag <- "ABSOLUTE_DRIFT"
      } else if (rmse_ratio > DRIFT_DEGRADATION) {
        log_warn("{sym}: RELATIVE DRIFT — new RMSE is {round(rmse_ratio,2)}x best historical RMSE")
        sym_report$drift_flag <- "RELATIVE_DRIFT"
      } else {
        log_info("{sym}: no drift detected | ratio={round(rmse_ratio, 3)}")
        sym_report$drift_flag <- "OK"
      }
      
      sym_report$best_historical_rmse <- best_historical_rmse
      sym_report$rmse_ratio           <- round(rmse_ratio, 4)
    } else {
      sym_report$drift_flag <- "FIRST_RUN"
    }
    
    sym_report$status <- "success"
  } else {
    sym_report$status <- "failed"
  }
  
  refresh_report$symbols[[sym]] <- sym_report
}

# ── Write refresh report ──────────────────────────────────────────────────────
report_path <- here::here("notes", paste0("refresh_", format(Sys.Date()), ".json"))
jsonlite::write_json(refresh_report, path = report_path,
                     auto_unbox = TRUE, pretty = TRUE)

log_info("=== Daily Refresh Complete ===")
log_info("Report saved: {report_path}")

# Print summary
cat("\n=== REFRESH SUMMARY ===\n")
for (sym in names(refresh_report$symbols)) {
  r <- refresh_report$symbols[[sym]]
  cat(sprintf("%-10s | Status: %-8s | RMSE: %s | Drift: %s\n",
              sym,
              r$status,
              if (!is.null(r$new_rmse)) round(r$new_rmse, 6) else "N/A",
              if (!is.null(r$drift_flag)) r$drift_flag else "N/A"))
}