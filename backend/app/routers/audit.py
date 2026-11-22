"""/v1/audit — the account's event log (newest first) + events only the client can see."""
from fastapi import APIRouter, Query, Request, Response
from sqlalchemy import select

from app.core.errors import ValidationFailed
from app.deps import DB, CurrentAuth, device_from, ip_hint
from app.models import AuditEvent
from app.schemas.dto import CLIENT_AUDIT_KINDS, AuditEventDTO, AuditRecordRequest
from app.services import audit

router = APIRouter(prefix="/v1/audit", tags=["audit"])


@router.get("", response_model=list[AuditEventDTO])
async def list_audit(auth: CurrentAuth, db: DB, limit: int = Query(50, ge=1, le=500)):
    rows = await db.execute(select(AuditEvent).where(AuditEvent.user_id == auth.user.id)
                            .order_by(AuditEvent.at.desc(), AuditEvent.seq.desc()).limit(limit))
    return [AuditEventDTO.model_validate(e) for e in rows.scalars()]


@router.post("", status_code=204)
async def record_audit(body: AuditRecordRequest, auth: CurrentAuth, request: Request, db: DB):
    # Server-side kinds (login, fileAdded...) are written by the server only: a client can't forge them.
    if body.kind not in CLIENT_AUDIT_KINDS:
        raise ValidationFailed("Это событие записывает сервер")
    # case_id isn't checked for existence: caseDeleted arrives after the case is already purged.
    audit.record(db, auth.user.id, body.kind, case_id=body.case_id, device_name=auth.session.device_name,
                 ip_hint=ip_hint(device_from(request).ip))
    await db.commit()
    return Response(status_code=204)
