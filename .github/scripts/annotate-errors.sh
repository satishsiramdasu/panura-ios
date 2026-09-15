#!/usr/bin/env bash
# Turns the compile errors in build/xcodebuild.log into GitHub error
# annotations, ten at a time from the offset given as $1.
#
# Why: this app is written on Windows and CI is the only compiler. A failed
# archive's log can only be read by someone signed in to GitHub, but
# annotations are public through the API for a public repo — so the errors can
# be read and fixed without anyone copying them out of a log first.
#
# Ten at a time because GitHub keeps at most ten error annotations per step;
# the workflow calls this from three steps to surface up to thirty.

LOG=build/xcodebuild.log
[ -f "$LOG" ] || exit 0
OFFSET="${1:-0}"

grep -E '^/[^:]+\.swift:[0-9]+:[0-9]+: error: ' "$LOG" 2>/dev/null \
  | sort -u \
  | tail -n +"$((OFFSET + 1))" \
  | head -n 10 \
  | while IFS= read -r line; do
      file="${line%%:*}"
      rest="${line#*:}"; lineno="${rest%%:*}"
      rest="${rest#*:}"; col="${rest%%:*}"
      msg="${rest#*: error: }"
      rel="${file#"$GITHUB_WORKSPACE"/}"
      # Workflow commands treat % as an escape; a literal one must be %25.
      msg="${msg//%/%25}"
      echo "::error file=${rel},line=${lineno},col=${col}::${msg}"
    done

exit 0
