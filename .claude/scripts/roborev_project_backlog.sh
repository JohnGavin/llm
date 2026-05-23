#!/usr/bin/env bash
# roborev_project_backlog.sh — Phase 1 of roborev closure-loop automation (#163)
#
# Closes roborev #1747 and #2109 (#181 Theme 5) — priority formula uses log10
# (not sqrt), keeping age growth sub-linear so severity stays dominant.
# The sqrt variant caused age to dominate severity, inverting triage order.
# Fix landed in commit 24de32e.
#
# Usage: roborev_project_backlog.sh <project-name>
#
# Reads ~/.roborev/reviews.db (read-only), categorizes open rejected findings,
# computes composite priority score, writes prioritized backlog markdown to
# <project-root>/.roborev/backlog.md.
#
# Exit codes:
#   0 = success
#   1 = project not found in DB
#   2 = DB unreadable
#
# Constraints:
#   - No && in bash (bash-safety rule)
#   - No mutations to DB — read-only queries only
#   - /usr/bin/python3 used directly (sqlite3 CLI not in nix shell PATH)

set -euo pipefail

PROJECT="${1:-}"
DB_PATH="${HOME}/.roborev/reviews.db"
SCRIPT_NAME="$(basename "$0")"

# --- Validation ---

if [ -z "$PROJECT" ]; then
  echo "Usage: ${SCRIPT_NAME} <project-name>" >&2
  exit 1
fi

if [ ! -f "$DB_PATH" ]; then
  echo "ERROR: DB not readable at ${DB_PATH}" >&2
  exit 2
fi

if [ ! -r "$DB_PATH" ]; then
  echo "ERROR: DB not readable at ${DB_PATH}" >&2
  exit 2
fi

# --- Delegate all logic to Python (sqlite3 available, no shell quoting headaches) ---

/usr/bin/python3 - "$PROJECT" "$DB_PATH" <<'PYEOF'
import sys
import os
import re
import math
import sqlite3
from datetime import datetime, timezone

project_name = sys.argv[1]
db_path = sys.argv[2]

# ---- Connect read-only ----
try:
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
except Exception as e:
    print(f"ERROR: Cannot open DB: {e}", file=sys.stderr)
    sys.exit(2)

cursor = conn.cursor()

# ---- Resolve repo root_path (pick the canonical non-tmp path if multiple rows) ----
cursor.execute(
    "SELECT id, root_path FROM repos WHERE name = ? ORDER BY id",
    (project_name,)
)
repo_rows = cursor.fetchall()

if not repo_rows:
    print(f"project not found: {project_name}", file=sys.stderr)
    sys.exit(1)

# Prefer the first non-/tmp path; fall back to first row
repo_id = None
root_path = None
for row in repo_rows:
    if not row["root_path"].startswith("/tmp") and not row["root_path"].startswith("/private/tmp"):
        repo_id = row["id"]
        root_path = row["root_path"]
        break

if root_path is None:
    repo_id = repo_rows[0]["id"]
    root_path = repo_rows[0]["root_path"]

# ---- Fetch open rejected findings across ALL repo_ids for this project name ----
repo_ids = [r["id"] for r in repo_rows]
placeholders = ",".join("?" * len(repo_ids))

cursor.execute(
    f"""
    SELECT
        rv.id,
        rv.output,
        rv.created_at,
        rv.closed,
        rv.verdict_bool,
        rj.git_ref,
        rj.branch
    FROM reviews rv
    JOIN review_jobs rj ON rv.job_id = rj.id
    WHERE rj.repo_id IN ({placeholders})
      AND rv.closed = 0
      AND rv.verdict_bool = 0
    ORDER BY rv.created_at ASC
    """,
    repo_ids,
)
open_findings = cursor.fetchall()

# ---- Fetch summary counts (total reviews, rejected, close rate) ----
cursor.execute(
    f"""
    SELECT
        COUNT(*)                                                       AS total,
        SUM(CASE WHEN rv.verdict_bool = 0 THEN 1 ELSE 0 END)          AS rejected,
        SUM(CASE WHEN rv.closed = 0 AND rv.verdict_bool = 0 THEN 1 ELSE 0 END) AS open_rejected,
        SUM(CASE WHEN rv.closed = 1 THEN 1 ELSE 0 END)                AS closed_count
    FROM reviews rv
    JOIN review_jobs rj ON rv.job_id = rj.id
    WHERE rj.repo_id IN ({placeholders})
    """,
    repo_ids,
)
summary = cursor.fetchone()
conn.close()

total       = summary["total"] or 0
rejected    = summary["rejected"] or 0
open_rej    = summary["open_rejected"] or 0
closed_cnt  = summary["closed_count"] or 0
close_rate  = (closed_cnt / total * 100) if total > 0 else 0.0

# ---- Priority weights ----

SEVERITY_WEIGHT = {
    "critical": 10,
    "high":     5,
    "medium":   2,
    "low":      1,
    "info":     1,
    "unknown":  1,
}

