# WatchApprove Pro — Design Specification

## 1. Product Overview

**Name**: WatchApprove Pro
**Tagline**: "AI 在干活，你随时走开；危险操作抬手就批，电脑绝不睡死。"

A native macOS/iOS/watchOS trio that commercialises and supercharges `agent-watch-approve`:
- **Remote approvals** pushed to Mac (Dynamic Island), iPhone, and Apple Watch
- **Anti-sleep** (Amphetamine-style) triggered automatically while Claude/Codex works, plus manual and schedule modes
- **Relay server** on self-hosted VPS for remote SSH compatibility

This is a **买断制** paid app: Mac App Store $14.99, iOS App Store $9.99. One payment, lifetime use.

---

## 2. System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      VPS Relay (FastAPI)                     │
│   /ws/hook  /ws/device/{token}  POST /approve  POST /register│
│              SQLite  [pending_approvals]                     │
└─────────────────────────────────────────────────────────────┘
            ▲ WebSocket / HTTPS              ▼ APNs push
            │                                │
    ┌───────┴───────┐              ┌─────────┴────────┐
    │  Claude Code  │              │   iOS  /  Mac    │
    │  hook scripts  │              │  UNUserNotification │
    │ (Python, any   │              │  PushKit (Mac BG) │
    │  machine)      │              └─────────┬────────┘
    └───────────────┘                        │
                                               │ WatchConnectivity
                                         ┌─────┴─────┐
                                         │  watchOS  │
                                         │ WKNotif   │
                                         └───────────┘
```

**Local-optimised path**: When Claude Code runs on the same Mac as the menu bar app, the hook POSTs to `http://localhost:18792` directly — no relay, <10ms latency.

**Remote path** (SSH, CI, etc.): hook connects via WebSocket to VPS relay. Any device with the app receives the approval push via APNs.

---

## 3. Feature Map by Platform

### macOS (Menu Bar App)

| Feature | Implementation |
|---------|---------------|
| Approval notifications | `UNUserNotificationCenter` + `UNNotificationContent` with `UNNotificationCategory` |
| Dynamic Island | `InterruptionLevel: .timeSensitive` + `RelevanceScore`; expanded content shows Allow/Deny buttons |
| Anti-sleep | `IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep)` |
| Menu bar UI | NSStatusItem + NSMenu; shows active/pending state |
| WatchConnectivity | `WCSession` to sync approvals to paired Watch |
| Local WS server | `python` websockets lib or `aiohttp` on `:18792` for hook communication |
| Local storage | SQLite via `sqlite3` stdlib; stores approval history |

### iOS App

| Feature | Implementation |
|---------|---------------|
| Push notifications | `UNUserNotificationCenter` + `UNNotificationCategory` with Allow/Deny/Terminal actions |
| Background refresh | `BGAppRefreshTask` for periodic WS reconnection |
| Anti-sleep schedule UI | SwiftUI settings screen for time-window rules |
| Watch management | Pairing info, enable/disable per-device |
| History | Local SQLite, last 100 approvals |

### watchOS App

| Feature | Implementation |
|---------|---------------|
| Approval display | `WKNotificationCenter` (mirror of iPhone notification) |
| Button response | `WKNotificationAction` → WatchConnectivity → relay |
| Anti-sleep status | Read-only indicator synced from iPhone |

---

## 4. Anti-Sleep Design

### Three Modes

**Mode A — Caffeinate While Working (automatic)**
```
PreToolUse hook fires → IOPMAssertionCreate (prevent sleep)
Stop hook fires       → IOPMAssertionRelease
```
Works for both Claude Code and Codex. Handles mid-session interruptions gracefully.

**Mode B — Manual Menu Bar Toggle**
Menu bar icon click → toggle prevent-sleep assertion. Visual state in menu: ☕ Active / 💤 Off.

**Mode C — Scheduled Windows**
SwiftUI settings panel:
- Add rule: "9:00 AM – 6:00 PM, Monday–Friday"
- Multiple overlapping windows allowed
- Inactive window = no assertion (IOPMAssertionRelease if currently held)

### Caffeinate Logic (macOS)

```python
# Pseudo; actual use IOKit via ctypes / subprocess to caffeinate
import subprocess

def prevent_sleep(reason: str):
    pid = subprocess.run(['caffeinate', '-s', '-m', '-i', '-t', '0'],
                         preexec_fn=os.setsid).pid
    return pid  # store; release with kill(pid)

def allow_sleep(pid):
    subprocess.run(['kill', str(pid)])
```

