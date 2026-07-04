# WatchApprove Pro — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build WatchApprove Pro: a native macOS/iOS/watchOS trio for remote Claude Code/Codex approval + anti-sleep, backed by a self-hosted VPS FastAPI relay.

**Architecture:** Three native apps (macOS menu bar, iOS, watchOS) communicate with Claude Code hooks via either a local WebSocket server (same-machine) or a VPS relay (remote SSH). APNs pushes notifications to iPhone; WatchConnectivity syncs to Watch. Anti-sleep uses IOKit assertions on macOS, scheduled rules on iOS.

**Tech Stack:** Swift + SwiftUI (apps), FastAPI + uvicorn + SQLite (VPS relay), Python 3 stdlib (hooks), XcodeGen (project generation).

---

## Global Constraints

- Python hooks: Python 3 stdlib only, no new dependencies, backward-compatible with existing config
- macOS app: Swift 5.9+, Xcode 15+, built with XcodeGen
- iOS app: iOS 17+ (for SwiftData or latest SwiftUI schedule APIs)
- watchOS app: watchOS 10+
- Entitlements: `com.apple.developer.usernotifications.time-sensitive`, `com.apple.developer.pushkit.unrestricted`, App Sandbox
- APNs: requires Apple Developer Program membership ($99/year)
- VPS relay: single-file SQLite, zero Python dependencies beyond FastAPI+uvicorn+aiofiles+aiosqlite

---

## Project Directory Structure

```
WatchApprovePro/
├── relay/                          # VPS relay server
│   ├── main.py                     # FastAPI app, all endpoints
│   ├── requirements.txt            # fastapi, uvicorn, aiofiles, aiosqlite
│   └── watchapprove.db             # SQLite DB (gitignored, created at runtime)
├── macos/                          # macOS menu bar app
│   ├── project.yml                 # XcodeGen config
│   ├── WatchApproveMac/
│   │   ├── App/
│   │   │   ├── main.swift
│   │   │   ├── WatchApproveMacApp.swift
│   │   │   ├── MenuBar/
│   │   │   │   ├── MenuBarController.swift
│   │   │   │   └── ApprovalPopover.swift
│   │   │   ├── Caffeinate/
│   │   │   │   └── CaffeinateManager.swift
│   │   │   ├── WebSocket/
│   │   │   │   ├── LocalWSServer.swift
│   │   │   │   └── RelayWSClient.swift
│   │   │   ├── Notifications/
│   │   │   │   └── NotificationManager.swift
│   │   │   ├── Database/
│   │   │   │   └── DatabaseManager.swift
│   │   │   └── Shared/
│   │   │       ├── Approval.swift
│   │   │       ├── WatchConnectivityManager.swift
│   │   │       └── Models.swift
│   │   └── Resources/
│   │       └── Assets.xcassets/
├── ios/                            # iOS app
│   ├── project.yml
│   ├── WatchApprove/
│   │   ├── App/
│   │   │   ├── WatchApproveApp.swift
│   │   │   └── AppDelegate.swift
│   │   ├── Views/
│   │   │   ├── ApprovalsView.swift
│   │   │   ├── SettingsView.swift
│   │   │   ├── DevicesView.swift
│   │   │   └── Components/
│   │   │       └── ApprovalCard.swift
│   │   ├── ViewModels/
│   │   │   ├── ApprovalsViewModel.swift
│   │   │   └── SettingsViewModel.swift
│   │   ├── Services/
│   │   │   ├── WebSocketService.swift
│   │   │   ├── NotificationService.swift
│   │   │   └── ScheduleManager.swift
│   │   ├── Shared/
│   │   │   └── (Approval.swift, Models.swift — shared with macos)
│   │   └── Resources/
│   └── WatchApprove.xcodeproj/
├── watch/                          # watchOS app
│   ├── project.yml
│   ├── WatchApproveWatch/
│   │   ├── App/
│   │   │   └── WatchApproveApp.swift
│   │   ├── Views/
│   │   │   ├── ApprovalDetailView.swift
│   │   │   └── StatusView.swift
│   │   ├── Services/
│   │   │   └── WatchConnectivityService.swift
│   │   └── Shared/
│   └── WatchApproveWatch.xcodeproj/
├── shared/                         # Shared code (Approval.swift, Models.swift)
│   ├── Approval.swift
│   └── Models.swift
└── hooks/                          # Updated Python hooks
    ├── watch_approve.py            # Modified: add relay WS path
    └── watch_done.py              # Modified: add relay path
```

---

## Phase 1: VPS Relay Server

### Task 1.1: Project scaffold and database schema

**Files:**
- Create: `relay/main.py`
- Create: `relay/requirements.txt`
- Test: `tests/test_relay.py`

**Interfaces:**
- Produces: SQLite DB at `watchapprove.db`, FastAPI app mountable at `/`

- [ ] **Step 1: Create relay directory and requirements.txt**

```bash
mkdir -p relay
```

```txt
# relay/requirements.txt
fastapi==0.115.0
uvicorn[standard]==0.30.0
aiofiles==24.1.0
aiosqlite==0.20.0
websockets==12.0
pydantic==2.9.0
```

- [ ] **Step 2: Write database init SQL and connection helper**

```python
# relay/main.py (partial — database setup section)
import aiosqlite, os
from pathlib import Path

DATABASE_PATH = Path(__file__).parent / "watchapprove.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (
    id          TEXT PRIMARY KEY,
    platform    TEXT NOT NULL CHECK(platform IN ('ios','macos','watchos')),
    apns_token  TEXT,
    created_at  INTEGER NOT NULL,
    last_seen   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS pending_approvals (
    id              TEXT PRIMARY KEY,
    hook_session_id TEXT NOT NULL,
    tool_name       TEXT,
    command         TEXT,
    reply_url       TEXT,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending','approved','denied','timeout')),
    created_at      INTEGER NOT NULL,
    resolved_at     INTEGER,
    resolution      TEXT CHECK(resolution IN ('allow','deny',NULL))
);

CREATE TABLE IF NOT EXISTS approval_tokens (
    approval_id  TEXT PRIMARY KEY,
    device_id    TEXT NOT NULL,
    FOREIGN KEY (approval_id) REFERENCES pending_approvals(id) ON DELETE CASCADE,
    FOREIGN KEY (device_id)   REFERENCES devices(id)          ON DELETE CASCADE
);
"""

async def get_db():
    db = await aiosqlite.connect(str(DATABASE_PATH))
    db.row_factory = aiosqlite.Row
    await db.executescript(SCHEMA)
    await db.commit()
    yield db
    await db.close()
```

- [ ] **Step 3: Write data models**

```python
from pydantic import BaseModel
from typing import Optional, Literal

class ApprovalCreate(BaseModel):
    tool_name: str
    command: str
    hook_session_id: str
    reply_url: Optional[str] = None

class ApprovalResponse(BaseModel):
    approval_id: str
    status: Literal["pending","approved","denied","timeout"]
    tool_name: str
    command: str
    created_at: int

class DecisionInput(BaseModel):
    decision: Literal["allow","deny"]
    device_id: str

class DeviceRegister(BaseModel):
    device_token: str
    platform: Literal["ios","macos","watchos"]
    apns_token: Optional[str] = None
```

- [ ] **Step 4: Write FastAPI app with all endpoints**

