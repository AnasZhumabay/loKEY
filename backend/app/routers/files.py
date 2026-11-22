"""/v1/files, /v1/cases/{id}/files, /v1/trash/files, blobs, versions."""
import uuid

from fastapi import APIRouter, Header, Request, Response
from fastapi.responses import StreamingResponse
from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert

from app.core.config import get_settings
from app.core.errors import Conflict, IntegrityFailed, NotFound, ValidationFailed
from app.deps import DB, CurrentAuth, IfMatch, Storage, device_from, ip_hint
from app.models import Case, File, FileVersion
from app.routers.cases import delete_blobs
from app.schemas.dto import FileRecordDTO, FileVersionDTO, ReplaceFileRequest
from app.schemas.types import precise_now, utcnow
from app.services import audit
from app.services.vault import ensure_quota, get_case, get_file

router = APIRouter(tags=["files"])

MAX_METADATA = 2 * 1024 * 1024


def file_dto(f: File) -> FileRecordDTO:
    return FileRecordDTO.model_validate(f)


def new_blob_key(file_id: str) -> str:
    return f"files/{file_id.lower()}/{uuid.uuid4().hex}"


def _check_metadata(meta: bytes) -> None:
    if not meta or len(meta) > MAX_METADATA:
        raise ValidationFailed("Неверный размер sealed_metadata")


def _audit(db, auth, request, kind, case_id):
    audit.record(db, auth.user.id, kind, case_id=case_id, device_name=auth.session.device_name,
                 ip_hint=ip_hint(device_from(request).ip))


# ───────── lists ─────────

@router.get("/v1/cases/{case_id}/files", response_model=list[FileRecordDTO])
async def list_files(case_id: str, auth: CurrentAuth, db: DB):
    await get_case(db, auth.user.id, case_id)
    rows = await db.execute(select(File).where(File.case_id == case_id, File.deleted_at.is_(None))
                            .order_by(File.created_at, File.id))
    return [file_dto(f) for f in rows.scalars()]


@router.get("/v1/trash/files", response_model=list[FileRecordDTO])
async def list_trash(auth: CurrentAuth, db: DB):
    """Trash of the user's own cases (members of shared cases don't see the owner's trash)."""
    rows = await db.execute(select(File).join(Case, Case.id == File.case_id)
                            .where(Case.owner_id == auth.user.id, File.deleted_at.is_not(None))
                            .order_by(File.deleted_at.desc(), File.id))
    return [file_dto(f) for f in rows.scalars()]


# ───────── create / update ─────────

@router.post("/v1/files", response_model=FileRecordDTO)
async def create_file(body: FileRecordDTO, auth: CurrentAuth, request: Request, db: DB, response: Response):
    _check_metadata(body.sealed_metadata)
    existing = await db.get(File, body.id)
    if existing is not None:  # idempotent repeat
        await get_case(db, auth.user.id, existing.case_id)
        response.status_code = 200
        return file_dto(existing)

    case = await get_case(db, auth.user.id, body.case_id, write=True, lock=True)
    await ensure_quota(db, case.owner_id, body.ciphertext_size)
    now = utcnow()
    result = await db.execute(
        insert(File).values(id=body.id, case_id=case.id, sealed_metadata=body.sealed_metadata,
                            ciphertext_size=body.ciphertext_size, ciphertext_sha256=body.ciphertext_sha256,
                            blob_key=None, revision=1, created_at=now, updated_at=now, content_at=precise_now(),
                            deleted_at=None)
        .on_conflict_do_nothing(index_elements=[File.id]))
    if result.rowcount == 1:
        _audit(db, auth, request, "fileAdded", case.id)
    await db.commit()
    f = await db.get(File, body.id)
    response.status_code = 201 if result.rowcount == 1 else 200
    return file_dto(f)


