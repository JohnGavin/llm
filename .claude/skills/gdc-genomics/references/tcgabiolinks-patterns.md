# TCGAbiolinks Query Patterns

## Standard RNA-seq Query

```r
query <- TCGAbiolinks::GDCquery(
  project = "MMRF-COMMPASS",
  data.category = "Transcriptome Profiling",
  data.type = "Gene Expression Quantification",
  workflow.type = "STAR - Counts"
)
```

**NEVER use:**
- `workflow.type = "HTSeq - Counts"` (legacy, deprecated)
- `data.type = "Gene Expression"` (wrong value)
- `data.category = "RNA-Seq"` (wrong value)

## Subsetting by Barcode

```r
query_results <- TCGAbiolinks::getResults(query)
selected_barcodes <- query_results$cases[1:100]

query_subset <- TCGAbiolinks::GDCquery(
  project = "MMRF-COMMPASS",
  data.category = "Transcriptome Profiling",
  data.type = "Gene Expression Quantification",
  workflow.type = "STAR - Counts",
  barcode = selected_barcodes
)
```

## Download and Prepare Pipeline

```r
# Step 1: Download (creates GDCdata/ directory)
TCGAbiolinks::GDCdownload(query, directory = data_dir)

# Step 2: Prepare (returns SummarizedExperiment)
se_data <- TCGAbiolinks::GDCprepare(query, directory = data_dir)

# Step 3: Extract raw counts
counts <- SummarizedExperiment::assay(se_data, "unstranded")

# Step 4: Extract metadata
col_data <- as.data.frame(SummarizedExperiment::colData(se_data))
row_data <- as.data.frame(SummarizedExperiment::rowData(se_data))
```

## Clinical Data Query

```r
# Clinical data (demographics, diagnosis, outcomes)
clinical <- TCGAbiolinks::GDCquery_clinic(
  project = "MMRF-COMMPASS",
  type = "clinical"
)

# Biospecimen data (sample characteristics)
biospecimen <- TCGAbiolinks::GDCquery_clinic(
  project = "MMRF-COMMPASS",
  type = "biospecimen"
)
```

## Known GDC Projects

| Project | Disease | Notes |
|---------|---------|-------|
| `MMRF-COMMPASS` | Multiple Myeloma | ~860 patients, longitudinal |
| `TCGA-*` | Various cancers | 33 cancer types |
| `TARGET-*` | Pediatric cancers | AML, ALL, neuroblastoma, etc. |

## Parquet Export Pattern

SummarizedExperiment objects contain list columns that arrow cannot write directly. Flatten before export:

```r
sample_meta <- as.data.frame(SummarizedExperiment::colData(se))
list_cols <- sapply(sample_meta, function(x) is.list(x) && !is.data.frame(x))
if (any(list_cols)) {
  for (col_name in names(sample_meta)[list_cols]) {
    sample_meta[[col_name]] <- sapply(
      sample_meta[[col_name]],
      function(x) if (length(x) == 0) NA_character_ else paste(x, collapse = "; ")
    )
  }
}
arrow::write_parquet(sample_meta, "sample_metadata.parquet", compression = "zstd")
```

## AWS S3 Open Access Bucket

CoMMpass data is also available via public S3:

```r
bucket <- "gdc-mmrf-commpass-phs000748-2-open"
region <- "us-east-1"
# Anonymous access (key = "", secret = "")
```
