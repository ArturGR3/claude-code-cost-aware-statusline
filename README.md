# claude-code-cost-aware-statusline

A status line for [Claude Code](https://claude.ai/code) that shows context usage, cache health, idle time, and session cost.

![Status line screenshot](screenshot.png)

## Why

Claude Code shows basic session info, but not the numbers that drive your costs: cache hit rate, idle time vs cache TTL, and per-turn spend. This script surfaces all of that so you know when a message will be cheap and when it won't.

## What you see

```
[Opus 4.6] | main | ctx [████░░░░] 48% | cache 87% | 2m | $0.240 (+$0.0310)
```

| Field | What it means |
|-------|---------------|
| `[Opus 4.6]` | Active model |
| `main` | Git branch (hidden outside repos) |
| `ctx [████░░░░] 48%` | Context window fill — green <50%, yellow 50-80%, red 80%+ |
| `cache 87%` | Prompt cache hit rate — green >10%, red ≤10% |
| `2m` | Time since last turn — green <3m, yellow 3-5m, red 5m+ (cache cold ❄) |
| `$0.240 (+$0.0310)` | Session cost + turn delta — yellow >$0.50, red >$2.00 |

A second line appears when something needs attention: context pressure, cache rebuilds, cold cache warnings, or first-turn cache warmup.

## Install

**1. Copy the script**

```sh
curl -o ~/.claude/statusline.sh \
  https://raw.githubusercontent.com/ArturGR3/claude-code-cost-aware-statusline/main/statusline.sh
chmod +x ~/.claude/statusline.sh
```

**2. Add to `~/.claude/settings.json`**

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh",
    "refreshInterval": 30
  }
}
```

**3. Restart Claude Code** — the status line appears immediately.
