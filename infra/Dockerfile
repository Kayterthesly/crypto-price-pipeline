FROM rocker/r-ver:4.5.0

# ── System libraries ──────────────────────────────────────────────────────────
# Required by: duckdb (cmake/g++), sodium (libsodium), plotly/shiny/plumber
# (libcurl/ssl/xml2), PKI/jose (libssl), tidyquant fonts (fontconfig/freetype)
RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libsodium-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    libgit2-dev \
    cmake \
    g++ \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ── Posit Package Manager — pre-compiled Linux binaries (Ubuntu 24.04 Noble) ──
# This eliminates all from-source compilation. duckdb, shiny, plotly etc.
# are downloaded as ready-to-use binaries instead of compiled from C++.
ENV RENV_CONFIG_REPOS_OVERRIDE="https://packagemanager.posit.co/cran/__linux__/noble/latest"

# ── renv bootstrap ────────────────────────────────────────────────────────────
COPY renv.lock renv.lock
COPY renv/activate.R renv/activate.R
COPY renv/.gitignore renv/.gitignore
COPY renv/settings.json renv/settings.json
COPY .Rprofile .Rprofile

RUN R -e "install.packages('renv', repos='https://packagemanager.posit.co/cran/__linux__/noble/latest')"
RUN R -e "renv::restore(clean = TRUE, prompt = FALSE)"

# ── Application code ──────────────────────────────────────────────────────────
COPY r_scripts/ r_scripts/
COPY api/ api/
COPY dashboard/ dashboard/

RUN mkdir -p data models notes

# ── Runtime ───────────────────────────────────────────────────────────────────
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=5 \
  CMD curl -f http://localhost:${PORT:-8000}/health || exit 1

CMD ["R", "--no-save", "-e", "source('api/run_api.R')"]