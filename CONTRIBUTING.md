# Contributing to crypto-price-pipeline

Thank you for your interest in contributing!

## How to Contribute

1. Fork the repository
2. Create a feature branch: `git checkout -b feat/your-feature`
3. Follow the existing code style:
   - Always `here::here()` for file paths
   - Always namespace dplyr: `dplyr::filter()`, `dplyr::lag()`
   - Always `on.exit(DBI::dbDisconnect(con, shutdown=TRUE)); gc()` for DuckDB
   - Conventional commits: `feat:`, `fix:`, `docs:`, `chore:`, `test:`
4. Run tests before submitting:
   ```r
   testthat::test_file(here::here('tests','unit','test_features.R'))
   testthat::test_file(here::here('tests','unit','test_modeling.R'))
   ```
   ```bash
   Rscript tests/data_tests.R
   ```
5. Open a Pull Request with a clear description

## Crypto-Native Rules (Non-Negotiable)

- Annualization: `sqrt(365)` — NEVER `sqrt(252)`
- `ts(frequency = 1)` — no forced seasonality
- No weekday filter — crypto trades 365 days/year
- Model versioning: UUID suffix — never timestamps as PKs

## Reporting Issues

Open a GitHub Issue with: R version, OS, exact error + stack trace, steps to reproduce.

## Contact

Kingsley Akenu — [@Kayterthesly](https://github.com/Kayterthesly)
