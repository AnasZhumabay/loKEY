"""/v1/billing — plans, subscription, purchase, cancel.

StoreKit isn't wired in the app yet (PlansView.buy sends apple_transaction = nil). Until App Store
verification is implemented, purchases are accepted only when LOKEY_ALLOW_TEST_PURCHASES is on
(default: everywhere except prod). TODO(storekit): verify the StoreKit 2 JWS with Apple's root certs.
"""
from datetime import timedelta

from fastapi import APIRouter

from app.core.config import get_settings
from app.core.errors import ValidationFailed
from app.deps import DB, CurrentAuth
from app.models import Subscription
from app.schemas.dto import PlanDTO, PurchaseRequest, SubscriptionDTO
from app.schemas.types import utcnow
from app.services.billing import PLANS, PLANS_BY_ID, plan_is_effective

router = APIRouter(prefix="/v1/billing", tags=["billing"])

FREE = SubscriptionDTO(plan_id="free", status="active", renews_at=None)


def sub_dto(sub: Subscription | None) -> SubscriptionDTO:
    if sub is None or sub.plan_id == "free":
        return FREE
    status = sub.status
    if status != "expired" and not plan_is_effective(sub):
        status = "expired"
    return SubscriptionDTO(plan_id=sub.plan_id, status=status, renews_at=sub.renews_at)


@router.get("/plans", response_model=list[PlanDTO])
async def plans():
    return PLANS


@router.get("/subscription", response_model=SubscriptionDTO)
async def subscription(auth: CurrentAuth, db: DB):
    return sub_dto(await db.get(Subscription, auth.user.id))


@router.post("/purchase", response_model=SubscriptionDTO)
async def purchase(body: PurchaseRequest, auth: CurrentAuth, db: DB):
    plan = PLANS_BY_ID.get(body.plan_id)
    if plan is None:
        raise ValidationFailed("Неизвестный тариф")
    if not get_settings().allow_test_purchases:
        raise ValidationFailed("Покупка пока недоступна: проверка App Store не настроена")
    now = utcnow()
    sub = await db.get(Subscription, auth.user.id, with_for_update=True)
    if sub is None:
        sub = Subscription(user_id=auth.user.id)
        db.add(sub)
    sub.plan_id, sub.status, sub.updated_at = plan.id, "active", now
    sub.apple_transaction = body.apple_transaction
    sub.renews_at = None if plan.period == "free" else now + timedelta(days=365 if plan.period == "year" else 30)
    await db.commit()
    return sub_dto(sub)


@router.post("/cancel", response_model=SubscriptionDTO)
async def cancel(auth: CurrentAuth, db: DB):
    """Stops renewal; the paid limit stays until renews_at, then the account falls back to free."""
    sub = await db.get(Subscription, auth.user.id, with_for_update=True)
    if sub is None or sub.plan_id == "free":
        return FREE
    if sub.status == "active":
        sub.status, sub.updated_at = "cancelled", utcnow()
        await db.commit()
    return sub_dto(sub)
