---
name: mlops-deployment
description: Use when deploying ML models to production using pins, vetiver, and plumber, implementing model versioning, serving APIs, monitoring, or rollback. Triggers: MLOps, model deployment, vetiver, pins, model serving, model monitoring, production ML.
---
# MLOps Deployment

## Description

Patterns for model versioning, packaging, serving, and monitoring in production using `pins`, `vetiver`, and `plumber`. Covers the full lifecycle from trained model to deployed API with rollback capability.

## Purpose

Use this skill when:
- Versioning trained models or datasets for reproducibility
- Deploying a model as a REST API
- Setting up prediction logging and audit trails
- Implementing model rollback
- Containerising model-serving infrastructure

## Model Versioning with pins

`pins` provides versioned, shareable storage for models, datasets, and other R objects.

### Local Board (Development)

```r
library(pins)

# Create a local pin board
board <- board_folder("pins-board", versioned = TRUE)

# Pin a trained model
pin_write(board, trained_model, name = "credit_model", type = "rds")

# Pin with metadata
pin_write(
  board, trained_model,
  name = "credit_model",
  type = "rds",
  metadata = list(
    metrics = list(log_loss = 0.42, brier = 0.18),
    training_date = Sys.Date(),
    training_rows = nrow(training_data),
    features = names(training_data)
  )
)

# List versions
pin_versions(board, "credit_model")

# Read specific version
previous_model <- pin_read(board, "credit_model", version = "20260115T143022Z-abc12")
```

### Remote Boards (Production)

```r
# S3 board
board_s3 <- board_s3("my-models-bucket", prefix = "production/")

# Connect board (Posit Connect)
board_connect <- board_connect()

# Same API regardless of backend
pin_write(board_s3, model, name = "credit_model")
```

## Model Packaging with vetiver

`vetiver` wraps a trained model with metadata for deployment.

### Create a Vetiver Model

```r
library(vetiver)

# From a tidymodels workflow
v <- vetiver_model(
  trained_workflow,
  model_name = "credit_risk_v2",
  metadata = list(
    developer = "team-ml",
    dataset = "credit_2026q1",
    baseline_log_loss = 0.48
  )
)

# Inspect
v
```

### Version with pins

```r
# Write vetiver model to pin board
vetiver_pin_write(board, v)

# Read back (latest)
v_loaded <- vetiver_pin_read(board, "credit_risk_v2")

# Read specific version
v_prev <- vetiver_pin_read(board, "credit_risk_v2", version = "20260110T120000Z-xyz")
```

## Model Serving with plumber

### Generate API from Vetiver

```r
# Auto-generate plumber API
vetiver_write_plumber(board, "credit_risk_v2", file = "plumber.R")

# The generated API includes:
# - POST /predict endpoint
# - GET /ping health check
# - GET /metadata model info
```

### Custom Endpoints

Extend the `plumber2-web-api` skill patterns with model-specific endpoints:

```r
# inst/plumber/model_api.R

library(plumber)
library(vetiver)

board <- pins::board_folder("pins-board")
v <- vetiver_pin_read(board, "credit_risk_v2")

#* @apiTitle Credit Risk Model API
#* @apiVersion 2.0.0

#* Health check
#* @get /ping
function() {
  list(status = "ok", model = v$model_name, timestamp = Sys.time())
}

#* Predict credit risk
#* @post /predict
#* @serializer json
function(req) {
  new_data <- jsonlite::fromJSON(req$postBody)
  predictions <- predict(v, new_data, type = "prob")

  # Log prediction (see Prediction Logging below)
  log_prediction(new_data, predictions, v$model_name)

  predictions
}

#* Model metadata
#* @get /metadata
function() {
  list(
    model_name = v$model_name,
    version = v$metadata$version,
    metrics = v$metadata$metrics,
    features = v$metadata$features
  )
}
```

## Prediction Logging

Every prediction in production must be logged for auditing and monitoring.

