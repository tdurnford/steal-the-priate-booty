#!/usr/bin/env bash
set -e

if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: $0 <iterations> <prd-file>"
  echo "Example: $0 5 refactor-prd.json"
  exit 1
fi

ITERATIONS=$1
PRD_FILE=$2

# Check if PRD file exists
if [ ! -f "plans/$PRD_FILE" ]; then
  echo "Error: PRD file 'plans/$PRD_FILE' not found"
  exit 1
fi

for ((i = 0; i < $ITERATIONS; i++)); do
  echo "Iteration $i: Executing command..."
  echo "----------------------------"
  result=$(claude --dangerously-skip-permissions -p "@plans/$PRD_FILE @progress.txt \
1. Find the highest-priority feature to work on and work only on that feature.
This should be the one YOU decide has the highest priority - not necessarily the first in the list. \
2. Use the Roblox Studio MCP server to test your changes in-game:
   - Use 'run_code' to execute Luau code directly in Roblox Studio
   - Use 'insert_model' to add models from the marketplace if needed
   - Verify your changes work correctly before committing
3. Check that the types check via and that the tests pass.
4. Update the PRD with the work that was done. \
5. Append your progress to the progress.txt file. \
Use this to leave a note for the next person working in the codebase. \
6. Make a git commit of that feature and push to the remote repository. \
ONLY WORK ON A SINGLE FEATURE.
If, while implementing the feature, you notice the PRD is complete, output <promise>COMPLETE</promise>.
")

  echo "$result"
  echo "----------------------------"

  if [[ "$result" == *"<promise>COMPLETE</promise>"* ]]; then
    echo "PRD complete, exiting."
    # tt notify "VM PRD complete after $i iterations" exit g
    exit 0
  fi
done


