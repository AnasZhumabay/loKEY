"""/v1/auth/* — register, login (+MFA), refresh, logout, password reset."""
import re
from datetime import timedelta

import pyotp
from fastapi import APIRouter, Request, Response
from sqlalchemy import delete, func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.errors import MFAInvalid, Unauthorized, ValidationFailed
from app.core.ratelimit import limiter
from app.core.security import hash_password, new_token, open_secret, safe_equal, token_hash, verify_password
from app.deps import DB, CurrentAuth, Device, device_from, ip_hint
from app.models import AuthSession, MFAChallenge, User
from app.schemas.dto import (
    AccountDTO,
    EmailRequest,
    LoginRequest,
    LoginResponse,
    MFAVerifyRequest,
    RefreshRequest,
    RegisterRequest,
    SessionDTO,
)
from app.schemas.types import utcnow
from app.services import audit

router = APIRouter(prefix="/v1/auth", tags=["auth"])

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
USERNAME_RE = re.compile(r"^[\w.\-]{3,32}$")  # \w is Unicode: Cyrillic names are fine
MIN_PASSWORD = 8  # same as the app (AuthView.validate)

LOGIN_FAILS, LOGIN_FAIL_WINDOW = 10, 15 * 60
IP_LOGINS, IP_LOGIN_WINDOW = 60, 5 * 60
REGISTERS, REGISTER_WINDOW = 30, 10 * 60
RESETS, RESET_WINDOW = 5, 60 * 60
MFA_ATTEMPTS = 5


def valid_email(email: str) -> bool:
    return bool(EMAIL_RE.match(email))


def issue_session(db: AsyncSession, user: User, device: Device) -> SessionDTO:
    """Create a session row and return the tokens (only their hashes are stored)."""
    s = get_settings()
    now = utcnow()
    access, refresh = new_token(), new_token()
    row = AuthSession(
        user_id=user.id, access_hash=token_hash(access), refresh_hash=token_hash(refresh),
        access_expires_at=now + timedelta(seconds=s.access_token_ttl_seconds),
        refresh_expires_at=now + timedelta(days=s.refresh_token_ttl_days),
        device_name=device.name, platform=device.platform, app_version=device.app_version, ip=device.ip,
        created_at=now, last_active_at=now,
    )
    db.add(row)
    return SessionDTO(access_token=access, refresh_token=refresh, expires_at=row.access_expires_at,
                      account=AccountDTO.model_validate(user))


@router.post("/register", response_model=SessionDTO)
async def register(body: RegisterRequest, request: Request, db: DB):
    device = device_from(request)
    limiter.hit(f"register:{device.ip}", REGISTERS, REGISTER_WINDOW)
    email, username = body.email.strip(), body.username.strip()
    if not valid_email(email):
        raise ValidationFailed("Введите корректный email")
    if len(username) < 3:
        raise ValidationFailed("Имя пользователя — минимум 3 символа")
    if not USERNAME_RE.match(username):
        raise ValidationFailed("Имя пользователя: до 32 символов, буквы, цифры, «.», «_», «-»")
    if len(body.password) < MIN_PASSWORD:
        raise ValidationFailed("Пароль — минимум 8 символов")

    taken = (await db.execute(select(User.email, User.username).where(
        or_(func.lower(User.email) == email.lower(), func.lower(User.username) == username.lower())))).first()
    if taken:
        raise ValidationFailed("Этот email уже зарегистрирован" if taken.email.lower() == email.lower()
                               else "Это имя пользователя уже занято")

    user = User(email=email, username=username, password_hash=await hash_password(body.password),
                mfa_enabled=False, created_at=utcnow())
    db.add(user)
    try:
        await db.flush()
    except IntegrityError:  # lost a race with an identical registration
        raise ValidationFailed("Этот email или имя пользователя уже заняты") from None
    session = issue_session(db, user, device)
    await db.commit()
    return session


@router.post("/login", response_model=LoginResponse, response_model_exclude_none=True)
async def login(body: LoginRequest, request: Request, db: DB):
    device = device_from(request)
    ident = body.identifier.strip()
    if not ident or not body.password:
        raise ValidationFailed("Введите логин и пароль")
    fail_key = f"login-fail:{ident.lower()}"
    limiter.check(fail_key, LOGIN_FAILS, LOGIN_FAIL_WINDOW)
    limiter.hit(f"login-ip:{device.ip}", IP_LOGINS, IP_LOGIN_WINDOW)

    user = (await db.execute(select(User).where(
        or_(func.lower(User.email) == ident.lower(), func.lower(User.username) == ident.lower())))).scalar_one_or_none()
    if not await verify_password(user.password_hash if user else None, body.password):
        limiter.add(fail_key)
        if user is not None:
            audit.record(db, user.id, "loginFailed", device_name=device.name, ip_hint=ip_hint(device.ip))
            await db.commit()
        raise Unauthorized("Неверный логин или пароль")
    limiter.reset(fail_key)

    if user.mfa_enabled:
        ch = MFAChallenge(user_id=user.id, attempts=0, device_name=device.name, platform=device.platform,
                          app_version=device.app_version,
                          expires_at=utcnow() + timedelta(seconds=get_settings().mfa_challenge_ttl_seconds))
        db.add(ch)
        await db.commit()
        return LoginResponse(mfa_challenge_id=ch.id)

    session = issue_session(db, user, device)
    audit.record(db, user.id, "login", device_name=device.name, ip_hint=ip_hint(device.ip))
    await db.commit()
    return LoginResponse(session=session)


