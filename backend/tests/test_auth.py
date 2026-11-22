"""Auth, MFA, refresh rotation, sessions, account."""
import re
from urllib.parse import parse_qs, urlparse

import pyotp

from tests.conftest import bearer

DATE = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")


async def test_register_returns_session_in_contract_format(register):
    u = await register("anna")
    s = u.session
    assert DATE.match(s["expires_at"]) and DATE.match(s["account"]["created_at"])
    assert s["account"]["mfa_enabled"] is False and s["account"]["username"] == "anna"
    assert s["access_token"] != s["refresh_token"]


async def test_register_validation_messages(client, register):
    await register("taken")
    cases = [
        ({"email": "bad", "username": "ok_name", "password": "12345678"}, "Введите корректный email"),
        ({"email": "a@b.co", "username": "ab", "password": "12345678"}, "Имя пользователя — минимум 3 символа"),
        ({"email": "a@b.co", "username": "ok_name", "password": "1234567"}, "Пароль — минимум 8 символов"),
        ({"email": "TAKEN@example.com", "username": "other", "password": "12345678"}, "Этот email уже зарегистрирован"),
        ({"email": "new@example.com", "username": "TaKeN", "password": "12345678"}, "Это имя пользователя уже занято"),
    ]
    for body, msg in cases:
        r = await client.post("/v1/auth/register", json=body)
        assert r.status_code == 400 and r.json() == {"code": "validation", "message": msg}, (body, r.text)


async def test_login_by_email_or_username_case_insensitive(client, register):
    u = await register("Boris")
    for ident in ("boris", "BORIS@EXAMPLE.COM", " Boris "):
        r = await client.post("/v1/auth/login", json={"identifier": ident, "password": u.password})
        assert r.status_code == 200 and set(r.json()) == {"session"}, r.text


async def test_wrong_password_is_401_and_logged(client, register):
    u = await register()
    r = await client.post("/v1/auth/login", json={"identifier": u.username, "password": "nope-nope"})
    assert r.status_code == 401 and r.json()["code"] == "unauthorized"
    r = await client.post("/v1/auth/login", json={"identifier": "ghost", "password": "nope-nope"})
    assert r.status_code == 401  # unknown user looks the same
    kinds = [e["kind"] for e in (await u.req("GET", "/v1/audit")).json()]
    assert "loginFailed" in kinds


async def test_bruteforce_is_rate_limited(client, register):
    u = await register()
    for _ in range(10):
        await client.post("/v1/auth/login", json={"identifier": u.username, "password": "bad-guess!"})
    r = await client.post("/v1/auth/login", json={"identifier": u.username, "password": u.password})
    assert r.status_code == 429 and r.json()["retry_after_seconds"] > 0 and "retry-after" in r.headers


async def test_refresh_rotates_and_detects_reuse(client, register):
    u = await register()
    old = u.session
    r = await client.post("/v1/auth/refresh", json={"refresh_token": old["refresh_token"]})
    assert r.status_code == 200
    new = r.json()
    assert new["refresh_token"] != old["refresh_token"] and new["access_token"] != old["access_token"]
    assert (await client.get("/v1/account", headers=bearer(old["access_token"]))).status_code == 401
    assert (await client.get("/v1/account", headers=bearer(new["access_token"]))).status_code == 200
    # The old refresh token comes back (stolen copy): the whole session dies.
    assert (await client.post("/v1/auth/refresh", json={"refresh_token": old["refresh_token"]})).status_code == 401
    assert (await client.get("/v1/account", headers=bearer(new["access_token"]))).status_code == 401


async def test_expired_access_token_is_401(client, register, settings):
    settings.access_token_ttl_seconds = -1
    u = await register()
    assert (await u.req("GET", "/v1/account")).status_code == 401


async def test_logout_and_sessions(client, register):
    u = await register(**{"User-Agent": "loKEY/12 CFNetwork/1568.100.1 Darwin/24.0.0"})
    r = await client.post("/v1/auth/login", json={"identifier": u.username, "password": u.password},
                          headers={"User-Agent": "python-httpx/0.28"})
    second = r.json()["session"]["access_token"]
    sessions = (await u.req("GET", "/v1/account/sessions")).json()
    assert len(sessions) == 2 and sum(s["is_current"] for s in sessions) == 1
    me = next(s for s in sessions if s["is_current"])
    assert (me["device_name"], me["platform"], me["app_version"]) == ("iPhone", "ios", "12")

    other = next(s for s in sessions if not s["is_current"])
    assert (await u.req("DELETE", f"/v1/account/sessions/{other['id']}")).status_code == 204
    assert (await client.get("/v1/account", headers=bearer(second))).status_code == 401
    assert (await u.req("DELETE", "/v1/account/sessions/nope")).status_code == 404

    assert (await u.req("POST", "/v1/auth/logout")).status_code == 204
    assert (await u.req("GET", "/v1/account")).status_code == 401