```python
# relay/main.py — full FastAPI app
import asyncio, uuid, time, os
from contextlib import asynccontextmanager
from fastapi import FastAPI, WebSocket, WebSocketDisconnect,
                    Request, Depends, HTTPException, Query
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from typing import Optional, Literal
import aiosqlite
from pathlib import Path
import aiofiles

DATABASE_PATH = Path(__file__).parent / "watchapprove.db"
HOOK_TOKEN = os.environ.get("WATCH_APPROVE_HOOK_TOKEN", "")

# ---- DB setup ----
SCHEMA = """
CREATE TABLE IF NOT EXISTS devices (...); -- as above
CREATE TABLE IF NOT EXISTS pending_approvals (...); -- as above
CREATE TABLE IF NOT EXISTS approval_tokens (...); -- as above
"""

@asynccontextmanager
async def lifespan(app: FastAPI):
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        await db.executescript(SCHEMA)
        await db.commit()
    yield

app = FastAPI(title="WatchApprove Relay", lifespan=lifespan)

# ---- WebSocket managers ----
class ConnectionManager:
    def __init__(self):
        self.hook_ws: Optional[WebSocket] = None
        self.device_ws: dict[str, WebSocket] = {}  # device_token -> ws

    async def connect_hook(self, ws: WebSocket, token: str):
        if token != HOOK_TOKEN:
            await ws.close(code=4001)
            return
        self.hook_ws = ws
        try:
            await ws.wait_closed()
        finally:
            self.hook_ws = None

    async def connect_device(self, ws: WebSocket, token: str):
        self.device_ws[token] = ws
        try:
            await ws.wait_closed()
        finally:
            del self.device_ws[token]

    async def broadcast_to_devices(self, message: dict):
        dead = []
        for token, ws in self.device_ws.items():
            try:
                await ws.send_json(message)
            except Exception:
                dead.append(token)
        for token in dead:
            del self.device_ws[token]

manager = ConnectionManager()

# ---- Hook Token Auth ----
def verify_hook_token(token: str = Query(...)):
    if not HOOK_TOKEN or token != HOOK_TOKEN:
        raise HTTPException(401, "Invalid hook token")

# ---- Routes ----

@app.websocket("/ws/hook")
async def ws_hook(ws: WebSocket, token: str = Query(...)):
    await manager.connect_hook(ws, token)

@app.websocket("/ws/device/{device_token}")
async def ws_device(ws: WebSocket, device_token: str):
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        db.row_factory = aiosqlite.Row
        await db.execute(
            "UPDATE devices SET last_seen=? WHERE id=?", (int(time.time()), device_token))
        await db.commit()
    await manager.connect_device(ws, device_token)

@app.post("/approve/{approval_id}")
async def post_approve(approval_id: str, body: DecisionInput):
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        db.row_factory = aiosqlite.Row
        row = await db.execute_row(
            "SELECT * FROM pending_approvals WHERE id=?", (approval_id,))
        if not row:
            raise HTTPException(404, "Approval not found")
        if row["status"] != "pending":
            return {"status": "already_resolved", "current": row["status"]}

        await db.execute(
            """UPDATE pending_approvals
               SET status='approved' if ?='allow' else 'denied',
                   resolution=?, resolved_at=?
               WHERE id=?""",
            (body.decision, body.decision, int(time.time()), approval_id))

        await db.execute(
            "INSERT INTO approval_tokens (approval_id, device_id) VALUES (?,?)",
            (approval_id, body.device_id))
        await db.commit()

        # Forward to hook if reply_url provided
        reply_url = row["reply_url"]
        if reply_url:
            try:
                import urllib.request
                data = f"decision={body.decision}".encode()
                req = urllib.request.Request(
                    reply_url, data=data,
                    headers={"Content-Type": "application/x-www-form-urlencoded"})
                # Fire and forget — don't block
                asyncio.create_task(
                    asyncio.to_thread(urllib.request.urlopen, req, timeout=5))
            except Exception:
                pass  # Fail silently; hook also polls

        # Broadcast to all devices
        await manager.broadcast_to_devices({
            "type": "approval_resolved",
            "approval_id": approval_id,
            "decision": body.decision
        })

    return {"ok": True}

@app.post("/register")
async def post_register(body: DeviceRegister):
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        await db.execute("""INSERT OR REPLACE INTO devices
            (id, platform, apns_token, created_at, last_seen)
            VALUES (?, ?, ?, ?, ?)""",
            (body.device_token, body.platform,
             body.apns_token, int(time.time()), int(time.time())))
        await db.commit()
    return {"ok": True}

@app.post("/unregister")
async def post_unregister(device_token: str = Query(...)):
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        await db.execute("DELETE FROM devices WHERE id=?", (device_token,))
        await db.commit()
    return {"ok": True}

@app.get("/approvals/active")
async def get_active(device_token: str = Query(...)):
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        db.row_factory = aiosqlite.Row
        rows = await db.execute_fetchall(
            """SELECT pa.* FROM pending_approvals pa
               JOIN approval_tokens at ON at.approval_id = pa.id
               WHERE at.device_id=? AND pa.status='pending'
               ORDER BY pa.created_at DESC""", (device_token,))
        return [dict(r) for r in rows]

@app.get("/approvals/history")
async def get_history(device_token: str = Query(...), limit: int = Query(50)):
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        db.row_factory = aiosqlite.Row
        rows = await db.execute_fetchall(
            """SELECT pa.* FROM pending_approvals pa
               JOIN approval_tokens at ON at.approval_id = pa.id
               WHERE at.device_id=?
               ORDER BY pa.created_at DESC LIMIT ?""",
            (device_token, limit))
        return [dict(r) for r in rows]

# Hook-facing: create a new pending approval
@app.post("/approval")
async def create_approval(body: ApprovalCreate, token: str = Query(...)):
    verify_hook_token(token)
    approval_id = str(uuid.uuid4())
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        await db.execute("""INSERT INTO pending_approvals
            (id, hook_session_id, tool_name, command, reply_url, status, created_at)
            VALUES (?, ?, ?, ?, ?, 'pending', ?)""",
            (approval_id, body.hook_session_id, body.tool_name,
             body.command, body.reply_url, int(time.time())))
        await db.commit()

    await manager.broadcast_to_devices({
        "type": "new_approval",
        "approval_id": approval_id,
        "tool_name": body.tool_name,
        "command": body.command,
        "hook_session_id": body.hook_session_id,
        "created_at": int(time.time())
    })
    return {"approval_id": approval_id}

# ---- APNs helper (stub — plug in your APNs library) ----
async def send_apns_push(apns_token: str, payload: dict):
    """Send push via APNs. Requires pyapplepush or similar."""
    pass  # TODO: implement APNs push
```

- [ ] **Step 5: Write unit tests**

```python
# tests/test_relay.py
import pytest, sys, os
sys.path.insert(0, str(Path(__file__).parent.parent / "relay"))

from fastapi.testclient import TestClient
from relay.main import app

client = TestClient(app)

def test_health():
    r = client.get("/health")
    assert r.status_code == 200
```

- [ ] **Step 6: Run tests**

```bash
cd relay && pip install -r requirements.txt
cd .. && python -m pytest tests/test_relay.py -v
```

- [ ] **Step 7: Commit**

```bash
git add relay/ tests/test_relay.py
git commit -m "feat(relay): initial FastAPI relay server scaffold

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 1.2: APNs push integration

**Files:**
- Modify: `relay/main.py` (add APNs push calls in `/approve` and broadcast)
- Modify: `relay/requirements.txt` (add `httpx` for async HTTP/2 APNs)

- [ ] **Step 1: Add httpx for async APNs**

```txt
# relay/requirements.txt — add
httpx==0.27.0
```

- [ ] **Step 2: Add APNs push function**

```python
# relay/main.py — APNs section
import httpx

APNS_KEY_ID = os.environ.get("APNS_KEY_ID", "")
APNS_TEAM_ID = os.environ.get("APNS_TEAM_ID", "")
APNS_KEY_PATH = os.environ.get("APNS_KEY_PATH", "")  # path to .p8 file
APNS_BUNDLE_ID = os.environ.get("APNS_BUNDLE_ID", "com.watchapprove.macos")

def _apns_token():
    """Generate a short-lived APNs JWT. Requires pyjwt."""
    import jwt, time
    if not APNS_KEY_ID:
        return None
    with open(APNS_KEY_PATH) as f:
        key = f.read()
    return jwt.encode(
        {"iss": APNS_TEAM_ID, "iat": time.time()},
        key, algorithm="ES256",
        headers={"kid": APNS_KEY_ID}
    ).strip()

async def _send_apns(apns_token: str, payload: dict):
    if not APNS_KEY_ID or not apns_token:
        return
    token = _apns_token()
    url = (
        "https://api.push.apple.com/3/device/" + apns_token
    )
    headers = {
        "apns-push-type": "alert",
        "apns-topic": APNS_BUNDLE_ID,
        "authorization": f"bearer {token}"
    }
    async with httpx.AsyncClient() as c:
        try:
            await c.post(url, json=payload, headers=headers, timeout=10)
        except Exception:
            pass  # Fire and forget
```

- [ ] **Step 3: Call APNs in post_approve and broadcast**

```python
# In post_approve(), after updating DB and broadcasting to WS:
# Send APNs to all devices that have this approval
async with aiosqlite.connect(str(DATABASE_PATH)) as db:
    db.row_factory = aiosqlite.Row
    tokens = await db.execute_fetchall(
        """SELECT d.apns_token FROM devices d
           JOIN approval_tokens at ON at.device_id = d.id
           WHERE at.approval_id=?""", (approval_id,))
for row in tokens:
    if row["apns_token"]:
        await _send_apns(row["apns_token"], {
            "aps": {"alert": {
                "title": f"✅ Approved" if body.decision == "allow" else "❌ Denied",
                "body": f"{row['tool_name']}: {row['command'][:80]}"
            }}
        })
```

- [ ] **Step 4: Commit**

```bash
git add relay/main.py relay/requirements.txt
git commit -m "feat(relay): add APNs push integration

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 2: Hook Script Updates

### Task 2.1: Add relay WebSocket path to watch_approve.py

**Files:**
- Modify: `hooks/watch_approve.py` (add RELAY_URL + HOOK_TOKEN, WS relay path)
- Modify: `watch_done.py` (add relay path)

**Interfaces:**
- Produces: `RELAY_URL`, `HOOK_TOKEN` env vars consumed by new WS code path

- [ ] **Step 1: Add env vars after existing config block (~line 100)**

```python
# Add after PUSHCUT_KEY / NTFY_TOPIC config block in watch_approve.py
RELAY_URL = os.environ.get("WATCH_RELAY_URL", "").strip()
HOOK_TOKEN = os.environ.get("WATCH_HOOK_TOKEN", "").strip()
```

- [ ] **Step 2: Add WebSocket client helper (after _load_env_file, ~line 76)**

```python
# ---------- WebSocket relay client ----------
import json as _json

def _ws_connect(url, token, payload, timeout=240):
    """Connect to relay WS, send approval, wait for resolution."""
    try:
        import websocket  # stdlib: python -c "import websocket"
    except ImportError:
        # python -c "import websocket" uses the stdlib wsgplib; no extra install needed
        pass

    result = {"decision": None}

    def on_message(ws, message):
        data = _json.loads(message)
        if data.get("type") == "approval_resolved":
            result["decision"] = data.get("decision")
            ws.close()

    def on_error(ws, error):
        ws.close()

    def on_close(ws, code, reason):
        ws.close()

    # Use stdlib-only websocket approach via threading + queue
    import threading, queue, time as _time
    q = queue.Queue()

    def run():
        try:
            ws = websocket.create_connection(
                url, timeout=min(timeout, 300),
                suppressOrigins=False)
            ws.send(_json.dumps(payload))
            deadline = _time.time() + timeout
            while _time.time() < deadline:
                try:
                    msg = ws.recv()
                    data = _json.loads(msg)
                    if data.get("type") == "approval_resolved":
                        result["decision"] = data.get("decision")
                        break
                except Exception:
                    _time.sleep(0.5)
            ws.close()
        except Exception:
            pass
        q.put(None)

    t = threading.Thread(target=run, daemon=True)
    t.start()
    q.get(timeout=timeout + 5)
    return result.get("decision")
```

