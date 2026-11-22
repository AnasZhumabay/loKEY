"""/v1/account — profile, backup email, MFA, storage usage, sessions."""
import pyotp
from fastapi import APIRouter, Request, Response
from sqlalchemy import delete, select

from app.core.errors import NotFound, ValidationFailed
from app.core.security import seal_secret
from app.deps import DB, CurrentAuth, device_from, ip_hint
from app.models import AuthSession
from app.routers.auth import valid_email
from app.schemas.dto import (
    AccountDTO,
    BackupEmailRequest,
    CaseUsageDTO,
    MFARequest,
    MFASetupDTO,
    SessionInfoDTO,
    StorageUsageDTO,
)
from app.services import audit
from app.services.billing import limit_bytes
from app.services.vault import used_bytes

router = APIRouter(prefix="/v1/account", tags=["account"])


@router.get("", response_model=AccountDTO)
async def me(auth: CurrentAuth):
    return AccountDTO.model_validate(auth.user)


@router.patch("", response_model=AccountDTO)
async def update_account(body: BackupEmailRequest, auth: CurrentAuth, db: DB):
    if "backup_email" in body.model_fields_set:  # {"backup_email": null} clears it
        email = body.backup_email.strip() if body.backup_email else None
        if email and not valid_email(email):
            raise ValidationFailed("Введите корректный email")
        auth.user.backup_email = email or None
        await db.commit()
    return AccountDTO.model_validate(auth.user)


@router.put("/mfa", response_model=MFASetupDTO, responses={204: {"description": "MFA disabled"}})
async def set_mfa(body: MFARequest, auth: CurrentAuth, request: Request, db: DB):
    user = auth.user
    if body.enabled and body.method == "sms":
        raise ValidationFailed("SMS-подтверждение пока недоступно, выберите приложение-аутентификатор")
    if body.enabled:
        secret = pyotp.random_base32()
        user.mfa_secret_sealed, user.mfa_method, user.mfa_enabled, user.mfa_last_step = (
            seal_secret(secret), "authenticator", True, None)
    else:
        user.mfa_secret_sealed, user.mfa_method, user.mfa_enabled, user.mfa_last_step = None, None, False, None
    audit.record(db, user.id, "mfaChanged", device_name=auth.session.device_name,
                 ip_hint=ip_hint(device_from(request).ip))
    await db.commit()
    if not body.enabled:
        return Response(status_code=204)
    return MFASetupDTO(method="authenticator",
                       otpauth_uri=pyotp.TOTP(secret).provisioning_uri(name=user.email, issuer_name="loKEY"))


@router.get("/storage", response_model=StorageUsageDTO)
async def storage(auth: CurrentAuth, db: DB):
    used, per_case = await used_bytes(db, auth.user.id)
    return StorageUsageDTO(used_bytes=used, limit_bytes=await limit_bytes(db, auth.user.id),
                           per_case=[CaseUsageDTO(case_id=c, bytes=b) for c, b in per_case.items()])


@router.get("/sessions", response_model=list[SessionInfoDTO])
async def list_sessions(auth: CurrentAuth, db: DB):
    rows = (await db.execute(select(AuthSession).where(AuthSession.user_id == auth.user.id)
                             .order_by(AuthSession.last_active_at.desc()))).scalars()
    return [SessionInfoDTO(id=s.id, device_name=s.device_name, platform=s.platform, app_version=s.app_version,
                           approx_location=None, created_at=s.created_at, last_active_at=s.last_active_at,
                           is_current=s.id == auth.session.id) for s in rows]


@router.delete("/sessions/{session_id}", status_code=204)
async def revoke_session(session_id: str, auth: CurrentAuth, db: DB):
    res = await db.execute(delete(AuthSession).where(AuthSession.id == session_id,
                                                     AuthSession.user_id == auth.user.id))
    if res.rowcount == 0:
        raise NotFound()
    await db.commit()
    return Response(status_code=204)


@router.post("/sessions/revoke-others", status_code=204)
async def revoke_others(auth: CurrentAuth, db: DB):
    await db.execute(delete(AuthSession).where(AuthSession.user_id == auth.user.id,
                                               AuthSession.id != auth.session.id))
    await db.commit()
    return Response(status_code=204)