async def test_revoke_others_keeps_current(client, register):
    u = await register()
    other = (await client.post("/v1/auth/login", json={"identifier": u.username, "password": u.password})).json()
    assert (await u.req("POST", "/v1/account/sessions/revoke-others")).status_code == 204
    assert (await client.get("/v1/account", headers=bearer(other["session"]["access_token"]))).status_code == 401
    assert (await u.req("GET", "/v1/account")).status_code == 200


def _totp_from(uri: str) -> pyotp.TOTP:
    return pyotp.TOTP(parse_qs(urlparse(uri).query)["secret"][0])


async def test_mfa_full_flow(client, register):
    u = await register()
    assert (await u.req("PUT", "/v1/account/mfa", json={"enabled": True, "method": "sms"})).status_code == 400
    r = await u.req("PUT", "/v1/account/mfa", json={"enabled": True, "method": "authenticator"})
    assert r.status_code == 200 and r.json()["method"] == "authenticator"
    assert r.json()["otpauth_uri"].startswith("otpauth://totp/loKEY:")
    totp = _totp_from(r.json()["otpauth_uri"])
    assert (await u.req("GET", "/v1/account")).json()["mfa_enabled"] is True

    login = {"identifier": u.username, "password": u.password}
    ch = (await client.post("/v1/auth/login", json=login)).json()
    assert set(ch) == {"mfa_challenge_id"}
    bad = await client.post("/v1/auth/mfa/verify", json={"challenge_id": ch["mfa_challenge_id"], "code": "000000"})
    assert bad.status_code == 401 and bad.json()["code"] == "mfa_invalid"
    code = totp.now()
    ok = await client.post("/v1/auth/mfa/verify", json={"challenge_id": ch["mfa_challenge_id"], "code": code})
    assert ok.status_code == 200 and ok.json()["account"]["mfa_enabled"] is True
    # The challenge is single-use, and the same code can't be replayed on a new challenge.
    again = await client.post("/v1/auth/mfa/verify", json={"challenge_id": ch["mfa_challenge_id"], "code": code})
    assert again.status_code == 401 and again.json()["code"] == "unauthorized"
    ch2 = (await client.post("/v1/auth/login", json=login)).json()["mfa_challenge_id"]
    replay = await client.post("/v1/auth/mfa/verify", json={"challenge_id": ch2, "code": code})
    assert replay.json()["code"] == "mfa_invalid"

    r = await u.req("PUT", "/v1/account/mfa", json={"enabled": False, "method": "authenticator"})
    assert r.status_code == 204 and r.content == b""
    assert set((await client.post("/v1/auth/login", json=login)).json()) == {"session"}
    assert [e["kind"] for e in (await u.req("GET", "/v1/audit")).json()].count("mfaChanged") == 2


async def test_mfa_challenge_dies_after_5_wrong_codes(client, register):
    u = await register()
    await u.req("PUT", "/v1/account/mfa", json={"enabled": True, "method": "authenticator"})
    ch = (await client.post("/v1/auth/login", json={"identifier": u.username, "password": u.password})).json()
    for _ in range(5):
        await client.post("/v1/auth/mfa/verify", json={"challenge_id": ch["mfa_challenge_id"], "code": "111111"})
    r = await client.post("/v1/auth/mfa/verify", json={"challenge_id": ch["mfa_challenge_id"], "code": "111111"})
    assert r.status_code == 401 and r.json()["code"] == "unauthorized"


async def test_backup_email_set_and_clear(register):
    u = await register()
    r = await u.req("PATCH", "/v1/account", json={"backup_email": "spare@example.com"})
    assert r.json()["backup_email"] == "spare@example.com"
    assert (await u.req("PATCH", "/v1/account", json={})).json()["backup_email"] == "spare@example.com"
    assert (await u.req("PATCH", "/v1/account", json={"backup_email": None})).json()["backup_email"] is None
    assert (await u.req("PATCH", "/v1/account", json={"backup_email": "nope"})).status_code == 400


async def test_password_reset_never_reveals_accounts(client, register):
    u = await register()
    for email in (u.email, "nobody@example.com"):
        assert (await client.post("/v1/auth/password-reset", json={"email": email})).status_code == 204


async def test_bearer_required_everywhere(client):
    for method, path in [("GET", "/v1/cases"), ("POST", "/v1/auth/logout"), ("GET", "/v1/backups"),
                         ("GET", "/v1/chat/messages"), ("POST", "/v1/security-events")]:
        r = await client.request(method, path, headers={"Authorization": "Basic abc"})
        assert r.status_code == 401 and r.json()["code"] == "unauthorized", path