@router.put("/v1/files/{file_id}", response_model=FileRecordDTO)
async def update_file(file_id: str, body: FileRecordDTO, expected: IfMatch, auth: CurrentAuth, db: DB):
    """Only sealed_metadata changes (rename, note, flags...)."""
    f, _ = await get_file(db, auth.user.id, file_id, write=True, lock=True)
    if f.revision != expected:
        raise Conflict()
    _check_metadata(body.sealed_metadata)
    f.sealed_metadata = body.sealed_metadata
    f.revision += 1
    f.updated_at = utcnow()
    await db.commit()
    return file_dto(f)


# ───────── blobs ─────────

@router.put("/v1/files/{file_id}/blob", status_code=204)
async def upload_blob(file_id: str, request: Request, auth: CurrentAuth, db: DB, storage: Storage,
                      x_content_sha256: str | None = Header(default=None)):
    f, _ = await get_file(db, auth.user.id, file_id, write=True)
    size, sha = f.ciphertext_size, f.ciphertext_sha256
    if not x_content_sha256 or x_content_sha256.strip().lower() != sha:
        raise IntegrityFailed()
    declared = request.headers.get("content-length")
    if declared is not None and declared.isdigit() and int(declared) != size:
        raise IntegrityFailed("Размер не совпал")
    await db.commit()  # don't keep a transaction open while the body streams in

    key = new_blob_key(file_id)
    await storage.put_verified(key, request.stream(), size=size, sha256=sha)

    f = await db.get(File, file_id, with_for_update=True, populate_existing=True)
    if f is None or f.ciphertext_sha256 != sha or f.ciphertext_size != size:
        await db.rollback()
        await storage.delete(key)  # content was replaced/deleted meanwhile
        raise Conflict()
    old_key, f.blob_key = f.blob_key, key
    await db.commit()
    if old_key and old_key != key:
        await delete_blobs(storage, [old_key])
    return Response(status_code=204)


async def _stream(storage, key: str, size: int) -> StreamingResponse:
    if not await storage.exists(key):
        raise NotFound()
    return StreamingResponse(storage.open_chunks(key), media_type="application/octet-stream",
                             headers={"Content-Length": str(size), "Cache-Control": "no-store"})


@router.get("/v1/files/{file_id}/blob", response_class=StreamingResponse)
async def download_blob(file_id: str, auth: CurrentAuth, db: DB, storage: Storage):
    f, _ = await get_file(db, auth.user.id, file_id)
    if f.blob_key is None:
        raise NotFound()
    return await _stream(storage, f.blob_key, f.ciphertext_size)


# ───────── trash ─────────

@router.post("/v1/files/{file_id}/trash", status_code=204)
async def trash_file(file_id: str, auth: CurrentAuth, request: Request, db: DB):
    f, case = await get_file(db, auth.user.id, file_id, write=True, lock=True)
    if f.deleted_at is None:
        now = utcnow()
        f.deleted_at, f.updated_at, f.revision = now, now, f.revision + 1
        _audit(db, auth, request, "fileTrashed", case.id)
        await db.commit()
    return Response(status_code=204)


@router.post("/v1/files/{file_id}/restore", response_model=FileRecordDTO)
async def restore_file(file_id: str, auth: CurrentAuth, request: Request, db: DB):
    f, case = await get_file(db, auth.user.id, file_id, write=True, lock=True)
    if f.deleted_at is not None:
        f.deleted_at, f.updated_at, f.revision = None, utcnow(), f.revision + 1
        _audit(db, auth, request, "fileRestored", case.id)
        await db.commit()
    return file_dto(f)


@router.delete("/v1/files/{file_id}", status_code=204)
async def purge_file(file_id: str, auth: CurrentAuth, db: DB, storage: Storage):
    f, _ = await get_file(db, auth.user.id, file_id, write=True, lock=True)
    keys = [f.blob_key] if f.blob_key else []
    keys += [k for (k,) in await db.execute(select(FileVersion.blob_key).where(FileVersion.file_id == file_id))]
    await db.execute(delete(File).where(File.id == file_id))
    await db.commit()
    await delete_blobs(storage, keys)
    return Response(status_code=204)


# ───────── versions (1.1.0) ─────────

