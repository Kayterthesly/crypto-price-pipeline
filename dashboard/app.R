# =============================================================================
# dashboard/app.R
# Pipeline: crypto-price-pipeline
# Stage: 5 — Interactive Dashboard (Shiny + Plotly)
# Usage: shiny::runApp(here::here("dashboard"))
# NOTE: Stop the API before running — DuckDB allows one connection at a time
# Pre-fixes applied:
#   - Y-axis capped at 1.5× historical max (prevents CI explosion distortion)
#   - Date columns formatted as character before renderTable
#   - About tab data source uses direct Sys.getenv() not reactive
# =============================================================================

library(shiny)
library(plotly)
library(bslib)
library(dplyr)
library(DBI)
library(duckdb)
library(logger)
library(here)
library(httr)

source(here::here("r_scripts", "03_modeling.R"))

# =============================================================================
# UI
# =============================================================================
ui <- page_sidebar(
  title = "crypto-price-pipeline | Forecast Dashboard",
  theme = bs_theme(bootswatch = "flatly", base_font = font_google("Inter")),
  
  sidebar = sidebar(
    width = 280,
    h5("📈 Forecast Settings"),
    hr(),
    
    textInput("symbol", "Ticker Symbol", value = "BTC-USD",
              placeholder = "e.g. BTC-USD, ETH-USD"),
    
    sliderInput("horizon", "Forecast Horizon (days)",
                min = 5, max = 90, value = 30, step = 5),
    
    sliderInput("history_days", "History to Display (days)",
                min = 30, max = 365, value = 180, step = 30),
    
    hr(),
    actionButton("run", "▶  Run Forecast", class = "btn-primary w-100"),
    hr(),
    
    h6("Environment"),
    verbatimTextOutput("env_info", placeholder = TRUE)
  ),
  
  navset_card_tab(
    
    nav_panel("📊 Price & Forecast",
              plotlyOutput("price_chart", height = "500px"),
              br(),
              uiOutput("forecast_status")
    ),
    
    nav_panel("🔬 Model Info",
              br(),
              tableOutput("model_meta_table"),
              br(),
              h6("Forecast Table (first 10 rows)"),
              tableOutput("forecast_table")
    ),
    
    nav_panel("ℹ About",
              br(),
              p("This dashboard runs the full crypto-price-pipeline:"),
              tags$ol(
                tags$li("Reads price data from DuckDB (raw_prices)"),
                tags$li("Computes lag-safe technical features (feature_prices)"),
                tags$li("Fits auto.arima on log returns — frequency=1, no seasonality"),
                tags$li("Volatility annualized with sqrt(365) — crypto-native"),
                tags$li("Converts log return forecasts back to price levels"),
                tags$li("Displays historical prices + 95% forecast cone")
              ),
              hr(),
              # Direct Sys.getenv() — avoids bslib inline reactive rendering issue
              p(strong("Data source:"), Sys.getenv("ENV_MODE", unset = "synthetic")),
              p(strong("Author:"), "Kingsley Akenu (@Kayterthesly / KAIZEN 改善)"),
              p(strong("Annualization:"), "sqrt(365) — crypto trades 365 days/year"),
              p(strong("Pipeline commit:"), "See Model Info tab after running forecast")
    )
  )
)