Better approach: direct IOKit via `ctypes` (no subprocess overhead):
```c
// IOPMAssertionCreateWithName
CFStringRef reason = CFSTR("WatchApprove Pro: Claude Code active");
IOReturn r = IOPMAssertionCreateWithName(
    kIOPMAssertPreventUserIdleSystemSleep,
    kIOPMAssertionLevel,
    reason,
    &assertionID);
```

### Mode Priority
If Mode A (auto) and Mode B (manual) both active → assertion stays held (union, not override). Mode C (schedule) evaluated every 60s via `DispatchSourceTimer`.

---

## 5. Approval Flow (Detailed)

### Hook → App (Local)

```
Claude Code PreToolUse hook
  → POST /approve {tool, command, session_id, cwd}
  → macOS menu bar app receives via localhost WS
  → App shows Dynamic Island / Notification
  → User taps Allow/Deny
  → App writes to SQLite: approval {session_id, decision, timestamp}
  → Hook polls GET /poll/{session_id} or WS receives
  → Hook outputs "permissionDecision: allow/deny" to stdout
```

### Hook → App (Remote via Relay)

```
Claude Code PreToolUse hook
  → WS connect to wss://your-vps.com/ws/hook?token=HOOK_TOKEN
  → Send {tool, command, session_id, reply_url}
  → VPS stores in SQLite: pending_approval {id, reply_url, device_tokens[], status}
  → VPS sends APNs push to all registered devices
  → User approves on any device
  → Device POSTs /approve/{id} {decision}
  → VPS forwards to reply_url (hook's pending GET /poll/{id})
```

### Multi-Device Sync
- All devices maintain a persistent WS to VPS relay
- New approval arrives via APNs (triggers notification) AND via WS (real-time UI update)
- Approval on one device instantly resolves on all others (WS broadcast)
- iPhone is primary APNs target; Mac is secondary (PushKit background wake)

---

## 6. VPS Relay API

Base URL: `https://your-vps.com/api/v1`

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `WS` | `/ws/hook` | Hook connects; auth via `HOOK_TOKEN` query param |
| `WS` | `/ws/device/{device_token}` | App connects; receives live approval events |
| `POST` | `/approve/{approval_id}` | `{decision: "allow"\|"deny", device_id}` |
| `POST` | `/register` | `{device_token, platform: "ios"\|"macos", apns_token}` |
| `POST` | `/unregister` | `{device_token}` |
| `GET` | `/approvals/active` | Returns all pending approvals for device |
| `GET` | `/approvals/history?limit=50` | Returns past approvals |

### Database Schema (SQLite)

```sql
CREATE TABLE devices (
  id          TEXT PRIMARY KEY,   -- device_token (UUID)
  platform    TEXT NOT NULL,      -- 'ios' | 'macos' | 'watchos'
  apns_token  TEXT,
  created_at  INTEGER,
  last_seen   INTEGER
);

CREATE TABLE pending_approvals (
  id              TEXT PRIMARY KEY,  -- UUID
  hook_session_id TEXT NOT NULL,     -- maps to Claude Code session
  tool_name       TEXT,
  command         TEXT,
  reply_url       TEXT,              -- hook's callback URL for relay
  status          TEXT DEFAULT 'pending', -- pending | approved | denied | timeout
  created_at      INTEGER,
  resolved_at     INTEGER,
  resolution      TEXT              -- 'allow' | 'deny' | null
);

CREATE TABLE approval_tokens (
  approval_id TEXT PRIMARY KEY,
  device_id  TEXT NOT NULL,
  FOREIGN KEY (approval_id) REFERENCES pending_approvals(id),
  FOREIGN KEY (device_id) REFERENCES devices(id)
);
```

### Auth Model
- **Hook token**: random 64-char hex, set in app settings + env var `WATCH_APPROVE_HOOK_TOKEN`. Hook sends it on WS connect; relay validates before accepting.
- **Device tokens**: issued by app on first launch, stored in Keychain. Used as WS connection auth.
- **APNs tokens**: registered with relay on first launch; used for push.

---

## 7. Dynamic Island Design (macOS)

### Compact View
Shows watch icon + "🦀 Claude" or "🤖 Codex" + truncated command.

### Expanded View (Long Press)
Full command text, cwd, "Allow ✅" / "Deny ❌" / "Terminal" buttons inline.

