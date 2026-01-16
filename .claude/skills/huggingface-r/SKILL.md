# Hugging Face Integration for R

## Description

R packages for integrating with Hugging Face Hub - downloading models, loading tokenizers, and working with safetensors format. Enables ML/AI workflows in R using pre-trained models from the Hugging Face ecosystem.

## Purpose

Use this skill when:
- Downloading pre-trained models from Hugging Face Hub
- Tokenizing text for NLP tasks
- Loading model weights in safetensors format
- Building R applications with Hugging Face models
- Deploying R Shiny apps to Hugging Face Spaces

## Core Packages

### Package Overview

| Package | Purpose | Backend |
|---------|---------|---------|
| `hfhub` | Download/cache files from HF Hub | Python cache layout |
| `tok` | Tokenizers (text → integers) | Rust via extendr |
| `safetensors` | Read/write model weights | Rust via extendr |

### Installation

```r
# All available on CRAN
install.packages(c("hfhub", "tok", "safetensors"))
```

**Nix Considerations:**
```nix
# In your rix configuration, add:
r_pkgs = [ "hfhub" "tok" "safetensors" ];

# tok and safetensors use Rust (extendr) - may need:
# - Rust toolchain in buildInputs
# - cargo available during build
```

## Basic Workflow

### 1. Download Model from Hub

```r
library(hfhub)

# Download a specific file from a model repository
model_path <- hub_download(
  repo_id = "gpt2",
  filename = "model.safetensors"
)

# Download with specific revision/branch
model_path <- hub_download(
  repo_id = "stabilityai/stablelm-3b-4e1t",
  filename = "model.safetensors",
  revision = "main"
)

# Files are cached - subsequent calls are instant
# Cache location compatible with Python's huggingface_hub
```

### 2. Load Tokenizer

```r
library(tok)

# Load pre-trained tokenizer matching the model
tokenizer <- tokenizer$from_pretrained("gpt2")

# Encode text to token IDs
encoded <- tokenizer$encode("Hello, world!")
encoded$ids
#> [1] 15496   11   995    0

# Decode back to text
tokenizer$decode(encoded$ids)
#> [1] "Hello, world!"

# Batch encoding
texts <- c("First sentence.", "Second sentence.")
batch <- tokenizer$encode_batch(texts)
lapply(batch, function(x) x$ids)
```
### 3. Load Model Weights

```r
library(safetensors)

# Read safetensors file
weights <- safe_load_file(model_path)

# weights is a named list of tensors
names(weights)
#> [1] "wte.weight" "wpe.weight" "h.0.ln_1.weight" ...

# Access individual tensors
embedding_weights <- weights[["wte.weight"]]
dim(embedding_weights)
```

## Complete Example: Text Generation Setup

```r
library(hfhub)
library(tok)
library(safetensors)

# 1. Download model files
model_dir <- hub_download("gpt2", "model.safetensors")
config_path <- hub_download("gpt2", "config.json")

# 2. Load tokenizer
tokenizer <- tok::tokenizer$from_pretrained("gpt2")

# 3. Load weights
weights <- safe_load_file(model_dir)

# 4. Tokenize input
input_text <- "The future of AI is"
tokens <- tokenizer$encode(input_text)

cat("Input:", input_text, "\n")
cat("Token IDs:", tokens$ids, "\n")
cat("Model has", length(weights), "weight tensors\n")

# Note: Actual inference requires a framework like torch
# This setup prepares all components for model use
```

## Hugging Face Spaces Deployment

Deploy R Shiny apps to Hugging Face Spaces for free hosting.

### Space Configuration

Create `app.R` for your Shiny app, then add:

**`Dockerfile`:**
```dockerfile
FROM rocker/shiny:latest

# Install R packages
RUN R -e "install.packages(c('shiny', 'hfhub', 'tok'))"

# Copy app
COPY app.R /srv/shiny-server/

# Expose port
EXPOSE 7860

CMD ["R", "-e", "shiny::runApp('/srv/shiny-server/app.R', host='0.0.0.0', port=7860)"]
```

