"""Blob storage for ciphertext (file blobs, versions, backups).

The server never looks inside blobs. Uploads are streamed to a temp file while SHA-256 and size are
computed; the blob becomes visible only if both match what the client declared (else 422).
`BlobStorage` is the seam: LocalBlobStorage now, an S3/MinIO class later with the same methods.
"""
import hashlib
import os
import re
import uuid
from collections.abc import AsyncIterator
from pathlib import Path
from typing import Protocol

import anyio

from app.core.errors import IntegrityFailed

_KEY_RE = re.compile(r"^[a-z0-9][a-z0-9/_-]{0,200}$")
CHUNK = 1 << 20  # 1 MiB


class BlobStorage(Protocol):
    async def put_verified(self, key: str, chunks: AsyncIterator[bytes], *, size: int, sha256: str) -> None: ...
    def open_chunks(self, key: str) -> AsyncIterator[bytes]: ...
    async def exists(self, key: str) -> bool: ...
    async def delete(self, key: str) -> None: ...


class LocalBlobStorage:
    def __init__(self, root: str | os.PathLike):
        self.root = Path(root).resolve()
        self.tmp = self.root / ".tmp"
        self.tmp.mkdir(parents=True, exist_ok=True)

    def _path(self, key: str) -> Path:
        if not _KEY_RE.match(key) or ".." in key:
            raise ValueError(f"bad blob key: {key!r}")
        return self.root / key

    async def put_verified(self, key: str, chunks: AsyncIterator[bytes], *, size: int, sha256: str) -> None:
        dest = self._path(key)
        tmp = self.tmp / uuid.uuid4().hex
        h, written = hashlib.sha256(), 0
        try:
            async with await anyio.open_file(tmp, "wb") as f:
                async for chunk in chunks:
                    written += len(chunk)
                    if written > size:  # stop early, don't let a client fill the disk
                        raise IntegrityFailed("Размер не совпал")
                    h.update(chunk)
                    await f.write(chunk)
            if written != size:
                raise IntegrityFailed("Размер не совпал")
            if h.hexdigest() != sha256:
                raise IntegrityFailed()
            await anyio.to_thread.run_sync(lambda: dest.parent.mkdir(parents=True, exist_ok=True))
            await anyio.to_thread.run_sync(os.replace, tmp, dest)  # atomic on the same filesystem
        finally:
            tmp.unlink(missing_ok=True)

    async def open_chunks(self, key: str) -> AsyncIterator[bytes]:
        async with await anyio.open_file(self._path(key), "rb") as f:
            while chunk := await f.read(CHUNK):
                yield chunk

    async def exists(self, key: str) -> bool:
        return await anyio.to_thread.run_sync(self._path(key).is_file)

    async def delete(self, key: str) -> None:
        await anyio.to_thread.run_sync(lambda: self._path(key).unlink(missing_ok=True))