```r
#' Log a prediction for audit trail
#'
#' @param input_data Input features (tibble)
#' @param predictions Model predictions (tibble)
#' @param model_name Name of the model that produced predictions
#' @param log_dir Directory for prediction logs
log_prediction <- function(
  input_data,
  predictions,
  model_name,
  log_dir = "logs/predictions"
) {
  fs::dir_create(log_dir)

  log_entry <- dplyr::bind_cols(
    tibble::tibble(
      prediction_id = uuid::UUIDgenerate(n = nrow(predictions)),
      model_name = model_name,
      timestamp = Sys.time()
    ),
    input_data,
    predictions
  )

  # Append to daily Parquet file
  log_file <- file.path(
    log_dir,
    paste0("predictions_", format(Sys.Date(), "%Y%m%d"), ".parquet")
  )

  if (file.exists(log_file)) {
    existing <- arrow::read_parquet(log_file)
    log_entry <- dplyr::bind_rows(existing, log_entry)
  }

  arrow::write_parquet(log_entry, log_file)
}
```

## Model Rollback

### Monitor and Rollback Pattern

```r
#' Check if current model is degraded and rollback if needed
#'
#' @param board A pins board
#' @param model_name Name of the pinned model
#' @param recent_actuals Tibble with columns: prediction_id, actual_outcome
#' @param threshold Maximum acceptable log loss
rollback_if_degraded <- function(board, model_name, recent_actuals, threshold = 0.5) {
  versions <- pins::pin_versions(board, model_name)

  if (nrow(versions) < 2) {
    cli::cli_alert_info("Only one version available, cannot rollback")
    return(invisible(NULL))
  }

  # Evaluate current model on recent actuals
  current_metrics <- evaluate_recent(board, model_name, recent_actuals)

  if (current_metrics$log_loss > threshold) {
    previous_version <- versions$version[2]  # Second most recent

    cli::cli_alert_warning(c(
      "Model {model_name} degraded: log_loss = {round(current_metrics$log_loss, 3)}",
      " (threshold: {threshold}). Rolling back to {previous_version}."
    ))

    # Pin the previous version as "current"
    prev_model <- pins::pin_read(board, model_name, version = previous_version)
    pins::pin_write(board, prev_model, name = model_name,
      metadata = list(rollback_from = versions$version[1], rollback_reason = "degraded_performance")
    )

    return(invisible(previous_version))
  }

  cli::cli_alert_success("Model {model_name} performing within threshold: {round(current_metrics$log_loss, 3)}")
  invisible(NULL)
}
```

## Containerised Deployment

```r
# Generate Dockerfile for the model API
vetiver::vetiver_write_docker(v, plumber_file = "plumber.R", path = ".")

# This creates a Dockerfile with:
# - R base image
# - Required packages
# - Model artifacts
# - plumber API
```

## targets Integration

```r
# R/tar_plans/plan_deployment.R
plan_deployment <- function() {
  list(
    tar_target(trained_model, fit_final_model(training_data)),
    tar_target(
      vetiver_model,
      vetiver::vetiver_model(trained_model, "my_model")
    ),
    tar_target(
      pinned_model,
      {
        board <- pins::board_folder("pins-board", versioned = TRUE)
        vetiver::vetiver_pin_write(board, vetiver_model)
        board
      }
    ),
    tar_target(
      api_file,
      {
        board <- pins::board_folder("pins-board")
        vetiver::vetiver_write_plumber(board, "my_model", file = "inst/plumber/api.R")
        "inst/plumber/api.R"
      },
      format = "file"
    )
  )
}
```

## Anti-Patterns

```r
# BAD: Model saved as loose .rds with no versioning
saveRDS(model, "model.rds")  # Which version? What data? What metrics?

# GOOD: Versioned pin with metadata
pin_write(board, model, "my_model", metadata = list(log_loss = 0.42))

# BAD: No prediction logging
predict(model, new_data)  # No audit trail

# GOOD: Every prediction logged
predictions <- predict(model, new_data)
log_prediction(new_data, predictions, "my_model")

# BAD: Manual model swaps in production
# "Just replace the .rds file on the server"

# GOOD: Versioned rollback
rollback_if_degraded(board, "my_model", recent_actuals)

# BAD: Serving model without health checks
# plumber API with only /predict

# GOOD: /ping, /metadata, /predict with logging
```

## Related Skills

- `modeling-baselines` - Models to deploy must have baseline comparisons
- `model-evaluation-calibration` - Evaluate before deploying
- `plumber2-web-api` - Base patterns for plumber APIs
- `data-validation-pointblank` - Validate inputs at API boundary
