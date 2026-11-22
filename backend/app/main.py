import asyncio
import contextlib
import logging
import re

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from app import CONTRACT_VERSION
from app.core.config import get_settings
from app.core.errors import install_error_handlers
from app.routers import (
    account,
    audit,
    auth,
    backups,
    billing,
    cases,
    chat,
    files,
    groups,
    health,
    security_events,
    shared,
)

# Raw-body uploads that stream to disk and are bounded by their declared size instead.
_STREAMED = re.compile(r"^/v1/(files/[^/]+/blob|backups/[^/]+)$")


@contextlib.asynccontextmanager
async def lifespan(_: FastAPI):
    settings = get_settings()
    task = None
    if settings.cleanup_interval_seconds > 0 and settings.env != "test":
        from app.jobs import cleanup_loop
        task = asyncio.create_task(cleanup_loop())
    yield
    if task:
        task.cancel()


def create_app() -> FastAPI:
    settings = get_settings()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")

    app = FastAPI(
        title="loKEY API",
        version=CONTRACT_VERSION,
        description="Zero-knowledge storage: the server only ever sees ciphertext.",
        # Interactive docs only in dev; prod doesn't advertise its surface.
        docs_url="/docs" if settings.is_dev else None,
        redoc_url=None,
        openapi_url="/openapi.json" if settings.is_dev else None,
        lifespan=lifespan,
    )
    install_error_handlers(app)

    @app.middleware("http")
    async def limit_json_body(request: Request, call_next):
        length = request.headers.get("content-length")
        if (length and length.isdigit() and int(length) > settings.max_json_body_bytes
                and not (request.method == "PUT" and _STREAMED.match(request.url.path))):
            return JSONResponse({"code": "validation", "message": "Слишком большой запрос"}, status_code=413)
        return await call_next(request)

    for r in (health, auth, account, cases, files, audit, billing, chat, groups, shared, backups, security_events):
        app.include_router(r.router)
    return app


app = create_app()
