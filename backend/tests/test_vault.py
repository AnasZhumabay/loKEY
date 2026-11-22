"""Cases, files, blobs, trash, versions, quota, audit, billing."""
import os
from pathlib import Path

from app.core.config import get_settings
from tests.conftest import b64, sha, uid


async def test_case_create_is_idempotent_and_isolated(register):
    a, b = await register(), await register()
    cid = uid()
    first = await a.req("POST", "/v1/cases", json={"id": cid, "sealed_header": b64(b"h1"), "revision": 7})
    assert first.status_code == 201 and first.json()["revision"] == 1
    again = await a.req("POST", "/v1/cases", json={"id": cid, "sealed_header": b64(b"other")})
    assert again.status_code == 200 and again.json()["sealed_header"] == b64(b"h1")
    stolen = await b.req("POST", "/v1/cases", json={"id": cid, "sealed_header": b64(b"x")})
    assert stolen.status_code == 403
    assert [c["id"] for c in (await b.req("GET", "/v1/cases")).json()] == []
    for method, path in [("PUT", f"/v1/cases/{cid}"), ("DELETE", f"/v1/cases/{cid}"),
                         ("GET", f"/v1/cases/{cid}/files")]:
        r = await b.req(method, path, json={"id": cid, "sealed_header": b64(b"x")}, headers={"If-Match": "1"})
        assert r.status_code == 404, (method, path)


async def test_case_update_revision_rules(register):
    a = await register()
    c = await a.create_case()
    path = f"/v1/cases/{c['id']}"
    body = {"id": c["id"], "sealed_header": b64(b"h2")}
    assert (await a.req("PUT", path, json=body)).json()["code"] == "conflict"  # no If-Match
    r = await a.req("PUT", path, json=body, headers={"If-Match": '"1"'})  # ETag style is fine
    assert r.status_code == 200 and r.json()["revision"] == 2
    assert r.json()["recovery_wrapped_key"] == b64(b"rk")  # absent key = keep
    assert (await a.req("PUT", path, json=body, headers={"If-Match": "1"})).status_code == 409
    assert (await a.req("PUT", path, json=body, headers={"If-Match": "two"})).status_code == 400


async def test_file_lifecycle_counts_and_blobs(register):
    a = await register()
    c = await a.create_case()
    data = os.urandom(3000)
    f = await a.add_file(c["id"], data)
    blob = await a.req("GET", f"/v1/files/{f['id']}/blob")
    assert blob.status_code == 200 and blob.content == data
    assert blob.headers["content-type"] == "application/octet-stream"

    case = (await a.req("GET", "/v1/cases")).json()[0]
    assert case["file_count"] == 1 and case["storage_bytes"] == 3000

    assert (await a.req("POST", f"/v1/files/{f['id']}/trash")).status_code == 204
    assert (await a.req("POST", f"/v1/files/{f['id']}/trash")).status_code == 204  # idempotent
    case = (await a.req("GET", "/v1/cases")).json()[0]
    assert case["file_count"] == 0 and case["storage_bytes"] == 3000  # trash still counts
    trash = (await a.req("GET", "/v1/trash/files")).json()
    assert trash[0]["id"] == f["id"] and trash[0]["deleted_at"] and trash[0]["revision"] == 2

    restored = (await a.req("POST", f"/v1/files/{f['id']}/restore", json={})).json()
    assert restored["deleted_at"] is None and restored["revision"] == 3
    kinds = [e["kind"] for e in (await a.req("GET", "/v1/audit")).json()]
    assert kinds[:3] == ["fileRestored", "fileTrashed", "fileAdded"]