CATEGORY_RISK = {
    "security":            5.0,
    "error-handling":      4.0,
    "async/concurrency":   2.0,
    "dependency/namespace":1.0,
    "test-quality":        1.5,
    "input-validation":    2.0,
    "performance":         1.5,
    "file-io":             1.0,
    "logging/observ":      0.8,
    "shell/bash":          1.5,
    "git/CI":              1.0,
    "config/settings":     1.0,
    "refactor/simplify":   0.8,
    "quarto/render":       0.5,
    "docs/comments":       0.3,
    "style/lint":          0.3,
    "uncategorized":       1.0,
}

CATEGORY_PATTERNS = [
    ("security",
     r"\b(secret|credential|password|token|api[_ ]?key|injection|xss|sql injection"
     r"|sanitiz|escape|hardcod\w*\s+(key|password|secret)|expose\w*\s+(token|key|credential))\b"),
    ("error-handling",
     r"\b(silent\s+(failure|catch|error)|swallow\w*\s+error|bare\s+except|tryCatch.*NULL"
     r"|stop\(\)|panic|missing\s+error|unhandled)\b"),
    ("test-quality",
     r"\b(missing\s+test|no\s+test|untested|test\s+coverage|mock\w*|fixture|snapshot"
     r"|expect_\w+|assert)\b"),
    ("input-validation",
     r"\b(input\s+validation|validate\s+input|missing\s+check|NULL\s+check|NA\s+handl\w*"
     r"|type\s+check|check_\w+|stopifnot)\b"),
    ("performance",
     r"\b(performance|slow|optim\w+|memory\s+leak|allocation|inefficient|O\(n\^?2\)|quadratic)\b"),
    ("docs/comments",
     r"\b(documentation|docstring|roxygen|@param|@return|@examples|missing\s+doc"
     r"|outdated\s+(doc|comment)|README|NEWS\.md|vignette)\b"),
    ("style/lint",
     r"\b(naming\s+convention|inconsistent\s+(naming|style)|formatting|indent"
     r"|tidyverse\s+style|snake_case|camelCase|lint)\b"),
    ("refactor/simplify",
     r"\b(refactor|simplif\w+|redundant|duplicat\w+\s+code|magic\s+number"
     r"|extract\s+function|too\s+long|complex\w+)\b"),
    ("dependency/namespace",
     r"\b(missing\s+import|undocumented\s+dependency|wrong\s+namespace|@importFrom"
     r"|DESCRIPTION\s+(Imports|Depends)|library\(\s*['\"]\w+['\"]?\s*\)|unused\s+import|@import\b)\b"),
    ("file-io",
     r"\b(file\s+path|hardcoded\s+path|portable\s+path|getwd|file\.path"
     r"|Sys\.getenv|absolute\s+path)\b"),
    ("async/concurrency",
     r"\b(race\s+condition|deadlock|lock|mutex|async|future|crew|mirai|parallel|concurrent)\b"),
    ("logging/observ",
     r"\b(logging|logger|telemetry|observ\w+|trace|metric|monitor)\b"),
    ("shell/bash",
     r"\b(bash|shell\s+script|launchctl|launchd|nix-shell|cd\s+&&|set\s+-e|trap|shebang|#!)\b"),
    ("quarto/render",
     r"\b(quarto|render|knitr|qmd|rmarkdown|chunk|fig-cap|alt[- ]text)\b"),
    ("git/CI",
     r"\b(github\s+actions|workflow|\.github/workflows|gh-pages|CI/CD|pre-commit|hook)\b"),
    ("config/settings",
     r"\b(\.claude/settings|hooks?\.sh|CLAUDE\.md|AGENTS\.md|\.roborev\.toml"
     r"|configuration|env\s+var)\b"),
]

# ---- Categorize + score each finding ----

def extract_severity(output_text):
    m = re.search(r"\*\*Severity\*\*:\s*(High|Medium|Low|Critical|Info)", output_text or "", re.I)
    if m:
        return m.group(1).lower()
    return "unknown"

def categorize(output_text):
    text_lower = (output_text or "").lower()
    matched = []
    for cat, pattern in CATEGORY_PATTERNS:
        if re.search(pattern, text_lower, re.I):
            matched.append(cat)
    if not matched:
        matched = ["uncategorized"]
    return matched

def days_old(created_at_str):
    try:
        # DB stores as 'YYYY-MM-DD HH:MM:SS' (UTC)
        dt = datetime.strptime(created_at_str, "%Y-%m-%d %H:%M:%S")
        dt = dt.replace(tzinfo=timezone.utc)
        now = datetime.now(tz=timezone.utc)
        delta = (now - dt).total_seconds() / 86400
        return max(delta, 0.0)
    except Exception:
        return 0.0

