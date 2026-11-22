"""1.3.0 server backups: one opaque `.lokeybackup` file per backup (never parsed)."""
import json
import uuid

from fastapi import APIRouter, Header, Request, Response
from fastapi.responses import StreamingResponse
from pydantic import ValidationError
from sqlalchemy import select

from app.core.errors import IntegrityFailed, NotFound, ValidationFailed
from app.deps import DB, CurrentAuth, Storage
from app.models import Backup
from app.routers.cases import delete_blobs
from app.schemas.dto import BackupInfoDTO
from app.services.vault import ensure_quota

router = APIRouter(prefix="/v1/backups", tags=["backups (1.3.0)"])

MAX_BACKUPS_PER_USER = 10


@router.get("", response_model=list[BackupInfoDTO])
async def list_backups(auth: CurrentAuth, db: DB):
    rows = await db.execute(select(Backup).where(Backup.user_id == auth.user.id)
                            .order_by(Backup.created_at.desc(), Backup.id))
    return [BackupInfoDTO.model_validate(b) for b in rows.scalars()]


async def _own(db, user_id: str, backup_id: str, lock: bool = False) -> Backup:
    b = await db.get(Backup, backup_id, with_for_update=lock)
    if b is None or b.user_id != user_id:
        raise NotFound()
    return b


@router.put("/{backup_id}", status_code=204)
async def upload_backup(backup_id: str, request: Request, auth: CurrentAuth, db: DB, storage: Storage,
                        x_lk_info: str | None = Header(default=None), x_lk_sha256: str | None = Header(default=None)):
    try:
        info = BackupInfoDTO.model_validate(json.loads(x_lk_info or ""))
    except (ValueError, ValidationError):
        raise ValidationFailed("Неверный заголовок X-LK-Info") from None
    if info.id != backup_id:
        raise IntegrityFailed("id не совпал")
    if not x_lk_sha256 or x_lk_sha256.strip().lower() != info.sha256:
        raise IntegrityFailed()
    declared = request.headers.get("content-length")
    if declared is not None and declared.isdigit() and int(declared) != info.size_bytes:
        raise IntegrityFailed("Размер не совпал")

    existing = await db.get(Backup, backup_id)
    if existing is not None and existing.user_id != auth.user.id:
        raise NotFound()
    await ensure_quota(db, auth.user.id, info.size_bytes - (existing.size_bytes if existing else 0))
    await db.commit()  # release the lock before the (possibly large) body streams in

    key = f"backups/{auth.user.id}/{uuid.uuid4().hex}"
    await storage.put_verified(key, request.stream(), size=info.size_bytes, sha256=info.sha256)

    b = await db.get(Backup, backup_id, with_for_update=True, populate_existing=True)
    old_keys = []
    if b is None:
        b = Backup(id=backup_id, user_id=auth.user.id)
        db.add(b)
    elif b.user_id != auth.user.id:
        await db.rollback()
        await storage.delete(key)
        raise NotFound()
    else:
        old_keys.append(b.blob_key)
    b.size_bytes, b.sha256, b.device_name, b.app_version, b.format_version, b.created_at, b.blob_key = (
        info.size_bytes, info.sha256, info.device_name, info.app_version, info.format_version, info.created_at, key)
    await db.flush()
    # Keep the newest N backups; older ones are dropped (and stop counting against the quota).
    extra = list((await db.execute(select(Backup).where(Backup.user_id == auth.user.id)
                                   .order_by(Backup.created_at.desc(), Backup.id).offset(MAX_BACKUPS_PER_USER))
                  ).scalars())
    for old in extra:
        old_keys.append(old.blob_key)
        await db.delete(old)
    await db.commit()
    await delete_blobs(storage, [k for k in old_keys if k and k != key])
    return Response(status_code=204)


@router.get("/{backup_id}/blob", response_class=StreamingResponse)
async def download_backup(backup_id: str, auth: CurrentAuth, db: DB, storage: Storage):
    b = await _own(db, auth.user.id, backup_id)
    if not await storage.exists(b.blob_key):
        raise NotFound()
    return StreamingResponse(storage.open_chunks(b.blob_key), media_type="application/octet-stream",
                             headers={"Content-Length": str(b.size_bytes), "Cache-Control": "no-store"})


@router.delete("/{backup_id}", status_code=204)
async def delete_backup(backup_id: str, auth: CurrentAuth, db: DB, storage: Storage):
    b = await _own(db, auth.user.id, backup_id, lock=True)
    key = b.blob_key
    await db.delete(b)
    await db.commit()
    await delete_blobs(storage, [key])
    return Response(status_code=204)
