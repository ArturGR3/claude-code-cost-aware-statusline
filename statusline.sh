#!/bin/bash
# Status line for Claude Code: context fill, cache health, idle time, and either
# plan usage (subscription) or dollars (API billing).
#
# Reads the status line JSON on stdin, prints one line, plus a second line when
# something needs attention.

input=$(cat)

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-statusline"
mkdir -p "$STATE_DIR" 2>/dev/null
# /clear starts a new session_id, so per-session state accumulates forever.
find "$STATE_DIR" -type f -mtime +7 -delete 2>/dev/null

# --- Every field we need, in one jq pass (line-based: values may contain spaces)
{
  read -r MODEL_RAW
  read -r SESSION_ID
  read -r CWD
  read -r TRANSCRIPT
  read -r PCT_RAW
  read -r TOTAL_INPUT
  read -r R
  read -r C
  read -r I
  read -r COST
  read -r RL5_PCT
  read -r RL5_RESET
  read -r RL7_PCT
  read -r RL7_RESET
  read -r RL7_OPUS_PCT
  read -r EFFORT
} < <(echo "$input" | jq -r '
  [ (.model.display_name // .model.id // "unknown"),
    (.session_id // "nosession"),
    (.workspace.current_dir // "."),
    (.transcript_path // ""),
    (.context_window.used_percentage // ""),
    (.context_window.total_input_tokens // 0),
    (.context_window.current_usage.cache_read_input_tokens // 0),
    (.context_window.current_usage.cache_creation_input_tokens // 0),
    (.context_window.current_usage.input_tokens // 0),
    (.cost.total_cost_usd // 0),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.seven_day.resets_at // ""),
    (.rate_limits.seven_day_opus.used_percentage // ""),
    (.effort.level // "")
  ] | .[] | tostring')

MODEL=${MODEL_RAW#Claude }
# low | medium | high | xhigh | max, shortened to keep the bracket narrow.
case "$EFFORT" in
  medium) EFFORT_SHORT="med" ;;
  xhigh)  EFFORT_SHORT="xhi" ;;
  *)      EFFORT_SHORT="$EFFORT" ;;
esac
branch=$(git -C "$CWD" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null)

# --- ANSI: labels and separators stay dim so only the numbers carry color ---
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
DIM='\033[90m'
RESET='\033[0m'
SEP="${DIM} · ${RESET}"

fmt_eta() { # $1 = seconds -> "6d9h" / "1h20m" / "42m"
  local s=$1 d h m
  [ "$s" -lt 0 ] && s=0
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then printf '%dm' "$m"
  else                      printf '<1m'
  fi
}

# --- Cache TTL: not in the payload, but the transcript records which bucket
# each cache write landed in, so read it from what actually happened. ---
TTL="5m"
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  detected=$(tail -n 400 "$TRANSCRIPT" 2>/dev/null | sed 1d | jq -r '
    (.message.usage.cache_creation // empty)
    | if   (.ephemeral_1h_input_tokens // 0) > 0 then "1h"
      elif (.ephemeral_5m_input_tokens // 0) > 0 then "5m"
      else empty end' 2>/dev/null | tail -1)
  [ -n "$detected" ] && TTL="$detected"
fi
if [ "$TTL" = "1h" ]; then
  TTL_WARN=1800; TTL_COLD=3600
else
  TTL_WARN=180;  TTL_COLD=300
fi

# --- Context fill ---
ctx_part=""
pct=""
if [ -n "$PCT_RAW" ]; then
  pct=$(printf "%.0f" "$PCT_RAW")
  if   [ "$pct" -ge 80 ]; then CTX_COLOR="$RED"
  elif [ "$pct" -ge 50 ]; then CTX_COLOR="$YELLOW"
  else                         CTX_COLOR="$GREEN"
  fi
  ctx_part=$(printf "${DIM}ctx${RESET} ${CTX_COLOR}%s%%${RESET}" "$pct")
fi

# --- Cache hit rate for the current turn ---
TOTAL=$(( R + C + I ))
Ck=$(( C / 1000 ))
if [ "$TOTAL" -gt 0 ]; then
  HIT=$(( R * 100 / TOTAL ))
  if [ "$HIT" -le 10 ]; then CACHE_COLOR="$RED"; else CACHE_COLOR="$GREEN"; fi
  cache_part=$(printf "${DIM}cache${RESET} ${CACHE_COLOR}%d%%${RESET}" "$HIT")
else
  HIT=0
  cache_part=$(printf "${DIM}cache${RESET} ${RED}-${RESET}")
fi

# --- Time since the last real turn (mtime of the cost marker, read before we
# overwrite it below) ---
COST_FILE="$STATE_DIR/cost-$SESSION_ID"
DISPLAY_FILE="$STATE_DIR/display-$SESSION_ID"
idle_part=""
AGO=0
if [ -f "$COST_FILE" ]; then
  LAST=$(stat -f %m "$COST_FILE" 2>/dev/null || stat -c %Y "$COST_FILE" 2>/dev/null)
  if [ -n "$LAST" ]; then
    AGO=$(( $(date +%s) - LAST ))
    if   [ "$AGO" -lt 60 ];          then IDLE_COLOR="$GREEN";  idle_label="${AGO}s"
    elif [ "$AGO" -lt "$TTL_WARN" ]; then IDLE_COLOR="$GREEN";  idle_label="$(( AGO / 60 ))m"
    elif [ "$AGO" -lt "$TTL_COLD" ]; then IDLE_COLOR="$YELLOW"; idle_label="$(( AGO / 60 ))m"
    else                                  IDLE_COLOR="$RED";    idle_label="$(( AGO / 60 ))m ❄"
    fi
    idle_part=$(printf "${IDLE_COLOR}%s${RESET}" "$idle_label")
  fi
fi

# --- Spend: plan usage on a subscription, dollars on API billing ---
# rate_limits is present only on subscriptions, so the default needs no config.
UNITS="${CLAUDE_STATUSLINE_UNITS:-auto}"
if [ "$UNITS" = "auto" ]; then
  if [ -n "$RL5_PCT" ]; then UNITS="usage"; else UNITS="cost"; fi
fi

usage_part=""
rl5=""; rl7=""; rl7_opus=""; rl5_eta=""; rl7_eta=""; wk=""
if [ "$UNITS" != "cost" ] && [ -n "$RL5_PCT" ]; then
  rl5=$(printf "%.0f" "$RL5_PCT")
  [ -n "$RL7_PCT" ] && rl7=$(printf "%.0f" "$RL7_PCT")
  [ -n "$RL7_OPUS_PCT" ] && rl7_opus=$(printf "%.0f" "$RL7_OPUS_PCT")
  NOW=$(date +%s)
  [ -n "$RL5_RESET" ] && rl5_eta=$(fmt_eta $(( RL5_RESET - NOW )))
  [ -n "$RL7_RESET" ] && rl7_eta=$(fmt_eta $(( RL7_RESET - NOW )))

  if   [ "$rl5" -ge 85 ]; then RL5_COLOR="$RED"
  elif [ "$rl5" -ge 60 ]; then RL5_COLOR="$YELLOW"
  else                         RL5_COLOR="$GREEN"
  fi
  usage_part=$(printf "${DIM}5h${RESET} ${RL5_COLOR}%s%%${RESET}" "$rl5")
  [ -n "$rl5_eta" ] && usage_part="${usage_part}$(printf " ${DIM}↻%s${RESET}" "$rl5_eta")"

  # The weekly window only earns space once it is the binding constraint.
  wk="$rl7"; wk_label="wk"
  if [ -n "$rl7_opus" ] && [ "$rl7_opus" -gt "${rl7:-0}" ]; then wk="$rl7_opus"; wk_label="wk opus"; fi
  if [ -n "$wk" ] && { [ "$wk" -gt "$rl5" ] || [ "$wk" -ge 50 ]; }; then
    if   [ "$wk" -ge 85 ]; then WK_COLOR="$RED"
    elif [ "$wk" -ge 60 ]; then WK_COLOR="$YELLOW"
    else                        WK_COLOR="$GREEN"
    fi
    usage_part="${usage_part}${SEP}$(printf "${DIM}%s${RESET} ${WK_COLOR}%s%%${RESET}" "$wk_label" "$wk")"
  fi
fi

# Dollars. total_cost_usd is not monotonic within a session (bridged and resumed
# sessions re-zero it), so the per-turn delta is clamped at zero, never trusted.
cost_part=""
if [ "$UNITS" != "usage" ]; then
  PREV_COST=$(cat "$COST_FILE" 2>/dev/null || echo "0")
  read -r DELTA COST_TIER < <(awk -v c="$COST" -v p="$PREV_COST" 'BEGIN {
    d = c - p; if (d < 0) d = 0
    t = (c > 2.0 ? "red" : (c > 0.5 ? "yellow" : "green"))
    printf "%.4f %s\n", d, t
  }')
  case "$COST_TIER" in
    red)    COST_COLOR="$RED" ;;
    yellow) COST_COLOR="$YELLOW" ;;
    *)      COST_COLOR="$GREEN" ;;
  esac
  if [ "$COST" != "$PREV_COST" ]; then
    cost_text=$(printf '$%.3f (+$%.4f)' "$COST" "$DELTA")
    printf '%s' "$cost_text" > "$DISPLAY_FILE"
  else
    # Refresh tick, not a new turn: keep the last turn's numbers on screen.
    cost_text=$(cat "$DISPLAY_FILE" 2>/dev/null || printf '$%.3f' "$COST")
  fi
  cost_part=$(printf "${COST_COLOR}%s${RESET}" "$cost_text")
fi

# The marker doubles as the idle clock, so only touch it on a real turn.
PREV_SEEN=$(cat "$COST_FILE" 2>/dev/null || echo "0")
[ "$COST" != "$PREV_SEEN" ] && printf '%s' "$COST" > "$COST_FILE"

# --- Line 1 ---
line="${DIM}[${RESET}${MODEL}"
[ -n "$EFFORT_SHORT" ] && line="${line}${DIM} ${EFFORT_SHORT}${RESET}"
line="${line}${DIM}]${RESET}"
[ -n "$branch" ]     && line="${line}${SEP}${DIM}${branch}${RESET}"
[ -n "$ctx_part" ]   && line="${line}${SEP}${ctx_part}"
line="${line}${SEP}${cache_part}"
[ -n "$idle_part" ]  && line="${line}${SEP}${idle_part}"
[ -n "$usage_part" ] && line="${line}${SEP}${usage_part}"
[ -n "$cost_part" ]  && line="${line}${SEP}${cost_part}"

# --- Line 2: one hint, most urgent first ---
hint=""

if [ -n "$rl5" ] && [ "$rl5" -ge 85 ]; then
  hint="⚠ 5h window ${rl5}% used${rl5_eta:+ - resets in $rl5_eta}"
fi

if [ -z "$hint" ] && [ -n "$wk" ] && [ "$wk" -ge 85 ]; then
  hint="⚠ Weekly window ${wk}% used${rl7_eta:+ - resets in $rl7_eta}"
fi

if [ -z "$hint" ] && [ -n "$pct" ]; then
  if   [ "$pct" -ge 80 ]; then
    hint="⚠ Context ${pct}% full - run /compact or /clear soon, or you'll lose conversation detail"
  elif [ "$pct" -ge 70 ]; then
    hint="↑ Context ${pct}% full - wrap up your current task before things get auto-summarized"
  fi
fi

if [ -z "$hint" ] && [ "$C" -gt 5000 ] && [ "$AGO" -lt "$TTL_COLD" ] && [ "$R" -gt 0 ]; then
  hint="✎ Cache rebuilt this turn (${Ck}k tokens) - did you edit CLAUDE.md, switch model, or change tools?"
fi

if [ -z "$hint" ] && [ "$AGO" -ge "$TTL_COLD" ]; then
  hint="❄ Idle $(( AGO / 60 ))m - past the ${TTL} cache TTL, so your next message pays full input price"
fi

if [ -z "$hint" ] && [ "$C" -gt 5000 ] && [ "$R" -eq 0 ]; then
  hint="○ Building cache - first turn always shows 0%, jumps to 80-90% next message"
fi

printf "%b\n" "$line"
[ -n "$hint" ] && printf "${DIM}%s${RESET}\n" "$hint"

exit 0
