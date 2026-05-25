#!/bin/bash
input=$(cat)

# --- Model: strip "Claude " prefix for brevity, e.g. "Claude Opus 4.6" -> "Opus 4.6" ---
MODEL_RAW=$(echo "$input" | jq -r '.model.display_name // .model.id // "unknown"')
MODEL=$(echo "$MODEL_RAW" | sed 's/^Claude //')

SESSION_ID=$(echo "$input" | jq -r '.session_id')
CWD=$(echo "$input" | jq -r '.workspace.current_dir')

branch=$(git -C "$CWD" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)

# --- ANSI colors ---
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

# --- Context fill bar ---
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
ctx_part=""
pct=""
if [ -n "$PCT" ]; then
  pct=$(printf "%.0f" "$PCT")
  filled=$(( pct * 8 / 100 ))
  bar=""; i=0
  while [ $i -lt $filled ]; do bar="${bar}█"; i=$(( i + 1 )); done
  while [ $i -lt 8 ];        do bar="${bar}░"; i=$(( i + 1 )); done
  if   [ "$pct" -ge 80 ]; then CTX_COLOR="$RED"
  elif [ "$pct" -ge 50 ]; then CTX_COLOR="$YELLOW"
  else                         CTX_COLOR="$GREEN"
  fi
  ctx_part=$(printf "ctx [${CTX_COLOR}%s${RESET}] ${CTX_COLOR}%s%%${RESET}" "$bar" "$pct")
fi

