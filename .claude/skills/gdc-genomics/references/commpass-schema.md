# CoMMpass-Specific Schema Reference

## Barcode Formats

### Short barcode
```
MMRF_1234_1_BM
│    │    │ └── Tissue: BM = Bone Marrow
│    │    └──── Visit number (1 = baseline, 2+ = follow-up)
│    └───────── 4-digit patient ID (0001-2149)
└────────────── MMRF prefix (always)
```

### GDC long barcode
```
MMRF_1234_1_BM_CD138pos_T1_TSMRU
│    │    │ │  │         │  └── Processing code
│    │    │ │  │         └──── Tissue number
│    │    │ │  └────────────── Cell selection (CD138+)
│    │    │ └───────────────── Tissue type
│    │    └─────────────────── Visit number
│    └──────────────────────── Patient ID
└───────────────────────────── MMRF prefix
```

### Parsing Pattern

```r
# Extract patient ID (4 digits after MMRF_)
patient_ids <- stringr::str_extract(barcodes, "(?<=MMRF_)\\d{4}")

# Extract visit number (single digit after MMRF_XXXX_)
visit_numbers <- stringr::str_extract(barcodes, "(?<=MMRF_\\d{4}_)\\d")

# Binary visit factor for paired analysis
visit <- factor(
  ifelse(visit_number == 1, "baseline", "relapsed"),
  levels = c("baseline", "relapsed")
)
```

## Cytogenetic Markers

### Marker List and Regex Patterns

| Marker | Clinical Significance | Column Pattern (regex) |
|--------|----------------------|----------------------|
| `t(4;14)` | High risk | `t\(?4[;,]14\)?|whsc1|nsd2|fgfr3` |
| `t(11;14)` | Standard risk (favorable) | `t\(?11[;,]14\)?|ccnd1` |
| `t(14;16)` | High risk | `t\(?14[;,]16\)?|maf[^b]|c.maf` |
| `t(14;20)` | High risk | `t\(?14[;,]20\)?|mafb` |
| `del(17p)` | High risk (TP53 loss) | `del\(?17p|tp53.*del|17p.*del` |
| `del(1p)` | Adverse | `del\(?1p|1p.*del` |
| `gain(1q)` | High risk | `gain\(?1q|1q.*gain|amp\(?1q` |

### Status Value Parsing

GDC clinical data uses inconsistent representations. Standardize:

```r
# Positive values
c("yes", "1", "true", "positive", "present", "y") -> "positive"

# Negative values
c("no", "0", "false", "negative", "absent", "n") -> "negative"

# Everything else -> NA
```

## IMWG 2014 Risk Classification

### High-risk markers
- `t(4;14)` — WHSC1/NSD2 dysregulation
- `t(14;16)` — c-MAF dysregulation
- `t(14;20)` — MAFB dysregulation
- `del(17p)` — TP53 loss
- `gain(1q)` — CKS1B amplification

### Standard-risk markers
- `t(11;14)` — CCND1 dysregulation (favorable prognosis)
- None of the high-risk markers present

### Classification Logic

```r
high_risk_markers <- c("t_4_14", "t_14_16", "t_14_20", "del_17p", "gain_1q")
is_high_risk <- any(markers[high_risk_markers] == "positive", na.rm = TRUE)
has_any_data <- any(!is.na(markers[high_risk_markers]))

risk_group <- case_when(
  !has_any_data ~ NA_character_,
  is_high_risk  ~ "high",
  TRUE          ~ "standard"
)
```

## ISS Staging

International Staging System for Multiple Myeloma:
- **Stage I**: Serum beta-2 microglobulin < 3.5 mg/L, albumin >= 3.5 g/dL
- **Stage II**: Neither I nor III
- **Stage III**: Serum beta-2 microglobulin >= 5.5 mg/L

### ISS NA Handling

**CRITICAL: Treat empty strings and "Not Reported" as NA:**

```r
surv$iss_stage[surv$iss_stage %in% c("", "Not Reported", "not reported")] <- NA
```

## Survival Time Construction

```r
vital <- tolower(clinical$vital_status)
is_dead <- vital %in% c("dead", "deceased", "1")

# Event indicator: 1 = dead, 0 = censored
status <- as.integer(is_dead)

# Time: use appropriate endpoint
time_days <- NA_real_
time_days[is_dead]  <- as.numeric(clinical$days_to_death[is_dead])
time_days[!is_dead] <- as.numeric(clinical$days_to_last_follow_up[!is_dead])

# CRITICAL: Filter invalid times
valid <- !is.na(time_days) & time_days > 0
```

### Survival Formula

```r
# Overall
survival::Surv(time_days, status) ~ 1

# Stratified by risk
survival::Surv(time_days, status) ~ risk_group

# Cox regression
survival::Surv(time_days, status) ~ age_years + gender + risk_group
```

## CoMMpass Study Details

- **Full name**: Multiple Myeloma Research Foundation CoMMpass Study
- **GDC project**: `MMRF-COMMPASS`
- **Patients**: ~860 newly diagnosed multiple myeloma patients
- **Design**: Longitudinal (baseline + follow-up visits)
- **Data types**: WGS, WES, RNA-seq, clinical, cytogenetic
- **Median age**: ~69 years at diagnosis
- **Key feature**: Paired samples enable within-patient longitudinal analysis
