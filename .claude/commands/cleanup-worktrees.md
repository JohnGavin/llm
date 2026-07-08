# /cleanup-worktrees - Triage Flagged Stale Worktrees

Review worktrees that the overnight `worktree_gc.sh` cron flagged as squash-merge
candidates (action='flagged' or action='skipped_unmerged' in `worktree_gc_events`)
and resolve each one: harvest, archive, or discard.

## Purpose

The overnight housekeeping job (`worktree_gc.sh` at 00:04) conservatively skips
worktrees whose branches have unique patch-ids vs the default branch — these may
be squash-merged or re-implemented. It writes them to `worktree_gc_events` with
`action='skipped_unmerged'` so they can be reviewed here.

This command:
1. Queries `unified.duckdb` for flagged rows in the last 14 days
2. Shows per-worktree triage information
3. For each candidate, prompts: harvest | archive | discard

## Steps

### Step 1 — Load flagged candidates from unified.duckdb

```bash
duckdb ~/.claude/logs/unified.duckdb "
  SELECT
    worktree_path,
    branch,
    project,
    location_pattern,
    action,
    reason,
    size_mb,
    fired_at
  FROM worktree_gc_events
  WHERE action IN ('skipped_unmerged', 'flagged')
    AND fired_at >= current_timestamp - INTERVAL 14 DAY
  ORDER BY fired_at DESC
"
```

If the query returns zero rows, no candidates need review — done.

### Step 2 — For each candidate: run the 3-step salvage check

For each row returned, apply the `branch-salvage-workflow` rule:

**Step 2a — Patch-id check** (fast, catches direct cherry-picks):

```bash
# Replace <repo> and <branch> with values from the query row
git -C <repo-dir> cherry main <branch>
```

All `-` lines → patch is in main → **DISCARD**
Any `+` lines → continue to Step 2b

**Step 2b — Closing-PR check** (catches squash-merges):

```bash
# Extract issue number from branch name or last commit subject
gh issue view <N> --comments
gh pr list --search "closed:<N>" --state closed
```

Issue closed via squash-merge PR → **DISCARD**

**Step 2c — Unique-strings check** (catches re-implementations):

```bash
git -C <repo-dir> diff main...<branch> | grep '^+' | head -30
# pick 2-3 distinctive strings, then grep main
grep -rn "<string>" R/ tests/ vignettes/
```

All strings found in main → **DISCARD**
Strings absent → **HARVEST or ARCHIVE**

### Step 3 — Resolve each candidate

For each candidate after the 3-step check, choose one outcome:

| Outcome  | When | Action |
|----------|------|--------|
| **Harvest** | Branch contains improvements not yet in main | Cherry-pick or re-implement before starting new work; reference source SHA in commit |
| **Archive** | Work is real but out of scope for this session | File a project issue naming the branch + commits + surfaces; mark resolved below |
| **Discard** | All 3 checks confirm content is in main | Delete branch (with user authorisation) |

### Step 4 — Write resolution back to unified.duckdb

After deciding each candidate, record the outcome so the audit trail is complete
and the overnight job stops re-flagging the same worktrees:

```bash
# Example: mark one candidate as resolved (archived)
duckdb ~/.claude/logs/unified.duckdb "
  INSERT OR IGNORE INTO worktree_gc_events
    (id, fired_at, source, session_id, location_pattern,
     project, worktree_path, branch, action, reason, size_mb)
  VALUES (
    lower(hex(randomblob(16))),
    current_timestamp,
    'cleanup-worktrees-command',
    NULL,
    '<pattern>',
    '<project>',
    '<worktree_path>',
    '<branch>',
    'archived',
    'Triage: <reason>',
    <size_mb>
  );
"
```

Replace `archived` with `removed` or `harvested` as appropriate.

### Step 5 — Optional: delete confirmed-discard worktrees

Only after completing Steps 2–4 and confirming with the user:

```bash
# Remove the worktree and delete the branch
git -C <repo-dir> worktree remove <worktree_path>
git -C <repo-dir> branch -d <branch>
```

## Output Format

```
## /cleanup-worktrees

### Flagged candidates (last 14 days)
Found N candidate(s) from worktree_gc_events.

1. <worktree_path> (branch: <branch>, project: <project>, size: X MB)
   Pattern: <location_pattern>  Flagged: <fired_at>
   Reason: <reason>

   Step 2a cherry: [all - / some + lines]
   Step 2b PR:     [closed via squash #N / issue still open / no issue]
   Step 2c grep:   [strings found in main / strings absent]

   → Verdict: DISCARD | HARVEST | ARCHIVE
   → Action taken: [deleted branch / filed issue #N / cherry-picked to main]

### Summary
- Harvested: N
- Archived:  N (issues: #X, #Y)
- Discarded: N
- Deferred:  N (needs user input)
```

## Related

- `branch-salvage-workflow` rule — the 3-step salvage decision matrix
- `worktree-location` rule — where worktrees live (3 location patterns)
- `housekeeping-framework` rule — the overnight housekeeping framework
- `worktree_gc.sh` — the cron that writes the flagged rows
- `/simplify` skill — broader session code review and cleanup
- llm#550 — origin issue (Phase D)
