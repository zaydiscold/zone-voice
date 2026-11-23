#!/bin/zsh
# Sweeps SwipeTuning overrides over the dev fixture and prints one line per configuration.
#   zsh scripts/swipe-eval/sweep.sh '{"yScale":0.85}' '{"endWeight":0.1}' ...
# Run from the repository root. Uses ~/.cache/zone-swipe-data/eval-dev-2000.json unless
# ZONE_SWIPE_FIXTURES is set.
set -u
FIXTURES=${ZONE_SWIPE_FIXTURES:-$HOME/.cache/zone-swipe-data/eval-dev-2000.json}
for config in "$@"; do
  line=$(ZONE_SWIPE_FIXTURES="$FIXTURES" ZONE_SWIPE_TUNING="$config" ZONE_SWIPE_PAIRS="${ZONE_SWIPE_PAIRS:-}" ZONE_SWIPE_WEIGHTS="${ZONE_SWIPE_WEIGHTS:-}" ZONE_SWIPE_ALL_WORDS="${ZONE_SWIPE_ALL_WORDS:-}" ZONE_SWIPE_EXTRA_WORDS="${ZONE_SWIPE_EXTRA_WORDS:-}" \
    swift test -c release --package-path ZoneCore --filter SwipeEvalTests 2>&1 | grep "SWIPE EVAL" | sed 's/SWIPE EVAL //')
  printf '%-60s %s\n' "$config" "$line"
done
