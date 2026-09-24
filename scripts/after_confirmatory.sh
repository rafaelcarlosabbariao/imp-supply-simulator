#!/bin/sh
# Waits for scripts/confirmatory_run.R to exit, then runs the pre-registered
# analysis if every replication is on disk. Output: results.txt beside the run.
cd "$(dirname "$0")/.." || exit 1
DIR=output/experiment/confirmatory
while pgrep -f "scripts/confirmatory_run.R" >/dev/null; do sleep 60; done
if grep -q "^done$" "$DIR/run.log"; then
  Rscript scripts/confirmatory_analysis.R > "$DIR/results.txt" 2>&1
  echo "analysis exit $? at $(date)" >> "$DIR/results.txt"
else
  echo "run ended without finishing at $(date); see run.log. No analysis run." > "$DIR/results.txt"
fi
