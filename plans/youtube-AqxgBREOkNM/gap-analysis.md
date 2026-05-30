# Gap Analysis: Miessler Patterns vs. Our llm/Claude Code Setup

## Sources

- `plans/youtube-AqxgBREOkNM/digest.md` — extracted patterns from video
- `/Users/johngavin/docs_gh/llm/.claude/` — current llm configuration (READ-ONLY)
- `/Users/johngavin/docs_gh/llm/.claude/hooks/` — session and pre-tool hooks
- `/Users/johngavin/docs_gh/llm/.claude/scripts/` — automation scripts
- `/Users/johngavin/docs_gh/llm/.claude/launchd/` — scheduled jobs
- `/Users/johngavin/docs_gh/llm/.claude/skills/` — skill definitions
- `/Users/johngavin/docs_gh/llm/.claude/CLAUDE.md` — global config

> ⚠ AI-inferred: All gap assessments below are inferred by comparing the
> pattern descriptions in the video against observed llm configuration files.
> Confidence is (high / medium / low) per row.

---

## Section A: Pattern-to-Asset Mapping

| # | Miessler Pattern | Our Equivalent Asset | Coverage | Confidence |
|---|---|---|---|---|
| 1 | TILOS ideal-state document | None found. `CURRENT_WORK.md` is session-ephemeral only. | GAP | high |
| 2 | 1 GB SQLite second brain (5yr history) | `~/.roborev/reviews.db` (reviews only). No personal history DB. | GAP | high |
| 3 | Monthly→annual→topic summarisation | `codex_overnight_learning.py` + `codex_self_learning_analyzer.py` (code patterns only, not life history) | PARTIAL | medium |
| 4 | GitHub as task bus (poll every 5 min) | Issues exist in JohnGavin/llm; no autonomous agent polling loop | GAP | high |
| 5 | Dedicated always-on Mac Mini agent hardware | Laptop-only. launchd jobs run on the user's laptop only. | GAP | medium |
| 6 | Incident response skill (one-command key rotation) | No equivalent found. No `incident_response.sh` or similar. | GAP | high |
| 7 | Two-vault credential system (auto vs ask) | `.Renviron` holds all credentials at same tier. No auto/ask split. | GAP | high |
| 8 | Prompt injection defense hook | `phi-scan-hook.sh` exists (PHI scan). No prompt injection semantic check. | PARTIAL | medium |
| 9 | Network isolation — DMZ at Layer 2/3 | No dedicated hardware isolation. All agents run in same network context as user. | GAP | high |
| 10 | PI status line in terminal | `config_pulse.sh` exists (config health only). No cross-domain life-domain decay view. | PARTIAL | medium |
| 11 | Session rename hook (auto-summary on session end) | `session_stop.sh` fires `session_end_refine.sh` for roborev. No session rename/label. | GAP | high |
| 12 | Competitive analysis pattern (delegate new tool research) | `codex_overnight_learning.py` does self-learning on code patterns. No structured competitor analysis. | PARTIAL | low |
| 13 | Upgrade skill (periodic AI-release review + system compare) | No equivalent. Rules/skills updated ad hoc. | GAP | high |
| 14 | Bitter-lesson engineering (periodic scaffolding audit) | No scheduled review asking "has the model outgrown this rule?" | GAP | high |
| 15 | Continuous security assessment skill | `phi-scan-hook.sh` scans for PHI on writes. No open-port / API-auth scan. | PARTIAL | high |
| 16 | Multi-model routing by task criticality | Single model (Sonnet). Some haiku/sonnet dispatch in `auto-delegation` rule. No Forge-equivalent for critical reviews. | PARTIAL | high |
| 17 | Agent naming with human-like names | Agents named by type (`critic`, `fixer`, `r-debugger`). Functional, not relational. | PARTIAL | low |
| 18 | Voice-first interaction (WhisperFlow) | Not in scope for llm config. User's personal choice. | N/A | — |
| 19 | UPS-backed always-on hardware | Not in scope (hardware). | N/A | — |
| 20 | Headscale self-hosted VPN | Not in scope. | N/A | — |

---

## Section B: Gaps by Theme

### Theme 1: Memory Architecture — No Long-Term Personal History Store

**Current state**: The llm project has no persistent cross-session memory beyond
what is committed to git. `CURRENT_WORK.md` is ephemeral (gitignored).
The knowledge base at `~/docs_gh/llm/knowledge/` stores wiki-format project
knowledge, but not personal history (emails, events, daily logs).

