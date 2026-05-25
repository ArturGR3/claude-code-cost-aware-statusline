# claude-code-cost-aware-statusline

A custom status line for [Claude Code](https://claude.ai/code) that surfaces the information you actually need to work efficiently: context usage, cache health, idle time, and session cost — all in a single line at the bottom of your terminal.

![Status line screenshot](screenshot.png)

```
[Sonnet 4.6] | main | ctx [█░░░░░░░] 9% | cache 98% | 19s | $0.082 (+$0.0081)
```

---

## Why

Claude Code's default status bar is minimal. This script adds:

- **Context fill bar** — visual indicator of how much context window you've used, color-coded so you know when to `/compact`
- **Cache hit rate** — tells you how efficiently Claude is reusing prior context (high = fast and cheap, low = something changed)
- **Idle timer** — shows how long since your last turn; turns red with ❄ after 5 minutes when the prompt cache goes cold
- **Session cost** — cumulative cost since session start, plus per-turn delta so you can see what each message costs
- **Smart hints** — one-line contextual advice: cache rebuild warnings, context pressure alerts, idle cost warnings

---

## What the status line shows

```
[Sonnet 4.6] | main | ctx [████░░░░] 48% | cache 87% | 2m | $0.24 (+$0.031)
↑ Context 48% full — consider /compact — auto-compaction triggers near 90%+
```

| Field | Meaning |
|-------|---------|
| `[Sonnet 4.6]` | Active model |
| `main` | Current git branch (omitted outside a git repo) |
| `ctx [████░░░░] 48%` | Context window usage; green <50%, yellow 50–70%, red 70%+ |
| `cache 87%` | Prompt cache hit rate; green ≥80%, yellow 50–80%, red <50% |
| `2m` | Time since last turn; turns red with ❄ after 5 min (cache goes cold) |
| `$0.24 (+$0.031)` | Session cost + this-turn delta; yellow ≥$0.50, red ≥$2.00 |

### Hint line (line 2)

One hint is shown at a time, in priority order:

| Condition | Hint |
|-----------|------|
| Context ≥ 80% | `⚠ Context N% full — run /compact or /clear soon` |
| Context 70–79% | `↑ Context N% full — consider /compact` |
| Cache rebuilt (creation > 5k tokens) | `✎ Cache rebuilt this turn — did you edit CLAUDE.md, switch model, or change tools?` |
| Idle ≥ 5 min | `❄ Idle Nm — your next message will cost ~12× more on re-cached tokens` |
| First turn (cache building) | `○ Building cache — first turn always shows 0%, jumps to 80–90% next message` |

---

## Requirements

- **macOS or Linux** (bash)
- [`jq`](https://jqlang.org/) — for JSON parsing
  ```sh
  brew install jq        # macOS
  apt install jq         # Debian/Ubuntu
  ```
- **git** — only needed for the branch display; optional
- **Claude Code** with a `statusLine` config that supports `type: "command"`

---

## Install

**1. Copy the script**

```sh
curl -o ~/.claude/statusline.sh \
  https://raw.githubusercontent.com/ArturGR3/claude-code-cost-aware-statusline/main/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Or clone and copy manually:

```sh
git clone https://github.com/ArturGR3/claude-code-cost-aware-statusline.git
cp claude-code-cost-aware-statusline/statusline.sh ~/.claude/statusline.sh
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

If you already have a `settings.json`, merge just the `statusLine` block in. See [`settings.example.json`](settings.example.json) for a complete example.

**3. Start a new Claude Code session** — the status line appears immediately.

---

## How prompt caching affects cost

Claude caches your conversation prefix (system prompt, tools, prior messages). When the cache is warm:

- **Cache read** costs 0.1× the base input price
- **Cache write** costs 1.25× the base input price (5-minute TTL by default)
- After **5 minutes idle**, the cache expires and the next turn must re-write it at 1.25×

This means a cold-cache turn on a large context costs **up to ~12× more** on the re-cached tokens than a warm-cache turn. The idle timer and ❄ indicator exist to make this visible before you send a message.

---

## License

MIT — see [LICENSE](LICENSE).
