# relay/main.py — WatchApprove Relay Server
import asyncio, uuid, time, os
from contextlib import asynccontextmanager
from fastapi import FastAPI, WebSocket, HTTPException, Query
from pydantic import BaseModel
from typing import Optional, Literal
import aiosqlite
from pathlib import Path

DATABASE_PATH = Path(__file__).parent / "watchapprove.db"
HOOK_TOKEN = os.environ.get("WATCH_APPROVE_HOOK_TOKEN", "")

# ---- DB setup ----
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

# ---- Pydantic models ----
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

# ---- Hook Token Auth ----
def verify_hook_token(token: str = Query(...)):
    if not HOOK_TOKEN or token != HOOK_TOKEN:
        raise HTTPException(401, "Invalid hook token")

# ---- Routes ----

@app.get("/health")
async def get_health():
    return {"status": "ok"}

@app.websocket("/ws/hook")
async def ws_hook(ws: WebSocket, token: str = Query(...)):
    await manager.connect_hook(ws, token)

@app.websocket("/ws/device/{device_token}")
async def ws_device(ws: WebSocket, device_token: str):
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        await db.execute(
            "UPDATE devices SET last_seen=? WHERE id=?", (int(time.time()), device_token))
        await db.commit()
    await manager.connect_device(ws, device_token)

@app.post("/approve/{approval_id}")
async def post_approve(approval_id: str, body: DecisionInput):
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT * FROM pending_approvals WHERE id=?", (approval_id,))
        row = await cursor.fetchone()
        if not row:
            raise HTTPException(404, "Approval not found")
        if row["status"] != "pending":
            return {"status": "already_resolved", "current": row["status"]}

        # ponytail: CASE WHEN for conditional status update
        await db.execute(
            """UPDATE pending_approvals
               SET status = CASE WHEN ? = 'allow' THEN 'approved' ELSE 'denied' END,
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
async def create_approval(body: ApprovalCreate, token: Optional[str] = Query(None)):
    if not token or token != HOOK_TOKEN:
        raise HTTPException(401, "Invalid hook token")
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
