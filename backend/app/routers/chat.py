"""/v1/chat — the "post office": identity keys and an encrypted mailbox per user.

The server sees only who → whom, when and size; `ciphertext` is never parsed.
"""
from datetime import timedelta

from fastapi import APIRouter, Query, Response
from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert

from app.core.config import get_settings
from app.core.errors import Conflict, Forbidden, NotFound, ValidationFailed
from app.core.ratelimit import limiter
from app.deps import DB, CurrentAuth
from app.models import ChatMessage, User
from app.schemas.dto import AckRequest, ChatEnvelopeDTO, ChatUserDTO, IdentityRequest
from app.schemas.types import utcnow

router = APIRouter(prefix="/v1/chat", tags=["chat"])

SENDS_PER_MINUTE = 120


def chat_user(u: User) -> ChatUserDTO:
    return ChatUserDTO(id=u.id, username=u.username, identity_key=u.chat_identity_key)


@router.put("/identity", response_model=ChatUserDTO)
async def register_identity(body: IdentityRequest, auth: CurrentAuth, db: DB):
    """Publish the X25519 public key. Same key again = OK. A *different* key is refused:
    silently swapping keys would let the server (or a thief) impersonate the user."""
    if len(body.public_key) != 32:
        raise ValidationFailed("Публичный ключ должен быть ровно 32 байта")
    user = await db.get(User, auth.user.id, with_for_update=True)
    if user.chat_identity_key is None:
        user.chat_identity_key = body.public_key
        await db.commit()
    elif user.chat_identity_key != body.public_key:
        raise Conflict("Ключ чата уже зарегистрирован для этого аккаунта")
    return chat_user(user)


@router.get("/users/{user_id}", response_model=ChatUserDTO)
async def find_user(user_id: str, auth: CurrentAuth, db: DB):
    u = await db.get(User, user_id)
    if u is None or u.chat_identity_key is None:
        raise NotFound()
    return chat_user(u)


async def enqueue(db, *, id: str, sender_id: str, recipient_id: str, version: int, ciphertext: bytes,
                  sent_at, expires_at) -> None:
    """Insert one mailbox row; a repeat of (sender, recipient, id) is silently ignored (idempotent send)."""
    s = get_settings()
    now = utcnow()
    max_exp = now + timedelta(days=s.chat_ttl_days)
    exp = min(expires_at, max_exp) if expires_at else max_exp
    await db.execute(insert(ChatMessage).values(
        id=id, sender_id=sender_id, recipient_id=recipient_id, version=version, ciphertext=ciphertext,
        sent_at=sent_at, expires_at=exp, received_at=now,
    ).on_conflict_do_nothing(constraint="ux_chat_dedup"))


def check_ciphertext(ct: bytes) -> None:
    if not ct:
        raise ValidationFailed("Пустое сообщение")
    if len(ct) > get_settings().chat_max_ciphertext_bytes:
        raise ValidationFailed("Сообщение слишком большое")


@router.post("/messages", status_code=204)
async def send(env: ChatEnvelopeDTO, auth: CurrentAuth, db: DB):
    if env.sender_id != auth.user.id:
        raise Forbidden()
    check_ciphertext(env.ciphertext)
    if await db.get(User, env.recipient_id) is None:
        raise NotFound("Получатель не найден")
    limiter.hit(f"chat-send:{auth.user.id}", SENDS_PER_MINUTE, 60)
    await enqueue(db, id=env.id, sender_id=env.sender_id, recipient_id=env.recipient_id, version=env.version,
                  ciphertext=env.ciphertext, sent_at=env.sent_at, expires_at=env.expires_at)
    await db.commit()
    return Response(status_code=204)


@router.get("/messages", response_model=list[ChatEnvelopeDTO])
async def fetch(auth: CurrentAuth, db: DB, limit: int = Query(100, ge=1, le=500)):
    """Oldest first; nothing is deleted until ack."""
    rows = await db.execute(select(ChatMessage).where(ChatMessage.recipient_id == auth.user.id,
                                                      ChatMessage.expires_at > utcnow())
                            .order_by(ChatMessage.seq).limit(limit))
    return [ChatEnvelopeDTO(id=m.id, sender_id=m.sender_id, recipient_id=m.recipient_id, version=m.version,
                            ciphertext=m.ciphertext, sent_at=m.sent_at, expires_at=m.expires_at)
            for m in rows.scalars()]


@router.post("/messages/ack", status_code=204)
async def acknowledge(body: AckRequest, auth: CurrentAuth, db: DB):
    """Deletes only from the caller's own mailbox, so ids of other people's messages are ignored."""
    if body.ids:
        await db.execute(delete(ChatMessage).where(ChatMessage.recipient_id == auth.user.id,
                                                   ChatMessage.id.in_(body.ids)))
        await db.commit()
    return Response(status_code=204)
