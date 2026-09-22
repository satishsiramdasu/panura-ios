#!/usr/bin/env bash
# Watch the GitHub Actions build for a commit and report how it ended.
#
# No `gh` and no token: this repo is public, so the Actions REST API answers
# anonymously. That is the whole point of the rewrite — the old watcher shelled
# out to `gh`, which was not installed, and forty "command not found" lines
# later it exited 0 and looked exactly like a green build.
#
# Anonymous API calls are rate limited to 60 an hour per address, so the default
# poll is 90 seconds. Do not lower it without counting.
#
#   tools/ci-watch.sh                 # HEAD, 90s poll, 45m limit
#   tools/ci-watch.sh <sha>           # a particular commit
#   tools/ci-watch.sh <sha> 60 3600   # sha, poll seconds, timeout seconds
#
# Exit: 0 the run succeeded · 1 it failed · 2 it was cancelled or timed out ·
# 3 no run ever appeared for that commit.
set -u

REPO="${CI_WATCH_REPO:-satishsiramdasu/panura-ios}"
SHA="${1:-$(git rev-parse HEAD)}"
POLL="${2:-90}"
LIMIT="${3:-2700}"
API="https://api.github.com/repos/$REPO"

short() { printf '%.7s' "$1"; }

# One field out of the run whose head_sha matches, or empty when no run exists
# for this commit yet — a push takes a few seconds to become a run.
run_field() {
    curl -fsS "$API/actions/runs?per_page=30" 2>/dev/null | python -c "
import json,sys
try: runs = json.load(sys.stdin).get('workflow_runs', [])
except Exception: sys.exit(0)
for r in runs:
    if r['head_sha'].startswith('$SHA'[:40]) or '$SHA'.startswith(r['head_sha'][:7]):
        print(r.get('$1') or '')
        break
"
}

echo "watching $REPO @ $(short "$SHA") — every ${POLL}s, giving up after ${LIMIT}s"

waited=0
while [ "$waited" -lt "$LIMIT" ]; do
    status=$(run_field status)
    if [ -z "$status" ]; then
        echo "  no run yet for $(short "$SHA")"
    elif [ "$status" = "completed" ]; then
        conclusion=$(run_field conclusion)
        url=$(run_field html_url)
        id=$(run_field id)
        echo "BUILD $(echo "$conclusion" | tr '[:lower:]' '[:upper:]') — $(short "$SHA")"
        echo "$url"
        case "$conclusion" in
            success) exit 0 ;;
            cancelled|skipped) exit 2 ;;
            *)
                # Which step broke, as far as an anonymous caller can see. The
                # log archive needs a token; the jobs list does not.
                curl -fsS "$API/actions/runs/$id/jobs" 2>/dev/null | python -c "
import json,sys
try: jobs = json.load(sys.stdin).get('jobs', [])
except Exception: sys.exit(0)
for j in jobs:
    if j.get('conclusion') in (None, 'success', 'skipped'): continue
    print('job:', j['name'], '->', j.get('conclusion'))
    for s in j.get('steps', []):
        if s.get('conclusion') not in (None, 'success', 'skipped'):
            print('  failed step:', s['name'])
"
                exit 1
                ;;
        esac
    else
        echo "  $status ($((waited / 60))m)"
    fi
    sleep "$POLL"
    waited=$((waited + POLL))
done

echo "gave up after ${LIMIT}s — $(short "$SHA") never finished"
exit 2
