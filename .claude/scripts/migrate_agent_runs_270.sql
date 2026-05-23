-- Migration for #270: additive columns on agent_runs. Idempotent.
ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS tool_use_id VARCHAR;
ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS backfilled BOOLEAN DEFAULT false;
