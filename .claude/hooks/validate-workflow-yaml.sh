#!/bin/bash
# PostToolUse hook: Validate YAML syntax of GitHub workflow files
# Fires after Edit or Write on .github/workflows/*.yml files

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path')

# Only validate GitHub workflow YAML files
if [[ ! "$FILE_PATH" =~ \.github/workflows/.*\.ya?ml$ ]]; then
  exit 0
fi

# Validate YAML syntax
ERROR=$(python3 -c "
import yaml, sys
try:
    yaml.safe_load(open('$FILE_PATH'))
except yaml.YAMLError as e:
    print(str(e), file=sys.stderr)
    sys.exit(1)
" 2>&1)

if [ $? -ne 0 ]; then
  echo "{\"decision\": \"block\", \"reason\": \"YAML syntax error in $FILE_PATH: $ERROR\"}"
  exit 0
fi

exit 0