**Miessler pattern**: 1 GB SQLite DB with 5 years of emails, Slack, tweets,
podcasts. Monthly/annual/topic summarisation hierarchy. Every agent session
starts by pulling relevant context from this DB.

**Impact**: Agents cannot recall project decisions made > 1 session ago without
the user re-explaining. `CHANGELOG.md` is a partial substitute but is
git-committed prose, not a queryable database.

**Assets we already have that could extend**: `~/.roborev/reviews.db` (SQLite),
`codex_overnight_learning.py`, `knowledge/` wiki — these are the kernel of a
second-brain architecture but none are integrated into agent session context.

---

### Theme 2: Proactive Scheduling — No Autonomous Agent Polling Loop

**Current state**: launchd jobs (20 plists) run scripts on schedules, but these
are mostly maintenance jobs (backup, roborev, health checks) that do not
autonomously pick up and execute tasks. The agent must be invoked by the user.

**Miessler pattern**: Agents poll GitHub issues every 5 minutes and
self-assign/claim tasks. This means work happens without the user initiating
a session — the agent network is proactive, not reactive.

**Impact**: All complex work requires user-initiated sessions. There is no
mechanism for an agent to see a new issue filed overnight and begin working
on it by morning.

**Assets we already have**: launchd infrastructure, `cc-worktree.sh`,
`agent_push_guard.sh`. The scaffolding for autonomous execution exists;
what is missing is a polling agent and a task-claiming protocol.

---

### Theme 3: Security Posture — Credential Tier and Incident Response Gaps

**Current state**: All credentials are stored in `.Renviron` at the same access
tier. The `destructive_api_guard.sh` hook blocks destructive API calls, and
`phi-scan-hook.sh` scans for PHI. There is no:
- Auto vault / ask vault split
- One-command incident response to rotate all keys
- Prompt injection semantic detection (only PHI pattern matching)

**Miessler pattern**: Two-vault split enforced at the tool level. Single-command
key rotation skill ready to fire. Prompt injection hook on every incoming prompt.

**Impact**: If any credential is compromised, there is no fast-path to rotate
everything. There is no mechanism preventing an agent from using a production
write credential in a context where only a read credential is appropriate.

---

### Theme 4: System Self-Improvement — No Upgrade Skill or Bitter-Lesson Audit

**Current state**: Rules and skills are updated reactively (when a bug is found
or when a user explicitly requests a change). There is no scheduled process that:
- Reviews recent Anthropic release notes and compares them to our rule set
- Asks "has this rule become obsolete because the model is now smarter?"
- Produces a prioritised upgrade list

**Miessler pattern**: Upgrade skill runs every 1–2 weeks, consuming all
Anthropic blog/release content plus system execution logs to propose changes.
Bitter-lesson engineering is a scheduled mindset: actively look for things to
DELETE from the system as the model improves.

**Impact**: Our rule and skill set accumulates cruft. Rules written for older
Claude versions may add overhead or conflict with current model behavior.

---

### Theme 5: Agent Outputs Visibility — No Cross-Domain Status View

**Current state**: `config_pulse.sh` reports config health (rules count, CI
status). Individual launchd job logs exist. There is no unified view showing
which life/project domains are "fresh" vs. "decaying" — analogous to
Miessler's PI status line.

**Miessler pattern**: Terminal status line showing per-domain freshness. Decay
triggers proactive maintenance. The operator can see the health of the whole
system at a glance without opening any tool.

**Impact**: Staleness in any domain is only noticed when the user actively
investigates or a job fails visibly.

---

## Section C: Priority Ordering

Priority is assessed by (Impact × Feasibility) / Implementation Cost.

| Rank | Gap | Theme | Impact | Feasibility | Notes |
|------|-----|-------|--------|-------------|-------|
| 1 | Session rename hook | Proactive scheduling | High | High | 1-script addition to `session_stop.sh` |
| 2 | Upgrade skill (periodic AI-release review) | Self-improvement | High | High | Bash script + scheduled launchd plist |
| 3 | Incident response skill (one-command key rotation) | Security | High | Medium | Requires mapping all credentials to `.Renviron` keys + rotation logic per provider |
| 4 | Auto vault / ask vault credential split | Security | High | Medium | Requires credential inventory + wrapper mechanism |
| 5 | Autonomous agent polling loop (GitHub issue bus) | Proactive scheduling | High | Medium | Requires polling script + worktree dispatch + task-claiming protocol |
| 6 | TILOS / ideal-state document | Memory | High | Low | Requires user to author the document; tooling then straightforward |
| 7 | SQLite second brain (personal history DB) | Memory | High | Low | Large effort: requires email/calendar/note ingestion pipeline |
| 8 | Prompt injection semantic hook | Security | Medium | Medium | Replace/extend `phi-scan-hook.sh` with LLM-based injection detector |
| 9 | Upgrade / decay status line in terminal | Visibility | Medium | Medium | Extend `config_pulse.sh` with domain-decay logic |
| 10 | Bitter-lesson engineering audit (scheduled) | Self-improvement | Medium | High | Add to upgrade skill: "what rules should be deleted?" |

