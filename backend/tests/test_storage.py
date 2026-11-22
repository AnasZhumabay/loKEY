import hashlib
import os

import pytest

from app.core.errors import IntegrityFailed
from app.storage import LocalBlobStorage


async def _chunks(data: bytes, size: int = 7):
    for i in range(0, len(data), size):
        yield data[i:i + size]


@pytest.fixture
def store(tmp_path):
    return LocalBlobStorage(tmp_path)


async def test_put_and_read_back(store):
    data = os.urandom(1000)
    await store.put_verified("files/abc", _chunks(data), size=len(data), sha256=hashlib.sha256(data).hexdigest())
    assert await store.exists("files/abc")
    got = b"".join([c async for c in store.open_chunks("files/abc")])
    assert got == data


@pytest.mark.parametrize("mutate", [
    lambda d, s: (d, "0" * 64),           # wrong hash
    lambda d, s: (d[:-1], s),             # too short
    lambda d, s: (d + b"x", s),           # too long
])
async def test_mismatch_is_422_and_leaves_nothing(store, mutate):
    data = os.urandom(100)
    body, sha = mutate(data, hashlib.sha256(data).hexdigest())
    with pytest.raises(IntegrityFailed):
        await store.put_verified("files/x", _chunks(body), size=len(data), sha256=sha)
    assert not await store.exists("files/x")
    assert list(store.tmp.iterdir()) == []


async def test_failed_reupload_keeps_previous_blob(store):
    data = b"original"
    await store.put_verified("files/k", _chunks(data), size=len(data), sha256=hashlib.sha256(data).hexdigest())
    with pytest.raises(IntegrityFailed):
        await store.put_verified("files/k", _chunks(b"evil!!!!"), size=8, sha256=hashlib.sha256(data).hexdigest())
    assert b"".join([c async for c in store.open_chunks("files/k")]) == data


@pytest.mark.parametrize("key", ["../etc/passwd", "/abs", "a/../../b", "UPPER", ""])
async def test_rejects_unsafe_keys(store, key):
    with pytest.raises(ValueError):
        await store.exists(key)


async def test_delete_is_idempotent(store):
    await store.delete("files/missing")
