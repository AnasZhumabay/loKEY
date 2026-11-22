"""1.3.0 shared cases: invites, members, per-member wrapped case key.

Each member keeps their own copy of the case key, wrapped for them on the inviter's device
(Docs/_shared_case_format.md). The server stores that blob and hands it only to its owner after accept.
Access to the case/files for active members is enforced in services/vault.get_case.
"""
from fastapi import APIRouter, Response
from sqlalchemy import select

from app.core.errors import Forbidden, NotFound, ValidationFailed
from app.deps import DB, CurrentAuth
from app.models import Case, CaseMember, User, new_id
from app.schemas.dto import CaseInviteDTO, CaseMemberDTO, InviteRequest, WrappedKeyDTO
from app.schemas.types import precise_now, utcnow
from app.services.vault import get_case

router = APIRouter(tags=["shared cases (1.3.0)"])

MAX_WRAPPED = 4096


def member_dto(m: CaseMember, name: str) -> CaseMemberDTO:
    return CaseMemberDTO(user_id=m.user_id, display_name=name, role=m.role, status=m.status, joined_at=m.joined_at)


@router.post("/v1/cases/{case_id}/invites", status_code=204)
async def invite(case_id: str, body: InviteRequest, auth: CurrentAuth, db: DB):
    case = await get_case(db, auth.user.id, case_id, owner_only=True, lock=True)
    if body.role == "owner":
        raise ValidationFailed("Можно выдать только роль «Редактор» или «Просмотр»")
    if body.invitee_user_id == auth.user.id:
        raise ValidationFailed("Нельзя пригласить себя")
    if not body.wrapped_key_for_invitee or len(body.wrapped_key_for_invitee) > MAX_WRAPPED:
        raise ValidationFailed("Неверный размер ключа")
    if await db.get(User, body.invitee_user_id) is None:
        raise NotFound("Пользователь не найден")
    m = await db.get(CaseMember, (case.id, body.invitee_user_id), with_for_update=True)
    now = precise_now()  # also orders the member list
    if m is None:
        db.add(CaseMember(case_id=case.id, user_id=body.invitee_user_id, invited_by=auth.user.id, role=body.role,
                          status="invited", wrapped_key=body.wrapped_key_for_invitee,
                          case_name_ciphertext=body.case_name_ciphertext, created_at=now))
    else:  # re-invite: refresh key/role; a revoked member gets a fresh invite
        m.role, m.wrapped_key, m.invited_by = body.role, body.wrapped_key_for_invitee, auth.user.id
        if body.case_name_ciphertext is not None:
            m.case_name_ciphertext = body.case_name_ciphertext
        if m.status == "revoked":
            m.status, m.invite_id, m.created_at, m.joined_at = "invited", new_id(), now, None
    await db.commit()
    return Response(status_code=204)


@router.get("/v1/cases/{case_id}/members", response_model=list[CaseMemberDTO])
async def list_members(case_id: str, auth: CurrentAuth, db: DB):
    case = await get_case(db, auth.user.id, case_id)
    owner = await db.get(User, case.owner_id)
    out = [CaseMemberDTO(user_id=owner.id, display_name=owner.username, role="owner", status="active",
                         joined_at=case.created_at)]
    rows = await db.execute(select(CaseMember, User.username).join(User, User.id == CaseMember.user_id)
                            .where(CaseMember.case_id == case_id).order_by(CaseMember.created_at))
    out += [member_dto(m, name) for m, name in rows]
    return out


@router.delete("/v1/cases/{case_id}/members/{user_id}", status_code=204)
async def revoke(case_id: str, user_id: str, auth: CurrentAuth, db: DB):
    """The owner removes anyone; a member may remove only themselves (leave)."""
    case = await get_case(db, auth.user.id, case_id)
    if user_id == case.owner_id:
        raise ValidationFailed("Владельца удалить нельзя")
    if auth.user.id != case.owner_id and auth.user.id != user_id:
        raise Forbidden()
    m = await db.get(CaseMember, (case_id, user_id), with_for_update=True)
    if m is None:
        raise NotFound()
    if m.status != "revoked":
        m.status, m.wrapped_key = "revoked", b""
        await db.commit()
    return Response(status_code=204)


@router.get("/v1/cases/{case_id}/wrapped-key", response_model=WrappedKeyDTO)
async def wrapped_key(case_id: str, auth: CurrentAuth, db: DB):
    """Only the caller's own copy, only after accept. 404 = no access (the app maps it to nil)."""
    m = await db.get(CaseMember, (case_id, auth.user.id))
    if m is None or m.status != "active" or not m.wrapped_key:
        raise NotFound()
    return WrappedKeyDTO(wrapped_key=m.wrapped_key)


@router.get("/v1/invites", response_model=list[CaseInviteDTO])
async def list_invites(auth: CurrentAuth, db: DB):
    rows = await db.execute(select(CaseMember).join(Case, Case.id == CaseMember.case_id)
                            .where(CaseMember.user_id == auth.user.id, CaseMember.status == "invited")
                            .order_by(CaseMember.created_at.desc()))
    return [CaseInviteDTO(id=m.invite_id, case_id=m.case_id, case_name_ciphertext=m.case_name_ciphertext,
                          from_user_id=m.invited_by, created_at=m.created_at) for m in rows.scalars()]


@router.post("/v1/invites/{invite_id}/accept", response_model=CaseMemberDTO)
async def accept(invite_id: str, auth: CurrentAuth, db: DB):
    m = (await db.execute(select(CaseMember).where(CaseMember.invite_id == invite_id).with_for_update())
         ).scalar_one_or_none()
    if m is None or m.user_id != auth.user.id or m.status == "revoked":
        raise NotFound()
    if m.status == "invited":
        m.status, m.joined_at = "active", utcnow()
        await db.commit()
    return member_dto(m, auth.user.username)
