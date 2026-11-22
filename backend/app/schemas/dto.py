"""DTOs, field-for-field from loKEY/Contract/APIModels.swift and ContractV13.swift.

Python field names are already snake_case, which is exactly the wire format.
Enum values are camelCase strings like in Swift (they are NOT converted).
"""
from typing import Literal

from pydantic import Field

from app.schemas.types import B64Bytes, ClientId, Schema, Sha256Hex, UTCDateTime

MFAMethod = Literal["authenticator", "sms"]
AuditKind = Literal[
    "login", "logout", "loginFailed",
    "caseCreated", "caseUnlocked", "caseLocked", "unlockFailed", "caseDeleted",
    "fileAdded", "fileTrashed", "fileRestored",
    "keyRecovered", "mfaChanged",
]
CLIENT_AUDIT_KINDS = {"caseCreated", "caseDeleted", "caseUnlocked", "caseLocked", "unlockFailed", "keyRecovered"}
PlanPeriod = Literal["free", "month", "year"]
SubscriptionStatus = Literal["active", "cancelled", "expired"]
SharedRole = Literal["owner", "editor", "viewer"]
SharedMemberStatus = Literal["invited", "active", "revoked"]
SecurityEventKind = Literal["caseWiped", "duressUnlock", "tooManyAttempts", "backupCreated", "backupRestored"]


# ───────── account & auth ─────────

class AccountDTO(Schema):
    id: str
    email: str
    username: str
    backup_email: str | None = None
    mfa_enabled: bool
    created_at: UTCDateTime


class SessionDTO(Schema):
    access_token: str
    refresh_token: str
    expires_at: UTCDateTime
    account: AccountDTO


class RegisterRequest(Schema):
    email: str = Field(max_length=320)
    username: str = Field(max_length=64)
    password: str = Field(max_length=1024)


class LoginRequest(Schema):
    identifier: str = Field(max_length=320)
    password: str = Field(max_length=1024)


class LoginResponse(Schema):
    session: SessionDTO | None = None
    mfa_challenge_id: str | None = None


class MFAVerifyRequest(Schema):
    challenge_id: str = Field(max_length=64)
    code: str = Field(max_length=16)


class RefreshRequest(Schema):
    refresh_token: str = Field(max_length=256)


class EmailRequest(Schema):
    email: str = Field(max_length=320)


class BackupEmailRequest(Schema):
    backup_email: str | None = Field(default=None, max_length=320)


class MFARequest(Schema):
    enabled: bool
    method: MFAMethod = "authenticator"


class MFASetupDTO(Schema):
    method: MFAMethod
    otpauth_uri: str | None = None


class SessionInfoDTO(Schema):
    id: str
    device_name: str
    platform: str
    app_version: str | None = None
    approx_location: str | None = None
    created_at: UTCDateTime
    last_active_at: UTCDateTime
    is_current: bool


# ───────── vault ─────────

class CaseRecordDTO(Schema):
    id: ClientId
    sealed_header: B64Bytes
    recovery_wrapped_key: B64Bytes | None = None
    # Server-computed; whatever the client sends is ignored.
    file_count: int = 0
    storage_bytes: int = 0
    revision: int = 0
    created_at: UTCDateTime | None = None
    updated_at: UTCDateTime | None = None
    deleted_at: UTCDateTime | None = None


class FileRecordDTO(Schema):
    id: ClientId
    case_id: str = Field(max_length=64)
    sealed_metadata: B64Bytes
    ciphertext_size: int = Field(ge=0)
    ciphertext_sha256: Sha256Hex
    revision: int = 0
    created_at: UTCDateTime | None = None
    updated_at: UTCDateTime | None = None
    deleted_at: UTCDateTime | None = None


class CaseUsageDTO(Schema):
    case_id: str
    bytes: int


class StorageUsageDTO(Schema):
    used_bytes: int
    limit_bytes: int
    per_case: list[CaseUsageDTO]


class FileVersionDTO(Schema):
    id: str
    file_id: str
    sealed_metadata: B64Bytes
    ciphertext_size: int
    ciphertext_sha256: str
    created_at: UTCDateTime


class ReplaceFileRequest(Schema):
    sealed_metadata: B64Bytes
    ciphertext_size: int = Field(ge=0)
    ciphertext_sha256: Sha256Hex
    expected_revision: int


# ───────── audit & billing ─────────

class AuditEventDTO(Schema):
    id: str
    kind: AuditKind
    case_id: str | None = None
    device_name: str
    ip_hint: str | None = None
    at: UTCDateTime


class AuditRecordRequest(Schema):
    kind: AuditKind
    case_id: str | None = Field(default=None, max_length=64)


class PlanDTO(Schema):
    id: str
    title: str
    storage_bytes: int
    price_minor: int
    currency: str
    period: PlanPeriod


class SubscriptionDTO(Schema):
    plan_id: str
    status: SubscriptionStatus
    renews_at: UTCDateTime | None = None


class PurchaseRequest(Schema):
    plan_id: str = Field(max_length=64)
    apple_transaction: str | None = Field(default=None, max_length=8192)


# ───────── chat ─────────

class IdentityRequest(Schema):
    public_key: B64Bytes


class ChatUserDTO(Schema):
    id: str
    username: str
    identity_key: B64Bytes


class ChatEnvelopeDTO(Schema):
    id: ClientId
    sender_id: str = Field(max_length=64)
    recipient_id: str = Field(max_length=64)
    version: int = Field(ge=1)
    ciphertext: B64Bytes
    sent_at: UTCDateTime
    expires_at: UTCDateTime | None = None


class AckRequest(Schema):
    ids: list[str] = Field(max_length=1000)


# ───────── 1.3.0 ─────────

class InviteRequest(Schema):
    invitee_user_id: str = Field(max_length=64)
    wrapped_key_for_invitee: B64Bytes
    role: SharedRole
    case_name_ciphertext: B64Bytes | None = None  # optional extra, not sent by the 1.3.0 client


class CaseMemberDTO(Schema):
    user_id: str
    display_name: str
    role: SharedRole
    status: SharedMemberStatus
    joined_at: UTCDateTime | None = None


class CaseInviteDTO(Schema):
    id: str
    case_id: str
    case_name_ciphertext: B64Bytes | None = None
    from_user_id: str
    created_at: UTCDateTime


class WrappedKeyDTO(Schema):
    wrapped_key: B64Bytes


class BackupInfoDTO(Schema):
    id: ClientId
    created_at: UTCDateTime
    size_bytes: int = Field(ge=0)
    sha256: Sha256Hex
    device_name: str = Field(max_length=128)
    app_version: str = Field(max_length=64)
    format_version: int


class GroupDTO(Schema):
    id: ClientId
    name_ciphertext: B64Bytes
    member_ids: list[str] = Field(max_length=256)
    created_at: UTCDateTime


class GroupMemberRequest(Schema):
    user_id: str = Field(max_length=64)


class GroupEnvelopeDTO(Schema):
    id: ClientId
    group_id: str = Field(max_length=64)
    sender_id: str = Field(max_length=64)
    sent_at: UTCDateTime
    ciphertext: B64Bytes
    recipient_ids: list[str] = Field(max_length=256)


class SecurityEventDTO(Schema):
    kind: SecurityEventKind
    case_id: str | None = Field(default=None, max_length=64)
    at: UTCDateTime
    device_name: str | None = Field(default=None, max_length=128)
