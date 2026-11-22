"""Plans (same ids/prices as the app's MockBackend) and the effective storage limit."""
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.models import Subscription
from app.schemas.dto import PlanDTO
from app.schemas.types import utcnow

GB = 1_000_000_000

PLANS: list[PlanDTO] = [
    PlanDTO(id="free", title="Бесплатный", storage_bytes=5 * GB, price_minor=0, currency="USD", period="free"),
    PlanDTO(id="plus_10_month", title="Плюс", storage_bytes=10 * GB, price_minor=499, currency="USD", period="month"),
    PlanDTO(id="pro_25_month", title="Про", storage_bytes=25 * GB, price_minor=999, currency="USD", period="month"),
    PlanDTO(id="max_120_month", title="Макс", storage_bytes=120 * GB, price_minor=4999, currency="USD", period="month"),
]
PLANS_BY_ID = {p.id: p for p in PLANS}


def plan_is_effective(sub: Subscription | None) -> bool:
    """A cancelled plan keeps working until the paid period ends."""
    if sub is None or sub.plan_id == "free" or sub.status == "expired":
        return False
    return sub.renews_at is None or sub.renews_at > utcnow()


async def limit_bytes(db: AsyncSession, user_id: str) -> int:
    sub = await db.get(Subscription, user_id)
    if plan_is_effective(sub) and sub.plan_id in PLANS_BY_ID:
        return PLANS_BY_ID[sub.plan_id].storage_bytes
    return get_settings().free_plan_bytes
