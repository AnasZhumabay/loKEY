"""Chat mailbox, groups, shared cases, backups, security events, cleanup job."""
import json
import os
from datetime import timedelta

from sqlalchemy import select, update

from app.db import SessionLocal
from app.jobs import run_cleanup
from app.models import ChatMessage, File, SecurityEvent
from app.schemas.types import format_utc, utcnow
from tests.conftest import b64, sha, uid


def envelope(sender, recipient, **kw):
    now = utcnow()
    return {"id": uid(), "sender_id": sender.id, "recipient_id": recipient.id, "version": 1,
            "ciphertext": b64(os.urandom(48)), "sent_at": format_utc(now),
            "expires_at": format_utc(now + timedelta(days=30)), **kw}


async def test_identity_rules(register):
    a, b = await register(), await register()
    assert (await a.req("GET", f"/v1/chat/users/{b.id}")).status_code == 404  # no key published yet
    assert (await a.req("PUT", "/v1/chat/identity", json={"public_key": b64(b"short")})).status_code == 400
    key = os.urandom(32)
    r = await a.req("PUT", "/v1/chat/identity", json={"public_key": b64(key)})
    assert r.json() == {"id": a.id, "username": a.username, "identity_key": b64(key)}
    assert (await a.req("PUT", "/v1/chat/identity", json={"public_key": b64(key)})).status_code == 200
    swap = await a.req("PUT", "/v1/chat/identity", json={"public_key": b64(os.urandom(32))})
    assert swap.status_code == 409  # never silently replace an identity key
    assert (await b.req("GET", f"/v1/chat/users/{a.id}")).json()["identity_key"] == b64(key)


async def test_mailbox(register, settings):
    a, b = await register(), await register()
    env = envelope(a, b, expires_at=format_utc(utcnow() + timedelta(days=400)))
    assert (await a.req("POST", "/v1/chat/messages", json=env)).status_code == 204
    assert (await a.req("POST", "/v1/chat/messages", json=env)).status_code == 204
    got = (await b.req("GET", "/v1/chat/messages?limit=10")).json()
    assert len(got) == 1 and got[0]["ciphertext"] == env["ciphertext"]
    assert got[0]["expires_at"] <= format_utc(utcnow() + timedelta(days=30))  # server caps the TTL

    settings.chat_max_ciphertext_bytes = 10
    assert (await a.req("POST", "/v1/chat/messages", json=envelope(a, b))).status_code == 400
    settings.chat_max_ciphertext_bytes = 8_000_000

    second = envelope(a, b)
    await a.req("POST", "/v1/chat/messages", json=second)
    assert [m["id"] for m in (await b.req("GET", "/v1/chat/messages")).json()] == [env["id"], second["id"]]
    assert [m["id"] for m in (await b.req("GET", "/v1/chat/messages?limit=1")).json()] == [env["id"]]
    await b.req("POST", "/v1/chat/messages/ack", json={"ids": [env["id"]]})
    assert [m["id"] for m in (await b.req("GET", "/v1/chat/messages")).json()] == [second["id"]]


async def test_groups_fan_out(register):
    a, b, c, stranger = await register(), await register(), await register(), await register()
    gid = uid()
    g = {"id": gid, "name_ciphertext": b64(b"name"), "member_ids": [b.id], "created_at": format_utc(utcnow())}
    r = await a.req("POST", "/v1/chat/groups", json=g)
    assert r.status_code == 201 and r.json()["member_ids"] == [a.id, b.id]
    assert (await a.req("POST", "/v1/chat/groups", json=g)).status_code == 200
    assert (await stranger.req("POST", "/v1/chat/groups", json=g)).status_code == 404
    assert (await b.req("POST", f"/v1/chat/groups/{gid}/members", json={"user_id": c.id})).status_code == 403
    r = await a.req("POST", f"/v1/chat/groups/{gid}/members", json={"user_id": c.id})
    assert r.json()["member_ids"] == [a.id, b.id, c.id]
    assert [x["id"] for x in (await c.req("GET", "/v1/chat/groups")).json()] == [gid]

    genv = {"id": uid(), "group_id": gid, "sender_id": a.id, "sent_at": format_utc(utcnow()),
            "ciphertext": b64(b"group-ct"), "recipient_ids": [a.id, b.id, c.id]}
    assert (await a.req("POST", f"/v1/chat/groups/{gid}/messages", json=genv)).status_code == 204
    for who in (b, c):
        msgs = (await who.req("GET", "/v1/chat/messages")).json()
        assert [m["id"] for m in msgs] == [genv["id"]] and msgs[0]["sender_id"] == a.id
    assert (await a.req("GET", "/v1/chat/messages")).json() == []  # no copy to the sender
    bad = {**genv, "id": uid(), "recipient_ids": [stranger.id]}
    assert (await a.req("POST", f"/v1/chat/groups/{gid}/messages", json=bad)).status_code == 403

    r = await b.req("DELETE", f"/v1/chat/groups/{gid}/members/{b.id}")  # leave
    assert r.status_code == 200 and b.id not in r.json()["member_ids"]
    assert (await b.req("GET", "/v1/chat/groups")).json() == []