**`README.md` (Space metadata):**
```yaml
---
title: My R Shiny App
emoji: 📊
colorFrom: blue
colorTo: green
sdk: docker
app_port: 7860
---
```

### Create Space via R

```r
# Using httr2 to create a Space
library(httr2)

# Requires HF_TOKEN environment variable
request("https://huggingface.co/api/repos/create") |>
request_auth_bearer_token(Sys.getenv("HF_TOKEN")) |>
  req_body_json(list(
    type = "space",
    name = "my-r-shiny-app",
    sdk = "docker",
    private = FALSE
  )) |>
  req_perform()
```

## Cache Management

### Cache Location

```r
# hfhub uses same cache as Python's huggingface_hub
# Default: ~/.cache/huggingface/hub/

# Check cache location
Sys.getenv("HF_HOME")  # Override with this env var

# List cached files
list.files("~/.cache/huggingface/hub", recursive = TRUE)
```

### Sharing Cache with Python

```r
# If using reticulate with Python HF libraries,
# both languages share the same cache automatically

library(reticulate)
hf <- import("huggingface_hub")

# Files downloaded by R are available to Python and vice versa
```

## Common Models

| Model | Repo ID | Use Case |
|-------|---------|----------|
| GPT-2 | `gpt2` | Text generation |
| BERT | `bert-base-uncased` | Classification, embeddings |
| Stable LM | `stabilityai/stablelm-3b-4e1t` | Text generation |
| Whisper | `openai/whisper-tiny` | Speech-to-text |
| CLIP | `openai/clip-vit-base-patch32` | Image-text matching |

## Integration with torch

For actual model inference, combine with the `torch` package:

```r
library(torch)
library(hfhub)
library(safetensors)

# Download and load weights
model_path <- hub_download("gpt2", "model.safetensors")
weights <- safe_load_file(model_path)

# Convert to torch tensors
torch_weights <- lapply(weights, function(w) {
  torch_tensor(w)
})

# Use in torch model...
# (Requires implementing model architecture in torch)
```

## Error Handling

```r
# Handle download failures
tryCatch({
  path <- hub_download("nonexistent/model", "file.bin")
}, error = function(e) {
  message("Model not found: ", e$message
)
})

# Check if file exists before downloading
hub_file_exists <- function(repo_id, filename) {
  tryCatch({
    hub_download(repo_id, filename)
    TRUE
  }, error = function(e) FALSE)
}
```

## Best Practices

1. **Cache models**: Don't re-download; hfhub caches automatically
2. **Match tokenizer to model**: Always use the tokenizer trained with the model
3. **Check model license**: Respect usage restrictions on HF Hub
4. **Pin revisions**: Use specific commits for reproducibility
5. **Handle large files**: Some models are multi-GB; ensure disk space

## Limitations

- **No inference engine**: These packages load models but don't run inference
- **Need torch/keras**: For actual predictions, integrate with torch or keras
- **Rust dependencies**: tok and safetensors require Rust toolchain to build from source
- **Large downloads**: Models can be GB-sized; first download is slow

## Resources

- [hfhub on CRAN](https://cran.r-project.org/package=hfhub)
- [tok on CRAN](https://cran.r-project.org/package=tok)
- [safetensors on CRAN](https://cran.r-project.org/package=safetensors)
- [Hugging Face Hub](https://huggingface.co/models)
- [RStudio AI Blog: HF Integrations](https://blogs.rstudio.com/ai/posts/2023-07-12-hugging-face-integrations/)
- [Hugging Face Spaces](https://huggingface.co/spaces)

## Related Skills

- data-wrangling-duckdb (for data preprocessing)
- parallel-processing (for batch inference)
- shinylive-deployment (note: HF packages won't work in WASM)
