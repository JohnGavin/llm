-- Unified log store schema
-- Location: ~/.claude/logs/unified.duckdb

-- Sessions: one row per Claude Code session
CREATE TABLE IF NOT EXISTS sessions (
  session_id VARCHAR PRIMARY KEY,
  project VARCHAR,
  started_at TIMESTAMP DEFAULT current_timestamp,
  ended_at TIMESTAMP,
  duration_min DOUBLE,
  model VARCHAR,
  burn_status VARCHAR,  -- ok/WARN/CRITICAL
  orphans_killed INTEGER DEFAULT 0,
  summary VARCHAR
);

-- Agent runs: subagent invocations
CREATE TABLE IF NOT EXISTS agent_runs (
  id INTEGER PRIMARY KEY DEFAULT nextval('agent_seq'),
  session_id VARCHAR REFERENCES sessions(session_id),
  agent_type VARCHAR,
  model VARCHAR,
  started_at TIMESTAMP DEFAULT current_timestamp,
  ended_at TIMESTAMP,
  duration_sec DOUBLE,
  prompt_preview VARCHAR,
  status VARCHAR DEFAULT 'running'  -- running/completed/failed
);
CREATE SEQUENCE IF NOT EXISTS agent_seq START 1;

-- Hook events: every hook firing
CREATE TABLE IF NOT EXISTS hook_events (
  id INTEGER PRIMARY KEY DEFAULT nextval('hook_seq'),
  session_id VARCHAR,
  hook_name VARCHAR,
  event_type VARCHAR,  -- SessionStart/PreToolUse/PostToolUse/Stop/PreCompact
  fired_at TIMESTAMP DEFAULT current_timestamp,
  duration_ms INTEGER,
  output_preview VARCHAR
);
CREATE SEQUENCE IF NOT EXISTS hook_seq START 1;

-- Errors: any error caught by hooks or agents
CREATE TABLE IF NOT EXISTS errors (
  id INTEGER PRIMARY KEY DEFAULT nextval('error_seq'),
  session_id VARCHAR,
  source VARCHAR,  -- hook/agent/target/render
  error_text VARCHAR,
  context VARCHAR,
  logged_at TIMESTAMP DEFAULT current_timestamp
);
CREATE SEQUENCE IF NOT EXISTS error_seq START 1;

-- Costs: daily cost tracking (from ccusage + model_mix)
CREATE TABLE IF NOT EXISTS costs (
  date DATE PRIMARY KEY,
  opus_cost DOUBLE DEFAULT 0,
  sonnet_cost DOUBLE DEFAULT 0,
  haiku_cost DOUBLE DEFAULT 0,
  total_cost DOUBLE DEFAULT 0,
  opus_pct DOUBLE,
  sonnet_pct DOUBLE,
  haiku_pct DOUBLE
);

-- Brain dumps: from Signal Notes or other capture methods
CREATE TABLE IF NOT EXISTS braindumps (
  id INTEGER PRIMARY KEY DEFAULT nextval('braindump_seq'),
  captured_at TIMESTAMP DEFAULT current_timestamp,
  source VARCHAR DEFAULT 'signal_notes',  -- signal_notes/email/terminal
  raw_text VARCHAR,
  processed_prompt VARCHAR,
  processed_at TIMESTAMP
);
CREATE SEQUENCE IF NOT EXISTS braindump_seq START 1;
