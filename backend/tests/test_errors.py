"""Error envelope: every 4xx/5xx is {"code","message",...}."""
from fastapi import FastAPI

from app.core.errors import QuotaExceeded, RateLimited, install_error_handlers
from app.schemas.types import B64Bytes, Schema


async def test_health(client):
    r = await client.get("/health")
    assert r.status_code == 200 and r.json()["contract"] == "1.3.0"


async def test_unknown_route_is_not_found_envelope(client):
    r = await client.get("/v1/nope")
    assert r.status_code == 404
    assert r.json() == {"code": "not_found", "message": "Not Found"}


async def test_not_implemented_envelope_has_exact_message():
    # The app compares message with "not_implemented" literally (SharedCaseServiceImpl.mapped).
    from app.core.errors import NotImplementedYet
    assert NotImplementedYet().body() == {"code": "not_implemented", "message": "not_implemented"}


def _app_with(route):
    app = FastAPI()
    install_error_handlers(app)
    app.add_api_route("/x", route, methods=["POST"])
    return app


async def _call(app, **kw):
    import httpx
    transport = httpx.ASGITransport(app=app, raise_app_exceptions=False)
    async with httpx.AsyncClient(transport=transport, base_url="http://t") as c:
        return await c.post("/x", **kw)


async def test_validation_is_400_and_never_echoes_values():
    class Body(Schema):
        password: str
        data: B64Bytes

    async def route(body: Body):
        return {}

    r = await _call(_app_with(route), json={"password": 123, "data": "secret-not-b64!"})
    assert r.status_code == 400
    j = r.json()
    assert j["code"] == "validation" and "data" in j["message"] and "password" in j["message"]
    assert "secret" not in r.text


async def test_quota_carries_limit_bytes():
    async def route():
        raise QuotaExceeded(5_000_000_000)

    r = await _call(_app_with(route))
    assert r.status_code == 413 and r.json()["code"] == "quota_exceeded" and r.json()["limit_bytes"] == 5_000_000_000


async def test_rate_limit_has_header_and_field():
    async def route():
        raise RateLimited(30)

    r = await _call(_app_with(route))
    assert r.status_code == 429 and r.headers["retry-after"] == "30" and r.json()["retry_after_seconds"] == 30


async def test_unhandled_exception_is_500_server():
    async def route():
        raise RuntimeError("boom with secret detail")

    r = await _call(_app_with(route))
    assert r.status_code == 500 and r.json()["code"] == "server" and "secret" not in r.text