async def test_shared_case_flow(register):
    owner, viewer, editor, stranger = await register(), await register(), await register(), await register()
    c = await owner.create_case()
    f = await owner.add_file(c["id"], b"shared-ct")
    inv = lambda u, role: {"invitee_user_id": u.id, "wrapped_key_for_invitee": b64(b"wrapped-" + u.id.encode()),  # noqa: E731
                           "role": role}

    assert (await owner.req("POST", f"/v1/cases/{c['id']}/invites", json=inv(owner, "viewer"))).status_code == 400
    assert (await owner.req("POST", f"/v1/cases/{c['id']}/invites", json=inv(viewer, "owner"))).status_code == 400
    assert (await stranger.req("POST", f"/v1/cases/{c['id']}/invites", json=inv(viewer, "viewer"))).status_code == 404
    assert (await owner.req("POST", f"/v1/cases/{c['id']}/invites",
                            json={**inv(viewer, "viewer"), "invitee_user_id": uid()})).status_code == 404
    for u, role in ((viewer, "viewer"), (editor, "editor")):
        assert (await owner.req("POST", f"/v1/cases/{c['id']}/invites", json=inv(u, role))).status_code == 204

    invites = (await viewer.req("GET", "/v1/invites")).json()
    assert len(invites) == 1 and invites[0]["case_id"] == c["id"] and invites[0]["from_user_id"] == owner.id
    assert (await viewer.req("GET", f"/v1/cases/{c['id']}/wrapped-key")).status_code == 404  # not accepted yet
    assert (await viewer.req("GET", f"/v1/cases/{c['id']}/files")).status_code == 404
    assert (await stranger.req("POST", f"/v1/invites/{invites[0]['id']}/accept")).status_code == 404

    m = (await viewer.req("POST", f"/v1/invites/{invites[0]['id']}/accept")).json()
    assert m["status"] == "active" and m["role"] == "viewer" and m["joined_at"]
    assert (await viewer.req("POST", f"/v1/invites/{invites[0]['id']}/accept")).status_code == 200  # idempotent
    assert (await viewer.req("GET", "/v1/invites")).json() == []
    wk = (await viewer.req("GET", f"/v1/cases/{c['id']}/wrapped-key")).json()
    assert wk == {"wrapped_key": b64(b"wrapped-" + viewer.id.encode())}

    # the member now sees the case and its files, but a viewer can't write
    assert [x["id"] for x in (await viewer.req("GET", "/v1/cases")).json()] == [c["id"]]
    assert (await viewer.req("GET", f"/v1/files/{f['id']}/blob")).content == b"shared-ct"
    assert (await viewer.req("POST", f"/v1/files/{f['id']}/trash")).status_code == 403
    assert (await viewer.req("POST", "/v1/files", json={
        "id": uid(), "case_id": c["id"], "sealed_metadata": b64(b"m"), "ciphertext_size": 1,
        "ciphertext_sha256": sha(b"x")})).status_code == 403
    assert (await viewer.req("PUT", f"/v1/cases/{c['id']}", json={"id": c["id"], "sealed_header": b64(b"x")},
                             headers={"If-Match": "1"})).status_code == 403
    assert (await viewer.req("POST", f"/v1/cases/{c['id']}/invites", json=inv(stranger, "viewer"))).status_code == 403

    # an editor can add files; they count against the OWNER's quota
    ed_inv = (await editor.req("GET", "/v1/invites")).json()[0]
    await editor.req("POST", f"/v1/invites/{ed_inv['id']}/accept")
    await editor.add_file(c["id"], b"from-editor")
    assert (await owner.req("GET", "/v1/account/storage")).json()["used_bytes"] == len(b"shared-ct") + 11
    assert (await editor.req("GET", "/v1/account/storage")).json()["used_bytes"] == 0

    members = (await viewer.req("GET", f"/v1/cases/{c['id']}/members")).json()
    assert [(x["user_id"], x["role"], x["status"]) for x in members] == [
        (owner.id, "owner", "active"), (viewer.id, "viewer", "active"), (editor.id, "editor", "active")]

    assert (await viewer.req("DELETE", f"/v1/cases/{c['id']}/members/{editor.id}")).status_code == 403
    assert (await owner.req("DELETE", f"/v1/cases/{c['id']}/members/{owner.id}")).status_code == 400
    assert (await viewer.req("DELETE", f"/v1/cases/{c['id']}/members/{viewer.id}")).status_code == 204  # leave
    assert (await viewer.req("GET", f"/v1/cases/{c['id']}/wrapped-key")).status_code == 404
    assert (await viewer.req("GET", f"/v1/files/{f['id']}/blob")).status_code == 404
    assert (await owner.req("DELETE", f"/v1/cases/{c['id']}/members/{editor.id}")).status_code == 204
    statuses = {x["user_id"]: x["status"] for x in (await owner.req("GET", f"/v1/cases/{c['id']}/members")).json()}
    assert statuses[viewer.id] == statuses[editor.id] == "revoked"

    # re-inviting a revoked member issues a fresh invite
    await owner.req("POST", f"/v1/cases/{c['id']}/invites", json=inv(viewer, "editor"))
    again = (await viewer.req("GET", "/v1/invites")).json()
    assert len(again) == 1 and again[0]["id"] != invites[0]["id"]