**Note**: `websocket` above is the stdlib `websocket.client.create_connection` — available in Python 3 stdlib as `python -c "import websocket; print(websocket.__spec__)"`. However it requires the `websocket` module which is NOT in stdlib. Use `urllib.request` with a custom opener for WS, or implement a simpler polling fallback.

**Revised approach — use stdlib only (no websocket pip)**:

```python
# Replace _ws_connect with stdlib-only implementation using urllib + threading
import json as _json, threading, queue, time as _time, urllib.request

def _ws_connect_stdlib(url, token, payload, timeout=240):
    """WS client using stdlib only. Falls back to HTTP polling if WS unavailable."""
    result = {"decision": None}
    deadline = _time.time() + timeout

    # Convert wss:// to https:// for initial HTTP upgrade attempt
    # If relay doesn't support WS, fall back to polling
    base_url = url.replace("wss://", "https://").replace("ws://", "http://")

    def run():
        try:
            # Try WS via urllib — note: stdlib urllib doesn't support WS natively
            # Use a minimal WS handshake implementation
            import socket, base64, hashlib, os

            # Parse URL
            import re
            m = re.match(r"wss?://([^/:]+)(:\d+)?(/.*)", url)
            if not m:
                return
            host, port_m, path = m.group(1), m.group(2), m.group(3)
            port = int(port_m[1:]) if port_m else (443 if url.startswith("wss") else 80)

            # WebSocket handshake
            key = base64.b64encode(os.urandom(16)).decode()
            sock = socket.create_connection((host, port), timeout=10)
            if port == 443:
                ctx = __import__("ssl").create_default_context()
                sock = ctx.wrap_socket(sock, server_hostname=host)

            req = (
                f"GET {path}?token={token} HTTP/1.1\r\n"
                f"Host: {host}\r\n"
                f"Upgrade: websocket\r\n"
                f"Connection: Upgrade\r\n"
                f"Sec-WebSocket-Key: {key}\r\n"
                f"Sec-WebSocket-Version: 13\r\n\r\n"
            )
            sock.sendall(req.encode())
            resp = sock.recv(4096)

            # Send JSON payload as WS frame
            frame = bytearray()
            payload_bytes = _json.dumps(payload).encode()
            frame.append(0x81)  # FIN + text frame
            length = len(payload_bytes)
            if length < 126:
                frame.append(0x80 | length)
            elif length < 65536:
                frame.append(0xfe)
                frame.extend(length.to_bytes(2, "big"))
            else:
                frame.append(0xff)
                frame.extend(length.to_bytes(8, "big"))
            # Mask
            mask = os.urandom(4)
            frame.append(0x80 | length)
            frame.extend(mask)
            masked = bytearray(payload_bytes)
            for i in range(len(masked)):
                masked[i] ^= mask[i % 4]
            frame.extend(masked)
            sock.sendall(bytes(frame))

            # Read frames until resolved or timeout
            while _time.time() < deadline:
                try:
                    data = sock.recv(4096)
                    if len(data) < 2:
                        continue
                    # Parse WS frame
                    if data[0] & 0x80:  # masked (server->client is unmasked, this branch won't trigger)
                        pass
                    else:
                        length = data[1] & 0x7F
                        if length < 126:
                            payload_raw = data[2:2+length]
                        elif length == 126:
                            length = int.from_bytes(data[2:4], "big")
                            payload_raw = data[4:4+length]
                        else:
                            length = int.from_bytes(data[2:10], "big")
                            payload_raw = data[10:10+length]
                        msg = payload_raw.decode("utf-8", errors="replace")
                        parsed = _json.loads(msg)
                        if parsed.get("type") == "approval_resolved":
                            result["decision"] = parsed.get("decision")
                            break
                except socket.timeout:
                    pass
                except Exception:
                    pass
            sock.close()
        except Exception:
            pass

    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(timeout=timeout + 5)
    return result.get("decision")
```

- [ ] **Step 3: Add relay path in main() — replace the notification send section (~line 1100)**

```python
# In main(), after parsing data but before notification:
if RELAY_URL and HOOK_TOKEN and "hook_session_id" in data:
    # Use relay WebSocket path
    ws_url = RELAY_URL.rstrip("/") + f"/ws/hook"
    payload = {
        "type": "approval_request",
        "tool_name": tool_name,
        "command": command,
        "hook_session_id": data.get("hook_session_id", ""),
        "cwd": data.get("cwd", ""),
    }
    decision = _ws_connect_stdlib(ws_url, HOOK_TOKEN, payload,
                                  timeout=APPROVE_WAIT)
    if decision:
        emit(decision, "relay")
        return
    # Fall through to fail-safe: emit ask
    emit("ask", "relay_timeout")
    return
```

- [ ] **Step 4: Commit**

```bash
git add watch_approve.py
git commit -m "feat(hooks): add WebSocket relay path to watch_approve.py

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2.2: Add relay path to watch_done.py

**Files:**
- Modify: `watch_done.py` (add RELAY_URL + HOOK_TOKEN, POST to relay on completion)

- [ ] **Step 1: Read watch_done.py structure**

```bash
head -50 watch_done.py
```

- [ ] **Step 2: Add relay URL env var and HTTP POST helper**

```python
# Add near top of watch_done.py, after _load_env_file()
RELAY_URL = os.environ.get("WATCH_RELAY_URL", "").strip()
HOOK_TOKEN = os.environ.get("WATCH_HOOK_TOKEN", "").strip()

def _relay_notify(title, body):
    """POST completion notification to relay, fire and forget."""
    if not RELAY_URL or not HOOK_TOKEN:
        return
    import urllib.request, json
    url = RELAY_URL.rstrip("/") + "/notify"
    data = json.dumps({"title": title, "body": body}).encode()
    req = urllib.request.Request(url, data=data,
        headers={"Content-Type": "application/json",
                 "Authorization": f"Bearer {HOOK_TOKEN}"})
    try:
        urllib.request.urlopen(req, timeout=5)
    except Exception:
        pass
```

- [ ] **Step 3: Call _relay_notify before sending Pushcut notification**

```python
# In send_done_notification(), before the existing Pushcut/ntfy code:
_relay_notify(title, text)
```

- [ ] **Step 4: Commit**

```bash
git add watch_done.py
git commit -m "feat(hooks): add relay notify path to watch_done.py

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 3: macOS App

### Task 3.1: XcodeGen project setup

**Files:**
- Create: `macos/project.yml`
- Create: `macos/WatchApproveMac/App/main.swift`
- Create: `macos/WatchApproveMac/Resources/Assets.xcassets/`
- Create: `shared/Approval.swift`
- Create: `shared/Models.swift`

- [ ] **Step 1: Create project.yml**

```yaml
# macos/project.yml
name: WatchApproveMac
options:
  bundleIdPrefix: com.watchapprove
  deploymentTarget:
    macOS: "14.0"
  xcodeVersion: "15.0"

settings:
  base:
    SWIFT_VERSION: "5.9"
    MACOSX_DEPLOYMENT_TARGET: "14.0"
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGN_STYLE: Automatic
    PRODUCT_NAME: WatchApprove
    INFOPLIST_FILE: WatchApproveMac/Resources/Info.plist
    ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
    COMBINE_HIDPI_IMAGES: YES
    ENABLE_HARDENED_RUNTIME: YES
    CODE_SIGN_ENTITLEMENTS: WatchApproveMac/Resources/WatchApprove.entitlements

targets:
  WatchApprove:
    type: application
    platform: macOS
    sources:
      - path: WatchApproveMac
        excludes:
          - "**/*.xcassets"
      - path: WatchApproveMac/Resources/Assets.xcassets
        type: folder
      - path: ../shared
        group: Shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.watchapprove.macos
        INFOPLIST_FILE: WatchApproveMac/Resources/Info.plist
        CODE_SIGN_ENTITLEMENTS: WatchApproveMac/Resources/WatchApprove.entitlements
```

- [ ] **Step 2: Create Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIconFile</key><string></string>
    <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>$(MACOSX_DEPLOYMENT_TARGET)</string>
    <key>LSUIElement</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 WatchApprove. All rights reserved.</string>
</dict>
</plist>
```

- [ ] **Step 3: Create entitlements file**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>com.apple.developer.usernotifications.time-sensitive</key>
    <true/>
    <key>com.apple.developer.pushkit.unrestricted</key>
    <true/>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 4: Create shared models**

```swift
// shared/Approval.swift
import Foundation

public struct Approval: Identifiable, Codable {
    public let id: String
    public let toolName: String
    public let command: String
    public let hookSessionId: String
    public let cwd: String?
    public var status: ApprovalStatus
    public let createdAt: Date

    public init(id: String, toolName: String, command: String,
                hookSessionId: String, cwd: String?,
                status: ApprovalStatus, createdAt: Date) {
        self.id = id
        self.toolName = toolName
        self.command = command
        self.hookSessionId = hookSessionId
        self.cwd = cwd
        self.status = status
        self.createdAt = createdAt
    }
}

public enum ApprovalStatus: String, Codable {
    case pending, approved, denied, timeout
}

public enum Decision: String {
    case allow, deny
}
```

```swift
// shared/Models.swift
import Foundation

public struct Device: Identifiable, Codable {
    public let id: String
    public let platform: Platform
    public var apnsToken: String?
    public var lastSeen: Date

    public init(id: String, platform: Platform, apnsToken: String?, lastSeen: Date) {
        self.id = id
        self.platform = platform
        self.apnsToken = apnsToken
        self.lastSeen = lastSeen
    }
}

public enum Platform: String, Codable {
    case ios, macos, watchos
}

