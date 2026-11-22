"""1.3.0 chat groups: membership + server fan-out of group envelopes into members' 1:1 mailboxes.

Not wired in the app UI yet (BuiltinCryptoEngine.supportsGroups == false), but the contract is served.
Rules: only the creator adds/removes others; anyone may leave; sender must be a member;
recipients must be members; the sender never gets a copy.
"""
from fastapi import APIRouter, Response
from sqlalchemy import func, select

from app.core.errors import Forbidden, NotFound, ValidationFailed
from app.core.ratelimit import limiter
from app.deps import DB, CurrentAuth
from app.models import ChatGroup, ChatGroupMember, User
from app.routers.chat import SENDS_PER_MINUTE, check_ciphertext, enqueue
from app.schemas.dto import GroupDTO, GroupEnvelopeDTO, GroupMemberRequest

router = APIRouter(prefix="/v1/chat/groups", tags=["chat groups (1.3.0)"])

MAX_MEMBERS = 256
GROUP_ENVELOPE_VERSION = 1  # GroupEnvelopeDTO has no version; recipients get it as a normal envelope


async def _member_ids(db, group_id: str) -> list[str]:
    rows = await db.execute(select(ChatGroupMember.user_id).where(ChatGroupMember.group_id == group_id)
                            .order_by(ChatGroupMember.position, ChatGroupMember.user_id))
    return list(rows.scalars())


async def _dto(db, g: ChatGroup) -> GroupDTO:
    return GroupDTO(id=g.id, name_ciphertext=g.name_ciphertext, member_ids=await _member_ids(db, g.id),
                    created_at=g.created_at)


async def _visible_group(db, group_id: str, user_id: str, lock: bool = False) -> ChatGroup:
    g = await db.get(ChatGroup, group_id, with_for_update=lock)
    if g is None or await db.get(ChatGroupMember, (group_id, user_id)) is None:
        raise NotFound()
    return g


async def _require_users(db, ids: list[str]) -> None:
    found = set((await db.execute(select(User.id).where(User.id.in_(ids)))).scalars())
    if missing := [i for i in ids if i not in found]:
        raise NotFound(f"Пользователь не найден: {missing[0]}")


@router.post("", response_model=GroupDTO)
async def create_group(body: GroupDTO, auth: CurrentAuth, db: DB, response: Response):
    existing = await db.get(ChatGroup, body.id)
    if existing is not None:  # idempotent by id
        await _visible_group(db, body.id, auth.user.id)
        response.status_code = 200
        return await _dto(db, existing)
    if not body.name_ciphertext or len(body.name_ciphertext) > 4096:
        raise ValidationFailed("Неверный размер name_ciphertext")
    members = list(dict.fromkeys([auth.user.id, *body.member_ids]))  # creator first, no duplicates
    if len(members) > MAX_MEMBERS:
        raise ValidationFailed("Слишком много участников")
    await _require_users(db, members)
    db.add(ChatGroup(id=body.id, creator_id=auth.user.id, name_ciphertext=body.name_ciphertext,
                     created_at=body.created_at))
    await db.flush()
    db.add_all(ChatGroupMember(group_id=body.id, user_id=u, position=i) for i, u in enumerate(members))
    await db.commit()
    response.status_code = 201
    return await _dto(db, await db.get(ChatGroup, body.id))


@router.get("", response_model=list[GroupDTO])
async def list_groups(auth: CurrentAuth, db: DB):
    mine = select(ChatGroupMember.group_id).where(ChatGroupMember.user_id == auth.user.id)
    groups = (await db.execute(select(ChatGroup).where(ChatGroup.id.in_(mine))
                               .order_by(ChatGroup.created_at, ChatGroup.id))).scalars()
    return [await _dto(db, g) for g in groups]


@router.post("/{group_id}/members", response_model=GroupDTO)
async def add_member(group_id: str, body: GroupMemberRequest, auth: CurrentAuth, db: DB):
    g = await _visible_group(db, group_id, auth.user.id, lock=True)
    if g.creator_id != auth.user.id:
        raise Forbidden()
    await _require_users(db, [body.user_id])
    if await db.get(ChatGroupMember, (group_id, body.user_id)) is None:
        count, last = (await db.execute(select(func.count(), func.coalesce(func.max(ChatGroupMember.position), 0))
                                        .where(ChatGroupMember.group_id == group_id))).one()
        if count >= MAX_MEMBERS:
            raise ValidationFailed("Слишком много участников")
        db.add(ChatGroupMember(group_id=group_id, user_id=body.user_id, position=last + 1))
        await db.commit()
    return await _dto(db, g)


@router.delete("/{group_id}/members/{user_id}", response_model=GroupDTO)
async def remove_member(group_id: str, user_id: str, auth: CurrentAuth, db: DB):
    g = await _visible_group(db, group_id, auth.user.id, lock=True)
    if g.creator_id != auth.user.id and user_id != auth.user.id:
        raise Forbidden()
    m = await db.get(ChatGroupMember, (group_id, user_id))
    if m is not None:
        await db.delete(m)
        await db.commit()
    return await _dto(db, g)


@router.post("/{group_id}/messages", status_code=204)
async def send_group(group_id: str, env: GroupEnvelopeDTO, auth: CurrentAuth, db: DB):
    if env.group_id != group_id:
        raise ValidationFailed("group_id не совпадает с путём")
    if env.sender_id != auth.user.id:
        raise Forbidden()
    await _visible_group(db, group_id, auth.user.id)
    check_ciphertext(env.ciphertext)
    members = set(await _member_ids(db, group_id))
    recipients = [r for r in dict.fromkeys(env.recipient_ids) if r != auth.user.id]
    if any(r not in members for r in recipients):
        raise Forbidden("Получатель не состоит в группе")
    limiter.hit(f"chat-send:{auth.user.id}", SENDS_PER_MINUTE, 60)
    for r in recipients:
        await enqueue(db, id=env.id, sender_id=auth.user.id, recipient_id=r, version=GROUP_ENVELOPE_VERSION,
                      ciphertext=env.ciphertext, sent_at=env.sent_at, expires_at=None)
    await db.commit()
    return Response(status_code=204)
