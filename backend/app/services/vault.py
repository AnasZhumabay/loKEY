"""Case access rules and storage accounting.

Access: the owner can do everything. A shared-case member (1.3.0) with status `active` can read;
`editor` can also write files; `viewer` is read-only (enforced here, the client's crypto can't enforce it).
Usage: trash and old versions count (contract), and so do backups. Shared cases count for the owner.
"""
from collections import defaultdict

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import Forbidden, NotFound, QuotaExceeded
from app.models import Backup, Case, CaseMember, File, FileVersion, User
from app.services.billing import limit_bytes


async def member_role(db: AsyncSession, case_id: str, user_id: str) -> str | None:
    m = await db.get(CaseMember, (case_id, user_id))
    return m.role if m is not None and m.status == "active" else None


async def get_case(db: AsyncSession, user_id: str, case_id: str, *, write: bool = False,
                   owner_only: bool = False, lock: bool = False) -> Case:
    """Return the case if `user_id` may access it, else 404 (unknown) / 403 (visible but not allowed)."""
    stmt = select(Case).where(Case.id == case_id)
    if lock:
        stmt = stmt.with_for_update()
    case = (await db.execute(stmt)).scalar_one_or_none()
    if case is None:
        raise NotFound()
    if case.owner_id == user_id:
        return case
    role = await member_role(db, case_id, user_id)
    if role is None:
        raise NotFound()  # don't reveal that someone else's case exists
    if owner_only or (write and role != "editor"):
        raise Forbidden()
    return case


async def get_file(db: AsyncSession, user_id: str, file_id: str, *, write: bool = False,
                   lock: bool = False) -> tuple[File, Case]:
    stmt = select(File).where(File.id == file_id)
    if lock:
        stmt = stmt.with_for_update()
    f = (await db.execute(stmt)).scalar_one_or_none()
    if f is None:
        raise NotFound()
    case = await get_case(db, user_id, f.case_id, write=write)
    return f, case


async def case_stats(db: AsyncSession, case_ids: list[str]) -> dict[str, tuple[int, int]]:
    """case_id -> (file_count without trash, storage_bytes with trash and versions)."""
    if not case_ids:
        return {}
    out: dict[str, list[int]] = defaultdict(lambda: [0, 0])
    rows = await db.execute(
        select(File.case_id,
               func.count().filter(File.deleted_at.is_(None)),
               func.coalesce(func.sum(File.ciphertext_size), 0))
        .where(File.case_id.in_(case_ids)).group_by(File.case_id))
    for cid, count, size in rows:
        out[cid][0], out[cid][1] = int(count), int(size)
    rows = await db.execute(
        select(File.case_id, func.coalesce(func.sum(FileVersion.ciphertext_size), 0))
        .join(FileVersion, FileVersion.file_id == File.id)
        .where(File.case_id.in_(case_ids)).group_by(File.case_id))
    for cid, size in rows:
        out[cid][1] += int(size)
    return {cid: (out[cid][0], out[cid][1]) for cid in case_ids}


async def owned_case_ids(db: AsyncSession, user_id: str) -> list[str]:
    return list((await db.execute(select(Case.id).where(Case.owner_id == user_id))).scalars())


async def used_bytes(db: AsyncSession, user_id: str) -> tuple[int, dict[str, int]]:
    """Total used by the account + per owned case."""
    stats = await case_stats(db, await owned_case_ids(db, user_id))
    per_case = {cid: s[1] for cid, s in stats.items()}
    backups = (await db.execute(
        select(func.coalesce(func.sum(Backup.size_bytes), 0)).where(Backup.user_id == user_id))).scalar_one()
    return sum(per_case.values()) + int(backups), per_case


async def ensure_quota(db: AsyncSession, owner_id: str, extra_bytes: int) -> None:
    """Raise 413 if adding `extra_bytes` would exceed the owner's plan.

    Locks the owner's user row so two parallel uploads can't both squeeze under the limit.
    """
    await db.execute(select(User.id).where(User.id == owner_id).with_for_update())
    used, _ = await used_bytes(db, owner_id)
    limit = await limit_bytes(db, owner_id)
    if used + extra_bytes > limit:
        raise QuotaExceeded(limit)
