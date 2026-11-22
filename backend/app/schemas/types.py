"""Wire-format rules of the contract (LKCoding in Contract/APIModels.swift).

* Dates: ISO-8601 UTC WITHOUT fractional seconds, e.g. 2025-01-15T10:30:00Z
  (Swift's `.iso8601` strategy rejects fractions, so this is not cosmetic).
* Data: standard base64 with padding.
* Keys: snake_case (Python field names already are); enum values stay camelCase as in Swift.
"""
import base64
import binascii
from datetime import UTC, datetime
from typing import Annotated, Any

from pydantic import (
    AfterValidator,
    AwareDatetime,
    BaseModel,
    ConfigDict,
    PlainSerializer,
    PlainValidator,
    StringConstraints,
    WithJsonSchema,
)


def utcnow() -> datetime:
    """Current time, UTC, truncated to whole seconds (what we store and send)."""
    return datetime.now(UTC).replace(microsecond=0)


def precise_now() -> datetime:
    """Full-precision UTC time, for ordering columns (still sent without fractions by UTCDateTime)."""
    return datetime.now(UTC)


def format_utc(dt: datetime) -> str:
    if dt.tzinfo is None:  # DB values without tz are UTC by convention
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _to_utc(dt: datetime) -> datetime:
    return dt.astimezone(UTC).replace(microsecond=0)


UTCDateTime = Annotated[
    AwareDatetime,
    AfterValidator(_to_utc),
    PlainSerializer(format_utc, return_type=str),
    WithJsonSchema({"type": "string", "format": "date-time", "example": "2025-01-15T10:30:00Z"}),
]


def _b64_decode(v: Any) -> bytes:
    if isinstance(v, bytes | bytearray | memoryview):  # already raw (e.g. loaded from the DB)
        return bytes(v)
    if not isinstance(v, str):
        raise ValueError("ожидалась строка base64")
    try:
        return base64.b64decode(v, validate=True)
    except (binascii.Error, ValueError) as e:
        raise ValueError("некорректный base64") from e


def _b64_encode(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


B64Bytes = Annotated[
    bytes,
    PlainValidator(_b64_decode),
    PlainSerializer(_b64_encode, return_type=str),
    WithJsonSchema({"type": "string", "format": "byte"}),
]

# Client-generated ids: UUID. The contract says lowercase, but the app's backup ids use
# `UUID().uuidString` (uppercase), so any case is accepted and stored exactly as sent.
ClientId = Annotated[
    str,
    StringConstraints(pattern=r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"),
]

# SHA-256 as lowercase hex.
Sha256Hex = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]


class Schema(BaseModel):
    """Base for all DTOs. Unknown keys from the client are ignored, ORM objects are accepted."""

    model_config = ConfigDict(from_attributes=True, extra="ignore")