def priority_score(sev, categories, age_days):
    sw = SEVERITY_WEIGHT.get(sev, 1)
    cr = max(CATEGORY_RISK.get(c, 1.0) for c in categories)
    # log10 keeps age growth sub-linear so severity stays dominant.
    # Cap at 1.5 to prevent age from bridging severity tiers: a very old Low
    # (sw=1) with cap=1.5 scores at most 1.5×cr, while a fresh Medium (sw=2)
    # scores 2.0×cr — so Medium always beats Low regardless of age.
    # Without the cap, after ~9-10 days a Low would exceed a fresh Medium
    # (1 + log10(11) ≈ 2.04 > 2.0 / 1.0 ratio). Cap derivation:
    #   cap × Low_base < Medium_base  →  cap × 1 < 2  →  cap < 2.0
    #   1.5 chosen to allow meaningful age signal while preserving tier order.
    #   stale Low 1yr (uncapped): sev=1 * cr * 3.56 — cap prevents this.
    age_factor = min(1 + math.log10(age_days + 1), 1.5)
    return sw * cr * age_factor

scored = []
for row in open_findings:
    output_text = row["output"] or ""
    sev = extract_severity(output_text)
    cats = categorize(output_text)
    primary_cat = max(cats, key=lambda c: CATEGORY_RISK.get(c, 1.0))
    age = days_old(row["created_at"])
    score = priority_score(sev, cats, age)
    summary_text = output_text.replace("\n", " ")[:100]
    scored.append({
        "id":         row["id"],
        "sev":        sev,
        "categories": cats,
        "primary":    primary_cat,
        "age_days":   age,
        "score":      score,
        "created_at": row["created_at"],
        "output":     output_text,
        "summary":    summary_text,
    })

# Sort by priority descending
scored.sort(key=lambda x: x["score"], reverse=True)

# ---- Build category breakdown ----

from collections import defaultdict
cat_stats = defaultdict(lambda: {"open": 0, "high": 0, "med": 0, "low": 0})
for f in scored:
    for c in f["categories"]:
        cat_stats[c]["open"] += 1
        if f["sev"] in ("high", "critical"):
            cat_stats[c]["high"] += 1
        elif f["sev"] == "medium":
            cat_stats[c]["med"] += 1
        elif f["sev"] in ("low", "info"):
            cat_stats[c]["low"] += 1

cat_rows_sorted = sorted(cat_stats.items(), key=lambda kv: kv[1]["open"], reverse=True)

# ---- Determine output path ----

fallback = False
if os.path.isdir(root_path):
    out_dir = os.path.join(root_path, ".roborev")
    out_path = os.path.join(out_dir, "backlog.md")
else:
    safe_name = re.sub(r"[^a-zA-Z0-9_-]", "_", project_name)
    out_path = f"/tmp/roborev_backlog_{safe_name}.md"
    out_dir = None
    fallback = True
    print(
        f"WARN: root_path '{root_path}' not found on this machine. "
        f"Writing to {out_path}",
        file=sys.stderr,
    )

if out_dir is not None:
    os.makedirs(out_dir, exist_ok=True)

# ---- Render backlog.md ----

now_iso = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
today_str = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d")

def age_str(days):
    if days < 1:
        return "<1d"
    if days < 7:
        return f"{int(days)}d"
    if days < 30:
        return f"{int(days/7)}w"
    return f"{int(days/30)}mo"

lines = []
lines.append(f"# Roborev backlog — {project_name} — {today_str}")
lines.append("")
lines.append(f"Generated: {now_iso}")
lines.append(f"Source: ~/.roborev/reviews.db")
lines.append("")
lines.append("## Summary")
lines.append("")
lines.append("| Metric | Value |")
lines.append("|---|---|")
lines.append(f"| Total reviews | {total} |")
lines.append(f"| Rejected | {rejected} |")
lines.append(f"| Open (action needed) | **{open_rej}** |")
lines.append(f"| Close rate | {close_rate:.1f}% |")
lines.append("")

# Top 20
lines.append("## Top 20 by priority")
lines.append("")
lines.append("| rank | id | sev | category | age | priority | summary (first 100 chars) |")
lines.append("|------|----|----|----------|-----|----------|---------------------------|")
for i, f in enumerate(scored[:20], start=1):
    row_str = (
        f"| {i} | {f['id']} | {f['sev']} | {f['primary']} "
        f"| {age_str(f['age_days'])} | {f['score']:.1f} | {f['summary']} |"
    )
    lines.append(row_str)
lines.append("")

# Category breakdown
lines.append("## By category (all open)")
lines.append("")
lines.append("| category | open | high | med | low |")
lines.append("|---|---|---|---|---|")
for cat, stats in cat_rows_sorted:
    lines.append(
        f"| {cat} | {stats['open']} | {stats['high']} | {stats['med']} | {stats['low']} |"
    )
lines.append("")

# Full list
lines.append("## Full list")
lines.append("")
lines.append(
    "All open findings, ordered by priority desc — id, severity, category, age, score, first 200 chars of output."
)
lines.append("")
for f in scored:
    out_excerpt = f["output"].replace("\n", " ")[:200]
    lines.append(
        f"**#{f['id']}** | {f['sev']} | {f['primary']} | {age_str(f['age_days'])} "
        f"| score {f['score']:.1f}"
    )
    lines.append(f"> {out_excerpt}")
    lines.append("")

content = "\n".join(lines) + "\n"

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(content)

print(f"Wrote {len(scored)} findings to {out_path}")
if not fallback:
    print(f"Project root: {root_path}")

PYEOF

EXIT_CODE=$?
exit $EXIT_CODE
