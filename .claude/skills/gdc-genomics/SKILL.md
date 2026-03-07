# GDC Genomics Spec-Bundled Skill

## When to Activate

Consult the `references/` directory before generating code for ANY of these tasks:

- **GDC data queries**: `GDCquery()`, `GDCquery_clinic()`, field names, valid enumerations
- **DESeq2 analysis**: Design formulas, shrinkage method, count extraction, paired designs
- **Survival analysis**: Time construction from GDC clinical fields, age conversion
- **MSigDB / pathway analysis**: Collection identifiers, gene ID handling, fgsea ranking
- **CoMMpass-specific**: Barcode parsing, cytogenetic markers, ISS staging, risk classification

## How to Use

1. **Before generating a GDCquery() call** → Read `references/tcgabiolinks-patterns.md`
2. **Before writing DESeq2 code** → Read `references/deseq2-workflow.md`
3. **Before using clinical field names** → Read `references/gdc-data-dictionary.md`
4. **Before parsing CoMMpass barcodes or cytogenetics** → Read `references/commpass-schema.md`

## Top Validation Rules (Quick Reference)

| Rule | Detail |
|------|--------|
| Age is in DAYS | `age_at_diagnosis / 365.25` to get years. Auto-detect: if max > 120, it's days. |
| Assay name is `"unstranded"` | NOT `"counts"`, NOT `"raw_counts"`. Use `SummarizedExperiment::assay(se, "unstranded")`. |
| Strip Ensembl versions | `sub("\\.\\d+$", "", gene_id)` before matching to MSigDB or any gene set. |
| Shrinkage = apeglm | `lfcShrink(dds, coef = resultsNames(dds)[2], type = "apeglm")`. NEVER `"normal"` or `"ashr"`. |
| Paired design | `~ patient_id + visit` — patient is blocking factor, visit is the effect of interest. |
| Survival time | `ifelse(dead, days_to_death, days_to_last_follow_up)` then filter `time > 0`. |
| vital_status values | `"Alive"`, `"Dead"`, `"Not Reported"` — case-sensitive from GDC. |
| GSEA ranking | Prefer DESeq2 Wald `stat`; fallback: `-log10(pvalue) * sign(log2FoldChange)`. |
| MSigDB Hallmark | Category `"H"`, subcategory `NULL`. |
| MSigDB KEGG | Category `"C2"`, subcategory `"CP:KEGG_MEDICUS"`. |
| ISS NA values | Treat `""` and `"Not Reported"` as `NA`. |

## Spec Version

- **GDC Data Dictionary**: v2 (as of 2026-01)
- **Source project**: coMMpass R package (`R/data_dictionary.R`, `R/01_data_acquisition.R`, etc.)
- **MSigDB**: v2024.1.Hs (Hallmark, C2, C5, C7)