# =============================================================================
# SERVER
# =============================================================================
server <- function(input, output, session) {
  
  forecast_data <- reactiveVal(NULL)
  error_message <- reactiveVal(NULL)
  
  # Environment info
  output$env_info <- renderText({
    paste0(
      "Mode: ", Sys.getenv("ENV_MODE", "synthetic"), "\n",
      "R:    ", paste(R.version$major, R.version$minor, sep = "."), "\n",
      "DB:   ", basename(Sys.getenv("DB_PATH", "crypto_prices.duckdb"))
    )
  })
  
  # Run forecast on button click
  observeEvent(input$run, {
    forecast_data(NULL)
    error_message(NULL)
    
    sym <- trimws(input$symbol)
    if (nchar(sym) == 0) {
      error_message("Please enter a ticker symbol (e.g. BTC-USD)")
      return()
    }
    
    withProgress(message = paste("Forecasting", sym, "..."), value = 0, {
      incProgress(0.2, detail = "Loading feature data...")
      
      result <- tryCatch({
        incProgress(0.3, detail = "Calling forecast API...")
        
        api_url <- Sys.getenv("API_BASE_URL", unset = "http://127.0.0.1:8000")
        api_key <- Sys.getenv("API_SECRET_KEY", unset = "")
        
        resp <- httr::POST(
          paste0(api_url, "/predict/price"),
          body    = jsonlite::toJSON(
            list(symbol = sym, horizon = as.integer(input$horizon)),
            auto_unbox = TRUE
          ),
          httr::content_type_json(),
          httr::add_headers("X-API-Key" = api_key)
        )
        
        if (httr::status_code(resp) != 200) {
          err_body <- jsonlite::fromJSON(
            httr::content(resp, "text", encoding = "UTF-8"))
          stop(err_body$error %||% "API call failed")
        }
        
        raw <- jsonlite::fromJSON(
          httr::content(resp, "text", encoding = "UTF-8"),
          simplifyDataFrame = TRUE
        )
        
        # Convert to same structure as direct compute_asset_forecasts()
        list(
          forecast_df   = as.data.frame(raw$forecast),
          model_meta    = raw$model_meta,
          model_version = raw$model_meta$model_version,
          rmse_test     = raw$model_meta$rmse_test
        )
      }, error = function(e) {
        error_message(paste("Error:", conditionMessage(e)))
        NULL
      })
      
      incProgress(0.4, detail = "Rendering chart...")
      forecast_data(result)
    })
  })
  
  # Price + Forecast chart
  output$price_chart <- renderPlotly({
    
    result       <- forecast_data()
    sym          <- trimws(input$symbol)
    history_days <- input$history_days
    cutoff_date  <- Sys.Date() - history_days
    
    # Load historical prices
    con <- tryCatch(get_db_connection(), error = function(e) NULL)
    if (is.null(con)) {
      return(plot_ly() |>
               layout(title = "Cannot connect to database — run the pipeline first"))
    }
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
    
    historical <- tryCatch({
      tbl(con, "raw_prices") |>
        dplyr::filter(symbol == !!sym, date >= !!cutoff_date) |>
        dplyr::arrange(date) |>
        dplyr::collect()
    }, error = function(e) NULL)
    
    fig <- plot_ly()
    
    # Historical price line
    if (!is.null(historical) && nrow(historical) > 0) {
      fig <- fig |>
        add_lines(data = historical, x = ~date, y = ~adjusted,
                  name = "Historical Price",
                  line = list(color = "#2196F3", width = 1.5))
    }
    
    # Forecast layers
    if (!is.null(result)) {
      fc <- result$forecast_df
      
      fig <- fig |>
        add_ribbons(data = fc, x = ~forecast_date,
                    ymin = ~price_lower, ymax = ~price_upper,
                    name = "95% CI",
                    fillcolor = "rgba(255,152,0,0.15)",
                    line = list(color = "transparent"),
                    hoverinfo = "skip") |>
        add_lines(data = fc, x = ~forecast_date, y = ~price_hat,
                  name = "Forecast",
                  line = list(color = "#FF9800", width = 2, dash = "dash"))
    }
    
    # Y-axis cap: 1.5× historical max prevents CI explosion distortion
    y_max <- if (!is.null(historical) && nrow(historical) > 0) {
      max(historical$adjusted, na.rm = TRUE) * 1.5
    } else NULL
    
    title_text <- if (is.null(result)) {
      paste(sym, "— Historical Prices (click Run Forecast)")
    } else {
      paste(sym, "— Historical +", input$horizon, "Day Forecast")
    }
    
    fig |> layout(
      title     = list(text = title_text, font = list(size = 14)),
      xaxis     = list(title = "Date", showgrid = FALSE),
      yaxis     = list(title = "Price (USD)", showgrid = TRUE,
                       gridcolor = "#f0f0f0",
                       range = if (!is.null(y_max)) list(0, y_max) else NULL),
      hovermode = "x unified",
      legend    = list(orientation = "h", y = -0.15),
      plot_bgcolor  = "#ffffff",
      paper_bgcolor = "#ffffff"
    )
  })
  
  # Status banner
  output$forecast_status <- renderUI({
    err <- error_message()
    res <- forecast_data()
    
    if (!is.null(err)) {
      div(class = "alert alert-danger", err)
    } else if (!is.null(res)) {
      div(class = "alert alert-success",
          paste0("✅ Forecast complete | Model: ", res$model_meta$model_type,
                 " | RMSE: ", round(res$model_meta$rmse_test, 5),
                 " | Version: ", substr(res$model_version, 1, 35), "..."))
    } else {
      div(class = "alert alert-info",
          "Set parameters and click ▶ Run Forecast to begin.")
    }
  })
  
  # Model metadata table
  output$model_meta_table <- renderTable({
    result <- forecast_data()
    req(result)
    meta <- result$model_meta
    data.frame(
      Field = c("Model Version","Symbol","Model Type","Train Rows",
                "Test Rows","Forecast Horizon","Test RMSE",
                "Last Price","Last Date","Data Hash","Created At"),
      Value = c(meta$model_version, meta$symbol, meta$model_type,
                meta$n_train, meta$n_test, meta$forecast_horizon,
                round(meta$rmse_test, 8), meta$last_price,
                meta$last_date, meta$data_hash, meta$created_at)
    )
  }, striped = TRUE, hover = TRUE, bordered = TRUE)
  
  # Forecast table — date formatted as character to prevent numeric rendering
  output$forecast_table <- renderTable({
    result <- forecast_data()
    req(result)
    result$forecast_df |>
      head(10) |>
      dplyr::mutate(
        forecast_date = format(forecast_date, "%Y-%m-%d"),
        price_hat     = round(price_hat,   2),
        price_lower   = round(price_lower, 2),
        price_upper   = round(price_upper, 2)
      ) |>
      dplyr::select(forecast_date, price_hat, price_lower, price_upper)
  }, striped = TRUE, hover = TRUE, bordered = TRUE)
}

# =============================================================================
# LAUNCH
# =============================================================================
shinyApp(ui = ui, server = server)