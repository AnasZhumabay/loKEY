from fastapi import APIRouter
from sqlalchemy import text

from app import CONTRACT_VERSION
from app.core.errors import APIError
from app.db import SessionLocal

router = APIRouter(tags=["health"])


@router.get("/health")
async def health():
    """Liveness: the process is up."""
    return {"status": "ok", "contract": CONTRACT_VERSION}


@router.get("/health/ready")
async def ready():
    """Readiness: the database answers."""
    try:
        async with SessionLocal() as s:
            await s.execute(text("SELECT 1"))
    except Exception as e:
        raise APIError("database unavailable") from e
    return {"status": "ready"}
