"""Database tables.

Ciphertext columns (sealed_*, *_ciphertext, wrapped keys) are opaque bytes: never parsed, never logged.
Ids of cases/files/messages/backups/groups come from the client; users/sessions/versions/audit ids are ours.
"""
import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    ForeignKey,
    Identity,
    Index,
    Integer,
    LargeBinary,
    String,
    UniqueConstraint,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base

TS = DateTime(timezone=True)
ID = String(64)


def new_id() -> str:
    return str(uuid.uuid4())


# ───────────────────────── accounts & auth ─────────────────────────

class User(Base):
    __tablename__ = "users"
    id: Mapped[str] = mapped_column(ID, primary_key=True, default=new_id)
    email: Mapped[str] = mapped_column(String(320))
    username: Mapped[str] = mapped_column(String(64))
    password_hash: Mapped[str] = mapped_column(String(256))
    backup_email: Mapped[str | None] = mapped_column(String(320))
    mfa_enabled: Mapped[bool] = mapped_column(Boolean, default=False)
    mfa_method: Mapped[str | None] = mapped_column(String(16))
    mfa_secret_sealed: Mapped[bytes | None] = mapped_column(LargeBinary)  # AES-GCM, see core/security.py
    mfa_last_step: Mapped[int | None] = mapped_column(BigInteger)  # last accepted TOTP time-step (anti-replay)
    chat_identity_key: Mapped[bytes | None] = mapped_column(LargeBinary)  # X25519 public key, 32 bytes
    created_at: Mapped[datetime] = mapped_column(TS)

    __table_args__ = (
        Index("ux_users_email_lower", func.lower(email), unique=True),
        Index("ux_users_username_lower", func.lower(username), unique=True),
    )


