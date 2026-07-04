# tests/test_relay.py
import pytest, sys, os
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent.parent / "relay"))

os.environ["WATCH_APPROVE_HOOK_TOKEN"] = "test-hook-token"

from fastapi.testclient import TestClient
from relay.main import app

@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c

def test_health(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}

def test_register_and_unregister(client):
    # Register a device
    r = client.post("/register", json={
        "device_token": "test-device-001",
        "platform": "ios",
        "apns_token": "apns-test-token"
    })
    assert r.status_code == 200
    assert r.json() == {"ok": True}

    # Unregister the device
    r = client.post("/unregister?device_token=test-device-001")
    assert r.status_code == 200
    assert r.json() == {"ok": True}

def test_create_approval_requires_auth(client):
    r = client.post("/approval", json={
        "tool_name": "Bash",
        "command": "rm -rf /",
        "hook_session_id": "sess-123"
    })
    assert r.status_code == 401

def test_create_approval_with_auth(client):
    r = client.post("/approval?token=test-hook-token", json={
        "tool_name": "Bash",
        "command": "echo hello",
        "hook_session_id": "sess-123",
        "reply_url": None
    })
    assert r.status_code == 200
    data = r.json()
    assert "approval_id" in data
    approval_id = data["approval_id"]

    # Fetch active approvals for a device (not yet linked, so empty)
    r = client.get("/approvals/active?device_token=test-device-001")
    assert r.status_code == 200
    assert isinstance(r.json(), list)

    # Approve the pending approval
    r = client.post(f"/approve/{approval_id}", json={
        "decision": "allow",
        "device_id": "test-device-001"
    })
    assert r.status_code == 200

    # History should show the resolved approval
    r = client.get("/approvals/history?device_token=test-device-001")
    assert r.status_code == 200
    history = r.json()
    assert len(history) == 1
    assert history[0]["status"] == "approved"

def test_approve_nonexistent(client):
    r = client.post("/approve/nonexistent-id", json={
        "decision": "allow",
        "device_id": "test-device-001"
    })
    assert r.status_code == 404

def test_approve_already_resolved(client):
    # Create approval
    r = client.post("/approval?token=test-hook-token", json={
        "tool_name": "Bash",
        "command": "echo hello",
        "hook_session_id": "sess-456"
    })
    approval_id = r.json()["approval_id"]

    # First approval
    r = client.post(f"/approve/{approval_id}", json={
        "decision": "allow",
        "device_id": "test-device-001"
    })
    assert r.status_code == 200

    # Second approval attempt
    r = client.post(f"/approve/{approval_id}", json={
        "decision": "deny",
        "device_id": "test-device-001"
    })
    assert r.status_code == 200
    assert r.json()["status"] == "already_resolved"