### Minimal View
Only icon + small badge count of pending approvals.

### Implementation
```swift
// UNNotificationContent with Dynamic Island relevance
let content = UNMutableNotificationContent()
content.title = "🦀 Claude 待批准"
content.body = "rm -rf node_modules"
content.interruptionLevel = .timeSensitive
content.relevanceScore = 100

// Dynamic Island expanded content via Notification Content Extension
// or via UNNotificationCategory with hiddenPreviewText / ...
```

---

## 8. UI Design (iOS)

### Screens

1. **Approvals List** (home) — pending approvals at top, history below
2. **Settings** — anti-sleep schedule editor, notification preferences, VPS URL + hook token
3. **Devices** — paired Mac/iPhone/Watch, online status

### Approval Card
```
┌──────────────────────────────────────────┐
│ 🦀 Claude  ·  Bash  ·  3s ago            │
│ rm -rf node_modules                      │
│                                          │
│ [✅ 允许]  [❌ 拒绝]  [🖥️ 终端查看]        │
└──────────────────────────────────────────┘
```

### Anti-Sleep Schedule Editor
SwiftUI `DatePicker` for start/end time, `Toggle` for weekdays. List of rules, swipe to delete.

---

## 9. Security

- Hook token: 64-char random hex, transmitted only over TLS + WSS
- Device tokens: UUID stored in Keychain (iOS) / Keychain (macOS)
- All APNs pushes are device-specific; no broadcast model
- Approval response includes device ID; relay verifies device is registered before forwarding
- No PII stored on relay VPS (approval content stays in memory/SQLite; no logging of command content)
- Claude Code hook scripts communicate over WSS with cert pinning

---

## 10. App Store & Distribution

### Requirements
- Apple Developer Program ($99/year) for APNs + App Store
- Separate Mac App Store + iOS App Store listings
- Notarization for macOS app (automatic via Xcode)

### In-App Config Screen (no separate website)
- VPS URL input
- Hook token input
- "Copy hook script" button → generates wget-able install script
- Anti-sleep schedule editor

### Entitlements
- `com.apple.developer.usernotifications.time-sensitive` (Dynamic Island)
- `com.apple.developer.pushkit.unrestricted` (PushKit background)
- `com.apple.developer.networking.wifi-info` (optional, for local discovery)
- App Sandbox + Hardened Runtime

---

## 11. Tech Stack

| Layer | Technology |
|-------|-----------|
| macOS app | Swift + SwiftUI (menu bar via NSStatusItem + NSPopover), IOKit (caffeinate), UserNotifications, WatchConnectivity, PushKit, SQLite.swift |
| iOS app | Swift + SwiftUI, UserNotifications, WatchConnectivity, SQLite.swift |
| watchOS app | Swift + SwiftUI, WatchConnectivity |
| VPS relay | FastAPI + uvicorn + SQLite (single-file, zero-dependency) + aiofiles |
| Hook scripts | Python 3 stdlib (update existing `watch_approve.py` + `watch_done.py`) |

---

## 12. Hook Script Changes (Minimal)

The existing Python scripts gain one new env var:

```bash
WATCH_RELAY_URL=wss://your-vps.com/api/v1
WATCH_HOOK_TOKEN=64_char_hex_token
```

When set, the script connects via WSS instead of polling ntfy. Falls back to existing Pushcut/ntfy path if relay is unreachable.

```python
# New in watch_approve.py
RELAY_URL = os.environ.get("WATCH_RELAY_URL", "")
HOOK_TOKEN = os.environ.get("WATCH_HOOK_TOKEN", "")

if RELAY_URL and HOOK_TOKEN:
    # Use WebSocket relay path
else:
    # Existing Pushcut/ntfy path (unchanged)
```

Zero breaking changes to existing users. Old config works identically.

---

## 13. Scope for v1.0

**In scope**:
- macOS menu bar app with Dynamic Island + Notification Center
- iOS app with approvals + anti-sleep schedule
- watchOS app (WatchConnectivity sync, notification display)
- VPS relay (FastAPI + SQLite)
- Anti-sleep: all three modes
- Claude Code + Codex support
- Local relay (localhost) for same-machine setup

**Out of scope for v1.0**:
- Multi-user / team features
- History analytics dashboard
- Custom hook configurations per workspace
- Android support (ntfy still works via existing scripts)