@router.get("/v1/files/{file_id}/versions", response_model=list[FileVersionDTO])
async def list_versions(file_id: str, auth: CurrentAuth, db: DB):
    await get_file(db, auth.user.id, file_id)
    rows = await db.execute(select(FileVersion).where(FileVersion.file_id == file_id)
                            .order_by(FileVersion.created_at.desc(), FileVersion.id))
    return [FileVersionDTO.model_validate(v) for v in rows.scalars()]


def _snapshot(f: File) -> FileVersion | None:
    """The file's current state as a version (only if its blob exists — otherwise there is nothing to keep)."""
    if f.blob_key is None:
        return None
    return FileVersion(file_id=f.id, sealed_metadata=f.sealed_metadata, ciphertext_size=f.ciphertext_size,
                       ciphertext_sha256=f.ciphertext_sha256, blob_key=f.blob_key, created_at=f.content_at)


async def _prune_versions(db, file_id: str) -> list[str]:
    keep = get_settings().max_versions_per_file
    old = list((await db.execute(select(FileVersion).where(FileVersion.file_id == file_id)
                                 .order_by(FileVersion.created_at.desc(), FileVersion.id).offset(keep))).scalars())
    for v in old:
        await db.delete(v)
    return [v.blob_key for v in old]


@router.post("/v1/files/{file_id}/versions", response_model=FileRecordDTO)
async def replace_content(file_id: str, body: ReplaceFileRequest, auth: CurrentAuth, db: DB, storage: Storage):
    """Atomically: current state → version, new metadata/size/sha, revision+1. Then the client PUTs the blob."""
    f, case = await get_file(db, auth.user.id, file_id, write=True, lock=True)
    if f.revision != body.expected_revision:
        raise Conflict()
    _check_metadata(body.sealed_metadata)
    await ensure_quota(db, case.owner_id, body.ciphertext_size)
    snap = _snapshot(f)
    if snap is not None:
        db.add(snap)
    now = utcnow()
    f.sealed_metadata, f.ciphertext_size, f.ciphertext_sha256 = (
        body.sealed_metadata, body.ciphertext_size, body.ciphertext_sha256)
    f.blob_key, f.content_at, f.updated_at, f.revision = None, precise_now(), now, f.revision + 1
    await db.flush()
    pruned = await _prune_versions(db, file_id)
    await db.commit()
    await delete_blobs(storage, pruned)
    return file_dto(f)


@router.get("/v1/file-versions/{version_id}/blob", response_class=StreamingResponse)
async def download_version_blob(version_id: str, auth: CurrentAuth, db: DB, storage: Storage):
    v = await db.get(FileVersion, version_id)
    if v is None:
        raise NotFound()
    await get_file(db, auth.user.id, v.file_id)
    return await _stream(storage, v.blob_key, v.ciphertext_size)


@router.post("/v1/files/{file_id}/versions/{version_id}/restore", response_model=FileRecordDTO)
async def restore_version(file_id: str, version_id: str, auth: CurrentAuth, db: DB):
    """Swap the current state and the chosen version."""
    f, _ = await get_file(db, auth.user.id, file_id, write=True, lock=True)
    v = await db.get(FileVersion, version_id, with_for_update=True)
    if v is None or v.file_id != f.id:
        raise NotFound()
    now = utcnow()
    current = _snapshot(f)
    f.sealed_metadata, f.ciphertext_size, f.ciphertext_sha256, f.blob_key = (
        v.sealed_metadata, v.ciphertext_size, v.ciphertext_sha256, v.blob_key)
    f.content_at, f.updated_at, f.revision = precise_now(), now, f.revision + 1
    if current is not None:
        v.sealed_metadata, v.ciphertext_size, v.ciphertext_sha256, v.blob_key, v.created_at = (
            current.sealed_metadata, current.ciphertext_size, current.ciphertext_sha256, current.blob_key,
            current.created_at)
    else:
        await db.delete(v)  # current had no blob yet: nothing to swap back
    await db.commit()
    return file_dto(f)

