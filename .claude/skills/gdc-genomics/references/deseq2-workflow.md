# DESeq2 Workflow Reference

## Design Formulas

### Unpaired (standard two-group comparison)

```r
dds <- DESeq2::DESeqDataSetFromMatrix(
  countData = counts,
  colData = col_data,
  design = ~ condition
)
```

### Paired Longitudinal (within-patient comparison)

**Use `~ patient_id + visit` where patient_id is the blocking factor and visit captures the treatment/relapse effect.**

```r
# Only include patients with >= 2 timepoints
dds <- DESeq2::DESeqDataSetFromMatrix(
  countData = counts,
  colData = col_data,
  design = ~ patient_id + visit  # patient blocks inter-patient variability
)
```

- `patient_id` must be a factor
- `visit` should be a factor with levels `c("baseline", "relapsed")`
- The coefficient of interest is the last one: `resultsNames(dds)` → look for `visit_relapsed_vs_baseline`

### Multi-factor

```r
design = ~ batch + treatment  # batch as blocking, treatment as effect
```

## Running DESeq2

```r
dds <- DESeq2::DESeq(dds)
res <- DESeq2::results(dds)
```

## LFC Shrinkage (MANDATORY for reporting)

**Always use `type = "apeglm"` — NOT `"normal"` or `"ashr"`.**

```r
coef_name <- DESeq2::resultsNames(dds)[2]
res_shrunk <- DESeq2::lfcShrink(
  dds,
  coef = coef_name,
  type = "apeglm"
)
```

- `apeglm` provides adaptive t-prior shrinkage (Zhu, Ibrahim, Love 2019)
- Produces more accurate fold-change estimates, especially for low-count genes
- The `coef` argument must be a character string from `resultsNames(dds)`, NOT a numeric index for apeglm

### For paired designs:

```r
coef_names <- DESeq2::resultsNames(dds)
visit_coef <- grep("^visit", coef_names, value = TRUE)
res_shrunk <- DESeq2::lfcShrink(dds, coef = visit_coef[1], type = "apeglm")
```

## Count Extraction from SummarizedExperiment

```r
assay_names <- SummarizedExperiment::assayNames(se_data)
if ("unstranded" %in% assay_names) {
  counts <- SummarizedExperiment::assay(se_data, "unstranded")
} else if ("counts" %in% assay_names) {
  counts <- SummarizedExperiment::assay(se_data, "counts")
} else {
  counts <- SummarizedExperiment::assay(se_data, 1)
}
storage.mode(counts) <- "integer"  # DESeq2 requires integer counts
```

## Pre-filtering

Remove low-count genes before running DESeq2:

```r
min_samples <- ncol(dds) * 0.1  # at least 10% of samples
keep <- rowSums(counts(dds) >= 10) >= min_samples
dds <- dds[keep, ]
```

## GSEA Gene Ranking

### Preferred: DESeq2 Wald statistic

```r
ranks <- res$stat
names(ranks) <- rownames(res)
ranks <- sort(ranks, decreasing = TRUE)
```

### Fallback: p-value + fold change

```r
pval <- res$pvalue
pval[pval == 0] <- .Machine$double.xmin  # avoid Inf
ranks <- -log10(pval) * sign(res$log2FoldChange)
names(ranks) <- rownames(res)
ranks <- sort(ranks, decreasing = TRUE)
```

## MSigDB Collection Map

| Shorthand | Category | Subcategory | Description |
|-----------|----------|-------------|-------------|
| `hallmark` | `"H"` | `NULL` | 50 hallmark gene sets |
| `kegg` | `"C2"` | `"CP:KEGG_MEDICUS"` | KEGG pathway database |
| `reactome` | `"C2"` | `"CP:REACTOME"` | Reactome pathways |
| `go_bp` | `"C5"` | `"GO:BP"` | Gene Ontology Biological Process |
| `go_mf` | `"C5"` | `"GO:MF"` | Gene Ontology Molecular Function |
| `go_cc` | `"C5"` | `"GO:CC"` | Gene Ontology Cellular Component |
| `c2` | `"C2"` | `NULL` | All curated gene sets |
| `c7` | `"C7"` | `NULL` | Immunologic signatures |

### msigdbr Usage

```r
# Hallmark
msigdb_df <- msigdbr::msigdbr(species = "Homo sapiens", category = "H")

# KEGG
msigdb_df <- msigdbr::msigdbr(
  species = "Homo sapiens",
  category = "C2",
  subcategory = "CP:KEGG_MEDICUS"
)

# Convert to fgsea-compatible list
gene_sets <- split(msigdb_df$ensembl_gene, msigdb_df$gs_name)
```

### Local Gene Sets (CoMMpass workaround)

msigdbr has a broken Nix hash. Use pre-converted local parquet files:

```r
pq_file <- system.file("extdata", "msigdb", "hallmark_ensembl.parquet",
                        package = "coMMpass")
pq_df <- arrow::read_parquet(pq_file)
gene_sets <- split(pq_df$ensembl_gene, pq_df$gs_name)
```

## fgsea Invocation

```r
gsea_res <- fgsea::fgsea(
  pathways = gene_sets,
  stats = ranked_genes,   # named numeric vector, sorted decreasing
  minSize = 15L,
  maxSize = 500L
)
```

## Ensembl Version Stripping (MANDATORY)

Gene IDs from GDC include version suffixes. **Strip before matching to any gene set:**

```r
genes <- sub("\\.\\d+$", "", rownames(de_table))
# ENSG00000141510.17 -> ENSG00000141510
```

Also handle duplicates after stripping (keep gene with largest absolute rank).

## Consensus DE Genes

Different p-value column names across methods:

| Method | Adjusted p-value column | Fold change column |
|--------|------------------------|--------------------|
| DESeq2 | `padj` | `log2FoldChange` |
| edgeR | `FDR` | `logFC` |
| limma | `adj.P.Val` | `logFC` |
