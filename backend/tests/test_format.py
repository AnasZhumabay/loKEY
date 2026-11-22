"""Wire format rules: dates without fractions, standard base64, ids, sha256."""
from datetime import UTC, datetime, timedelta, timezone

import pytest
from pydantic import ValidationError

from app.schemas.types import B64Bytes, ClientId, Schema, Sha256Hex, UTCDateTime


class Sample(Schema):
    id: ClientId
    at: UTCDateTime
    blob: B64Bytes
    sha: Sha256Hex
    optional_at: UTCDateTime | None = None


GOOD = {
    "id": "c0000000-0000-4000-8000-000000000001",
    "at": "2025-01-15T10:30:00Z",
    "blob": "3q2+7w==",
    "sha": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
}


def test_roundtrip_matches_contract():
    m = Sample.model_validate(GOOD)
    assert m.blob == bytes.fromhex("deadbeef")
    assert m.at == datetime(2025, 1, 15, 10, 30, tzinfo=UTC)
    assert m.model_dump(mode="json") == {**GOOD, "optional_at": None}


def test_dates_drop_fractions_and_convert_to_utc():
    m = Sample.model_validate({**GOOD, "at": "2025-01-15T15:30:00.987+05:00"})
    assert m.model_dump(mode="json")["at"] == "2025-01-15T10:30:00Z"
    m.at = datetime(2025, 1, 15, 10, 30, 0, 123456, tzinfo=timezone(timedelta(hours=3)))
    assert m.model_dump(mode="json")["at"] == "2025-01-15T07:30:00Z"


def test_bytes_from_db_are_kept_raw():
    m = Sample.model_validate({**GOOD, "blob": b"\x00\xff"})
    assert m.model_dump(mode="json")["blob"] == "AP8="


@pytest.mark.parametrize("field,value", [
    ("at", "2025-01-15T10:30:00"),          # naive date: timezone is required
    ("blob", "not base64!"),
    ("blob", "3q2+7w"),                     # missing padding
    ("id", "../../etc/passwd"),
    ("sha", "E3B0" + "0" * 60),            # uppercase hex
    ("sha", "abc"),
])
def test_rejects_bad_values(field, value):
    with pytest.raises(ValidationError):
        Sample.model_validate({**GOOD, field: value})


def test_uppercase_uuid_accepted_as_is():
    # BackupServiceImpl sends UUID().uuidString (uppercase); keep it unchanged.
    up = "C0000000-0000-4000-8000-00000000000A"
    assert Sample.model_validate({**GOOD, "id": up}).id == up


def test_unknown_keys_ignored():
    assert Sample.model_validate({**GOOD, "revision": 0, "file_count": 3}).id == GOOD["id"]