async def test_backups(register):
    a, b = await register(), await register()
    data = os.urandom(700)
    bid = uid().upper()  # the app sends uppercase UUIDs here (BackupServiceImpl)
    info = {"id": bid, "created_at": format_utc(utcnow()), "size_bytes": len(data), "sha256": sha(data),
            "device_name": "iPhone", "app_version": "1.0", "format_version": 1}
    hdr = lambda i, s: {"X-LK-Info": json.dumps(i), "X-LK-SHA256": s}  # noqa: E731
    put = lambda u, i, s, body=data: u.req("PUT", f"/v1/backups/{i['id']}", content=body, headers=hdr(i, s))  # noqa: E731

    assert (await put(a, info, "0" * 64)).status_code == 422
    assert (await a.req("PUT", f"/v1/backups/{uid()}", content=data, headers=hdr(info, sha(data)))).status_code == 422
    assert (await a.req("PUT", f"/v1/backups/{bid}", content=data,
                        headers={"X-LK-Info": "{not json", "X-LK-SHA256": sha(data)})).status_code == 400
    assert (await put(a, info, sha(data), body=data[:-1])).status_code == 422
    assert (await put(a, info, sha(data))).status_code == 204
    assert (await put(a, info, sha(data))).status_code == 204  # idempotent re-upload

    listed = (await a.req("GET", "/v1/backups")).json()
    assert listed == [info]
    assert (await a.req("GET", "/v1/account/storage")).json()["used_bytes"] == len(data)
    assert (await a.req("GET", f"/v1/backups/{bid}/blob")).content == data
    assert (await b.req("GET", f"/v1/backups/{bid}/blob")).status_code == 404
    assert (await b.req("DELETE", f"/v1/backups/{bid}")).status_code == 404
    assert (await put(b, info, sha(data))).status_code == 404  # can't overwrite someone else's
    assert (await a.req("DELETE", f"/v1/backups/{bid}")).status_code == 204
    assert (await a.req("GET", "/v1/backups")).json() == []


async def test_security_events_kept_out_of_audit(register):
    a = await register()
    c = await a.create_case()
    now = format_utc(utcnow())
    for kind in ("caseWiped", "duressUnlock", "tooManyAttempts", "backupCreated", "backupRestored"):
        r = await a.req("POST", "/v1/security-events", json={"kind": kind, "case_id": c["id"], "at": now})
        assert r.status_code == 204, kind
    assert (await a.req("POST", "/v1/security-events", json={"kind": "bogus", "at": now})).status_code == 400
    future = format_utc(utcnow() + timedelta(days=5))
    assert (await a.req("POST", "/v1/security-events", json={"kind": "caseWiped", "at": future})).status_code == 400
    await a.req("POST", "/v1/security-events", json={"kind": "caseWiped", "case_id": uid(), "at": now})
    assert all(e["kind"] not in ("duressUnlock", "caseWiped") for e in (await a.req("GET", "/v1/audit")).json())
    async with SessionLocal() as db:
        rows = list((await db.execute(select(SecurityEvent).order_by(SecurityEvent.received_at))).scalars())
    assert len(rows) == 6 and rows[-1].case_id is None  # foreign case reference dropped


async def test_cleanup_job(register):
    a, b = await register(), await register()
    c = await a.create_case()
    old_trash = await a.add_file(c["id"], b"old")
    fresh_trash = await a.add_file(c["id"], b"fresh")
    orphan = await a.add_file(c["id"], b"never-uploaded", upload=False)
    keep = await a.add_file(c["id"], b"keep")
    for f in (old_trash, fresh_trash):
        await a.req("POST", f"/v1/files/{f['id']}/trash")
    await a.req("POST", "/v1/chat/messages", json=envelope(a, b))
    async with SessionLocal() as db:
        past = utcnow() - timedelta(days=31)
        await db.execute(update(File).where(File.id == orphan["id"]).values(created_at=past))
        await db.execute(update(File).where(File.id == old_trash["id"]).values(deleted_at=past))
        await db.execute(update(ChatMessage).values(expires_at=utcnow() - timedelta(seconds=1)))
        await db.commit()

    stats = await run_cleanup()
    assert stats["trash_purged"] == 1 and stats["orphans_purged"] == 1 and stats["chat_expired"] == 1
    trash = [f["id"] for f in (await a.req("GET", "/v1/trash/files")).json()]
    assert trash == [fresh_trash["id"]]
    alive = {f["id"] for f in (await a.req("GET", f"/v1/cases/{c['id']}/files")).json()}
    assert alive == {keep["id"]}
    assert (await a.req("GET", f"/v1/files/{old_trash['id']}/blob")).status_code == 404
