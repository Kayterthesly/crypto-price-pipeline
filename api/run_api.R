# =============================================================================
# api/run_api.R
# Purpose: launch the Plumber API server
# Usage: source(here::here("api", "run_api.R"))
# Stop: click the red Stop button in RStudio Console, or Ctrl+C
# NOTE: Stop the API before launching the dashboard (DuckDB single connection)
# =============================================================================

library(plumber)
library(here)

cat("\n=== Starting crypto-price-pipeline API ===\n")
cat("ENV_MODE  :", Sys.getenv("ENV_MODE", "synthetic"), "\n")
cat("Port      : 8000\n")
cat("Endpoints : GET  /health\n")
cat("            POST /predict/price\n\n")

pr(here::here("api", "plumber.R")) |>
  pr_run(host = "0.0.0.0", port = 8000)