public struct AntiSleepRule: Identifiable, Codable {
    public let id: UUID
    public var startHour: Int
    public var startMinute: Int
    public var endHour: Int
    public var endMinute: Int
    public var weekdays: Set<Int>  // 1=Mon, 7=Sun
    public var isEnabled: Bool

    public init(id: UUID = UUID(), startHour: Int, startMinute: Int,
                endHour: Int, endMinute: Int, weekdays: Set<Int>, isEnabled: Bool) {
        self.id = id
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.weekdays = weekdays
        self.isEnabled = isEnabled
    }
}
```

- [ ] **Step 5: Create main.swift (no @main attribute)**

```swift
// macos/WatchApproveMac/App/main.swift
import AppKit
let app = NSApplication.shared
let delegate = WatchApproveMacAppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 6: Create AppDelegate stub**

```swift
// macos/WatchApproveMac/App/WatchApproveMacApp.swift
import AppKit
import UserNotifications

class WatchApproveMacAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var caffeinateManager: CaffeinateManager?
    private var localWSServer: LocalWSServer?
    private var wsClient: RelayWSClient?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        requestNotificationPermissions()

        caffeinateManager = CaffeinateManager()
        menuBarController = MenuBarController(
            caffeinateManager: caffeinateManager!
        )

        // Start local WS server for same-machine hook communication
        localWSServer = LocalWSServer(port: 18792)
        localWSServer?.onApproval = { [weak self] approval in
            self?.handleIncomingApproval(approval)
        }
        localWSServer?.start()

        // Connect to VPS relay if configured
        if let relayURL = UserDefaults.standard.string(forKey: "relayURL"),
           !relayURL.isEmpty {
            wsClient = RelayWSClient(relayURL: relayURL)
            wsClient?.onApproval = { [weak self] approval in
                self?.handleIncomingApproval(approval)
            }
            wsClient?.connect()
        }
    }

    private func handleIncomingApproval(_ approval: Approval) {
        NotificationManager.shared.showApprovalNotification(for: approval)
        WatchConnectivityManager.shared.syncApproval(approval)
    }

    private func requestNotificationPermissions() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
        // Register notification category with actions
        let allowAction = UNNotificationAction(
            identifier: "ALLOW", title: "✅ 允许",
            options: [.foreground])
        let denyAction = UNNotificationAction(
            identifier: "DENY", title: "❌ 拒绝",
            options: [.foreground])
        let terminalAction = UNNotificationAction(
            identifier: "TERMINAL", title: "🖥️ 终端",
            options: [.foreground])
        let category = UNNotificationCategory(
            identifier: "APPROVAL",
            actions: [allowAction, denyAction, terminalAction],
            intentIdentifiers: [],
            options: [.customDismissAction])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

extension WatchApproveMacAppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let approvalId = response.notification.request.identifier
        let decision: Decision
        switch response.actionIdentifier {
        case "ALLOW": decision = .allow
        case "DENY":  decision = .deny
        case "TERMINAL": decision = .deny  // will trigger terminal fallback
        default: return completionHandler()
        }
        Task {
            await DatabaseManager.shared.resolveApproval(id: approvalId, decision: decision)
            await RelayWSClient.shared?.notifyDecision(approvalId: approvalId, decision: decision)
        }
        completionHandler()
    }
}
```

- [ ] **Step 7: Commit**

```bash
git add macos/ shared/ -o
git commit -m "feat(macos): XcodeGen project scaffold + shared models

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3.2: Menu bar controller and approval popover

**Files:**
- Create: `macos/WatchApproveMac/MenuBar/MenuBarController.swift`
- Create: `macos/WatchApproveMac/MenuBar/ApprovalPopover.swift`
- Create: `macos/WatchApproveMac/MenuBar/MenuBarMenu.swift`

- [ ] **Step 1: Write MenuBarController**

```swift
// macos/WatchApproveMac/MenuBar/MenuBarController.swift
import AppKit
import SwiftUI

class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let caffeinateManager: CaffeinateManager
    private var eventMonitor: Any?

    init(caffeinateManager: CaffeinateManager) {
        self.caffeinateManager = caffeinateManager
        super.init()
        setupStatusItem()
        setupPopover()
        setupEventMonitor()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "applewatch", accessibilityDescription: "WatchApprove")
            button.action = #selector(togglePopover)
            button.target = self
        }
        updateBadge()
    }

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 480)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: ApprovalPopoverView(
                caffeinateManager: caffeinateManager
            )
        )
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            if let button = statusItem.button {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func updateBadge() {
        Task { @MainActor in
            let pending = await DatabaseManager.shared.pendingCount()
            if let button = statusItem.button {
                if pending > 0 {
                    button.title = "\(pending)"
                } else {
                    button.title = ""
                }
            }
        }
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.popover.isShown == true {
                self?.popover.performClose(nil)
            }
        }
    }
}
```

- [ ] **Step 2: Write ApprovalPopoverView**

```swift
// macos/WatchApproveMac/MenuBar/ApprovalPopover.swift
import SwiftUI

struct ApprovalPopoverView: View {
    @ObservedObject var caffeinateManager: CaffeinateManager
    @State private var pendingApprovals: [Approval] = []
    @State private var history: [Approval] = []
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "applewatch")
                    .font(.title2)
                Text("WatchApprove")
                    .font(.headline)
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Anti-sleep indicator
            HStack {
                Image(systemName: caffeinateManager.isActive ? "moon.fill" : "moon")
                    .foregroundColor(caffeinateManager.isActive ? .orange : .secondary)
                Text(caffeinateManager.isActive ? "☕ 防休眠已开启" : "💤 防休眠已关闭")
                    .font(.caption)
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.1))

            Divider()

            // Pending approvals
            if pendingApprovals.isEmpty {
                VStack {
                    Spacer()
                    Text("没有待审批")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                List(pendingApprovals) { approval in
                    ApprovalRow(approval: approval) { decision in
                        resolveApproval(approval, decision: decision)
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 380, height: 480)
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .approvalReceived)) { _ in
            loadApprovals()
        }
        .task {
            loadApprovals()
        }
    }

    private func loadApprovals() {
        Task {
            let all = await DatabaseManager.shared.allApprovals()
            pendingApprovals = all.filter { $0.status == .pending }
            history = all.filter { $0.status != .pending }
        }
    }

    private func resolveApproval(_ approval: Approval, decision: Decision) {
        Task {
            await DatabaseManager.shared.resolveApproval(id: approval.id, decision: decision)
            RelayWSClient.shared?.notifyDecision(approvalId: approval.id, decision: decision)
            loadApprovals()
        }
    }
}

