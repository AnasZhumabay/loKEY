from sqlalchemy.ext.asyncio import AsyncSession

from app.models import AuditEvent
from app.schemas.types import utcnow


def record(db: AsyncSession, user_id: str, kind: str, *, device_name: str, ip_hint: str | None = None,
           case_id: str | None = None) -> None:
    """Add an audit row to the current transaction (the caller commits). Never store content, only facts."""
    db.add(AuditEvent(user_id=user_id, kind=kind, case_id=case_id, device_name=device_name, ip_hint=ip_hint,
                      at=utcnow()))
