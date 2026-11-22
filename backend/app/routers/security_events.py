"""1.3.0 security events (caseWiped, duressUnlock, ...).

Stored in their own table and never shown in the audit log: `duressUnlock` means the user may be
under coercion, and the coercer could be looking at the same screen.
"""
from datetime import timedelta

from fastapi import APIRouter, Response

from app.core.errors import APIError, ValidationFailed
from app.core.ratelimit import limiter
from app.deps import DB, CurrentAuth
from app.models import SecurityEvent
from app.schemas.dto import SecurityEventDTO
from app.schemas.types import utcnow
from app.services.vault import get_case

router = APIRouter(prefix="/v1/security-events", tags=["security events (1.3.0)"])


@router.post("", status_code=204)
async def report(body: SecurityEventDTO, auth: CurrentAuth, db: DB):
    limiter.hit(f"sec-events:{auth.user.id}", 30, 60)
    now = utcnow()
    if body.at > now + timedelta(days=1):
        raise ValidationFailed("Дата события в будущем")
    case_id = body.case_id
    if case_id is not None:
        try:
            await get_case(db, auth.user.id, case_id)
        except APIError:
            case_id = None  # not the user's case: keep the event, drop the reference
    db.add(SecurityEvent(user_id=auth.user.id, kind=body.kind, case_id=case_id, device_name=body.device_name,
                         at=body.at, received_at=now))
    await db.commit()
    return Response(status_code=204)