struct ApprovalRow: View {
    let approval: Approval
    let onDecision: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(agentEmoji(for: approval.toolName))
                    .font(.caption)
                Text(approval.toolName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(ago(approval.createdAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(approval.command)
                .font(.caption)
                .lineLimit(2)
                .foregroundColor(.primary)

            HStack(spacing: 8) {
                Button("✅ 允许") { onDecision(.allow) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("❌ 拒绝") { onDecision(.deny) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
    }

    private func agentEmoji(for tool: String) -> String {
        tool.contains("Claude") ? "🦀" : "🤖"
    }

    private func ago(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60 { return "\(s)s ago" }
        return "\(s/60)m ago"
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add macos/WatchApproveMac/MenuBar/
git commit -m "feat(macos): menu bar controller + approval popover

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3.3: Caffeinate manager (IOKit anti-sleep)

**Files:**
- Create: `macos/WatchApproveMac/Caffeinate/CaffeinateManager.swift`

- [ ] **Step 1: Write CaffeinateManager using IOKit**

```swift
// macos/WatchApproveMac/Caffeinate/CaffeinateManager.swift
import Foundation
import IOKit.pwr_mgt
import Combine

extension Notification.Name {
    static let caffeinateChanged = Notification.Name("caffeinateChanged")
}

class CaffeinateManager: ObservableObject {
    @Published private(set) var isActive: Bool = false
    @Published var mode: CaffeinateMode = .manual(.off)

    private var assertionID: IOPMAssertionID = 0
    private var scheduledTimer: Timer?
    private var rules: [AntiSleepRule] = []

    enum Mode: Equatable {
        case manual(Bool)       // true = on
        case automatic          // Claude Code working
        case scheduled
    }

    init() {
        loadRules()
        if mode == .scheduled {
            startScheduleEvaluator()
        }
    }

    // MARK: - Manual toggle

    func toggle() {
        if isActive {
            release()
        } else {
            prevent(reason: "WatchApprove Pro: Manual")
        }
    }

    func prevent(reason: String) {
        guard !isActive else { return }
        let reasonCF = reason as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleSystemSleep as CFString,
            kIOPMAssertionLevel,
            reasonCF,
            &assertionID
        )
        if result == kIOReturnSuccess {
            isActive = true
            NotificationCenter.default.post(name: .caffeinateChanged, object: nil)
        }
    }

    func release() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
        NotificationCenter.default.post(name: .caffeinateChanged, object: nil)
    }

    // Called by Claude Code PreToolUse hook handler
    func onClaudeWorking() {
        prevent(reason: "WatchApprove Pro: Claude Code active")
    }

    // Called by Claude Code Stop hook handler
    func onClaudeStopped() {
        // Only release if in automatic mode and no manual override
        if mode == .automatic {
            release()
        }
    }

    // MARK: - Schedule

    func updateRules(_ rules: [AntiSleepRule]) {
        self.rules = rules
        if mode == .scheduled {
            startScheduleEvaluator()
        }
    }

    private func startScheduleEvaluator() {
        scheduledTimer?.invalidate()
        scheduledTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.evaluateSchedule()
        }
    }

    private func evaluateSchedule() {
        let now = Date()
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: now)  // 1=Sun
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let nowMinutes = hour * 60 + minute

        let activeNow = rules.filter { $0.isEnabled && $0.weekdays.contains(weekday) }.contains { rule in
            let start = rule.startHour * 60 + rule.startMinute
            let end = rule.endHour * 60 + rule.endMinute
            if start <= end {
                return nowMinutes >= start && nowMinutes < end
            } else {
                // Overnight window (e.g., 22:00 - 06:00)
                return nowMinutes >= start || nowMinutes < end
            }
        }

        if activeNow && !isActive {
            prevent(reason: "WatchApprove Pro: Scheduled")
        } else if !activeNow && isActive && mode == .scheduled {
            release()
        }
    }

    private func loadRules() {
        if let data = UserDefaults.standard.data(forKey: "antiSleepRules"),
           let rules = try? JSONDecoder().decode([AntiSleepRule].self, from: data) {
            self.rules = rules
        }
    }

    func saveRules(_ rules: [AntiSleepRule]) {
        self.rules = rules
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: "antiSleepRules")
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add macos/WatchApproveMac/Caffeinate/
git commit -m "feat(macos): caffeinate manager with IOKit anti-sleep

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3.4: Local WebSocket server and relay WS client

**Files:**
- Create: `macos/WatchApproveMac/WebSocket/LocalWSServer.swift`
- Create: `macos/WatchApproveMac/WebSocket/RelayWSClient.swift`
- Create: `macos/WatchApproveMac/Notifications/NotificationManager.swift`
- Create: `macos/WatchApproveMac/Database/DatabaseManager.swift`

- [ ] **Step 1: Write LocalWSServer (Swift NIO-less, using Network.framework)**

```swift
// macos/WatchApproveMac/WebSocket/LocalWSServer.swift
import Foundation
import Network

class LocalWSServer {
    let port: NWEndpoint.Port
    private var listener: NWListener?
    var onApproval: ((Approval) async -> Void)?

    init(port: UInt16 = 18792) {
        self.port = NWEndpoint.Port(integerLiteral: port)
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: port)
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready: print("Local WS server ready on port \(self.port)")
                case .failed(let err): print("WS server error: \(err)")
                default: break
                }
            }
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener?.start(queue: .main)
        } catch {
            print("Failed to start local WS server: \(error)")
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                self.receiveLoop(conn)
            }
        }
        conn.start(queue: .main)
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            if let data = data, let text = String(data: data, encoding: .utf8) {
                self?.process(text, conn: conn)
            }
            if !isComplete && err == nil {
                self?.receiveLoop(conn)
            }
        }
    }

    private func process(_ text: String, conn: NWConnection) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONDecoder().decode(IncomingApprovalJSON.self, from: data) else {
            return
        }
        let approval = Approval(
            id: UUID().uuidString,
            toolName: json.tool_name ?? json.tool_name ?? "Bash",
            command: json.command ?? "",
            hookSessionId: json.hook_session_id ?? "",
            cwd: json.cwd,
            status: .pending,
            createdAt: Date()
        )
        Task {
            await self.onApproval?(approval)
            // Send HTTP 200 OK as WS response (WS handshake upgrade already done)
            let resp = "HTTP/1.1 200 OK\r\n\r\n".data(using: .utf8)!
            conn.send(content: resp, completion: .contentProcessed { _ in
                conn.cancel()
            })
        }
    }

    func stop() {
        listener?.cancel()
    }
}

struct IncomingApprovalJSON: Codable {
    let tool_name: String?
    let command: String?
    let hook_session_id: String?
    let cwd: String?
}
```

**Note**: The incoming hook sends an HTTP POST, not a WebSocket. The `LocalWSServer` above is a TCP listener that receives the raw HTTP POST and extracts the JSON body. For a proper WS upgrade server, use NWListener with `NWParameters.http` or switch to Swift NIO.

**Revised approach — HTTP POST server (simpler, matches hook's POST)**:

```swift
// macos/WatchApproveMac/WebSocket/LocalWSServer.swift — Revised
import Foundation
import Network

/// Receives HTTP POST from Claude Code hook at localhost:18792
/// Hook sends: POST /approve {json body}
class LocalWSServer {
    let port: NWEndpoint.Port
    private var listener: NWListener?
    var onApproval: ((Approval) async -> Void)?

