"""/v1/cases — list, create (idempotent), update (If-Match), purge."""
import logging

from fastapi import APIRouter, Response
from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert

from app.core.errors import Conflict, Forbidden, ValidationFailed
from app.deps import DB, CurrentAuth, IfMatch, Storage
from app.models import Case, CaseMember, File, FileVersion
from app.schemas.dto import CaseRecordDTO
from app.schemas.types import utcnow
from app.services.vault import case_stats, get_case

router = APIRouter(prefix="/v1/cases", tags=["cases"])
log = logging.getLogger("lokey.cases")

MAX_HEADER = 256 * 1024
MAX_RECOVERY = 16 * 1024


def case_dto(c: Case, stats: tuple[int, int]) -> CaseRecordDTO:
    return CaseRecordDTO(id=c.id, sealed_header=c.sealed_header, recovery_wrapped_key=c.recovery_wrapped_key,
                         file_count=stats[0], storage_bytes=stats[1], revision=c.revision,
                         created_at=c.created_at, updated_at=c.updated_at, deleted_at=None)


async def case_dto_for(db, c: Case) -> CaseRecordDTO:
    return case_dto(c, (await case_stats(db, [c.id]))[c.id])


def _check_sizes(body: CaseRecordDTO) -> None:
    if not body.sealed_header or len(body.sealed_header) > MAX_HEADER:
        raise ValidationFailed("Неверный размер sealed_header")
    if body.recovery_wrapped_key is not None and len(body.recovery_wrapped_key) > MAX_RECOVERY:
        raise ValidationFailed("Неверный размер recovery_wrapped_key")


@router.get("", response_model=list[CaseRecordDTO])
async def list_cases(auth: CurrentAuth, db: DB):
    """Own cases + shared cases where the user is an active member (1.3.0)."""
    shared = select(CaseMember.case_id).where(CaseMember.user_id == auth.user.id, CaseMember.status == "active")
    cases = list((await db.execute(
        select(Case).where((Case.owner_id == auth.user.id) | Case.id.in_(shared)).order_by(Case.created_at, Case.id)
    )).scalars())
    stats = await case_stats(db, [c.id for c in cases])
    return [case_dto(c, stats[c.id]) for c in cases]


@router.post("", response_model=CaseRecordDTO)
async def create_case(body: CaseRecordDTO, auth: CurrentAuth, db: DB, response: Response):
    _check_sizes(body)
    now = utcnow()
    result = await db.execute(
        insert(Case).values(id=body.id, owner_id=auth.user.id, sealed_header=body.sealed_header,
                            recovery_wrapped_key=body.recovery_wrapped_key, revision=1, created_at=now, updated_at=now)
        .on_conflict_do_nothing(index_elements=[Case.id]))
    await db.commit()
    case = await db.get(Case, body.id)
    if case.owner_id != auth.user.id:
        raise Forbidden()
    response.status_code = 201 if result.rowcount == 1 else 200  # repeat POST returns the existing record
    return await case_dto_for(db, case)


@router.put("/{case_id}", response_model=CaseRecordDTO)
async def update_case(case_id: str, body: CaseRecordDTO, expected: IfMatch, auth: CurrentAuth, db: DB):
    """Only sealed_header and recovery_wrapped_key change. An absent recovery key keeps the stored one
    (Swift omits nil keys, so absence can't mean "delete")."""
    case = await get_case(db, auth.user.id, case_id, owner_only=True, lock=True)
    if case.revision != expected:
        raise Conflict()
    _check_sizes(body)
    case.sealed_header = body.sealed_header
    if body.recovery_wrapped_key is not None:
        case.recovery_wrapped_key = body.recovery_wrapped_key
    case.revision += 1
    case.updated_at = utcnow()
    await db.commit()
    return await case_dto_for(db, case)


@router.delete("/{case_id}", status_code=204)
async def purge_case(case_id: str, auth: CurrentAuth, db: DB, storage: Storage):
    """Forever: the case, its files, versions and blobs (cascade)."""
    await get_case(db, auth.user.id, case_id, owner_only=True, lock=True)
    file_keys = (await db.execute(select(File.blob_key).where(File.case_id == case_id, File.blob_key.is_not(None))))
    version_keys = await db.execute(
        select(FileVersion.blob_key).join(File, File.id == FileVersion.file_id).where(File.case_id == case_id))
    keys = [k for (k,) in file_keys] + [k for (k,) in version_keys]
    await db.execute(delete(Case).where(Case.id == case_id))
    await db.commit()
    await delete_blobs(storage, keys)
    return Response(status_code=204)


async def delete_blobs(storage, keys) -> None:
    """After the DB commit. A failure leaves an unreferenced blob, never a dangling DB row."""
    for k in keys:
        try:
            await storage.delete(k)
        except Exception:
            log.exception("failed to delete blob")