async def test_blob_integrity(register):
    a = await register()
    c = await a.create_case()
    data = b"exact bytes"
    f = await a.add_file(c["id"], data, upload=False)
    path = f"/v1/files/{f['id']}/blob"
    assert (await a.req("GET", path)).status_code == 404  # nothing uploaded yet
    for content, h in [(data, "0" * 64), (data[:-1], sha(data)), (data + b"!", sha(data)), (data, None)]:
        r = await a.req("PUT", path, content=content, headers={"X-Content-SHA256": h} if h else {})
        assert r.status_code == 422 and r.json()["code"] == "integrity_failed"
    assert (await a.req("PUT", path, content=data, headers={"X-Content-SHA256": sha(data).upper()})).status_code == 204
    # re-upload of the same content replaces the blob without leaving the old one behind
    assert (await a.req("PUT", path, content=data, headers={"X-Content-SHA256": sha(data)})).status_code == 204
    root = Path(get_settings().blob_dir) / "files" / f["id"]
    assert len(list(root.iterdir())) == 1


async def test_file_update_and_validation(register):
    a = await register()
    c = await a.create_case()
    f = await a.add_file(c["id"])
    p = f"/v1/files/{f['id']}"
    r = await a.req("PUT", p, json={**f, "sealed_metadata": b64(b"m2"), "ciphertext_size": 999},
                    headers={"If-Match": "1"})
    assert r.status_code == 200 and r.json()["revision"] == 2 and r.json()["ciphertext_size"] == f["ciphertext_size"]
    assert (await a.req("PUT", p, json=f, headers={"If-Match": "1"})).status_code == 409
    bad = await a.req("POST", "/v1/files", json={**f, "id": uid(), "ciphertext_sha256": "XYZ"})
    assert bad.status_code == 400 and "ciphertext_sha256" in bad.json()["message"]
    missing = await a.req("POST", "/v1/files", json={**f, "id": uid(), "case_id": uid()})
    assert missing.status_code == 404


async def test_quota(register, settings):
    settings.free_plan_bytes = 1000
    a = await register()
    c = await a.create_case()
    await a.add_file(c["id"], b"x" * 600)
    r = await a.req("POST", "/v1/files", json={"id": uid(), "case_id": c["id"], "sealed_metadata": b64(b"m"),
                                               "ciphertext_size": 500, "ciphertext_sha256": "0" * 64})
    assert r.status_code == 413 and r.json() == {"code": "quota_exceeded", "message": r.json()["message"],
                                                 "limit_bytes": 1000}
    usage = (await a.req("GET", "/v1/account/storage")).json()
    assert usage == {"used_bytes": 600, "limit_bytes": 1000, "per_case": [{"case_id": c["id"], "bytes": 600}]}


async def test_versions_replace_download_restore(register, settings):
    settings.max_versions_per_file = 2
    a = await register()
    c = await a.create_case()
    v1, v2, v3 = b"version-one", b"version-two!", b"version-three"
    f = await a.add_file(c["id"], v1)
    fid = f["id"]
    stale = await a.req("POST", f"/v1/files/{fid}/versions", json={
        "sealed_metadata": b64(b"m2"), "ciphertext_size": len(v2), "ciphertext_sha256": sha(v2),
        "expected_revision": 9})
    assert stale.status_code == 409

    for rev, data in ((1, v2), (2, v3)):
        r = await a.req("POST", f"/v1/files/{fid}/versions", json={
            "sealed_metadata": b64(b"m"), "ciphertext_size": len(data), "ciphertext_sha256": sha(data),
            "expected_revision": rev})
        assert r.status_code == 200 and r.json()["revision"] == rev + 1
        assert (await a.req("GET", f"/v1/files/{fid}/blob")).status_code == 404  # waiting for the new blob
        assert (await a.req("PUT", f"/v1/files/{fid}/blob", content=data,
                            headers={"X-Content-SHA256": sha(data)})).status_code == 204

    versions = (await a.req("GET", f"/v1/files/{fid}/versions")).json()
    assert [v["ciphertext_size"] for v in versions] == [len(v2), len(v1)]  # newest first, current excluded
    old = await a.req("GET", f"/v1/file-versions/{versions[1]['id']}/blob")
    assert old.content == v1
    assert (await a.req("GET", "/v1/account/storage")).json()["used_bytes"] == len(v1) + len(v2) + len(v3)

    r = await a.req("POST", f"/v1/files/{fid}/versions/{versions[1]['id']}/restore", json={})
    assert r.status_code == 200 and r.json()["revision"] == 4 and r.json()["ciphertext_sha256"] == sha(v1)
    assert (await a.req("GET", f"/v1/files/{fid}/blob")).content == v1
    sizes = sorted(v["ciphertext_size"] for v in (await a.req("GET", f"/v1/files/{fid}/versions")).json())
    assert sizes == sorted([len(v2), len(v3)])  # swapped, not lost

    # one more replace: only max_versions_per_file (2) are kept
    v4 = b"v4"
    await a.req("POST", f"/v1/files/{fid}/versions", json={
        "sealed_metadata": b64(b"m"), "ciphertext_size": len(v4), "ciphertext_sha256": sha(v4), "expected_revision": 4})
    assert len((await a.req("GET", f"/v1/files/{fid}/versions")).json()) == 2


