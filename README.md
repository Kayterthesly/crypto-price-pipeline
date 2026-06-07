# crypto-price-pipeline

Production-Grade Crypto Price Analysis and Forecasting Pipeline  
**Author:** Kingsley Akenu (@Kayterthesly / KAIZEN 改善)  
**Stack:** R 4.5.2 · DuckDB · tidyquant · ARIMA · ETS · Plumber · Shiny

---

## Pipeline Log

### Stage 0 — Workspace Setup
**Date:** 2026-06-06 | **Commit:** 6176aab | **Status:** Complete
- renv initialized, packages locked: here, logger, purrr
- `.Renviron`: ENV_MODE=synthetic, DB_PATH=data/crypto_prices.duckdb
- Crypto-native constants: sqrt(365) annualization, ts_frequency=1
- 9 directories scaffolded including tests/integration/

### Stage 1 — Data Ingestion
**Date:** 2026-06-07 | **Commit:** 0f3a07c | **Status:** ✅ Complete

- DuckDB store: `data/crypto_prices.duckdb`
- Table: `raw_prices` — PRIMARY KEY (symbol, date)
- Crypto-native: no weekday filter, 365-day calendar
- Symbols: BTC-USD (1,825 rows, 100% coverage) | ETH-USD (1,826 rows)
- Upsert pattern: multi-symbol safe, idempotent

