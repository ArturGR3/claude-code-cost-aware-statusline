#!/bin/bash
input=$(cat)

# --- ANSI colors ---
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
RESET=$'\033[0m'

MODEL=$(echo "$input" | jq -r '.model.display_name // .model.id // "unknown"')
SESSION_ID=$(echo "$input" | jq -r '.session_id')
CWD=$(echo "$input" | jq -r '.workspace.current_dir')

branch=$(git -C "$CWD" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)

# --- Context fill bar (green <50%, yellow 50-70%, red 70%+) ---
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_part=""
pct=""
if [ -n "$PCT" ]; then
  pct=$(printf "%.0f" "$PCT")
  filled=$(( pct * 8 / 100 ))
  bar=""; i=0
  while [ $i -lt $filled ]; do bar="${bar}█"; i=$(( i + 1 )); done
  while [ $i -lt 8 ];        do bar="${bar}░"; i=$(( i + 1 )); done
  if   [ "$pct" -ge 70 ]; then ctx_color="$RED"
  elif [ "$pct" -ge 50 ]; then ctx_color="$YELLOW"
  else                          ctx_color="$GREEN"
  fi
  ctx_part="${ctx_color}ctx [${bar}] ${pct}%${RESET}"
fi

# --- Cache numbers (green 80%+, yellow 50-80%, red <50%) ---
read -r R C I < <(echo "$input" | jq -r '
  .context_window.current_usage as $u
  | "\($u.cache_read_input_tokens // 0) \($u.cache_creation_input_tokens // 0) \($u.input_tokens // 0)"
')
TOTAL=$(( R + C + I ))
Ck=$(( C / 1000 ))
if [ $TOTAL -gt 0 ]; then
  HIT=$(( R * 100 / TOTAL ))
  if   [ "$HIT" -ge 80 ]; then cache_color="$GREEN"
  elif [ "$HIT" -ge 50 ]; then cache_color="$YELLOW"
  else                          cache_color="$RED"
  fi
  cache_part="${cache_color}cache ${HIT}%${RESET}"
else
  HIT=0
  cache_part="cache —"
fi

# --- Time since last turn (red when cache cold 5m+) ---
PREV_COST_FILE="/tmp/statusline-prev-cost-${SESSION_ID}"
ttl_part=""
AGO=0
if [ -f "$PREV_COST_FILE" ]; then
  NOW=$(date +%s)
  LAST=$(stat -c %Y "$PREV_COST_FILE" 2>/dev/null || stat -f %m "$PREV_COST_FILE" 2>/dev/null)
  if [ -n "$LAST" ]; then
    AGO=$(( NOW - LAST ))
    if   [ $AGO -lt 60 ];  then ttl_part="${AGO}s"
    elif [ $AGO -lt 300 ]; then ttl_part="$(( AGO / 60 ))m"
    else                        ttl_part="${RED}$(( AGO / 60 ))m ❄${RESET}"
    fi
  fi
fi

# --- Detect /clear via context drop ---
PREV_PCT_FILE="/tmp/statusline-prev-pct-${SESSION_ID}"
PREV_PCT=$(cat "$PREV_PCT_FILE" 2>/dev/null || echo "0")
[ -n "$pct" ] && echo "$pct" > "$PREV_PCT_FILE"

CLEARED=0
if [ -n "$pct" ] && [ "$PREV_PCT" -gt 10 ] && [ "$pct" -lt 3 ]; then
  CLEARED=1
fi

# --- Cost: simplified display (default <$0.50, yellow $0.50-$2, red $2+) ---
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PREV_COST=$(cat "$PREV_COST_FILE" 2>/dev/null || echo "0")
DELTA=$(echo "$COST $PREV_COST" | awk '{printf "%.4f", $1 - $2}')

BASELINE_FILE="/tmp/statusline-baseline-${SESSION_ID}"
BASELINE=$(cat "$BASELINE_FILE" 2>/dev/null || echo "0")

DISPLAY_FILE="/tmp/statusline-cost-display-${SESSION_ID}"

if [ "$CLEARED" = "1" ]; then
  echo "$COST" > "$BASELINE_FILE"
  echo "$COST" > "$PREV_COST_FILE"
  cost_raw='$0.000'
  delta_raw=""
elif [ "$COST" != "$PREV_COST" ]; then
  ADJ_COST=$(echo "$COST $BASELINE" | awk '{printf "%.3f", $1 - $2}')
  echo "$COST" > "$PREV_COST_FILE"
  cost_raw=$(printf '$%s' "$ADJ_COST")
  delta_raw=$(printf ' (+$%s)' "$DELTA")
  echo "${cost_raw}${delta_raw}" > "$DISPLAY_FILE"
else
  cached=$(cat "$DISPLAY_FILE" 2>/dev/null)
  if [ -n "$cached" ]; then
    cost_raw="$cached"
    delta_raw=""
  else
    ADJ_COST=$(echo "$COST $BASELINE" | awk '{printf "%.3f", $1 - $2}')
    cost_raw=$(printf '$%s' "$ADJ_COST")
    delta_raw=""
  fi
fi

ADJ_NUM=$(echo "$COST $BASELINE" | awk '{printf "%.4f", $1 - $2}')
if echo "$ADJ_NUM" | awk '{exit ($1 >= 2.0) ? 0 : 1}'; then
  cost_color="$RED"
elif echo "$ADJ_NUM" | awk '{exit ($1 >= 0.5) ? 0 : 1}'; then
  cost_color="$YELLOW"
else
  cost_color=""
fi

if [ -n "$cost_color" ]; then
  cost_part="${cost_color}${cost_raw}${delta_raw}${RESET}"
else
  cost_part="${cost_raw}${delta_raw}"
fi

# --- Build line 1 ---
parts="[$MODEL]"
[ -n "$branch" ]   && parts="$parts | ${branch}"
[ -n "$ctx_part" ] && parts="$parts | $ctx_part"
parts="$parts | $cache_part"
[ -n "$ttl_part" ] && parts="$parts | $ttl_part"
parts="$parts | $cost_part"

# --- Build line 2: one prioritized hint, colored by severity ---
hint=""

if [ -n "$pct" ]; then
  if   [ "$pct" -ge 80 ]; then
    hint="${RED}⚠ Context ${pct}% full — run /compact or /clear soon, or you'll lose conversation detail${RESET}"
  elif [ "$pct" -ge 70 ]; then
    hint="${YELLOW}↑ Context ${pct}% full — consider /compact — auto-compaction triggers near 90%+${RESET}"
  fi
fi

if [ -z "$hint" ] && [ "$C" -gt 5000 ] && [ "$R" -gt 0 ]; then
  hint="${YELLOW}✎ Cache rebuilt this turn (${Ck}k tokens) — did you edit CLAUDE.md, switch model, or change tools?${RESET}"
fi

if [ -z "$hint" ] && [ "$AGO" -ge 300 ]; then
  hint="${RED}❄ Idle $(( AGO / 60 ))m — your next message will cost ~12× more on re-cached tokens (cache went cold)${RESET}"
fi

if [ -z "$hint" ] && [ "$C" -gt 5000 ] && [ "$R" -eq 0 ]; then
  hint="○ Building cache — first turn always shows 0%, jumps to 80–90% next message"
fi

# --- Emit ---
echo "$parts"
if [ -n "$hint" ]; then
  echo "$hint"
fi

exit 0