---

## Section D: Top 5 Actionable Gaps with Implementation Proposals

---

### Gap 1 — Session Rename Hook

**Problem**: Agent sessions are identified by UUID only. Finding "the session
where I fixed the ETL pipeline" requires reading CHANGELOG or scrolling history.

**Proposed fix**: Extend `session_stop.sh` to call a lightweight Rscript (or
bash + `claude` CLI) that generates a 6–10 word slug from the session's
`CURRENT_WORK.md` content and writes it to a session index log.

**Implementation sketch**:
```bash
# In session_stop.sh, after existing roborev block:
SESSION_LABEL=$(timeout 30 Rscript -e '
  cw <- readLines(".claude/CURRENT_WORK.md", warn=FALSE)
  cat(paste(head(strsplit(cw[1], " ")[[1]], 8), collapse="-"))
' 2>/dev/null | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) branch=$(git rev-parse --abbrev-ref HEAD) label=$SESSION_LABEL" \
  >> ~/.claude/logs/session_index.log
```

**Effort**: Small (< 1 hour). No architectural changes.
**Files affected**: `.claude/hooks/session_stop.sh`, new log file.

---

### Gap 2 — Upgrade Skill (Periodic AI-Release Review)

**Problem**: Rules and skills are updated reactively. We have no scheduled
process that ingests new Anthropic release notes / blog posts and compares
them to our current rule set to identify what should change.

**Proposed fix**: A new launchd job running weekly (or triggered by `/check`)
that:
1. Fetches the Anthropic news RSS feed or GitHub anthropics/anthropic-sdk-python changelog
2. Reads recent `session_stop.sh` error logs
3. Asks Claude (via `claude` CLI with a short prompt) "given these new
   capabilities, which of our current rules in `.claude/rules/` may now be
   obsolete, over-engineered, or conflicting?"
4. Writes a prioritised suggestion list to `~/.claude/logs/upgrade_suggestions.log`
5. Surfaces the top 3 suggestions at the next `/hi` session start

**Implementation sketch**:
```bash
# .claude/scripts/upgrade_skill.sh
#!/usr/bin/env bash
# Fetch recent Anthropic blog/changelog content (e.g. GitHub releases)
# Compare against .claude/rules/ directory
# Output to log
RULES_SUMMARY=$(ls ~/.claude/rules/*.md | wc -l)
# ... call claude CLI with system context ...
```

**Effort**: Medium (2–4 hours). Requires `claude` CLI access in launchd context.
**Files affected**: New `.claude/scripts/upgrade_skill.sh`, new `.claude/launchd/com.claude.upgrade-skill-weekly.plist`.

---

### Gap 3 — Incident Response Skill (One-Command Key Rotation)

**Problem**: If any credential in `.Renviron` is compromised, there is no fast
path to rotate everything. The user must manually revoke and rotate keys across
all providers (GitHub PAT, Anthropic API key, OpenAI key, etc.) one by one.

**Proposed fix**: A script `incident_response.sh` that:
1. Reads a provider inventory (a TOML or simple text file listing: provider
   name, rotation method, notification URL)
2. For each provider, calls the appropriate rotation API or outputs the manual
   URL + instructions
3. Updates `.Renviron` with new key placeholders and a `ROTATED_AT=` timestamp
4. Fires a notification (macOS `osascript` alert or `say` command)
5. Logs everything to `~/.claude/logs/incident_response.log`

**Note on MCP risk classification** (per `permission-discipline` rule): this
script performs `write` operations against external credential providers (API
calls to revoke/rotate tokens). Each provider integration is `destructive`
tier for that provider's old key. The rotation script itself must NOT be
invocable by any agent without explicit user confirmation — it is a
`ask vault` class operation.

**Implementation sketch**:
```bash
# .claude/scripts/incident_response.sh
#!/usr/bin/env bash
set -euo pipefail
LOG="$HOME/.claude/logs/incident_response.log"
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) INCIDENT RESPONSE INITIATED" >> "$LOG"
# For each known provider:
#   GitHub: open https://github.com/settings/tokens in browser
#   Anthropic: open https://console.anthropic.com/settings/keys
#   (auto-revoke where API supports it)
osascript -e 'display alert "INCIDENT RESPONSE" message "Rotating all keys. Check log." as critical'
```

