# GDC Data Dictionary Reference

## Clinical Fields

| Field | Type | Units | Description | Typical Range |
|-------|------|-------|-------------|---------------|
| `submitter_id` | character | — | Patient ID from submitting institution | `MMRF_0001` to `MMRF_2149` |
| `project_id` | character | — | GDC project identifier | `MMRF-COMMPASS` |
| `age_at_diagnosis` | integer | **DAYS** | Age at primary diagnosis. **CRITICAL: stored in days, NOT years.** Divide by 365.25. | 10000-35000 (~27-96 years) |
| `gender` | character | — | Patient sex/gender | `female`, `male`, `not reported` |
| `race` | character | — | NIH race category | `white`, `black or african american`, `asian`, `not reported`, `other` |
| `ethnicity` | character | — | NIH ethnicity | `not hispanic or latino`, `hispanic or latino`, `not reported` |
| `vital_status` | character | — | Status at last follow-up | `Alive`, `Dead`, `Not Reported` |
| `days_to_death` | integer | days | Days from diagnosis to death. NA if alive. | 0-5000+ |
| `days_to_last_follow_up` | integer | days | Days from diagnosis to last follow-up. NA if deceased. | 0-5000+ |
| `primary_diagnosis` | character | — | ICD-O-3 morphology description | `Plasma cell myeloma`, `Myeloma NOS` |
| `disease_type` | character | — | Disease studied | `Multiple Myeloma` |
| `site_of_resection_or_biopsy` | character | — | Anatomic site of sample | `Bone marrow`, `Blood` |
| `tissue_or_organ_of_origin` | character | — | Anatomic site of disease | `Bone marrow` |
| `year_of_diagnosis` | integer | year | Calendar year of diagnosis | 2005-2020 |
| `classification_of_tumor` | character | — | Tumor classification | `primary`, `recurrence`, `metastasis`, `not reported` |
| `prior_malignancy` | character | — | Prior malignancy history | `yes`, `no`, `not reported` |
| `prior_treatment` | character | — | Prior treatment history | `yes`, `no`, `not reported` |
| `days_to_last_known_disease_status` | integer | days | Days to last disease assessment | 0-5000+ |

### Age Auto-Detection Pattern

GDC stores age in days. Some downstream datasets may already be converted to years. Use this pattern:

```r
age_raw <- as.numeric(clinical$age_at_diagnosis)
age_years <- ifelse(
  max(age_raw, na.rm = TRUE) > 120,
  round(age_raw / 365.25, 1),  # days -> years
  age_raw                        # already years
)
```

## Biospecimen Fields

| Field | Type | Description | Example Values |
|-------|------|-------------|----------------|
| `sample_submitter_id` | character | Sample ID from institution | `MMRF_0001_1_BM` |
| `sample_id` | character | GDC-assigned UUID | UUID format |
| `sample_type` | character | Type of sample | `Primary Blood Derived Cancer - Bone Marrow` |
| `sample_type_id` | character | Numeric code | `01`, `09`, `10` |
| `tissue_type` | character | Tumor vs normal | `Tumor`, `Normal` |
| `preservation_method` | character | Preservation method | `FFPE`, `Frozen` |
| `composition` | character | Sample composition | `Bone Marrow Components`, `Blood Derived` |

## RNA-seq Count Assays

**CRITICAL: Use `"unstranded"` for raw counts. This is the correct assay name in GDC STAR-Counts SummarizedExperiment objects.**

| Assay Name | Type | Units | Use For |
|------------|------|-------|---------|
| `unstranded` | integer | raw counts | **DESeq2/edgeR** (primary analysis) |
| `stranded_first` | integer | raw counts | dUTP protocol (alternative) |
| `stranded_second` | integer | raw counts | Second strand (rarely used) |
| `tpm_unstranded` | numeric | TPM | Visualization, cross-sample comparison only |
| `fpkm_unstranded` | numeric | FPKM | **Deprecated** — use TPM instead |
| `fpkm_uq_unstranded` | numeric | FPKM-UQ | Upper-quartile normalized FPKM |

### Assay Extraction Pattern

```r
assay_names <- SummarizedExperiment::assayNames(se)
if ("unstranded" %in% assay_names) {
  counts <- SummarizedExperiment::assay(se, "unstranded")
} else if ("counts" %in% assay_names) {
  counts <- SummarizedExperiment::assay(se, "counts")
} else {
  counts <- SummarizedExperiment::assay(se, 1)
  warning("Using first assay — 'unstranded' not found")
}
storage.mode(counts) <- "integer"  # DESeq2 requires integer
```

## RNA-seq Gene Metadata

| Field | Type | Description | Example |
|-------|------|-------------|---------|
| `gene_id` | character | Ensembl ID **with version** | `ENSG00000000003.15` |
| `gene_name` | character | HGNC gene symbol | `TP53`, `KRAS`, `MYC` |
| `gene_type` | character | GENCODE biotype | `protein_coding`, `lncRNA`, `miRNA`, `processed_pseudogene` |

### Ensembl Version Stripping

Gene IDs from GDC include version suffixes. **Always strip before matching to gene sets (MSigDB, KEGG, etc.):**

```r
gene_ids_clean <- sub("\\.\\d+$", "", gene_ids)
# ENSG00000000003.15 -> ENSG00000000003
```

## GDC API Links

- Clinical: `https://docs.gdc.cancer.gov/Data_Dictionary/viewer/#?view=table-definition-view&id=clinical`
- Biospecimen: `https://docs.gdc.cancer.gov/Data_Dictionary/viewer/#?view=table-definition-view&id=sample`
- RNA-seq pipeline: `https://docs.gdc.cancer.gov/Data/Bioinformatics_Pipelines/Expression_mRNA_Pipeline/`

## Valid Enumerations

### vital_status
`Alive`, `Dead`, `Not Reported`

### sample_type (common in CoMMpass)
`Primary Blood Derived Cancer - Bone Marrow`, `Blood Derived Cancer - Peripheral Blood`, `Solid Tissue Normal`

### data.category (for GDCquery)
`Transcriptome Profiling`, `Copy Number Variation`, `Simple Nucleotide Variation`, `DNA Methylation`, `Clinical`, `Biospecimen`

### workflow.type (for RNA-seq)
`STAR - Counts` (current standard), `HTSeq - Counts` (legacy)
