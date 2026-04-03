# Spec-Bundled Skills Pattern

## Pattern

A "spec-bundled skill" packages a domain specification (API schema, data dictionary, standard definition) as a reference file alongside a Claude skill prompt. This grounds the LLM in the actual spec rather than relying on training knowledge, reducing hallucination and improving output accuracy.

**Origin:** Stephen Turner's [brand.yml Claude skill](https://github.com/stephenturner/skill-brand-yml) demonstrated this pattern — bundling the full `brand-yml` specification as `references/brand-yml-spec.md` alongside `SKILL.md` instructions. Claude reads the spec at invocation time and generates valid YAML output.

## Directory Structure Convention (agentskills.io compliant)

```
skill-name/
  SKILL.md            # Required. Metadata frontmatter + instructions (<500 lines)
  references/         # Optional. Spec files, API docs, data dictionaries
    api_reference.md
    gotchas.md        # Hard-won lessons (highest-value content)
  scripts/            # Optional. Executable helper scripts (R, Python, bash)
    check_system.sh
    validate.R
  examples/           # Optional. Runnable worked examples with expected output
    basic-usage/
      input.csv
      run.R
      output/         # Expected output for verification
        result.csv
  evals/              # Optional. Test cases for skill quality evaluation
    evals.json        # Prompts + assertions per agentskills.io spec
    files/            # Input files for test cases
```

### When to Use Each Directory

| Directory | Use When | Don't Use When |
|-----------|----------|---------------|
| `references/` | Spec files, API docs, gotchas, detailed patterns | Content fits in SKILL.md (<500 lines) |
| `scripts/` | Reusable code the agent runs during the skill | One-off commands (put inline in SKILL.md) |
| `examples/` | Multi-step workflows with verifiable output | Simple pattern/convention skills |
| `evals/` | Testing whether the skill produces good outputs | Skill is too simple to need evaluation |

### Progressive Disclosure

1. **Metadata** (~100 tokens): `name` + `description` — loaded at startup for all skills
2. **Instructions** (<5000 tokens): SKILL.md body — loaded when skill activates
3. **Resources** (on demand): references/, scripts/, examples/ — loaded only when needed

### SKILL.md Frontmatter (MANDATORY)

```yaml
---
name: skill-name          # lowercase + hyphens, matches directory name
description: >
  Use when <imperative trigger>. Triggers: <keyword1>, <keyword2>.
---
```

See agentskills.io/specification for full spec. Audit with `Rscript .claude/scripts/audit_skills.R`.

## Critical Review

### Strengths
- **Grounded generation** — Claude generates output against the actual spec, not memory
- **Low risk** — outputs are declarative (YAML, JSON, config), trivially reviewable
- **Transferable** — anyone with Claude Code can use the skill without domain expertise
- **Versioned** — spec file tracks the version of the standard being targeted

### Weaknesses
- **Claude-specific** — not transferable to other LLMs without adaptation
- **Prompt engineering in disguise** — a `.skill` is just a well-structured system prompt
- **No programmatic validation** — Claude self-checks against the spec, but there's no schema validator step
- **Spec drift** — if the upstream spec changes, the bundled reference becomes stale
- **Context budget** — large specs consume tokens; must balance completeness vs. cost

### When to use this pattern
- The domain has a formal specification or data dictionary
- Claude would otherwise hallucinate field names, valid values, or API parameters
- The output is declarative (YAML, JSON, SQL DDL, config) rather than imperative code
- Multiple team members need the same domain knowledge without reading the full spec

### When NOT to use
- The spec is >50 pages (too much context; summarize instead)
- The domain is well-covered by Claude's training (e.g., standard SQL, common R packages)
- The output requires runtime validation that Claude can't perform

---

## Recommended Skills for Current Projects

### 1. `erddap-ocean-data` (irishbuoys)

**Spec to bundle:** ERDDAP tabledap API specification + Irish buoy variable dictionary.

**What it would contain:**
```
references/
  erddap-tabledap-spec.md    # Query syntax, constraints, response formats
  iwb-variables.md            # 22 oceanographic variables with units and QC flags
  beaufort-scale.md           # Wind speed classification (reused by storm alerts)
```

**Use cases:**
- Generate correct ERDDAP query URLs for new variables
- Map ERDDAP variable names to human-readable labels with units
- Build data dictionaries for new buoy stations
- Generate pointblank validation rules matching variable ranges

**Reusability:** Any project using ERDDAP servers (NOAA IOOS, Copernicus, Australian IMOS).

---

### 2. `gdc-genomics` (coMMpass)