**Effort**: Medium (3–5 hours) to enumerate all providers and build partial
automation.
**Files affected**: New `.claude/scripts/incident_response.sh`, updated `.Renviron` template.

---

### Gap 4 — Autonomous Agent Polling Loop (GitHub Issue Bus)

**Problem**: All agentic work requires the user to initiate a session. There
is no mechanism for agents to autonomously pick up filed issues and begin
working on them.

**Proposed fix**: A launchd job running every 5 minutes that:
1. Calls `gh issue list --label "auto-agent" --state open --json number,title,body`
2. For any unclaimed issue, dispatches a `fixer` or `r-debugger` agent via
   `cc-worktree.sh` + `claude` CLI
3. Claims the issue by adding a comment "auto-agent: in-progress at $(date)"
4. Enforces the existing `agent_push_guard.sh` safety constraints

**Safety constraints** (mandatory — do NOT waive):
- Only issues labeled `auto-agent` are eligible (human must opt in per issue)
- One agent dispatch per issue maximum (check for "in-progress" comment before dispatching)
- Agent is always `isolation: "worktree"` — never runs in main checkout
- Push to feature branch only; PR requires human merge

**Implementation sketch**:
```bash
# .claude/scripts/agent_issue_poller.sh
#!/usr/bin/env bash
OPEN=$(gh issue list --label auto-agent --state open --json number,title,body -q '.[0]')
[ -z "$OPEN" ] && exit 0
NUM=$(echo "$OPEN" | jq -r '.number')
# Check not already claimed
CLAIMED=$(gh issue view "$NUM" --json comments -q '.comments[].body' | grep -c "auto-agent: in-progress" || true)
[ "$CLAIMED" -gt 0 ] && exit 0
gh issue comment "$NUM" --body "auto-agent: in-progress at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
~/.claude/scripts/cc-worktree.sh llm "auto-agent/issue-$NUM"
# ... dispatch claude CLI in worktree ...
```

**Effort**: Large (1–2 days). Requires careful safety review before enabling.
**Files affected**: New `.claude/scripts/agent_issue_poller.sh`, new `.claude/launchd/com.claude.agent-issue-poller.plist`.

---

### Gap 5 — TILOS Ideal-State Document + Proactive Morning Brief

**Problem**: There is no persistent document mapping current state to ideal
state across life/project domains. Agents have no top-level frame for what
"winning" looks like. Each session starts cold without a sense of direction
beyond the immediate task.

**Proposed fix**:
1. **Author** a `~/.claude/IDEAL_STATE.md` (outside the git repo, like
   `CURRENT_WORK.md`) covering domains: current projects, health/wellbeing,
   skill targets, outstanding decisions, key relationships.
2. **Inject** a summary of IDEAL_STATE into every session start (add to
   `session_init.sh` Phase 1 output).
3. **Morning brief launchd job**: each weekday at 08:00, run a script that
   reads IDEAL_STATE + recent git log + open issues and produces a 5-bullet
   prioritised daily agenda to `~/.claude/logs/morning_brief.log`.

**Note**: The TILOS document is personal and must never be committed to any
git repo. It should live at `~/.claude/IDEAL_STATE.md` (gitignored globally)
or equivalent.

**Implementation sketch**:
```bash
# In session_init.sh Phase 1 addition:
if [ -f "$HOME/.claude/IDEAL_STATE.md" ]; then
  IDEAL_DIGEST=$(head -30 "$HOME/.claude/IDEAL_STATE.md")
  echo "IDEAL_STATE (top 30 lines):"
  echo "$IDEAL_DIGEST"
fi
```

**Effort**: Small for the tooling (< 1 hour); large for the human work of
authoring and maintaining `IDEAL_STATE.md`.
**Files affected**: `.claude/hooks/session_init.sh`, new `~/.claude/IDEAL_STATE.md` (not committed).

---

## Summary Table

| Rank | Gap | Effort | Risk | Recommended Action |
|------|-----|--------|------|--------------------|
| 1 | Session rename hook | Small | Low | File issue, implement in next fixer run |
| 2 | Upgrade skill (weekly) | Medium | Low | File issue, design before implementing |
| 3 | Incident response skill | Medium | Medium | File issue, review all credentials first |
| 4 | Autonomous agent polling loop | Large | High | File issue, design + safety review |
| 5 | TILOS ideal-state document | Small (tooling) | Low | File issue, user authors document first |