async def test_purge_removes_blobs_from_disk(register):
    a = await register()
    c = await a.create_case()
    f1 = await a.add_file(c["id"], b"one")
    f2 = await a.add_file(c["id"], b"two")
    root = Path(get_settings().blob_dir) / "files"
    assert (root / f1["id"]).exists()
    assert (await a.req("DELETE", f"/v1/files/{f1['id']}")).status_code == 204
    assert not any((root / f1["id"]).iterdir())
    assert (await a.req("DELETE", f"/v1/files/{f1['id']}")).status_code == 404
    assert (await a.req("DELETE", f"/v1/cases/{c['id']}")).status_code == 204
    assert not any((root / f2["id"]).iterdir())
    assert (await a.req("GET", f"/v1/files/{f2['id']}/blob")).status_code == 404
    assert (await a.req("DELETE", f"/v1/cases/{c['id']}")).status_code == 404


async def test_audit_rules(register):
    a = await register()
    cid = uid()
    assert (await a.req("POST", "/v1/audit", json={"kind": "caseDeleted", "case_id": cid})).status_code == 204
    forged = await a.req("POST", "/v1/audit", json={"kind": "login"})
    assert forged.status_code == 400
    assert (await a.req("POST", "/v1/audit", json={"kind": "madeUp"})).status_code == 400
    for _ in range(3):
        await a.req("POST", "/v1/audit", json={"kind": "caseUnlocked", "case_id": cid})
    events = (await a.req("GET", "/v1/audit?limit=2")).json()
    assert len(events) == 2 and events[0]["kind"] == "caseUnlocked" and events[0]["case_id"] == cid
    assert events[0]["ip_hint"] in (None, "127.0.0.x") or events[0]["ip_hint"].endswith(".x")


async def test_billing(register, settings):
    a = await register()
    plans = (await a.req("GET", "/v1/billing/plans")).json()
    assert [p["id"] for p in plans] == ["free", "plus_10_month", "pro_25_month", "max_120_month"]
    assert (await a.req("GET", "/v1/billing/subscription")).json() == {"plan_id": "free", "status": "active",
                                                                     "renews_at": None}
    assert (await a.req("POST", "/v1/billing/purchase", json={"plan_id": "gold"})).status_code == 400
    sub = (await a.req("POST", "/v1/billing/purchase", json={"plan_id": "plus_10_month"})).json()
    assert sub["status"] == "active" and sub["renews_at"]
    assert (await a.req("GET", "/v1/account/storage")).json()["limit_bytes"] == 10_000_000_000
    cancelled = (await a.req("POST", "/v1/billing/cancel", json={})).json()
    assert cancelled["status"] == "cancelled"
    assert (await a.req("GET", "/v1/account/storage")).json()["limit_bytes"] == 10_000_000_000  # until renews_at

    settings.allow_test_purchases = False
    r = await a.req("POST", "/v1/billing/purchase", json={"plan_id": "pro_25_month"})
    assert r.status_code == 400
