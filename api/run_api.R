library(here)
library(DBI)
library(duckdb)
library(dbplyr)   # explicit load — required by generate_pipeline_features() in Docker
library(plumber)

cat("=== Starting crypto-price-pipeline API ===\n")
cat("ENV_MODE :", Sys.getenv("ENV_MODE", unset = "not set"), "\n")
cat("Port     :", Sys.getenv("PORT",     unset = "8000"),    "\n")
cat("Endpoints: GET  /health\n")
cat("           POST /predict/price\n")

# ── Startup seeding ──────────────────────────────────────────────────────────
# Railway containers have no persistent storage — DuckDB is absent on every
# fresh deploy. Seed synthetic data (no HTTP, ~10 sec) before accepting traffic.
# Runs only when the DB file is missing.
tryCatch({
  dir.create(here::here("data"),   showWarnings = FALSE, recursive = TRUE)
  dir.create(here::here("models"), showWarnings = FALSE, recursive = TRUE)

  db_path    <- here::here("data", "crypto_prices.duckdb")
  needs_seed <- !file.exists(db_path)

  if (needs_seed) {
    cat("=== Cold start — DB absent, seeding synthetic data ===\n")

    saved_mode <- Sys.getenv("ENV_MODE", unset = "synthetic")
    Sys.setenv(ENV_MODE = "synthetic")

    source(here::here("r_scripts", "00_workspace_init.R"))
    source(here::here("r_scripts", "01_ingestion.R"))
    source(here::here("r_scripts", "02_features.R"))
    source(here::here("r_scripts", "03_modeling.R"))

    for (sym in c("BTC-USD", "ETH-USD")) {
      tryCatch({
        fetch_and_store_history(sym, years_back = 5)
        generate_pipeline_features(sym)
        cat("[OK] Seeded:", sym, "\n")
      }, error = function(e) {
        cat("[WARN] Seed failed for", sym, ":", conditionMessage(e), "\n")
      })
    }

    Sys.setenv(ENV_MODE = saved_mode)
    cat("=== Seeding complete — API ready ===\n")
  } else {
    cat("=== DB exists — skipping seed ===\n")
  }
}, error = function(e) {
  cat("=== Startup seed warning (non-fatal):", conditionMessage(e), "===\n")
})

# ── Start API ────────────────────────────────────────────────────────────────
port <- as.integer(Sys.getenv("PORT", unset = "8000"))
cat("Binding to port:", port, "\n")

pr(here::here("api", "plumber.R")) |>
  pr_set_serializer(plumber::serializer_json(auto_unbox = TRUE)) |>
  pr_run(host = "0.0.0.0", port = port)