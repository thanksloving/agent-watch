# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`agent-watch-approve` pushes Claude Code / Codex CLI dangerous-operation approvals and task-completion notifications to Apple Watch / iPhone (via Pushcut) or Android / Wear OS (via ntfy). Two Python scripts, stdlib only, zero dependencies.

## Scripts

- **`watch_approve.py`** — PreToolUse / PermissionRequest hook. Receives JSON from stdin, sends a notification with Allow/Deny/Terminal buttons, listens on ntfy stream for the button click, outputs the decision.
- **`watch_done.py`** — Stop / StopFailure hook. Sends a "task done" or "rate limit" notification.

## Commands

```bash
# Self-check (run after any config change)
python watch_approve.py --doctor

# Print Claude Code config snippet (pipe into ~/.claude/settings.json)
python watch_approve.py --print-claude-config

# Print Codex config snippet (save to ~/.codex/hooks.json)
python watch_approve.py --print-codex-config

# Single test (dangerous command, matches WATCH_DANGER_ONLY=1)
echo '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/x"}}' \
  | python watch_approve.py

# Run tests
python -m pytest tests/test_watch.py -v
# Single test
python -m pytest tests/test_watch.py -v -k test_name
```

## Architecture

```
watch_approve.py
├── _load_env_file()        # Reads watch.env as fallback (Codex doesn't pass env to hooks)
├── Config from env vars    # PUSHCUT_KEY, NTFY_TOPIC, WATCH_TRANSPORT, etc.
├── is_dangerous(text)      # Built-in danger regex list + WATCH_DANGER_EXTRA
├── is_protected_write()    # WATCH_PROTECT_SELF / WATCH_PROTECT_PATHS guard
├── send_notification()      # Dispatches to _send_pushcut() or _send_ntfy()
├── wait_for_decision()     # Polls ntfy stream for button click
└── main()                  # stdin JSON → notification → wait → stdout decision

watch_done.py
└── Sends completion/rate-limit notification only (no waiting)
```

**Transport abstraction**: `WATCH_TRANSPORT=pushcut` (default, Apple) uses Pushcut cloud API. `WATCH_TRANSPORT=ntfy` (Android/Wear OS) publishes directly to ntfy with native HTTP-action buttons. Both share the same ntfy-based reply channel.

**Multi-window isolation**: `WATCH_UNIQUE_TOPIC=1` (default) generates a random reply topic per approval (base topic + 12-char suffix) so simultaneous windows don't cross-trigger.

**Fail-safe**: Any config missing / network error / timeout returns `decision: "ask"` (falls back to terminal prompt). The hook never crashes the agent.

## Config

All config via environment variables. `watch.env` in the script directory is a fallback that填补 Codex's env-passing gap — real env vars always win. Copy `watch.env.example` to `watch.env` and fill in keys.

Key env vars:
- `PUSHCUT_KEY`, `PUSHCUT_NOTIF` — Pushcut API key and notification name
- `NTFY_TOPIC` — Reply channel topic (long random string, acts as password)
- `WATCH_TRANSPORT` — `pushcut` (default) or `ntfy`
- `NTFY_NOTIFY_TOPIC` — Required for ntfy transport (notification topic, separate from reply topic)
- `WATCH_DANGER_ONLY=1` — Only dangerous operations trigger watch notification
- `WATCH_PROTECT_SELF=1` — Writes to script's own directory require watch approval
- `HTTPS_PROXY` — Outbound proxy (required in China)
