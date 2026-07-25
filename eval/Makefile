# eval/Makefile — single-command entrypoint for the agent-behaviour eval
# harness (llm#816). See README.md for the three-tier plan.
#
# Usage from repo root:
#   make -C eval eval
# Usage from inside eval/:
#   make eval

NIX_FILE := $(abspath ../default.nix)

.PHONY: eval
eval:
	nix-shell $(NIX_FILE) --run "Rscript run.R"

.PHONY: clean
clean:
	rm -f results/latest.json
