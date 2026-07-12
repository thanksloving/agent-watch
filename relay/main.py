# relay/main.py - WatchApprove Relay Server
import asyncio, uuid, time, os
from contextlib import asynccontextmanager, suppress
from fastapi import FastAPI, WebSocket, WebSocketDisconnect, HTTPException, Query, Header
from pydantic import BaseModel
from typing import Optional, Literal
import aiosqlite
from pathlib import Path

DATABASE_PATH = Path(
    os.environ.get("WATCH_APPROVE_DB", str(Path(__file__).parent / "watchapprove.db"))
)
HOOK_TOKEN = (
    os.environ.get("WATCH_APPROVE_HOOK_TOKEN")
    or os.environ.get("WATCH_HOOK_TOKEN")
    or ""
)

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
    approval_id  TEXT NOT NULL,
    device_id    TEXT NOT NULL,
    PRIMARY KEY (approval_id, device_id),
    FOREIGN KEY (approval_id) REFERENCES pending_approvals(id) ON DELETE CASCADE,
    FOREIGN KEY (device_id)   REFERENCES devices(id)          ON DELETE CASCADE
);
"""

async def init_db():
    DATABASE_PATH.parent.mkdir(parents=True, exist_ok=True)
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        await db.executescript(SCHEMA)
        await migrate_approval_tokens(db)
        await db.commit()

async def migrate_approval_tokens(db: aiosqlite.Connection):
    cursor = await db.execute("PRAGMA table_info(approval_tokens)")
    columns = await cursor.fetchall()
    pk_columns = [row[1] for row in columns if row[5]]
    if pk_columns in (["approval_id", "device_id"], ["device_id", "approval_id"]):
        return

    await db.execute("ALTER TABLE approval_tokens RENAME TO approval_tokens_old")
    await db.execute("""
        CREATE TABLE approval_tokens (
            approval_id  TEXT NOT NULL,
            device_id    TEXT NOT NULL,
            PRIMARY KEY (approval_id, device_id),
            FOREIGN KEY (approval_id) REFERENCES pending_approvals(id) ON DELETE CASCADE,
            FOREIGN KEY (device_id)   REFERENCES devices(id)          ON DELETE CASCADE
        )
    """)
    await db.execute("""
        INSERT OR IGNORE INTO approval_tokens (approval_id, device_id)
        SELECT approval_id, device_id
        FROM approval_tokens_old
        WHERE approval_id IS NOT NULL AND device_id IS NOT NULL
    """)
    await db.execute("DROP TABLE approval_tokens_old")

@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield

app = FastAPI(title="WatchApprove Relay", lifespan=lifespan)

# ---- WebSocket managers ----
class ConnectionManager:
    def __init__(self):
        self.device_ws: dict[str, WebSocket] = {}  # device_token -> ws
        self.approval_waiters: dict[str, asyncio.Future[str]] = {}

    async def add_device(self, token: str, ws: WebSocket):
        old_ws = self.device_ws.get(token)
        if old_ws and old_ws is not ws:
            with suppress(Exception):
                await old_ws.close(code=4000)
        self.device_ws[token] = ws

    def remove_device(self, token: str, ws: WebSocket):
        if self.device_ws.get(token) is ws:
            del self.device_ws[token]

    def register_waiter(self, approval_id: str) -> asyncio.Future[str]:
        future: asyncio.Future[str] = asyncio.get_running_loop().create_future()
        self.approval_waiters[approval_id] = future
        return future

    def unregister_waiter(self, approval_id: str, future: asyncio.Future[str]):
        if self.approval_waiters.get(approval_id) is future:
            del self.approval_waiters[approval_id]

    def resolve_waiter(self, approval_id: str, decision: str):
        future = self.approval_waiters.get(approval_id)
        if future and not future.done():
            future.set_result(decision)

    async def broadcast_to_devices(self, message: dict):
        dead = []
        for token, ws in list(self.device_ws.items()):
            try:
                await ws.send_json(message)
            except Exception:
                dead.append(token)
        for token in dead:
            if token in self.device_ws:
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

class NotifyPayload(BaseModel):
    title: str
    body: str

def authorize_hook(token: Optional[str] = None, authorization: Optional[str] = None):
    bearer = ""
    if authorization and authorization.lower().startswith("bearer "):
        bearer = authorization[7:].strip()
    supplied = token or bearer
    if not HOOK_TOKEN or supplied != HOOK_TOKEN:
        raise HTTPException(401, "Invalid hook token")

@app.post("/notify")
async def post_notify(
    body: NotifyPayload,
    token: Optional[str] = Query(None),
    authorization: Optional[str] = Header(None),
):
    authorize_hook(token, authorization)
    await manager.broadcast_to_devices({
        "type": "relay_notification",
        "title": body.title,
        "body": body.body
    })
    return {"ok": True}

# ---- Routes ----

@app.get("/health")
async def get_health():
    return {"status": "ok"}

@app.websocket("/ws/hook")
async def ws_hook(ws: WebSocket, token: str = Query(...)):
    await ws.accept()
    if not HOOK_TOKEN or token != HOOK_TOKEN:
        await ws.close(code=4001)
        return

    try:
        payload = await ws.receive_json()
    except WebSocketDisconnect:
        return
    except Exception:
        await ws.close(code=1003)
        return

    if payload.get("type") != "approval_request":
        await ws.close(code=1003)
        return

    approval = ApprovalCreate(
        tool_name=str(payload.get("tool_name") or "Tool"),
        command=str(payload.get("command") or ""),
        hook_session_id=str(payload.get("hook_session_id") or ""),
        reply_url=payload.get("reply_url"),
    )
    approval_id, created_at = await create_pending_approval(approval)
    future = manager.register_waiter(approval_id)
    receive_task = asyncio.create_task(ws.receive_text())

    await manager.broadcast_to_devices(approval_message(
        approval_id=approval_id,
        approval=approval,
        created_at=created_at,
    ))

    try:
        done, pending = await asyncio.wait(
            {future, receive_task},
            return_when=asyncio.FIRST_COMPLETED,
        )
        for task in pending:
            task.cancel()
        if receive_task in done:
            with suppress(Exception):
                receive_task.result()
        if future in done:
            await ws.send_json({
                "type": "approval_resolved",
                "approval_id": approval_id,
                "decision": future.result(),
            })
    except WebSocketDisconnect:
        pass
    finally:
        manager.unregister_waiter(approval_id, future)
        receive_task.cancel()
        with suppress(Exception):
            await ws.close()

@app.websocket("/ws/device/{device_token}")
async def ws_device(
    ws: WebSocket,
    device_token: str,
    platform: Literal["ios", "macos", "watchos"] = Query("ios"),
):
    await ws.accept()
    await upsert_device(device_token, platform)
    await link_pending_approvals_to_device(device_token)
    await manager.add_device(device_token, ws)
    try:
        for message in await active_messages_for_device(device_token):
            await ws.send_json(message)
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        manager.remove_device(device_token, ws)

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

        # Verify this device has a token for this approval
        token_row = await db.execute(
            "SELECT 1 FROM approval_tokens WHERE approval_id=? AND device_id=?",
            (approval_id, body.device_id))
        token_result = await token_row.fetchone()
        if not token_result and body.device_id not in manager.device_ws:
            raise HTTPException(403, "Device not authorized for this approval")
        if not token_result:
            await db.execute(
                "INSERT OR IGNORE INTO approval_tokens (approval_id, device_id) VALUES (?,?)",
                (approval_id, body.device_id))

        await db.execute(
            """UPDATE pending_approvals
               SET status = CASE WHEN ? = 'allow' THEN 'approved' ELSE 'denied' END,
                   resolution=?, resolved_at=?
               WHERE id=?""",
            (body.decision, body.decision, int(time.time()), approval_id))
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
        manager.resolve_waiter(approval_id, body.decision)

    return {"ok": True}

@app.post("/register")
async def post_register(body: DeviceRegister):
    await upsert_device(body.device_token, body.platform, body.apns_token)
    await link_pending_approvals_to_device(body.device_token)
    return {"ok": True}

@app.post("/unregister")
async def post_unregister(device_token: str = Query(...)):
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        await db.execute("DELETE FROM devices WHERE id=?", (device_token,))
        await db.commit()
    return {"ok": True}

@app.get("/approvals/active")
async def get_active(device_token: str = Query(...)):
    # Verify device is registered
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute("SELECT 1 FROM devices WHERE id=?", (device_token,))
        row = await cursor.fetchone()
        if not row:
            raise HTTPException(403, "Unknown device")
        rows = await db.execute_fetchall(
            """SELECT pa.* FROM pending_approvals pa
               JOIN approval_tokens at ON at.approval_id = pa.id
               WHERE at.device_id=? AND pa.status='pending'
               ORDER BY pa.created_at DESC""", (device_token,))
        return [dict(r) for r in rows]

@app.get("/approvals/history")
async def get_history(device_token: str = Query(...), limit: int = Query(50)):
    # Verify device is registered
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute("SELECT 1 FROM devices WHERE id=?", (device_token,))
        row = await cursor.fetchone()
        if not row:
            raise HTTPException(403, "Unknown device")
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
    authorize_hook(token)
    approval_id, created_at = await create_pending_approval(body)
    await manager.broadcast_to_devices(approval_message(approval_id, body, created_at))
    return {"approval_id": approval_id}

def approval_message(approval_id: str, approval: ApprovalCreate, created_at: int) -> dict:
    return {
        "type": "new_approval",
        "approval_id": approval_id,
        "tool_name": approval.tool_name,
        "command": approval.command,
        "hook_session_id": approval.hook_session_id,
        "created_at": created_at,
    }

async def upsert_device(
    device_token: str,
    platform: Literal["ios", "macos", "watchos"] = "ios",
    apns_token: Optional[str] = None,
):
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        now = int(time.time())
        await db.execute("""INSERT INTO devices
            (id, platform, apns_token, created_at, last_seen)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                platform=excluded.platform,
                apns_token=COALESCE(excluded.apns_token, devices.apns_token),
                last_seen=excluded.last_seen""",
            (device_token, platform, apns_token, now, now))
        await db.commit()

async def link_pending_approvals_to_device(device_token: str):
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        await db.execute("""
            INSERT OR IGNORE INTO approval_tokens (approval_id, device_id)
            SELECT id, ? FROM pending_approvals WHERE status='pending'
        """, (device_token,))
        await db.commit()

async def create_pending_approval(body: ApprovalCreate) -> tuple[str, int]:
    approval_id = str(uuid.uuid4())
    created_at = int(time.time())
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        await db.execute("""INSERT INTO pending_approvals
            (id, hook_session_id, tool_name, command, reply_url, status, created_at)
            VALUES (?, ?, ?, ?, ?, 'pending', ?)""",
            (approval_id, body.hook_session_id, body.tool_name,
             body.command, body.reply_url, created_at))

        device_ids = set(manager.device_ws.keys())
        cursor = await db.execute("SELECT id FROM devices")
        rows = await cursor.fetchall()
        device_ids.update(row[0] for row in rows)
        for device_id in device_ids:
            await db.execute(
                "INSERT OR IGNORE INTO approval_tokens (approval_id, device_id) VALUES (?,?)",
                (approval_id, device_id))
        await db.commit()
    return approval_id, created_at

async def active_messages_for_device(device_token: str) -> list[dict]:
    async with aiosqlite.connect(str(DATABASE_PATH)) as db:
        db.row_factory = aiosqlite.Row
        rows = await db.execute_fetchall(
            """SELECT pa.* FROM pending_approvals pa
               JOIN approval_tokens at ON at.approval_id = pa.id
               WHERE at.device_id=? AND pa.status='pending'
               ORDER BY pa.created_at DESC""",
            (device_token,))
        return [
            approval_message(
                approval_id=row["id"],
                approval=ApprovalCreate(
                    tool_name=row["tool_name"] or "Tool",
                    command=row["command"] or "",
                    hook_session_id=row["hook_session_id"],
                    reply_url=row["reply_url"],
                ),
                created_at=row["created_at"],
            )
            for row in rows
        ]

# ---- APNs helper (stub — plug in your APNs library) ----
async def send_apns_push(apns_token: str, payload: dict):
    """Send push via APNs. Requires pyapplepush or similar."""
    pass  # TODO: implement APNs push
