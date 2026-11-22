"""Unified error envelope (contract section 3).

Every 4xx/5xx response is JSON: {"code", "message", "retry_after_seconds"?, "limit_bytes"?}.
The app maps `code` to its Swift `APIError` (see APIError.from in Contract/APIModels.swift).
"""
import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

log = logging.getLogger("lokey.errors")


class APIError(Exception):
    status: int = 500
    code: str = "server"
    default_message: str = "Внутренняя ошибка сервера"

    def __init__(self, message: str | None = None, *, headers: dict[str, str] | None = None):
        self.message = message or self.default_message
        self.headers = headers or {}
        super().__init__(self.message)

    def body(self) -> dict:
        return {"code": self.code, "message": self.message}


class ValidationFailed(APIError):
    status, code, default_message = 400, "validation", "Неверные данные запроса"


class Unauthorized(APIError):
    status, code, default_message = 401, "unauthorized", "Требуется вход"


class MFAInvalid(APIError):
    status, code, default_message = 401, "mfa_invalid", "Неверный код подтверждения"


class Forbidden(APIError):
    status, code, default_message = 403, "forbidden", "Доступ запрещён"


class NotFound(APIError):
    status, code, default_message = 404, "not_found", "Не найдено"


class Conflict(APIError):
    status, code, default_message = 409, "conflict", "Запись изменилась, обновите данные"


class QuotaExceeded(APIError):
    status, code, default_message = 413, "quota_exceeded", "Превышен лимит хранилища"

    def __init__(self, limit_bytes: int, message: str | None = None):
        super().__init__(message)
        self.limit_bytes = limit_bytes

    def body(self) -> dict:
        return {**super().body(), "limit_bytes": self.limit_bytes}


class IntegrityFailed(APIError):
    status, code, default_message = 422, "integrity_failed", "Контрольная сумма не совпала"


class RateLimited(APIError):
    status, code, default_message = 429, "rate_limited", "Слишком много запросов, попробуйте позже"

    def __init__(self, retry_after_seconds: int, message: str | None = None):
        super().__init__(message, headers={"Retry-After": str(retry_after_seconds)})
        self.retry_after_seconds = retry_after_seconds

    def body(self) -> dict:
        return {**super().body(), "retry_after_seconds": self.retry_after_seconds}


class NotImplementedYet(APIError):
    # The client compares message with "not_implemented" exactly — do not translate.
    status, code, default_message = 501, "not_implemented", "not_implemented"

    def __init__(self):
        super().__init__("not_implemented")


_STATUS_CODES = {400: "validation", 401: "unauthorized", 403: "forbidden", 404: "not_found",
                 409: "conflict", 422: "integrity_failed", 429: "rate_limited"}


def _field_name(loc: tuple) -> str:
    # ("body", "email") -> "email"; never echo the submitted value (it may be a password).
    parts = [str(p) for p in loc if p not in ("body", "query", "path", "header")]
    return ".".join(parts) or "body"


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(APIError)
    async def _api_error(_: Request, exc: APIError):
        return JSONResponse(exc.body(), status_code=exc.status, headers=exc.headers)

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, exc: RequestValidationError):
        fields = sorted({_field_name(tuple(e.get("loc", ()))) for e in exc.errors()})
        msg = "Неверное поле: " + ", ".join(fields) if fields else ValidationFailed.default_message
        return JSONResponse({"code": "validation", "message": msg}, status_code=400)

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException):
        code = _STATUS_CODES.get(exc.status_code, "server")
        message = exc.detail if isinstance(exc.detail, str) else code
        return JSONResponse({"code": code, "message": message}, status_code=exc.status_code,
                            headers=getattr(exc, "headers", None))

    @app.exception_handler(Exception)
    async def _unhandled(request: Request, exc: Exception):
        # Log type + path only: request bodies may contain ciphertext or credentials.
        log.exception("unhandled error on %s %s", request.method, request.url.path)
        return JSONResponse({"code": "server", "message": APIError.default_message}, status_code=500)
