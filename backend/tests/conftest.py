"""Test setup: real Postgres (database lokey_test from docker compose), temp blob dir, clean state per test.

    docker compose up -d db && .venv/bin/pytest -q
"""
import base64
import hashlib
import os
import secrets
import tempfile
import uuid
from pathlib import Path

from dotenv import dotenv_values


def _test_db_url() -> str:
    """LOKEY_TEST_DATABASE_URL from the environment or backend/.env (no password lives in the code)."""
    url = os.environ.get("LOKEY_TEST_DATABASE_URL") or dotenv_values(Path(__file__).parent.parent / ".env").get(
        "LOKEY_TEST_DATABASE_URL")
    if not url:
        raise SystemExit("LOKEY_TEST_DATABASE_URL is not set — run: sh scripts/init-env.sh")
    # Tests TRUNCATE every table: refuse anything that isn't a *_test database.
    if not url.rsplit("/", 1)[-1].split("?")[0].endswith("_test"):
        raise SystemExit(f"Refusing to run tests against a non-test database: {url.rsplit('@', 1)[-1]}")
    return url


os.environ["LOKEY_ENV"] = "test"
os.environ["LOKEY_DATABASE_URL"] = _test_db_url()  # override: never the dev DB from .env
os.environ.setdefault("LOKEY_SECRET_KEY", secrets.token_urlsafe(48))
os.environ.setdefault("LOKEY_BLOB_DIR", tempfile.mkdtemp(prefix="lokey-test-blobs-"))

import httpx  # noqa: E402
import pytest  # noqa: E402
from sqlalchemy import text  # noqa: E402

import app.models  # noqa: E402,F401
from app.core.config import get_settings  # noqa: E402
from app.core.ratelimit import limiter  # noqa: E402
from app.db import Base, engine  # noqa: E402
from app.main import create_app  # noqa: E402

_schema_ready = False


@pytest.fixture(autouse=True)
async def clean_db():
    global _schema_ready
    async with engine.begin() as conn:
        if not _schema_ready:
            await conn.run_sync(Base.metadata.drop_all)
            await conn.run_sync(Base.metadata.create_all)
            _schema_ready = True
        else:
            tables = ", ".join(t.name for t in Base.metadata.sorted_tables)
            await conn.execute(text(f"TRUNCATE {tables} RESTART IDENTITY CASCADE"))
    limiter.clear()
    yield


@pytest.fixture
def settings(monkeypatch):
    """Mutable settings for a test (monkeypatch restores them afterwards)."""
    s = get_settings()

    class _S:
        def __getattr__(self, k):
            return getattr(s, k)

        def __setattr__(self, k, v):
            monkeypatch.setattr(s, k, v)
    return _S()


@pytest.fixture
async def client():
    transport = httpx.ASGITransport(app=create_app(), raise_app_exceptions=False)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


# ───────── helpers ─────────

def uid() -> str:
    return str(uuid.uuid4())


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode()


def sha(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def bearer(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


class User:
    def __init__(self, client, session: dict, password: str):
        self.c, self.session, self.password = client, session, password
        self.id = session["account"]["id"]
        self.username = session["account"]["username"]
        self.email = session["account"]["email"]

    @property
    def h(self) -> dict:
        return bearer(self.session["access_token"])

    async def req(self, method, path, **kw):
        headers = {**self.h, **kw.pop("headers", {})}
        return await self.c.request(method, path, headers=headers, **kw)

    async def create_case(self, case_id=None) -> dict:
        case_id = case_id or uid()
        r = await self.req("POST", "/v1/cases", json={"id": case_id, "sealed_header": b64(b"hdr"),
                                                      "recovery_wrapped_key": b64(b"rk")})
        assert r.status_code in (200, 201), r.text
        return r.json()

    async def add_file(self, case_id: str, data: bytes = b"ciphertext", upload=True) -> dict:
        r = await self.req("POST", "/v1/files", json={"id": uid(), "case_id": case_id, "sealed_metadata": b64(b"m"),
                                                      "ciphertext_size": len(data), "ciphertext_sha256": sha(data)})
        assert r.status_code in (200, 201), r.text
        if upload:
            u = await self.req("PUT", f"/v1/files/{r.json()['id']}/blob", content=data,
                               headers={"X-Content-SHA256": sha(data)})
            assert u.status_code == 204, u.text
        return r.json()


@pytest.fixture
def register(client):
    async def _register(name: str | None = None, password: str = "correct-horse", **headers) -> User:
        name = name or "u" + uuid.uuid4().hex[:8]
        r = await client.post("/v1/auth/register", json={"email": f"{name}@example.com", "username": name,
                                                          "password": password}, headers=headers)
        assert r.status_code == 200, r.text
        return User(client, r.json(), password)
    return _register