**Spec to bundle:** GDC Data Dictionary + TCGAbiolinks query patterns + DESeq2 workflow spec.

**What it would contain:**
```
references/
  gdc-data-dictionary.md      # Entity types, fields, valid values, relationships
  tcgabiolinks-patterns.md    # GDCquery/GDCdownload/GDCprepare patterns
  deseq2-workflow.md           # Proper paired design, shrinkage, contrast spec
  commpass-schema.md           # CoMMpass-specific clinical/genomic fields
```

**Use cases:**
- Generate correct `GDCquery()` calls for any GDC project (not just CoMMpass)
- Build `DESeqDataSet` with proper design formulas for paired/longitudinal data
- Map GDC clinical fields (age in days, vital_status codes) correctly
- Generate GSEA/fgsea calls with correct MSigDB collection identifiers

**Reusability:** Any cancer genomics project using GDC + Bioconductor (TCGA, TARGET, MMRF).

**Priority:** HIGH — GDC data dictionary is complex (100+ fields, strict enums), and Claude frequently hallucinates field names or gets age units wrong (days vs years).

---

### 3. `risk-metrics` (micromort)

**Spec to bundle:** Micromort/microlife definitions + CDC MMWR format + provenance schema.

**What it would contain:**
```
references/
  micromort-definition.md     # Formal definition, calculation, Spiegelhalter 2012
  microlife-definition.md     # 30-min life expectancy units, conversion rules
  risk-schema.md              # Unified schema: activity, micromorts, category, source_id
  cdc-mmwr-format.md          # MMWR table format, age-adjusted rates, confidence intervals
```

**Use cases:**
- Standardize risk data from new sources into the unified schema
- Calculate micromorts from raw mortality data (rate per exposure)
- Generate source provenance metadata with DOIs and access dates
- Format risk comparisons for public communication (avoiding common pitfalls)

**Reusability:** Any public health risk communication or actuarial analysis project.

---

### 4. `targets-pipeline-spec` (all projects)

**Spec to bundle:** targets package pipeline conventions + crew worker patterns.

**What it would contain:**
```
references/
  targets-conventions.md      # tar_target patterns, format options, branching
  crew-patterns.md            # Worker pool config, transient vs persistent
  plan-file-standard.md       # plan_*.R structure, naming, dependency rules
  anti-patterns.md            # Common mistakes: DuckDB locks, non-serializable objects
```

**Use cases:**
- Generate new `plan_*.R` files following project conventions
- Debug pipeline failures (format mismatches, lock conflicts)
- Add crew parallelism to sequential pipelines correctly
- Migrate from monolithic `_targets.R` to modular plans

**Reusability:** Every R project using targets (all 5 current projects).

**Priority:** MEDIUM — targets is well-documented but project-specific conventions (plan file structure, DuckDB lock avoidance) are not.

---

### 5. `ccusage-telemetry` (llmtelemetry)

**Spec to bundle:** ccusage JSON output schema + token pricing model.

**What it would contain:**
```
references/
  ccusage-json-schema.md      # Field definitions, type quirks (NULL/array/string)
  token-pricing.md            # Per-model input/output/cache pricing
  cost-attribution.md         # Project-level cost rollup rules
```

**Use cases:**
- Parse ccusage JSON correctly (handling inconsistent `modelsUsed` types)
- Calculate costs with correct per-model rates
- Generate cost summary reports with cache efficiency metrics

**Reusability:** Limited to ccusage users. Lower priority.

---

## Implementation Priority

| Skill | Project(s) | Effort | Impact | Priority |
|-------|-----------|--------|--------|----------|
| `gdc-genomics` | coMMpass | High (large spec) | High (complex domain) | 1 |
| `erddap-ocean-data` | irishbuoys | Medium | Medium-High | 2 |
| `targets-pipeline-spec` | All projects | Medium | Medium (cross-project) | 3 |
| `risk-metrics` | micromort | Low-Medium | Medium | 4 |
| `ccusage-telemetry` | llmtelemetry | Low | Low | 5 |

## How to Create a New Spec-Bundled Skill

1. **Extract the spec** — find the authoritative source (API docs, data dictionary, RFC)
2. **Condense to <20 pages** — keep field definitions, valid values, examples; drop tutorials
3. **Write SKILL.md** — instructions for Claude: when to consult the spec, what to generate, validation steps
4. **Add worked examples** — 2-3 concrete input/output pairs showing correct usage
5. **Test against known cases** — give Claude a task and verify output matches the spec
6. **Version the spec** — note which version of the upstream standard is bundled
7. **Store in `~/.claude/skills/`** — or distribute as `.skill` zip for portability
