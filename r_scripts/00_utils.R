# =============================================================================
# 00_utils.R
# Pipeline: crypto-price-pipeline
# Purpose: Shared DB connection — sourced by ALL stage scripts
# NEVER run directly — always source() from another script
# =============================================================================

library(DBI)
library(duckdb)
library(logger)
library(here)

# -----------------------------------------------------------------------------
# get_db_connection()
# Returns active DuckDB connection based on ENV_MODE.
# Caller MUST close: on.exit(dbDisconnect(con, shutdown = TRUE))
# -----------------------------------------------------------------------------
get_db_connection <- function() {
  
  mode    <- Sys.getenv("ENV_MODE",  unset = "synthetic")
  db_file <- here(Sys.getenv("DB_PATH", unset = "data/crypto_prices.duckdb"))
  
  log_info("Opening DB | mode={mode} | path={db_file}")
  
  if (mode %in% c("synthetic", "live_yahoo")) {
    
    if (!dir.exists(dirname(db_file))) {
      dir.create(dirname(db_file), recursive = TRUE)
    }
    con <- dbConnect(duckdb(), dbdir = db_file, read_only = FALSE)
    
  } else if (mode == "production") {
    
    required <- c("PROD_DB_HOST","PROD_DB_NAME","PROD_DB_PORT",
                  "PROD_DB_USER","PROD_DB_PASS")
    missing  <- required[nchar(Sys.getenv(required)) == 0]
    if (length(missing) > 0) {
      stop("[DB ABORT] Missing production .Renviron vars: ",
           paste(missing, collapse = ", "), call. = FALSE)
    }
    con <- DBI::dbConnect(
      RPostgres::Postgres(),
      host     = Sys.getenv("PROD_DB_HOST"),
      dbname   = Sys.getenv("PROD_DB_NAME"),
      port     = as.integer(Sys.getenv("PROD_DB_PORT")),
      user     = Sys.getenv("PROD_DB_USER"),
      password = Sys.getenv("PROD_DB_PASS")
    )
    
  } else {
    stop("[DB ABORT] Unknown ENV_MODE: '", mode,
         "'. Use synthetic, live_yahoo, or production.", call. = FALSE)
  }
  con
}