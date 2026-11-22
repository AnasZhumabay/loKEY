"""Passwords, tokens, MFA secrets.

* Passwords: argon2id (slow on purpose; run in a thread so the event loop isn't blocked).
* Tokens: opaque random strings. The DB stores only SHA-256(token), so a DB leak doesn't leak sessions,
  and revoking a session = deleting its row (takes effect immediately).
* TOTP secrets: encrypted at rest with AES-GCM under a key derived from LOKEY_SECRET_KEY.
"""
import hashlib
import hmac
import os
import secrets

import anyio
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from app.core.config import get_settings

_ph = PasswordHasher()  # argon2id, library defaults (RFC 9106 low-memory profile)
_DUMMY_HASH = _ph.hash("timing-equaliser-not-a-real-password")


async def hash_password(password: str) -> str:
    return await anyio.to_thread.run_sync(_ph.hash, password)


async def verify_password(stored_hash: str | None, password: str) -> bool:
    """Constant-ish time: an unknown user still costs one argon2 verify."""
    def _verify() -> bool:
        try:
            return _ph.verify(stored_hash or _DUMMY_HASH, password) and stored_hash is not None
        except (VerifyMismatchError, VerificationError, InvalidHashError):
            return False
    return await anyio.to_thread.run_sync(_verify)


def new_token() -> str:
    return secrets.token_urlsafe(32)  # 256 bits


def token_hash(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def safe_equal(a: str, b: str) -> bool:
    return hmac.compare_digest(a.encode(), b.encode())


def _mfa_key() -> bytes:
    return hashlib.sha256(b"lokey/mfa-secret/v1:" + get_settings().secret_key.encode()).digest()


def seal_secret(plain: str) -> bytes:
    nonce = os.urandom(12)
    return nonce + AESGCM(_mfa_key()).encrypt(nonce, plain.encode(), b"lokey-mfa")


def open_secret(sealed: bytes) -> str:
    return AESGCM(_mfa_key()).decrypt(sealed[:12], sealed[12:], b"lokey-mfa").decode()
