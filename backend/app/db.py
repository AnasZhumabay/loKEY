"""Async SQLAlchemy engine + session dependency."""
from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase
from sqlalchemy.pool import NullPool

from app.core.config import get_settings


class Base(DeclarativeBase):
    pass


_settings = get_settings()
# Tests run each case in a fresh event loop, so pooled connections can't be reused there.
engine = (create_async_engine(_settings.database_url, poolclass=NullPool) if _settings.env == "test"
          else create_async_engine(_settings.database_url, pool_pre_ping=True, pool_size=10, max_overflow=20))
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)


async def get_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session
