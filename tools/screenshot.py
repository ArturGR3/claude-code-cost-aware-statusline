#!/usr/bin/env python3
"""Regenerate README screenshot.png from the real output of statusline.sh.

Runs the script for three states, converts its ANSI output to HTML, and
screenshots that in headless Chrome. Nothing in the image is hand-written: the
text is whatever the script actually printed.

    python3 tools/screenshot.py [path/to/session.jsonl]

The transcript argument only feeds cache-TTL detection; it defaults to the most
recent Claude Code transcript on this machine, and can be omitted entirely.
"""
import glob
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO, "statusline.sh")
OUT_PNG = os.path.join(REPO, "screenshot.png")
STATE = os.path.expanduser("~/.cache/claude-statusline")
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

ANSI_CLASS = {"31": "red", "32": "green", "33": "yellow", "90": "dim"}
CAPTIONS = ["subscription", "when something needs attention", "API billing"]


def newest_transcript():
    found = glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))
    return max(found, key=os.path.getmtime) if found else ""


def payload(*, transcript, pct, cache_hit, rl5, rl5_in, rl7=7, cost=0.394):
    return {
        "session_id": "screenshot-demo",
        "transcript_path": transcript,
        "effort": {"level": "medium"},
        "model": {"id": "claude-opus-5", "display_name": "Opus 5"},
        "workspace": {"current_dir": REPO},
        "cost": {"total_cost_usd": cost},
        "context_window": {
            "used_percentage": pct,
            "total_input_tokens": 240000,
            "current_usage": {
                "cache_read_input_tokens": cache_hit * 1000,
                "cache_creation_input_tokens": (100 - cache_hit) * 1000,
                "input_tokens": 0,
            },
        },
        "rate_limits": {
            "five_hour": {"used_percentage": rl5, "resets_at": int(time.time()) + rl5_in},
            "seven_day": {"used_percentage": rl7, "resets_at": int(time.time()) + 500000},
        },
    }


def run(pl, idle_seconds, prev_cost=None):
    """Run statusline.sh for real and return its raw ANSI output."""
    marker = f"{STATE}/cost-{pl['session_id']}"
    os.makedirs(STATE, exist_ok=True)
    with open(marker, "w") as f:
        # A different prior value makes this look like a real turn, so the
        # per-turn delta renders instead of the frozen refresh-tick display.
        cost = pl["cost"]["total_cost_usd"] if prev_cost is None else prev_cost
        f.write(str(cost))
    # The idle field comes from this marker's mtime.
    past = time.time() - idle_seconds
    os.utime(marker, (past, past))
    out = subprocess.run(
        ["bash", SCRIPT], input=json.dumps(pl), capture_output=True, text=True
    ).stdout.rstrip("\n")
    os.unlink(marker)
    return out


def to_rows(text):
    rows = []
    for line in text.split("\n"):
        parts, cls = [], None
        for chunk in re.split(r"(\x1b\[[0-9;]*m)", line):
            if not chunk:
                continue
            m = re.fullmatch(r"\x1b\[([0-9;]*)m", chunk)
            if m:
                cls = ANSI_CLASS.get(m.group(1))
                continue
            esc = html.escape(chunk)
            parts.append(f'<span class="{cls}">{esc}</span>' if cls else esc)
        rows.append("".join(parts))
    return rows


def main():
    transcript = sys.argv[1] if len(sys.argv) > 1 else newest_transcript()
    healthy = payload(transcript=transcript, pct=24, cache_hit=97, rl5=68, rl5_in=4800)
    pressure = payload(
        transcript=transcript, pct=82, cache_hit=97, rl5=91, rl5_in=1080, rl7=44
    )
    api = payload(transcript=transcript, pct=24, cache_hit=97, rl5=68, rl5_in=4800)
    del api["rate_limits"]

    blocks = [
        to_rows(run(healthy, 30)),
        to_rows(run(pressure, 120)),
        to_rows(run(api, 30, prev_cost=0.363)),
    ]
    for rows in blocks:
        print(re.sub(r"<[^>]+>", "", "\n".join(rows)))

    panels = "\n".join(
        f'<p class="cap">{cap}</p><div class="panel">'
        + "".join(f"<div class=row>{r}</div>" for r in rows)
        + "</div>"
        for cap, rows in zip(CAPTIONS, blocks)
    )
    page = """<!doctype html><meta charset="utf-8"><style>
  :root {
    --bg:#12141a; --panel:#1b1e26; --edge:#282c37;
    --fg:#d8dee9; --dim:#6f7787;
    --green:#a3be8c; --yellow:#ebcb8b; --red:#bf616a;
  }
  * { margin:0; padding:0; box-sizing:border-box; }
  body {
    background:var(--bg); padding:26px; width:max-content; color:var(--fg);
    font:16px/1.7 "Menlo","SF Mono",ui-monospace,monospace;
    -webkit-font-smoothing:antialiased;
  }
  .panel {
    background:var(--panel); border:1px solid var(--edge); border-radius:8px;
    padding:13px 18px; margin-bottom:14px; white-space:pre; min-width:660px;
  }
  .panel:last-child { margin-bottom:0; }
  .cap {
    font-size:11.5px; color:#565d6b; letter-spacing:.09em;
    text-transform:uppercase; margin:0 0 6px 3px; font-weight:500;
  }
  .dim { color:var(--dim); } .green { color:var(--green); }
  .yellow { color:var(--yellow); } .red { color:var(--red); }
</style>
""" + panels

    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "shot.html")
        with open(src, "w") as f:
            f.write(page)
        subprocess.run(
            [CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
             "--force-device-scale-factor=2", "--window-size=740,346",
             f"--screenshot={OUT_PNG}", src],
            capture_output=True, check=True,
        )
    print(f"\nwrote {OUT_PNG}")


if __name__ == "__main__":
    main()
