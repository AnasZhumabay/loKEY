"""Periodic cleanup (contract: trash 30 days, orphan file records after a day, chat envelopes after expiry).

Runs inside the API process every `cleanup_interval_seconds` (a Postgres advisory lock makes sure only one
process does it at a time), or once from the command line / cron:

    python -m app.jobs
"""
import asyncio
import logging
from datetime import timedelta

from sqlalchemy import delete, exists, select, text

from app.core.config import get_settings
from app.db import SessionLocal
from app.deps import get_storage
from app.models import AuditEvent, AuthSession, ChatMessage, File, FileVersion, MFAChallenge
from app.routers.cases import delete_blobs
from app.schemas.types import utcnow

log = logging.getLogger("lokey.jobs")
LOCK_ID = 0x10CE7  # arbitrary constant for pg_try_advisory_lock
AUDIT_RETENTION_DAYS = 365


async def _purge_files(db, where) -> tuple[int, list[str]]:
    files = list((await db.execute(select(File.id, File.blob_key).where(where))).all())
    if not files:
        return 0, []
    ids = [f.id for f in files]
    keys = [f.blob_key for f in files if f.blob_key]
    keys += list((await db.execute(select(FileVersion.blob_key).where(FileVersion.file_id.in_(ids)))).scalars())
    await db.execute(delete(File).where(File.id.in_(ids)))
    return len(ids), keys


async def run_cleanup() -> dict[str, int]:
    s = get_settings()
    now = utcnow()
    stats: dict[str, int] = {}
    async with SessionLocal() as db:
        got = (await db.execute(text("SELECT pg_try_advisory_lock(:k)"), {"k": LOCK_ID})).scalar()
        if not got:
            return {"skipped": 1}
        try:
            n, keys = await _purge_files(db, File.deleted_at < now - timedelta(days=s.trash_retention_days))
            stats["trash_purged"] = n
            # Records whose blob never arrived (upload failed and the client never retried / deleted them).
            no_versions = ~exists().where(FileVersion.file_id == File.id)
            n, more = await _purge_files(db, File.blob_key.is_(None) & no_versions
                                         & (File.created_at < now - timedelta(hours=s.orphan_file_hours)))
            stats["orphans_purged"], keys = n, keys + more

            for name, stmt in {
                "chat_expired": delete(ChatMessage).where(ChatMessage.expires_at <= now),
                "sessions_expired": delete(AuthSession).where(AuthSession.refresh_expires_at <= now),
                "mfa_challenges_expired": delete(MFAChallenge).where(MFAChallenge.expires_at <= now),
                "audit_old": delete(AuditEvent).where(AuditEvent.at < now - timedelta(days=AUDIT_RETENTION_DAYS)),
            }.items():
                stats[name] = (await db.execute(stmt)).rowcount
            await db.commit()
        finally:
            await db.execute(text("SELECT pg_advisory_unlock(:k)"), {"k": LOCK_ID})
            await db.commit()
    await delete_blobs(get_storage(), keys)
    if any(stats.values()):
        log.info("cleanup: %s", stats)
    return stats


async def cleanup_loop() -> None:
    interval = get_settings().cleanup_interval_seconds
    while True:
        await asyncio.sleep(interval)
        try:
            await run_cleanup()
        except Exception:
            log.exception("cleanup failed")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    print(asyncio.run(run_cleanup()))
