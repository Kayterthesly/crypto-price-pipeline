# =============================================================================
# infra/Dockerfile
# Pipeline: crypto-price-pipeline
# Stage: 6 — Containerized Plumber API
# Build: docker build -f infra/Dockerfile -t crypto-price-pipeline .
# Run:   docker run -p 8000:8000 \
#          -e ENV_MODE=live_yahoo \
#          -v $(pwd)/data:/app/data \
#          crypto-price-pipeline
# =============================================================================

FROM rocker/r-ver:4.5.0

RUN apt-get update && apt-get install -y \
    libssl-dev \
    libcurl4-openssl-dev \
    libxml2-dev \
    libfontconfig1-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy renv files first — Docker cache layer:
# packages only reinstall if renv.lock changes
COPY renv.lock       renv.lock
COPY renv/activate.R renv/activate.R
COPY renv/settings.json renv/settings.json
COPY renv/.gitignore renv/.gitignore
COPY .Rprofile       .Rprofile

# Install renv and restore packages
RUN R -e "install.packages('renv', repos='https://cloud.r-project.org')"
RUN R -e "renv::restore(clean = TRUE, prompt = FALSE)"

# Copy application code (after package install for better cache utilization)
COPY r_scripts/ r_scripts/
COPY api/        api/

# Create runtime directories
RUN mkdir -p data models notes

# Environment variables — override at runtime:
#   docker run -e ENV_MODE=live_yahoo ...
#   NEVER put actual credentials here — use -e or secrets manager
ENV ENV_MODE=synthetic
ENV DB_PATH=data/crypto_prices.duckdb
ENV LOG_LEVEL=INFO
# Railway uses dynamic PORT — expose hint only
EXPOSE 8000

# Health check uses dynamic port
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=5 \
  CMD curl -f http://localhost:${PORT:-8000}/health || exit 1

# CMD (not ENTRYPOINT) allows Railway to inject PORT at runtime
CMD ["R", "--no-save", "-e", "source('api/run_api.R')"]