def _totp_step(secret: str, code: str, last_step: int | None) -> int | None:
    """Return the matched time-step (±1 step of clock drift), refusing already-used steps (replay)."""
    if not code.isdigit() or len(code) != 6:
        return None
    totp = pyotp.TOTP(secret)
    now_step = int(utcnow().timestamp()) // totp.interval
    for step in (now_step - 1, now_step, now_step + 1):
        if safe_equal(totp.at(step * totp.interval), code) and (last_step is None or step > last_step):
            return step
    return None


@router.post("/mfa/verify", response_model=SessionDTO)
async def verify_mfa(body: MFAVerifyRequest, request: Request, db: DB):
    ch = await db.get(MFAChallenge, body.challenge_id, with_for_update=True)
    if ch is None or ch.expires_at <= utcnow() or ch.attempts >= MFA_ATTEMPTS:
        if ch is not None:
            await db.delete(ch)
            await db.commit()
        raise Unauthorized("Срок подтверждения истёк, войдите снова")
    user = await db.get(User, ch.user_id, with_for_update=True)
    secret = open_secret(user.mfa_secret_sealed) if user and user.mfa_secret_sealed else None
    step = _totp_step(secret, body.code.strip(), user.mfa_last_step) if secret else None
    if step is None:
        ch.attempts += 1
        await db.commit()
        raise MFAInvalid()

    user.mfa_last_step = step
    await db.delete(ch)
    device = Device(name=ch.device_name, platform=ch.platform, app_version=ch.app_version, ip=device_from(request).ip)
    session = issue_session(db, user, device)
    audit.record(db, user.id, "login", device_name=device.name, ip_hint=ip_hint(device.ip))
    await db.commit()
    return session


@router.post("/refresh", response_model=SessionDTO)
async def refresh(body: RefreshRequest, request: Request, db: DB):
    h = token_hash(body.refresh_token)
    sess = (await db.execute(
        select(AuthSession).where(AuthSession.refresh_hash == h).with_for_update())).scalar_one_or_none()
    if sess is None:
        # An already-rotated token came back: it was probably stolen. Kill that session.
        await db.execute(delete(AuthSession).where(AuthSession.prev_refresh_hash == h))
        await db.commit()
        raise Unauthorized()
    now = utcnow()
    if sess.refresh_expires_at <= now:
        await db.delete(sess)
        await db.commit()
        raise Unauthorized()

    s = get_settings()
    access, new_refresh = new_token(), new_token()
    sess.prev_refresh_hash = sess.refresh_hash
    sess.refresh_hash = token_hash(new_refresh)
    sess.access_hash = token_hash(access)
    sess.access_expires_at = now + timedelta(seconds=s.access_token_ttl_seconds)
    sess.refresh_expires_at = now + timedelta(days=s.refresh_token_ttl_days)
    sess.last_active_at = now
    sess.ip = device_from(request).ip
    user = await db.get(User, sess.user_id)
    await db.commit()
    return SessionDTO(access_token=access, refresh_token=new_refresh, expires_at=sess.access_expires_at,
                      account=AccountDTO.model_validate(user))


@router.post("/logout", status_code=204)
async def logout(auth: CurrentAuth, request: Request, db: DB):
    audit.record(db, auth.user.id, "logout", device_name=auth.session.device_name,
                 ip_hint=ip_hint(device_from(request).ip))
    await db.execute(delete(AuthSession).where(AuthSession.id == auth.session.id))
    await db.commit()
    return Response(status_code=204)


@router.post("/password-reset", status_code=204)
async def password_reset(body: EmailRequest, request: Request):
    """Always 204: never reveal whether an account exists.

    TODO(email): send a reset link once an email provider (SMTP) is configured. Note: a reset can't
    recover case keys — they are only on the device / in the 12-word phrase.
    """
    limiter.hit(f"reset:{device_from(request).ip}", RESETS, RESET_WINDOW)
    if not valid_email(body.email.strip()):
        raise ValidationFailed("Введите корректный email")
    return Response(status_code=204)