class AuthSession(Base):
    """One row per signed-in device. Deleting the row revokes it."""
    __tablename__ = "auth_sessions"
    id: Mapped[str] = mapped_column(ID, primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    access_hash: Mapped[str] = mapped_column(String(64), unique=True)
    access_expires_at: Mapped[datetime] = mapped_column(TS)
    refresh_hash: Mapped[str] = mapped_column(String(64), unique=True)
    prev_refresh_hash: Mapped[str | None] = mapped_column(String(64), index=True)  # reuse detection
    refresh_expires_at: Mapped[datetime] = mapped_column(TS)
    device_name: Mapped[str] = mapped_column(String(128))
    platform: Mapped[str] = mapped_column(String(32))
    app_version: Mapped[str | None] = mapped_column(String(64))
    ip: Mapped[str | None] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(TS)
    last_active_at: Mapped[datetime] = mapped_column(TS)


class MFAChallenge(Base):
    __tablename__ = "mfa_challenges"
    id: Mapped[str] = mapped_column(ID, primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    attempts: Mapped[int] = mapped_column(Integer, default=0)
    expires_at: Mapped[datetime] = mapped_column(TS)
    device_name: Mapped[str] = mapped_column(String(128))
    platform: Mapped[str] = mapped_column(String(32))
    app_version: Mapped[str | None] = mapped_column(String(64))


class Subscription(Base):
    __tablename__ = "subscriptions"
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    plan_id: Mapped[str] = mapped_column(String(64))
    status: Mapped[str] = mapped_column(String(16))  # active | cancelled | expired
    renews_at: Mapped[datetime | None] = mapped_column(TS)
    apple_transaction: Mapped[str | None] = mapped_column(String(8192))
    updated_at: Mapped[datetime] = mapped_column(TS)


class AuditEvent(Base):
    __tablename__ = "audit_events"
    id: Mapped[str] = mapped_column(ID, primary_key=True, default=new_id)
    seq: Mapped[int] = mapped_column(BigInteger, Identity(), unique=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    kind: Mapped[str] = mapped_column(String(32))
    case_id: Mapped[str | None] = mapped_column(ID)
    device_name: Mapped[str] = mapped_column(String(128))
    ip_hint: Mapped[str | None] = mapped_column(String(64))
    at: Mapped[datetime] = mapped_column(TS)

    __table_args__ = (Index("ix_audit_user_at", "user_id", "at"),)


# ───────────────────────── vault ─────────────────────────

class Case(Base):
    __tablename__ = "cases"
    id: Mapped[str] = mapped_column(ID, primary_key=True)
    owner_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    sealed_header: Mapped[bytes] = mapped_column(LargeBinary)
    recovery_wrapped_key: Mapped[bytes | None] = mapped_column(LargeBinary)
    revision: Mapped[int] = mapped_column(Integer, default=1)
    created_at: Mapped[datetime] = mapped_column(TS)
    updated_at: Mapped[datetime] = mapped_column(TS)


class File(Base):
    __tablename__ = "files"
    id: Mapped[str] = mapped_column(ID, primary_key=True)
    case_id: Mapped[str] = mapped_column(ForeignKey("cases.id", ondelete="CASCADE"), index=True)
    sealed_metadata: Mapped[bytes] = mapped_column(LargeBinary)
    ciphertext_size: Mapped[int] = mapped_column(BigInteger)
    ciphertext_sha256: Mapped[str] = mapped_column(String(64))
    blob_key: Mapped[str | None] = mapped_column(String(256))  # None until the blob is uploaded
    revision: Mapped[int] = mapped_column(Integer, default=1)
    created_at: Mapped[datetime] = mapped_column(TS)
    updated_at: Mapped[datetime] = mapped_column(TS)
    content_at: Mapped[datetime] = mapped_column(TS)  # when the current content became current
    deleted_at: Mapped[datetime | None] = mapped_column(TS, index=True)


class FileVersion(Base):
    __tablename__ = "file_versions"
    id: Mapped[str] = mapped_column(ID, primary_key=True, default=new_id)
    file_id: Mapped[str] = mapped_column(ForeignKey("files.id", ondelete="CASCADE"), index=True)
    sealed_metadata: Mapped[bytes] = mapped_column(LargeBinary)
    ciphertext_size: Mapped[int] = mapped_column(BigInteger)
    ciphertext_sha256: Mapped[str] = mapped_column(String(64))
    blob_key: Mapped[str] = mapped_column(String(256))
    created_at: Mapped[datetime] = mapped_column(TS)


# ───────────────────────── chat ─────────────────────────

class ChatMessage(Base):
    """Mailbox: one row per (envelope, recipient). Deleted on ack or after expires_at."""
    __tablename__ = "chat_messages"
    seq: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)  # delivery order
    id: Mapped[str] = mapped_column(ID)
    sender_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    recipient_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    version: Mapped[int] = mapped_column(Integer)
    ciphertext: Mapped[bytes] = mapped_column(LargeBinary)
    sent_at: Mapped[datetime] = mapped_column(TS)
    expires_at: Mapped[datetime] = mapped_column(TS, index=True)
    received_at: Mapped[datetime] = mapped_column(TS)

    __table_args__ = (
        UniqueConstraint("sender_id", "recipient_id", "id", name="ux_chat_dedup"),
        Index("ix_chat_recipient_seq", "recipient_id", "seq"),
    )


class ChatGroup(Base):
    __tablename__ = "chat_groups"
    id: Mapped[str] = mapped_column(ID, primary_key=True)
    creator_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    name_ciphertext: Mapped[bytes] = mapped_column(LargeBinary)
    created_at: Mapped[datetime] = mapped_column(TS)


class ChatGroupMember(Base):
    __tablename__ = "chat_group_members"
    group_id: Mapped[str] = mapped_column(ForeignKey("chat_groups.id", ondelete="CASCADE"), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True, index=True)
    position: Mapped[int] = mapped_column(Integer, default=0)  # keeps member_ids order stable


# ───────────────────────── 1.3.0: shared cases, backups, security events ─────────────────────────

class CaseMember(Base):
    """A non-owner's access to a case. The owner is implicit (cases.owner_id)."""
    __tablename__ = "case_members"
    case_id: Mapped[str] = mapped_column(ForeignKey("cases.id", ondelete="CASCADE"), primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True, index=True)
    invite_id: Mapped[str] = mapped_column(ID, unique=True, default=new_id)
    invited_by: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"))
    role: Mapped[str] = mapped_column(String(16))  # editor | viewer
    status: Mapped[str] = mapped_column(String(16))  # invited | active | revoked
    wrapped_key: Mapped[bytes] = mapped_column(LargeBinary)
    case_name_ciphertext: Mapped[bytes | None] = mapped_column(LargeBinary)
    created_at: Mapped[datetime] = mapped_column(TS)
    joined_at: Mapped[datetime | None] = mapped_column(TS)


class Backup(Base):
    __tablename__ = "backups"
    id: Mapped[str] = mapped_column(ID, primary_key=True)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    size_bytes: Mapped[int] = mapped_column(BigInteger)
    sha256: Mapped[str] = mapped_column(String(64))
    device_name: Mapped[str] = mapped_column(String(128))
    app_version: Mapped[str] = mapped_column(String(64))
    format_version: Mapped[int] = mapped_column(Integer)
    blob_key: Mapped[str] = mapped_column(String(256))
    created_at: Mapped[datetime] = mapped_column(TS)


class SecurityEvent(Base):
    """Kept apart from the audit log on purpose: `duressUnlock` must not show up where a coercer could see it."""
    __tablename__ = "security_events"
    id: Mapped[str] = mapped_column(ID, primary_key=True, default=new_id)
    user_id: Mapped[str] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    kind: Mapped[str] = mapped_column(String(32))
    case_id: Mapped[str | None] = mapped_column(ID)
    device_name: Mapped[str | None] = mapped_column(String(128))
    at: Mapped[datetime] = mapped_column(TS)
    received_at: Mapped[datetime] = mapped_column(TS)
