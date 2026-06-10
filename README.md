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


### Stage 2 — Feature Engineering
**Date:** 2026-06-07 | **Commit:** 3ae7000 | **Status:** ✅ Complete
- `feature_prices` table: 15 columns, both symbols preserved
- Crypto-native: vol_30 uses sqrt(365) = 19.105 annualization
- All rolling features lagged by 1 — zero leakage (1,775 rows verified)
- NA defense: coalesce adjusted/close in ingestion + forward-fill in features

### Stage 3 — Modeling & Forecasting
**Date:** 2026-06-07 | **Commit:** f0a2def | **Status:** ✅ Complete
- ARIMA on log returns, frequency=1 (no forced seasonality)
- Train: 1,300 | Test: 325 | RMSE: 0.023268
- UUID versioning: arima_BTCUSD_20260607_5ef82c4c
- model_registry table initialized in DuckDB
- Artifacts: .rds + .json saved to models/

### Stage 4 — REST API (Plumber)
**Date:** 2026-06-08 | **Commit:** 6c2fa55 | **Status:** ✅ Complete
- `GET /health` — liveness check, returns env_mode + pipeline name
- `POST /predict/price` — full ARIMA forecast over HTTP
- trace_id propagated: 6f3b2c3d-33e3-41ef-a3dd-9326de0168b6
- Input validation + tryCatch error handling on all endpoints

### Stage 5 — Dashboard
**Date:** 2026-06-08 | **Commit:** 4176ad2 | **Status:** ✅ Complete
- Shiny + Plotly, flatly theme, Inter font
- Tab 1: historical price + CI cone + forecast line (all pre-fixes applied)
- Tab 2: model metadata + formatted forecast table
- Tab 3: crypto-native rationale (sqrt(365) explained)
- Zero runtime bugs — all r-price-pipeline Stage 5 fixes pre-applied

### Stage 6 — Testing, Docker, GitHub Actions CI
**Date:** 2026-06-08 | **Status:** ✅ Complete
- testthat unit tests: features (6 tests PASS) + modeling (11 assertions PASS)
- data tests: 14 schema + integrity checks on production DuckDB
- Test isolation: dedicated `data/test_crypto.duckdb`, withr cleanup, gc() between calls
- Dockerfile: rocker/r-ver:4.5.0, HEALTHCHECK, no secrets in image
- GitHub Actions CI: lint → test → data validate → Docker build
- GitHub repo live: https://github.com/Kayterthesly/crypto-price-pipeline

### Stage 7A — Pipeline Completion
**Date:** 2026-06-09 | **Commit:** 01f6e47 | **Status:** ✅ Complete
- ETH-USD added to model_registry: ARIMA, RMSE=0.035621
- `batch_forecast_all_symbols()` — loops all symbols automatically
- `check_leakage()` expanded: now validates all 5 features (sma_50, sma_200, rolling_max, vol_30, rsi_14)
- Integration test: full chain verified (ingest → features → forecast → registry)

### Stage 7B — API Security
**Date:** 2026-06-09 | **Commit:** b5a5a76 | **Status:** ✅ Complete
- API key authentication: `X-API-Key` header required on all forecast endpoints
- Rate limiting: 10 requests per 60 seconds per client IP
- CORS headers: browser clients (shinyapps.io) can call the Railway API
- Dashboard wired to Railway API via `API_BASE_URL` env var with direct-call fallback

### Stage 7C — Automation & Drift Detection
**Date:** 2026-06-09 | **Commit:** f51c674 | **Status:** ✅ Complete
- GitHub Actions cron: daily at 02:00 UTC fetches live Yahoo Finance prices
- Automated retraining for all symbols on new data
- Drift detection: flags if new RMSE > 1.25x best historical RMSE or > 5% absolute threshold
- Refresh report saved to `notes/refresh_YYYY-MM-DD.json`

### Stage 7D — Showcase & Deployment
**Date:** 2026-06-10 | **Status:** ✅ Complete
- Live Dashboard: https://e9yw5n-kayterthesly.shinyapps.io/crypto-price-pipeline/
- Live API: https://crypto-price-pipeline-production.up.railway.app/health
- API: secured (X-API-Key), rate-limited, CORS-enabled, auto_unbox JSON
- LICENSE (MIT) + CONTRIBUTING.md added
- GitHub Secret `API_SECRET_KEY` configured for CI/CD
