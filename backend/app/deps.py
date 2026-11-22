"""Shared request dependencies: current user/session, device info, blob storage, If-Match."""
import ipaddress
import re
from dataclasses import dataclass
from datetime import timedelta
from functools import lru_cache
from typing import Annotated

from fastapi import Depends, Header, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.errors import Conflict, Unauthorized, ValidationFailed
from app.core.security import token_hash
from app.db import get_session
from app.models import AuthSession, User
from app.schemas.types import utcnow
from app.storage import LocalBlobStorage

DB = Annotated[AsyncSession, Depends(get_session)]


@dataclass
class Auth:
    user: User
    session: AuthSession


async def current_auth(request: Request, db: DB) -> Auth:
    header = request.headers.get("authorization", "")
    scheme, _, token = header.partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise Unauthorized()
    now = utcnow()
    row = (await db.execute(
        select(AuthSession, User).join(User, User.id == AuthSession.user_id)
        .where(AuthSession.access_hash == token_hash(token.strip()))
    )).first()
    if row is None or row.AuthSession.access_expires_at <= now:
        raise Unauthorized()
    sess, user = row
    if now - sess.last_active_at > timedelta(seconds=60):  # don't write on every request
        sess.last_active_at = now
        await db.commit()
    return Auth(user=user, session=sess)


CurrentAuth = Annotated[Auth, Depends(current_auth)]


# ───────── device info ─────────
# The 1.3.0 client sends no device fields at login (LoginRequest = identifier + password), so we read optional
# X-Device-Name / X-Platform / X-App-Version headers if a future client adds them, else guess from User-Agent.
# iOS URLSession default UA: "loKEY/12 CFNetwork/1568.100.1 Darwin/24.0.0".

_UA_APP = re.compile(r"^([A-Za-z][\w.\-]*)/([\w.\-]+)")


@dataclass
class Device:
    name: str
    platform: str
    app_version: str | None
    ip: str | None


def device_from(request: Request) -> Device:
    h = request.headers
    ua = h.get("user-agent", "")
    apple = "CFNetwork" in ua or "Darwin" in ua
    m = _UA_APP.match(ua)
    name = h.get("x-device-name") or ("iPhone" if apple else (m.group(1) if m else "Неизвестное устройство"))
    platform = h.get("x-platform") or ("ios" if apple else "other")
    version = h.get("x-app-version") or (m.group(2) if (m and apple) else None)
    ip = request.client.host if request.client else None
    return Device(name=name[:128], platform=platform[:32].lower(), app_version=version[:64] if version else None, ip=ip)


def ip_hint(ip: str | None) -> str | None:
    """Coarse IP for the audit log: 203.0.113.x / 2001:db8:85a3::/48."""
    if not ip:
        return None
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return None
    if addr.version == 4:
        return ".".join(ip.split(".")[:3]) + ".x"
    return str(ipaddress.ip_network(f"{ip}/48", strict=False))


# ───────── storage ─────────

@lru_cache
def _storage() -> LocalBlobStorage:
    return LocalBlobStorage(get_settings().blob_dir)


def get_storage() -> LocalBlobStorage:
    return _storage()


Storage = Annotated[LocalBlobStorage, Depends(get_storage)]


# ───────── optimistic locking ─────────

def expected_revision(if_match: Annotated[str | None, Header(alias="If-Match")] = None) -> int:
    """`If-Match: 3` (also tolerates ETag style `"3"` / `W/"3"`). Missing header → 409, as the app expects."""
    if if_match is None:
        raise Conflict("Нужен заголовок If-Match")
    raw = if_match.strip().removeprefix("W/").strip('"')
    try:
        return int(raw)
    except ValueError:
        raise ValidationFailed("If-Match должен быть числом") from None


IfMatch = Annotated[int, Depends(expected_revision)]