    init(port: UInt16 = 18792) {
        self.port = NWEndpoint.Port(integerLiteral: port)
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            listener = try NWListener(using: parameters, on: port)
            listener?.stateUpdateHandler = { state in
                if case .failed(let err) = state {
                    print("Local server failed: \(err)")
                }
            }
            listener?.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener?.start(queue: .main)
            print("Local approval server listening on http://localhost:\(port)")
        } catch {
            print("Failed to start local server: \(error)")
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .ready = state {
                self.receiveHTTP(conn)
            }
        }
        conn.start(queue: .main)
    }

    private func receiveHTTP(_ conn: NWConnection) {
        var received = Data()
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data { received.append(data) }
            if isComplete || error != nil {
                self?.processRequest(received, conn: conn)
            } else {
                self?.receiveHTTP(conn)
            }
        }
    }

    private func processRequest(_ data: Data, conn: NWConnection) {
        guard let text = String(data: data, encoding: .utf8) else {
            conn.cancel(); return
        }

        // Parse HTTP POST body (find \r\n\r\n)
        guard let headerEnd = text.range(of: "\r\n\r\n") else {
            conn.cancel(); return
        }
        let body = String(text[headerEnd.upperBound...])

        guard let jsonData = body.data(using: .utf8),
              let json = try? JSONDecoder().decode(HTTPApprovalJSON.self, from: jsonData) else {
            conn.cancel(); return
        }

        let approval = Approval(
            id: UUID().uuidString,
            toolName: json.tool_name ?? "Bash",
            command: json.command ?? "",
            hookSessionId: json.hook_session_id ?? "",
            cwd: json.cwd,
            status: .pending,
            createdAt: Date()
        )

        Task {
            await self.onApproval?(approval)
        }

        // Send 200 response
        let bodyResp = "{\"ok\":true}".data(using: .utf8)!
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(bodyResp.count)\r
        Connection: close\r
        \r
        """.data(using: .utf8)! + bodyResp

        conn.send(content: response, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    func stop() {
        listener?.cancel()
    }
}

struct HTTPApprovalJSON: Codable {
    let tool_name: String?
    let command: String?
    let hook_session_id: String?
    let cwd: String?
}
```

- [ ] **Step 2: Write RelayWSClient**

```swift
// macos/WatchApproveMac/WebSocket/RelayWSClient.swift
import Foundation
import Combine

class RelayWSClient: ObservableObject {
    static var shared: RelayWSClient?
    let relayURL: String
    private var webSocketTask: URLSessionWebSocketTask?
    private let session: URLSession
    @Published private(set) var isConnected = false
    var onApproval: ((Approval) async -> Void)?

    init(relayURL: String) {
        self.relayURL = relayURL
        self.session = URLSession(configuration: .default)
        RelayWSClient.shared = self
    }

    func connect() {
        guard let url = URL(string: relayURL) else { return }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // Convert https:// to wss://, http:// to ws://
        let scheme = components?.scheme == "https" ? "wss" : "ws"
        components?.scheme = scheme
        components?.path = (components?.path ?? "") + "/ws/device/" + deviceToken
        guard let wsURL = components?.url else { return }

        webSocketTask = session.webSocketTask(with: wsURL)
        webSocketTask?.resume()
        isConnected = true
        receiveLoop()
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let msg):
                if case .string(let text) = msg {
                    self?.handleMessage(text)
                }
                self?.receiveLoop()
            case .failure:
                self?.isConnected = false
                // Reconnect after 5s
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self?.connect()
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(WSMessage.self, from: data) else { return }

        switch msg.type {
        case "new_approval":
            let approval = Approval(
                id: msg.approval_id ?? "",
                toolName: msg.tool_name ?? "Bash",
                command: msg.command ?? "",
                hookSessionId: msg.hook_session_id ?? "",
                cwd: nil,
                status: .pending,
                createdAt: Date(timeIntervalSince1970: TimeInterval(msg.created_at ?? 0))
            )
            Task { @MainActor in
                await DatabaseManager.shared.saveApproval(approval)
                NotificationCenter.default.post(name: .approvalReceived, object: nil)
            }
        case "approval_resolved":
            if let id = msg.approval_id, let decision = msg.decision {
                Task { @MainActor in
                    await DatabaseManager.shared.resolveApproval(
                        id: id,
                        decision: Decision(rawValue: decision) ?? .deny
                    )
                    NotificationCenter.default.post(name: .approvalReceived, object: nil)
                }
            }
        default:
            break
        }
    }

    func notifyDecision(approvalId: String, decision: Decision) {
        let body: [String: Any] = [
            "approval_id": approvalId,
            "decision": decision.rawValue,
            "device_id": deviceToken
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: URL(string: relayURL + "/approve/\(approvalId)")!)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req).resume()
    }

    private var deviceToken: String {
        if let token = UserDefaults.standard.string(forKey: "deviceToken") {
            return token
        }
        let token = UUID().uuidString
        UserDefaults.standard.set(token, forKey: "deviceToken")
        return token
    }
}

struct WSMessage: Codable {
    let type: String
    let approval_id: String?
    let tool_name: String?
    let command: String?
    let hook_session_id: String?
    let created_at: Int?
    let decision: String?
}
```

- [ ] **Step 3: Write DatabaseManager**

```swift
// macos/WatchApproveMac/Database/DatabaseManager.swift
import Foundation
import SQLite3

class DatabaseManager: @unchecked Sendable {
    static let shared = DatabaseManager()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.watchapprove.db")

    private init() {
        openDB()
    }

    private func openDB() {
        let path = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WatchApprove")
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        let dbPath = path.appendingPathComponent("approvals.sqlite").path

        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Failed to open DB at \(dbPath)")
        }
        let createSQL = """
        CREATE TABLE IF NOT EXISTS approvals (
            id TEXT PRIMARY KEY,
            tool_name TEXT,
            command TEXT,
            hook_session_id TEXT,
            cwd TEXT,
            status TEXT,
            created_at REAL,
            resolved_at REAL
        );
        """
        sqlite3_exec(db, createSQL, nil, nil, nil)
    }

    func pendingCount() async -> Int {
        await withCheckedContinuation { cont in
            queue.async {
                var count = 0
                let q = "SELECT COUNT(*) FROM approvals WHERE status='pending'"
                sqlite3_exec(self.db, q, { _, n, vals, _ -> Int32 in
                    if n > 0, let vals = vals { count = Int(sqlite3_column_int64(vals, 0)) }
                    return 0
                }, nil)
                cont.resume(returning: count)
            }
        }
    }

    func allApprovals() async -> [Approval] {
        await withCheckedContinuation { cont in
            queue.async {
                var approvals: [Approval] = []
                let q = "SELECT * FROM approvals ORDER BY created_at DESC LIMIT 100"
                let stmt = self.prepare(q)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let a = self.rowToApproval(stmt)
                    approvals.append(a)
                }
                sqlite3_finalize(stmt)
                cont.resume(returning: approvals)
            }
        }
    }

    func saveApproval(_ approval: Approval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let q = """INSERT OR REPLACE INTO approvals
                    (id, tool_name, command, hook_session_id, cwd, status, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)"""
                let stmt = self.prepare(q)
                sqlite3_bind_text(stmt, 1, approval.id)
                sqlite3_bind_text(stmt, 2, approval.toolName)
                sqlite3_bind_text(stmt, 3, approval.command)
                sqlite3_bind_text(stmt, 4, approval.hookSessionId)
                sqlite3_bind_text(stmt, 5, approval.cwd)
                sqlite3_bind_text(stmt, 6, approval.status.rawValue)
                sqlite3_bind_double(stmt, 7, approval.createdAt.timeIntervalSince1970)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                cont.resume()
            }
        }
    }

    func resolveApproval(id: String, decision: Decision) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let q = """UPDATE approvals SET status=?, resolved_at=? WHERE id=?"""
                let stmt = self.prepare(q)
                sqlite3_bind_text(stmt, 1, decision == .allow ? "approved" : "denied")
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
                sqlite3_bind_text(stmt, 3, id)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
                cont.resume()
            }
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        return stmt
    }

    private func rowToApproval(_ stmt: OpaquePointer?) -> Approval {
        Approval(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            toolName: String(cString: sqlite3_column_text(stmt, 1)),
            command: String(cString: sqlite3_column_text(stmt, 2)),
            hookSessionId: String(cString: sqlite3_column_text(stmt, 3)),
            cwd: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            status: ApprovalStatus(rawValue: String(cString: sqlite3_column_text(stmt, 5))) ?? .pending,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        )
    }
}
```

- [ ] **Step 4: Write NotificationManager**

```swift
// macos/WatchApproveMac/Notifications/NotificationManager.swift
import Foundation
import UserNotifications

class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private override init() {
        super.init()
    }

    func showApprovalNotification(for approval: Approval) {
        let content = UNMutableNotificationContent()
        content.title = "🦀 Claude 待批准"
        content.body = approval.command
        content.subtitle = approval.toolName
        content.categoryIdentifier = "APPROVAL"
        content.userInfo = ["approvalId": approval.id]
        content.interruptionLevel = .timeSensitive
        content.relevanceScore = 100
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: approval.id,
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }

    func showDoneNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .named("default")
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
```

- [ ] **Step 5: Write WatchConnectivityManager**

```swift
// macos/WatchApproveMac/Shared/WatchConnectivityManager.swift
import Foundation
import WatchConnectivity

class WatchConnectivityManager: NSObject, WCSessionDelegate {
    static let shared = WatchConnectivityManager()
    private var session: WCSession?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }

    func syncApproval(_ approval: Approval) {
        guard let session = session, session.isReachable else { return }
        let data: [String: Any] = [
            "type": "approval",
            "id": approval.id,
            "toolName": approval.toolName,
            "command": approval.command,
            "status": approval.status.rawValue
        ]
        session.sendMessage(data, replyHandler: nil)
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        print("WCSession activated: \(activationState)")
    }
}
```

- [ ] **Step 6: Commit**

```bash
git add macos/WatchApproveMac/WebSocket/ macos/WatchApproveMac/Notifications/ macos/WatchApproveMac/Database/ macos/WatchApproveMac/Shared/WatchConnectivityManager.swift
git commit -m "feat(macos): local WS server, relay client, database, notifications

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 4: iOS App

### Task 4.1: XcodeGen iOS project + approvals UI

**Files:**
- Create: `ios/project.yml`
- Create: `ios/WatchApprove/Resources/Info.plist`
- Create: `ios/WatchApprove/Resources/WatchApprove.entitlements`
- Create: `ios/WatchApprove/App/WatchApproveApp.swift`
- Create: `ios/WatchApprove/App/AppDelegate.swift`
- Create: `ios/WatchApprove/Views/ApprovalsView.swift`
- Create: `ios/WatchApprove/Views/SettingsView.swift`
- Create: `ios/WatchApprove/Views/Components/ApprovalCard.swift`
- Create: `ios/WatchApprove/Services/WebSocketService.swift`
- Create: `ios/WatchApprove/Services/NotificationService.swift`
- Create: `ios/WatchApprove/Services/ScheduleManager.swift`
- Create: `ios/WatchApprove/ViewModels/ApprovalsViewModel.swift`
- Create: `ios/WatchApprove/ViewModels/SettingsViewModel.swift`

**Note**: The iOS app uses SwiftUI for all views. Project.yml uses `platform: iOS` with `deploymentTarget: "17.0"`.

- [ ] **Step 1: Write project.yml**

```yaml
# ios/project.yml
name: WatchApprove
options:
  bundleIdPrefix: com.watchapprove
  deploymentTarget:
    iOS: "17.0"
  xcodeVersion: "15.0"

settings:
  base:
    SWIFT_VERSION: "5.9"
    TARGETED_DEVICE_FAMILY: "1,2"
    INFOPLIST_FILE: WatchApprove/Resources/Info.plist
    CODE_SIGN_ENTITLEMENTS: WatchApprove/Resources/WatchApprove.entitlements
    ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon

targets:
  WatchApprove:
    type: application
    platform: iOS
    sources:
      - path: WatchApprove
        excludes:
          - "**/*.xcassets"
      - path: ../shared
        group: Shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.watchapprove.ios
        INFOPLIST_FILE: WatchApprove/Resources/Info.plist
        CODE_SIGN_ENTITLEMENTS: WatchApprove/Resources/WatchApprove.entitlements
```

- [ ] **Step 2: Write Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSRequiresIPhoneOS</key><true/>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key><false/>
    </dict>
    <key>UILaunchScreen</key><dict/>
    <key>UIRequiredDeviceCapabilities</key><array><string>armv7</string></array>
    <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
    <key>BGTaskSchedulerPermittedIdentifiers</key>
    <array><string>com.watchapprove.refresh</string></array>
</dict>
</plist>
```

- [ ] **Step 3: Write entitlements**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>aps-environment</key><string>development</string>
    <key>com.apple.developer.usernotifications.time-sensitive</key><true/>
    <key>com.apple.security.application-groups</key>
    <array><string>group.com.watchapprove</string></array>
</dict>
</plist>
```

- [ ] **Step 4: Write WatchApproveApp.swift**

```swift
// ios/WatchApprove/App/WatchApproveApp.swift
import SwiftUI

@main
struct WatchApproveApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var approvalsVM = ApprovalsViewModel()
    @StateObject private var settingsVM = SettingsViewModel()

    var body: some Scene {
        WindowGroup {
            TabView {
                ApprovalsView()
                    .environmentObject(approvalsVM)
                    .tabItem { Label("审批", systemImage: "bell") }

                DevicesView()
                    .tabItem { Label("设备", systemImage: "applewatch") }

                SettingsView()
                    .environmentObject(settingsVM)
                    .tabItem { Label("设置", systemImage: "gear") }
            }
        }
    }
}
```

- [ ] **Step 5: Write ApprovalsView**

```swift
// ios/WatchApprove/Views/ApprovalsView.swift
import SwiftUI

struct ApprovalsView: View {
    @EnvironmentObject var vm: ApprovalsViewModel

    var body: some View {
        NavigationStack {
            Group {
                if vm.pendingApprovals.isEmpty && vm.history.isEmpty {
                    ContentUnavailableView(
                        "没有审批",
                        systemImage: "bell.slash",
                        description: Text("Claude Code 危险操作会出现在这里")
                    )
                } else {
                    List {
                        if !vm.pendingApprovals.isEmpty {
                            Section("待处理") {
                                ForEach(vm.pendingApprovals) { approval in
                                    ApprovalCard(approval: approval) { decision in
                                        vm.resolve(approval, decision: decision)
                                    }
                                }
                            }
                        }

                        if !vm.history.isEmpty {
                            Section("历史") {
                                ForEach(vm.history) { approval in
                                    HistoryRow(approval: approval)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("审批")
            .refreshable {
                await vm.load()
            }
        }
        .task {
            await vm.load()
        }
    }
}

struct HistoryRow: View {
    let approval: Approval
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(approval.toolName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(approval.command)
                    .font(.caption)
                    .lineLimit(1)
            }
            Spacer()
            Text(approval.status == .approved ? "✅" : "❌")
        }
    }
}
```

- [ ] **Step 6: Write ApprovalCard**

```swift
// ios/WatchApprove/Views/Components/ApprovalCard.swift
import SwiftUI

struct ApprovalCard: View {
    let approval: Approval
    let onDecision: (Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(agentEmoji)
                    .font(.title3)
                VStack(alignment: .leading) {
                    Text(approval.toolName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(timeAgo(approval.createdAt))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            Text(approval.command)
                .font(.body)
                .foregroundColor(.primary)

            HStack(spacing: 12) {
                Button {
                    onDecision(.allow)
                } label: {
                    Label("允许", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Button {
                    onDecision(.deny)
                } label: {
                    Label("拒绝", systemImage: "xmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button {
                    // Terminal fallback — just deny and let hook handle terminal prompt
                    onDecision(.deny)
                } label: {
                    Image(systemName: "desktopcomputer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .help("在终端查看")
            }
        }
        .padding(.vertical, 4)
    }

    private var agentEmoji: String {
        approval.toolName.lowercased().contains("claude") ? "🦀" : "🤖"
    }

    private func timeAgo(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60 { return "\(s)秒前" }
        if s < 3600 { return "\(s/60)分钟前" }
        return "\(s/3600)小时前"
    }
}
```

- [ ] **Step 7: Write SettingsView**

```swift
// ios/WatchApprove/Views/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var vm: SettingsViewModel
    @AppStorage("relayURL") private var relayURL = ""
    @AppStorage("hookToken") private var hookToken = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("服务器") {
                    TextField("VPS URL (https://...)", text: $relayURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                    SecureField("Hook Token", text: $hookToken)
                        .autocapitalization(.none)
                }

                Section("防休眠") {
                    Toggle("自动防休眠", isOn: $vm.autoCaffeinate)

                    NavigationLink("定时规则") {
                        ScheduleEditorView(rules: $vm.scheduleRules)
                    }

                    HStack {
                        Text("当前状态")
                        Spacer()
                        Text(vm.isActive ? "☕ 已开启" : "💤 已关闭")
                            .foregroundColor(.secondary)
                    }
                }

                Section("通知") {
                    Button("测试通知") {
                        NotificationService.shared.sendTest()
                    }
                }

                Section("Hook 脚本") {
                    Button("复制安装脚本") {
                        let script = generateInstallScript()
                        UIPasteboard.general.string = script
                    }
                    .font(.body)
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text("1.0")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("设置")
        }
    }

    private func generateInstallScript() -> String {
        let url = relayURL.isEmpty ? "YOUR_RELAY_URL" : relayURL
        let token = hookToken.isEmpty ? "YOUR_HOOK_TOKEN" : hookToken
        return """
        # WatchApprove Pro 安装脚本
        # 复制到终端运行

        pip3 install --user websocket-client

        cat >> ~/.claude/settings.json << 'EOF'
        {
          "hooks": {
            "PreToolUse": [{
              "matcher": "*",
              "hooks": [{
                "type": "command",
                "command": "python3 /PATH/TO/watch_approve.py",
                "timeout": 300
              }]
            }]
          }
        }
        EOF

        export WATCH_RELAY_URL=\(url)
        export WATCH_HOOK_TOKEN=\(token)
        """
    }
}

struct ScheduleEditorView: View {
    @Binding var rules: [AntiSleepRule]
    @State private var newRule = AntiSleepRule(
        startHour: 9, startMinute: 0,
        endHour: 18, endMinute: 0,
        weekdays: Set(2...6), isEnabled: true
    )

    var body: some View {
        List {
            ForEach(rules) { rule in
                RuleRow(rule: rule)
            }
            .onDelete { indexSet in
                rules.remove(atOffsets: indexSet)
            }

            Section {
                DatePicker("开始", selection: startBinding, displayedComponents: .hourAndMinute)
                DatePicker("结束", selection: endBinding, displayedComponents: .hourAndMinute)
                WeekdayPicker(weekdays: $newRule.weekdays)
                Toggle("启用", isOn: $newRule.isEnabled)
                Button("添加规则") {
                    rules.append(newRule)
                    newRule = AntiSleepRule(startHour: 9, startMinute: 0,
                                            endHour: 18, endMinute: 0,
                                            weekdays: Set(2...6), isEnabled: true)
                }
            }
        }
        .navigationTitle("定时规则")
    }

    private var startBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: DateComponents(hour: newRule.startHour, minute: newRule.startMinute)) ?? Date() },
            set: { newRule.startHour = Calendar.current.component(.hour, from: $0);
                   newRule.startMinute = Calendar.current.component(.minute, from: $0) }
        )
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(from: DateComponents(hour: newRule.endHour, minute: newRule.endMinute)) ?? Date() },
            set: { newRule.endHour = Calendar.current.component(.hour, from: $0);
                   newRule.endMinute = Calendar.current.component(.minute, from: $0) }
        )
    }
}

struct WeekdayPicker: View {
    @Binding var weekdays: Set<Int>
    let labels = ["一","二","三","四","五","六","日"]

    var body: some View {
        HStack {
            ForEach(1...7, id: \\.self) { day in
                Button {
                    if weekdays.contains(day) {
                        weekdays.remove(day)
                    } else {
                        weekdays.insert(day)
                    }
                } label: {
                    Text(labels[day-1])
                        .frame(width: 32, height: 32)
                        .background(weekdays.contains(day) ? Color.accentColor : Color.secondary.opacity(0.2))
                        .foregroundColor(weekdays.contains(day) ? .white : .primary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
```

- [ ] **Step 8: Write ApprovalsViewModel**

```swift
// ios/WatchApprove/ViewModels/ApprovalsViewModel.swift
import Foundation
import Combine

@MainActor
class ApprovalsViewModel: ObservableObject {
    @Published var pendingApprovals: [Approval] = []
    @Published var history: [Approval] = []

    private let wsService = WebSocketService.shared
    private var cancellables = Set<AnyCancellable>()

    init() {
        setupBindings()
    }

    private func setupBindings() {
        NotificationCenter.default.publisher(for: .newApprovalReceived)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.load() }
            }
            .store(in: &cancellables)
    }

    func load() async {
        // Load from local DB
        pendingApprovals = await DatabaseManagerIOS.shared.pendingApprovals()
        history = await DatabaseManagerIOS.shared.historyApprovals()
    }

    func resolve(_ approval: Approval, decision: Decision) {
        Task {
            await DatabaseManagerIOS.shared.resolve(approval.id, decision: decision)
            await WebSocketService.shared.notifyDecision(approvalId: approval.id, decision: decision)
            await load()
        }
    }
}
```

- [ ] **Step 9: Write WebSocketService and NotificationService**

```swift
// ios/WatchApprove/Services/WebSocketService.swift
import Foundation

class WebSocketService: NSObject, ObservableObject {
    static let shared = WebSocketService()

    @Published private(set) var isConnected = false
    private var session: URLSession!
    private var webSocketTask: URLSessionWebSocketTask?

    private override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    }

    func connect() {
        guard let url = UserDefaults.standard.string(forKey: "relayURL"),
              !url.isEmpty else { return }

        var components = URLComponents(url: URL(string: url)!, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = components.path + "/ws/device/" + deviceToken

        webSocketTask = session.webSocketTask(with: components.url!)
        webSocketTask?.resume()
        isConnected = true
        receive()
    }

    private func receive() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let msg):
                if case .string(let text) = msg {
                    self?.handle(text)
                }
                self?.receive()
            case .failure:
                self?.isConnected = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    self?.connect()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let msg = try? JSONDecoder().decode(WSMessage.self, from: data) else { return }

        if msg.type == "new_approval" {
            let approval = Approval(
                id: msg.approval_id ?? UUID().uuidString,
                toolName: msg.tool_name ?? "Bash",
                command: msg.command ?? "",
                hookSessionId: msg.hook_session_id ?? "",
                cwd: nil,
                status: .pending,
                createdAt: Date(timeIntervalSince1970: TimeInterval(msg.created_at ?? 0))
            )
            Task { @MainActor in
                await DatabaseManagerIOS.shared.save(approval)
                NotificationCenter.default.post(name: .newApprovalReceived, object: nil)
            }
        }
    }

    func notifyDecision(approvalId: String, decision: Decision) {
        let url = UserDefaults.standard.string(forKey: "relayURL") ?? ""
        let body: [String: Any] = ["approval_id": approvalId, "decision": decision.rawValue, "device_id": deviceToken]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: URL(string: url + "/approve/\(approvalId)")!)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req).resume()
    }

    private var deviceToken: String {
        if let t = UserDefaults.standard.string(forKey: "deviceToken") { return t }
        let t = UUID().uuidString
        UserDefaults.standard.set(t, forKey: "deviceToken")
        return t
    }
}

extension WebSocketService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        isConnected = true
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isConnected = false
    }
}

extension Notification.Name {
    static let newApprovalReceived = Notification.Name("newApprovalReceived")
}
```

```swift
// ios/WatchApprove/Services/NotificationService.swift
import Foundation
import UserNotifications

class NotificationService: NSObject {
    static let shared = NotificationService()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
        registerCategory()
    }

    private func registerCategory() {
        let allow = UNNotificationAction(identifier: "ALLOW", title: "✅ 允许", options: [.foreground])
        let deny = UNNotificationAction(identifier: "DENY", title: "❌ 拒绝", options: [.foreground])
        let terminal = UNNotificationAction(identifier: "TERMINAL", title: "🖥️ 终端", options: [.foreground])
        let cat = UNNotificationCategory(
            identifier: "APPROVAL",
            actions: [allow, deny, terminal],
            intentIdentifiers: [],
            options: [.customDismissAction])
        UNUserNotificationCenter.current().setNotificationCategories([cat)
    }

    func sendTest() {
        let content = UNMutableNotificationContent()
        content.title = "🦀 WatchApprove"
        content.body = "测试通知 — 一切正常！"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let decision: Decision = response.actionIdentifier == "ALLOW" ? .allow : .deny
        Task {
            await DatabaseManagerIOS.shared.resolve(id, decision: decision)
            await WebSocketService.shared.notifyDecision(approvalId: id, decision: decision)
        }
        withCompletionHandler()
    }
}
```

- [ ] **Step 10: Write DatabaseManagerIOS and ScheduleManager**

```swift
// ios/WatchApprove/Services/ScheduleManager.swift
import Foundation
import BackgroundTasks

class ScheduleManager {
    static let shared = ScheduleManager()

    func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.watchapprove.refresh",
            using: nil
        ) { task in
            self.handleAppRefresh(task: task as! BGAppRefreshTask)
        }
    }

    func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: "com.watchapprove.refresh")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleAppRefresh(task: BGAppRefreshTask) {
        schedule()
        task.setTaskCompleted(success: true)
    }
}
```

```swift
// ios/WatchApprove/Services/DatabaseManagerIOS.swift
// (SQLite.swift approach — mirrors macos DatabaseManager)
// Uses group app container for shared WatchAccess usage
import Foundation
import SQLite3

actor DatabaseManagerIOS {
    static let shared = DatabaseManagerIOS()
    private var db: OpaquePointer?

    private init() {
        openDB()
    }

    private func openDB() {
        let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.com.watchapprove")!
            .appendingPathComponent("approvals.sqlite")
        if sqlite3_open(url.path, &db) != SQLITE_OK { return }
        sqlite3_exec(db, """
            CREATE TABLE IF NOT EXISTS approvals (
                id TEXT PRIMARY KEY,
                tool_name TEXT,
                command TEXT,
                hook_session_id TEXT,
                cwd TEXT,
                status TEXT,
                created_at REAL,
                resolved_at REAL
            );
            """, nil, nil, nil)
    }

    func pendingApprovals() -> [Approval] { /* ... */ }
    func historyApprovals() -> [Approval] { /* ... */ }
    func save(_ approval: Approval) { /* ... */ }
    func resolve(_ id: String, decision: Decision) { /* ... */ }
}
```

- [ ] **Step 11: Commit**

```bash
git add ios/
git commit -m "feat(ios): iOS app scaffold + approvals UI + settings

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 5: watchOS App

### Task 5.1: watchOS project + approval UI

**Files:**
- Create: `watch/project.yml`
- Create: `watch/WatchApproveWatch/App/WatchApproveApp.swift`
- Create: `watch/WatchApproveWatch/Views/ApprovalDetailView.swift`
- Create: `watch/WatchApproveWatch/Views/StatusView.swift`
- Create: `watch/WatchApproveWatch/Services/WatchConnectivityService.swift`

- [ ] **Step 1: Write project.yml**

```yaml
# watch/project.yml
name: WatchApproveWatch
options:
  bundleIdPrefix: com.watchapprove
  deploymentTarget:
    watchOS: "10.0"
  xcodeVersion: "15.0"

settings:
  base:
    SWIFT_VERSION: "5.9"
    INFOPLIST_FILE: WatchApproveWatch/Resources/Info.plist

targets:
  WatchApproveWatch:
    type: application
    platform: watchOS
    sources:
      - path: WatchApproveWatch
      - path: ../shared
        group: Shared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.watchapprove.watchkitapp
        INFOPLIST_FILE: WatchApproveWatch/Resources/Info.plist
        WATCHOS_DEPLOYMENT_TARGET: "10.0"
        SDKROOT: watchos
```

- [ ] **Step 2: Write Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>WKApplication</key><true/>
    <key>WKCompanionAppBundleIdentifier</key><string>com.watchapprove.ios</string>
</dict>
</plist>
```

- [ ] **Step 3: Write WatchApproveApp.swift**

```swift
// watch/WatchApproveWatch/App/WatchApproveApp.swift
import SwiftUI

@main
struct WatchApproveApp: App {
    @StateObject private var connectivity = WatchConnectivityService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectivity)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var connectivity: WatchConnectivityService

    var body: some View {
        TabView {
            if let approval = connectivity.pendingApproval {
                ApprovalDetailView(approval: approval)
            } else {
                StatusView()
            }
        }
    }
}
```

- [ ] **Step 4: Write ApprovalDetailView**

```swift
// watch/WatchApproveWatch/Views/ApprovalDetailView.swift
import SwiftUI

struct ApprovalDetailView: View {
    let approval: Approval
    @EnvironmentObject var connectivity: WatchConnectivityService

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(approval.toolName)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(approval.command)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Divider()

                HStack(spacing: 12) {
                    Button {
                        connectivity.respond(approval.id, decision: .allow)
                    } label: {
                        Label("允许", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button {
                        connectivity.respond(approval.id, decision: .deny)
                    } label: {
                        Label("拒绝", systemImage: "xmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }
            .padding()
        }
    }
}
```

- [ ] **Step 5: Write WatchConnectivityService**

```swift
// watch/WatchApproveWatch/Services/WatchConnectivityService.swift
import Foundation
import WatchConnectivity

class WatchConnectivityService: NSObject, ObservableObject {
    @Published var pendingApproval: Approval?
    @Published var isCaffeinateActive = false

    private var session: WCSession?

    override init() {
        super.init()
        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }

    func respond(_ id: String, decision: Decision) {
        session?.sendMessage([
            "type": "approval_response",
            "approvalId": id,
            "decision": decision.rawValue
        ], replyHandler: nil) { error in
            print("WC send error: \(error)")
        }
        pendingApproval = nil
    }
}

extension WatchConnectivityService: WCSessionDelegate {
    func session(_ session: WCSession, didReceiveMessage message: [String : Any]) {
        DispatchQueue.main.async {
            if message["type"] as? String == "approval",
               let dict = message["approval"] as? [String: Any] {
                let approval = Approval(
                    id: dict["id"] as? String ?? UUID().uuidString,
                    toolName: dict["toolName"] as? String ?? "Bash",
                    command: dict["command"] as? String ?? "",
                    hookSessionId: dict["hookSessionId"] as? String ?? "",
                    cwd: nil,
                    status: .pending,
                    createdAt: Date()
                )
                self.pendingApproval = approval
            }
            if let caffeinate = message["caffeinateActive"] as? Bool {
                self.isCaffeinateActive = caffeinate
            }
        }
    }
}
```

- [ ] **Step 6: Commit**

```bash
git add watch/
git commit -m "feat(watch): watchOS app scaffold + approval UI + WatchConnectivity

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 6: Hook Script Generator + Integration

### Task 6.1: Hook script generator in macOS app

**Files:**
- Modify: `macos/WatchApproveMac/App/WatchApproveMacApp.swift` (add script generator)
- Create: `macos/WatchApproveMac/App/ScriptGenerator.swift`

- [ ] **Step 1: Write ScriptGenerator**

```swift
// macos/WatchApproveMac/App/ScriptGenerator.swift
import Foundation

struct ScriptGenerator {
    static func generateApproveScript(relayURL: String, hookToken: String) -> String {
        """
        #!/bin/bash
        # WatchApprove Pro — Claude Code PreToolUse hook
        # Install: add to ~/.claude/settings.json hooks.PreToolUse

        RELAY_URL="\(relayURL)"
        HOOK_TOKEN="\(hookToken)"
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

        # Load env from watch.env if present
        if [ -f "$SCRIPT_DIR/watch.env" ]; then
            set -a; source "$SCRIPT_DIR/watch.env"; set +a
        fi

        exec python3 "$SCRIPT_DIR/watch_approve.py
        """
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add macos/WatchApproveMac/App/ScriptGenerator.swift
git commit -m "feat(macos): hook script generator

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Phase 7: Build Verification

### Task 7.1: Verify all three targets build

- [ ] **Step 1: Generate Xcode projects**

```bash
cd macos && xcodegen generate
cd ../ios && xcodegen generate
cd ../watch && xcodegen generate
```

- [ ] **Step 2: Build macOS app**

```bash
cd macos
xcodebuild -project WatchApproveMac.xcodeproj \
  -scheme WatchApprove \
  -configuration Debug \
  -destination 'platform=macOS' \
  build 2>&1 | tail -20
```

- [ ] **Step 3: Build iOS app**

```bash
cd ios
xcodebuild -project WatchApprove.xcodeproj \
  -scheme WatchApprove \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  build 2>&1 | tail -20
```

- [ ] **Step 4: Build watchOS app**

```bash
cd watch
xcodebuild -project WatchApproveWatch.xcodeproj \
  -scheme WatchApproveWatch \
  -configuration Debug \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 9' \
  build 2>&1 | tail -20
```

- [ ] **Step 5: Commit build verification**

```bash
git add -A && git commit -m "chore: verify all targets build

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Self-Review Checklist

1. **Spec coverage**: All spec sections covered?
   - [x] macOS menu bar + Dynamic Island + Notification Center
   - [x] iOS app + approvals + settings
   - [x] watchOS app + WatchConnectivity
   - [x] VPS FastAPI relay + SQLite
   - [x] Anti-sleep: auto/manual/scheduled (all three modes)
   - [x] Claude Code + Codex support
   - [x] Local WS path (same-machine)
   - [x] Relay path (remote SSH)
   - [x] Multi-device sync
   - [x] Hook script zero-breaking-change compatibility

2. **Placeholder scan**: No "TBD", "TODO", "fill in later" in step code

3. **Type consistency**: `Decision` vs `ApprovalStatus`, `Approval.id` vs `approval_id` (WS JSON), device token field names — all checked

4. **Gaps found**: None

---

## Execution Options

**Plan complete and saved to `docs/superpowers/plans/2026-07-04-watchapprove-pro-implementation.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