# --- Cache numbers (current turn) ---
read -r R C I < <(echo "$input" | jq -r '
  .context_window.current_usage as $u
  | "\($u.cache_read_input_tokens // 0) \($u.cache_creation_input_tokens // 0) \($u.input_tokens // 0)"
')
TOTAL=$(( R + C + I ))
Ck=$(( C / 1000 ))
if [ $TOTAL -gt 0 ]; then
  HIT=$(( R * 100 / TOTAL ))
  if [ $HIT -le 10 ]; then
    CACHE_COLOR="$RED"
  else
    CACHE_COLOR="$GREEN"
  fi
  cache_part=$(printf "cache ${CACHE_COLOR}%d%%${RESET}" "$HIT")
  [ $C -gt 2000 ] && cache_part="${cache_part} [✎${Ck}k]"
else
  HIT=0
  cache_part=$(printf "cache ${RED}—${RESET}")
fi

# --- Time since last turn (read mtime BEFORE we potentially overwrite) ---
PREV_COST_FILE="/tmp/statusline-prev-cost-${SESSION_ID}"
ttl_part=""
AGO=0
if [ -f "$PREV_COST_FILE" ]; then
  NOW=$(date +%s)
  LAST=$(stat -c %Y "$PREV_COST_FILE" 2>/dev/null || stat -f %m "$PREV_COST_FILE" 2>/dev/null)
  if [ -n "$LAST" ]; then
    AGO=$(( NOW - LAST ))
    # Color coding: green < 3m (cache warm), yellow 3–5m (cache at risk), red >= 5m (cache dropped)
    if   [ $AGO -lt 60 ];  then TTL_COLOR="$GREEN"; ttl_label="${AGO}s"
    elif [ $AGO -lt 180 ]; then TTL_COLOR="$GREEN"; ttl_label="$(( AGO / 60 ))m"
    elif [ $AGO -lt 300 ]; then TTL_COLOR="$YELLOW"; ttl_label="$(( AGO / 60 ))m"
    else                        TTL_COLOR="$RED";    ttl_label="$(( AGO / 60 ))m ❄"
    fi
    ttl_part=$(printf "${TTL_COLOR}%s${RESET}" "$ttl_label")
  fi
fi

# --- Detect /clear or /compact via context drop, set CLEARED flag ---
PREV_PCT_FILE="/tmp/statusline-prev-pct-${SESSION_ID}"
PREV_PCT_RAW=$(cat "$PREV_PCT_FILE" 2>/dev/null || echo "0")
echo "${PCT:-0}" > "$PREV_PCT_FILE"

TOTAL_INPUT=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
PREV_TOKENS_FILE="/tmp/statusline-prev-tokens-${SESSION_ID}"
PREV_TOKENS=$(cat "$PREV_TOKENS_FILE" 2>/dev/null || echo "0")
echo "$TOTAL_INPUT" > "$PREV_TOKENS_FILE"

CLEARED=0
if [ -z "$PCT" ] && [ "$(echo "$PREV_PCT_RAW >= 0.1" | bc -l)" = "1" ]; then
  CLEARED=1
elif [ -n "$PCT" ] && [ "$(echo "$PREV_PCT_RAW > $PCT" | bc -l)" = "1" ]; then
  CLEARED=1
elif [ "$PREV_TOKENS" -gt 0 ] && [ "$TOTAL_INPUT" -eq 0 ]; then
  CLEARED=1
fi

# --- Cost: baseline-adjusted display, resets to $0 on /clear ---
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PREV_COST=$(cat "$PREV_COST_FILE" 2>/dev/null || echo "0")
DELTA=$(echo "$COST $PREV_COST" | awk '{printf "%.4f", $1 - $2}')

BASELINE_FILE="/tmp/statusline-baseline-${SESSION_ID}"
BASELINE=$(cat "$BASELINE_FILE" 2>/dev/null || echo "0")

DISPLAY_FILE="/tmp/statusline-cost-display-${SESSION_ID}"

# Fallback: no context but cost grew past baseline — missed the /clear transition
if [ "$CLEARED" = "0" ] && [ "$TOTAL_INPUT" -eq 0 ] && [ "$(echo "$COST > $BASELINE + 0.001" | bc -l)" = "1" ]; then
  CLEARED=1
fi

if [ "$CLEARED" = "1" ]; then
  # /clear happened — reset baseline to current raw cost, display goes to $0
  echo "$COST" > "$BASELINE_FILE"
  echo "$COST" > "$PREV_COST_FILE"
  cost_part='$0.000 (fresh)'
  echo "$cost_part" > "$DISPLAY_FILE"
elif [ "$COST" != "$PREV_COST" ]; then
  # Real turn — compute display in baseline-adjusted dollars
  ADJ_COST=$(echo "$COST $BASELINE" | awk '{printf "%.4f", $1 - $2}')
  ADJ_PREV=$(echo "$PREV_COST $BASELINE" | awk '{printf "%.4f", $1 - $2}')
  echo "$COST" > "$PREV_COST_FILE"
  cost_part=$(printf '$%.3f (+$%.4f)' "$ADJ_COST" "$DELTA")
  echo "$cost_part" > "$DISPLAY_FILE"
else
  # Refresh tick — frozen display
  cost_part=$(cat "$DISPLAY_FILE" 2>/dev/null || printf '$%.3f' "$COST")
fi

# --- Cost color: green < $0.50, yellow $0.50–$2.00, red > $2.00 ---
ADJ_FOR_COLOR=$(echo "$COST $BASELINE" | awk '{printf "%.4f", $1 - $2}')
if [ "$(echo "$ADJ_FOR_COLOR > 2.0" | bc -l)" = "1" ]; then
  COST_COLOR="$RED"
elif [ "$(echo "$ADJ_FOR_COLOR > 0.5" | bc -l)" = "1" ]; then
  COST_COLOR="$YELLOW"
else
  COST_COLOR="$GREEN"
fi
colored_cost=$(printf "${COST_COLOR}%s${RESET}" "$cost_part")

# --- Build line 1 ---
parts="[$MODEL]"
[ -n "$branch" ]   && parts="$parts | ${branch}"
[ -n "$ctx_part" ] && parts="$parts | $ctx_part"
parts="$parts | $cache_part"
[ -n "$ttl_part" ] && parts="$parts | $ttl_part"

# --- Build line 2: one prioritized hint, or nothing ---
hint=""

# 1. Context approaching auto-compact (most urgent)
if [ -n "$pct" ]; then
  if   [ "$pct" -ge 80 ]; then
    hint="⚠ Context ${pct}% full — run /compact or /clear soon, or you'll lose conversation detail"
  elif [ "$pct" -ge 70 ]; then
    hint="↑ Context ${pct}% full — wrap up your current task before things get auto-summarized"
  fi
fi

# 2. Cache rewrite mid-session (large write, not from idle — something changed)
if [ -z "$hint" ] && [ "$C" -gt 5000 ] && [ "$AGO" -lt 300 ] && [ "$R" -gt 0 ]; then
  hint="✎ Cache rebuilt this turn (${Ck}k tokens) — did you edit CLAUDE.md, switch model, or change tools?"
fi

# 3. Cold cache from idle
if [ -z "$hint" ] && [ "$AGO" -ge 300 ]; then
  hint="❄ Idle $(( AGO / 60 ))m — your next message will cost ~5× more than usual (cache went cold)"
fi

# 4. Warming (first turn — lots of writes, no reads yet)
if [ -z "$hint" ] && [ "$C" -gt 5000 ] && [ "$R" -eq 0 ]; then
  hint="○ Building cache — first turn always shows 0%, jumps to 80–90% next message"
fi

# --- Emit: plain parts + colored cost, hint in default color ---
printf "%s | ${COST_COLOR}%s${RESET}\n" "$parts" "$cost_part"
if [ -n "$hint" ]; then
  printf "%s\n" "$hint"
fi

exit 0
