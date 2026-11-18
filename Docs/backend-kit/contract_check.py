#!/usr/bin/env python3
"""loKEY backend contract check (Python 3.8+, только stdlib).

Прогоняет smoke-сценарий против сервера и проверяет статусы, JSON-схемы (по
фикстурам из ./fixtures), конверт ошибок, 409/404/401, идемпотентность.

  python3 contract_check.py --base-url http://localhost:8080
  python3 contract_check.py --base-url https://api.example --token <access_token>
  python3 contract_check.py --mock          # самопроверка на встроенном мок-сервере

Код выхода: 0 - всё прошло, 1 - есть провалы. WARN (не реализовано 1.3.0 -> 501) не считается провалом.
Источник правды: Docs/BACKEND_CONTRACT.md, loKEY/Contract/*.swift.
"""
import argparse, base64, hashlib, json, os, re, sys, threading, time, uuid
import urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer
try:
    from http.server import ThreadingHTTPServer
except ImportError:  # pragma: no cover
    from socketserver import ThreadingMixIn
    class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
        daemon_threads = True

HERE = os.path.dirname(os.path.abspath(__file__))
FIX_DIR = os.path.join(HERE, "fixtures")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")   # ISO-8601 UTC, БЕЗ долей секунды
B64_KEYS = {"sealed_header", "recovery_wrapped_key", "sealed_metadata", "ciphertext", "name_ciphertext",
            "case_name_ciphertext", "identity_key", "public_key", "wrapped_key"}
LIMIT = 1 << 30

# ───────────────────────── схемы из фикстур ─────────────────────────
# имя -> (файл фикстуры | None, образец, необязательные ключи)
def _load(name):
    with open(os.path.join(FIX_DIR, name + ".json"), encoding="utf-8") as f:
        return json.load(f)

OPTIONAL = {
    "AccountDTO": {"backup_email"},
    "SessionDTO": set(),
    "CaseRecordDTO": {"recovery_wrapped_key", "deleted_at"},
    "FileRecordDTO": {"deleted_at"},
    "AuditEventDTO": {"case_id", "ip_hint"},
    "StorageUsageDTO": set(),
    "MFASetupDTO": {"otpauth_uri"},
    "ErrorEnvelope": {"retry_after_seconds", "limit_bytes"},
    "ChatEnvelopeDTO": {"expires_at"},
    "ChatUserDTO": set(),
    "SessionInfoDTO": {"app_version", "approx_location"},
    "FileVersionDTO": set(),
    "PlanDTO": set(),
    "SubscriptionDTO": {"renews_at"},
    "CaseMemberDTO": {"joined_at"},
    "CaseInviteDTO": {"case_name_ciphertext"},
    "BackupInfoDTO": set(),
    "GroupDTO": set(),
    "GroupEnvelopeDTO": set(),
    "SecurityEventDTO": {"case_id", "device_name"},
}
# DTO без фикстуры в loKEYTests/Fixtures: образцы собраны по Swift-структурам (APIModels.swift)
EXTRA = {
    "ChatUserDTO": {"id": "u", "username": "anna", "identity_key": "AAAA"},
    "ChatEnvelopeDTO": {"id": "m", "sender_id": "a", "recipient_id": "b", "version": 1, "ciphertext": "AAAAAA==",
                        "sent_at": "2025-01-15T10:32:00Z", "expires_at": "2025-02-14T10:32:00Z"},
    "SessionInfoDTO": {"id": "s", "device_name": "iPhone", "platform": "ios", "created_at": "2025-01-15T10:30:00Z",
                       "last_active_at": "2025-01-15T10:30:00Z", "is_current": True},
    "FileVersionDTO": {"id": "v", "file_id": "f", "sealed_metadata": "3q2+7w==", "ciphertext_size": 1,
                       "ciphertext_sha256": "00", "created_at": "2025-01-15T10:30:00Z"},
    "PlanDTO": {"id": "free", "title": "Free", "storage_bytes": 1, "price_minor": 0, "currency": "USD", "period": "free"},
    "SubscriptionDTO": {"plan_id": "free", "status": "active"},
}
NESTED_OPT = {"account": OPTIONAL["AccountDTO"]}   # вложенные объекты: SessionDTO.account
_cache = {}
def sample(name):
    if name not in _cache:
        _cache[name] = EXTRA[name] if name in EXTRA else _load("APIErrorEnvelope" if name == "ErrorEnvelope" else name)
    return _cache[name]

def _tname(v):
    if isinstance(v, bool): return "bool"
    if isinstance(v, int): return "int"
    if isinstance(v, float): return "float"
    if isinstance(v, str): return "str"
    if isinstance(v, list): return "list"
    if isinstance(v, dict): return "dict"
    return "null"

def validate(value, name, optional=None, path=""):
    """Возвращает список ошибок (пусто = ок). Образец - фикстура; лишние ключи допустимы."""
    return _validate(value, sample(name), OPTIONAL.get(name, set()) if optional is None else optional, path or name)

def _validate(value, samp, opt, path):
    errs = []
    if not isinstance(value, dict):
        return ["%s: ожидался объект, пришло %s" % (path, _tname(value))]
    for k, sv in samp.items():
        if k not in value or value[k] is None:
            if k not in opt:
                errs.append("%s.%s: обязательное поле отсутствует/null" % (path, k))
            continue
        v = value[k]
        st, vt = _tname(sv), _tname(v)
        if st == "int" and vt == "float" and float(v).is_integer():
            vt = "int"
        if st != vt:
            errs.append("%s.%s: тип %s, ожидался %s" % (path, k, vt, st)); continue
        if (k.endswith("_at") or k == "at") and st == "str" and not DATE_RE.match(v):
            errs.append("%s.%s: дата %r не в формате 2025-01-15T10:30:00Z (без долей секунды)" % (path, k, v))
        if k in B64_KEYS and st == "str":
            try: base64.b64decode(v, validate=True)
            except Exception: errs.append("%s.%s: не base64" % (path, k))
        if st == "dict":
            errs += _validate(v, sv, NESTED_OPT.get(k, set()), path + "." + k)
        if st == "list" and sv and isinstance(sv[0], dict):
            for i, it in enumerate(v):
                errs += _validate(it, sv[0], set(), "%s.%s[%d]" % (path, k, i))
    return errs

# ───────────────────────── HTTP-клиент ─────────────────────────
class Resp:
    def __init__(self, status, headers, body):
        self.status, self.headers, self.body = status, headers, body
    def json(self):
        try: return json.loads(self.body.decode("utf-8"))
        except Exception: return None

def http(base, method, path, token=None, body=None, raw=None, headers=None, timeout=30):
    h = {"Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body, sort_keys=True).encode(); h["Content-Type"] = "application/json"
    if raw is not None:
        data = raw; h["Content-Type"] = "application/octet-stream"
    if token: h["Authorization"] = "Bearer " + token
    h.update(headers or {})
    req = urllib.request.Request(base.rstrip("/") + path, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return Resp(r.status, dict(r.headers), r.read())
    except urllib.error.HTTPError as e:
        return Resp(e.code, dict(e.headers), e.read())
    except Exception as e:
        return Resp(0, {}, str(e).encode())

# ───────────────────────── проверки ─────────────────────────
class Report:
    def __init__(self): self.rows = []; self.section = ""
    def sec(self, s):
        self.section = s; print("\n== %s" % s)
    def add(self, ok, name, detail="", warn=False):
        tag = "PASS" if ok else ("WARN" if warn else "FAIL")
        self.rows.append((tag, self.section, name, detail))
        print("  [%s] %s%s" % (tag, name, ("  -> " + detail) if detail and tag != "PASS" else ""))
        return ok
    def fails(self): return [r for r in self.rows if r[0] == "FAIL"]

def now_iso(): return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
def uid(): return str(uuid.uuid4())
def b64(b): return base64.b64encode(b).decode()

class Checker:
    def __init__(self, base, token=None):
        self.base, self.token_arg, self.r = base, token, Report()
        self.state = {}
    def call(self, *a, **k): return http(self.base, *a, **k)

    def status(self, resp, expect, name):
        exp = expect if isinstance(expect, (set, tuple, list)) else {expect}
        ok = resp.status in exp
        return self.r.add(ok, name, "статус %s, ожидался %s; тело: %s" % (resp.status, sorted(exp), resp.body[:200]))

    def schema(self, value, dto, name):
        errs = validate(value, dto)
        return self.r.add(not errs, name, "; ".join(errs[:4]))

    def error(self, resp, status, code, name):
        j = resp.json()
        ok = resp.status == status and isinstance(j, dict) and isinstance(j.get("message"), str) and j.get("code") == code
        return self.r.add(ok, name, "статус %s (ждали %s), тело %s (ждали code=%s + message)" % (resp.status, status, resp.body[:160], code))

    def ok_or_501(self, resp, expect, name, dto=None, is_list=False):
        if resp.status == 501:
            j = resp.json() or {}
            self.r.add(j.get("code") == "not_implemented" and j.get("message") == "not_implemented", name + " [501 not_implemented]",
                       "501 должен нести {code,message}=not_implemented, пришло %s" % resp.body[:120], warn=False)
            self.r.add(False, name + " - не реализовано (501)", "ожидаемо до реализации 1.3.0", warn=True); return None
        if not self.status(resp, expect, name): return None
        j = resp.json()
        if dto and j is not None:
            for i, it in enumerate(j if is_list else [j]):
                self.schema(it, dto, "%s: схема %s" % (name, dto))
        return j

    # ---- сценарий ----
    def run(self):
        c, r = self.call, self.r
        reg_tpl = _load("RegisterRequest")
        tag = uid()[:8]

        r.sec("1. Регистрация / вход")
        users = {}
        for who in ("a", "b"):
            req = dict(reg_tpl, email="chk-%s-%s@example.com" % (who, tag), username="chk%s%s" % (who, tag))
            resp = c("POST", "/v1/auth/register", body=req)
            if self.status(resp, {200, 201}, "register %s" % who):
                self.schema(resp.json(), "SessionDTO", "register %s: схема SessionDTO" % who)
                users[who] = {"session": resp.json(), "req": req}
        bad = c("POST", "/v1/auth/register", body={"email": "not-an-email", "username": "", "password": ""})
        self.error(bad, 400, "validation", "register с невалидными полями -> 400 validation")
        if "a" not in users or "b" not in users:
            r.add(False, "дальше нельзя без двух пользователей", "register не прошёл"); return
        A, Bu = users["a"], users["b"]
        resp = c("POST", "/v1/auth/login", body={"identifier": A["req"]["username"], "password": A["req"]["password"]})
        if self.status(resp, 200, "login по username"):
            j = resp.json() or {}
            r.add((j.get("session") is None) != (j.get("mfa_challenge_id") is None), "login: ровно одно из session / mfa_challenge_id", resp.body[:150])
            if j.get("session"): self.schema(j["session"], "SessionDTO", "login: схема SessionDTO"); A["session"] = j["session"]
        resp = c("POST", "/v1/auth/login", body={"identifier": A["req"]["email"], "password": A["req"]["password"]})
        self.status(resp, 200, "login по email")
        resp = c("POST", "/v1/auth/login", body={"identifier": A["req"]["username"], "password": "wrong-password-xx"})
        self.error(resp, 401, "unauthorized", "login с неверным паролем -> 401 unauthorized")
        tokA = self.token_arg or A["session"]["access_token"]
        tokB = Bu["session"]["access_token"]
        self.state.update(tokA=tokA, tokB=tokB)

        r.sec("2. Авторизация, refresh, аккаунт")
        resp = c("GET", "/v1/account")
        self.error(resp, 401, "unauthorized", "GET /v1/account без токена -> 401 unauthorized")
        resp = c("GET", "/v1/account", token="bogus-token")
        self.error(resp, 401, "unauthorized", "GET /v1/account с мусорным токеном -> 401 unauthorized")
        resp = c("GET", "/v1/account", token=tokA)
        if self.status(resp, 200, "GET /v1/account"):
            self.schema(resp.json(), "AccountDTO", "account: схема AccountDTO"); idA = resp.json().get("id")
        else: idA = A["session"]["account"]["id"]
        idB = Bu["session"]["account"]["id"]
        resp = c("POST", "/v1/auth/refresh", body={"refresh_token": "bogus"})
        self.status(resp, {401, 403}, "refresh с мусорным токеном -> 401/403")
        resp = c("POST", "/v1/auth/refresh", body={"refresh_token": Bu["session"]["refresh_token"]})
        if self.status(resp, 200, "refresh с валидным токеном"):
            self.schema(resp.json(), "SessionDTO", "refresh: схема SessionDTO")
            Bu["session"] = resp.json(); tokB = self.state["tokB"] = resp.json()["access_token"]
        resp = c("PATCH", "/v1/account", token=tokA, body={"backup_email": "backup-%s@example.com" % tag})
        if self.status(resp, 200, "PATCH backup_email"): r.add(resp.json().get("backup_email") == "backup-%s@example.com" % tag, "backup_email сохранён")
        resp = c("PATCH", "/v1/account", token=tokA, body={"backup_email": None})
        if self.status(resp, 200, "PATCH backup_email: null очищает"): r.add(resp.json().get("backup_email") in (None, ""), "backup_email очищен")
        resp = c("GET", "/v1/account/storage", token=tokA)
        if self.status(resp, 200, "GET /v1/account/storage"): self.schema(resp.json(), "StorageUsageDTO", "storage: схема")
        resp = c("GET", "/v1/account/sessions", token=tokA)
        if self.status(resp, 200, "GET /v1/account/sessions") and isinstance(resp.json(), list):
            for it in resp.json(): self.schema(it, "SessionInfoDTO", "sessions: схема SessionInfoDTO")
            r.add(sum(1 for s in resp.json() if s.get("is_current")) == 1, "ровно один сеанс is_current=true")
        resp = c("POST", "/v1/auth/password-reset", body={"email": "nobody-%s@example.com" % tag})
        self.status(resp, 204, "password-reset неизвестного email -> 204 (не раскрываем аккаунты)")

        r.sec("3. Кейсы (идемпотентность, If-Match / 409)")
        cid = uid()
        case = dict(_load("CaseRecordDTO"), id=cid, revision=0, file_count=0, storage_bytes=0, created_at=now_iso(), updated_at=now_iso())
        resp = c("POST", "/v1/cases", token=tokA, body=case)
        if self.status(resp, {200, 201}, "POST /v1/cases"):
            self.schema(resp.json(), "CaseRecordDTO", "case: схема CaseRecordDTO")
            r.add(resp.json().get("revision") == 1 and resp.json().get("id") == cid, "create: revision == 1, id сохранён", resp.body[:150])
        again = dict(case, sealed_header=b64(b"other-header"))
        resp = c("POST", "/v1/cases", token=tokA, body=again)
        if self.status(resp, {200, 201}, "повторный POST того же id (идемпотентность)"):
            j = resp.json() or {}
            r.add(j.get("id") == cid and j.get("revision") == 1 and j.get("sealed_header") == case["sealed_header"],
                  "re-create вернул СУЩЕСТВУЮЩУЮ запись (revision=1, sealed_header прежний)", resp.body[:200])
        resp = c("GET", "/v1/cases", token=tokA)
        if self.status(resp, 200, "GET /v1/cases") and isinstance(resp.json(), list):
            r.add(sum(1 for x in resp.json() if x["id"] == cid) == 1, "кейс в списке ровно один раз")
        resp = c("GET", "/v1/cases", token=tokB)
        if resp.status == 200 and isinstance(resp.json(), list):
            r.add(all(x["id"] != cid for x in resp.json()), "изоляция: пользователь B не видит кейс A")
        upd = dict(case, sealed_header=b64(b"new-header"))
        resp = c("PUT", "/v1/cases/" + cid, token=tokA, body=upd, headers={"If-Match": "1"})
        if self.status(resp, 200, "PUT /v1/cases/{id} If-Match: 1"):
            r.add(resp.json().get("revision") == 2 and resp.json().get("sealed_header") == upd["sealed_header"], "update: revision 2, sealed_header обновлён", resp.body[:150])
        resp = c("PUT", "/v1/cases/" + cid, token=tokA, body=upd, headers={"If-Match": "1"})
        self.error(resp, 409, "conflict", "PUT со старым If-Match: 1 -> 409 conflict")
        resp = c("PUT", "/v1/cases/" + uid(), token=tokA, body=upd, headers={"If-Match": "1"})
        self.error(resp, 404, "not_found", "PUT несуществующего кейса -> 404 not_found")
        resp = c("GET", "/v1/cases/%s/files" % uid(), token=tokA)
        self.error(resp, 404, "not_found", "GET files несуществующего кейса -> 404")
        resp = c("GET", "/v1/cases/%s/files" % cid, token=tokB)
        self.status(resp, {403, 404}, "чужой кейс: GET files -> 403/404")

        r.sec("4. Файлы и blob'ы")
        fid = uid()
        blob = os.urandom(2048); sha = hashlib.sha256(blob).hexdigest()
        frec = {k: v for k, v in _load("FileRecordDTO").items() if k != "deleted_at"}
        frec.update(id=fid, case_id=cid, ciphertext_size=len(blob), ciphertext_sha256=sha, revision=0, created_at=now_iso(), updated_at=now_iso())
        resp = c("POST", "/v1/files", token=tokA, body=dict(frec, case_id=uid()))
        self.error(resp, 404, "not_found", "POST /v1/files с несуществующим case_id -> 404")
        resp = c("POST", "/v1/files", token=tokA, body=frec)
        if self.status(resp, {200, 201}, "POST /v1/files"):
            self.schema(resp.json(), "FileRecordDTO", "file: схема FileRecordDTO")
            r.add(resp.json().get("revision") == 1, "file create: revision == 1")
        resp = c("POST", "/v1/files", token=tokA, body=frec)
        if self.status(resp, {200, 201}, "повторный POST файла (идемпотентно)"):
            r.add((resp.json() or {}).get("revision") == 1, "re-create файла: revision по-прежнему 1")
        resp = c("PUT", "/v1/files/%s/blob" % fid, token=tokA, raw=blob, headers={"X-Content-SHA256": "0" * 64})
        self.error(resp, 422, "integrity_failed", "blob с неверным X-Content-SHA256 -> 422 integrity_failed")
        resp = c("PUT", "/v1/files/%s/blob" % fid, token=tokA, raw=blob[:-1], headers={"X-Content-SHA256": sha})
        self.error(resp, 422, "integrity_failed", "blob неверной длины -> 422 integrity_failed")
        resp = c("PUT", "/v1/files/%s/blob" % fid, token=tokA, raw=blob, headers={"X-Content-SHA256": sha})
        self.status(resp, 204, "PUT blob с верным sha -> 204")
        resp = c("GET", "/v1/files/%s/blob" % fid, token=tokA, headers={"Accept": "application/octet-stream"})
        if self.status(resp, 200, "GET blob"): r.add(resp.body == blob, "скачанные байты идентичны загруженным")
        resp = c("GET", "/v1/files/%s/blob" % fid, token=tokB)
        self.status(resp, {403, 404}, "чужой blob -> 403/404")
        resp = c("GET", "/v1/files/%s/blob" % uid(), token=tokA)
        self.error(resp, 404, "not_found", "GET blob несуществующего файла -> 404")
        resp = c("GET", "/v1/cases/%s/files" % cid, token=tokA)
        if self.status(resp, 200, "GET /v1/cases/{id}/files") and isinstance(resp.json(), list):
            r.add(any(x["id"] == fid for x in resp.json()), "файл в списке кейса")
            for it in resp.json(): self.schema(it, "FileRecordDTO", "files list: схема")
        resp = c("GET", "/v1/cases", token=tokA)
        cr = next((x for x in (resp.json() or []) if x.get("id") == cid), None) if resp.status == 200 else None
        r.add(bool(cr) and cr["file_count"] == 1 and cr["storage_bytes"] >= len(blob), "кейс: file_count=1 и storage_bytes>=размера blob", str(cr))
        fupd = dict(frec, sealed_metadata=b64(b"meta-2"))
        resp = c("PUT", "/v1/files/" + fid, token=tokA, body=fupd, headers={"If-Match": "1"})
        if self.status(resp, 200, "PUT /v1/files/{id} If-Match: 1"): r.add(resp.json().get("revision") == 2, "file update: revision 2")
        resp = c("PUT", "/v1/files/" + fid, token=tokA, body=fupd, headers={"If-Match": "1"})
        self.error(resp, 409, "conflict", "PUT файла со старым If-Match -> 409 conflict")
        resp = c("GET", "/v1/files/%s/versions" % fid, token=tokA)
        if self.status(resp, 200, "GET versions") and isinstance(resp.json(), list):
            for it in resp.json(): self.schema(it, "FileVersionDTO", "versions: схема")
        resp = c("POST", "/v1/files/%s/trash" % fid, token=tokA)
        self.status(resp, 204, "POST trash -> 204")
        resp = c("GET", "/v1/trash/files", token=tokA)
        if self.status(resp, 200, "GET /v1/trash/files") and isinstance(resp.json(), list):
            it = next((x for x in resp.json() if x["id"] == fid), None)
            r.add(bool(it) and it.get("deleted_at"), "файл в корзине с deleted_at")
        resp = c("GET", "/v1/cases/%s/files" % cid, token=tokA)
        if resp.status == 200: r.add(all(x["id"] != fid for x in resp.json()), "удалённый файл не в списке кейса")
        resp = c("POST", "/v1/files/%s/restore" % fid, token=tokA, body={})
        if self.status(resp, 200, "POST restore"):
            self.schema(resp.json(), "FileRecordDTO", "restore: схема"); r.add(not resp.json().get("deleted_at"), "restore: deleted_at снят")
        resp = c("GET", "/v1/billing/plans", token=tokA)
        if self.status(resp, 200, "GET billing/plans") and isinstance(resp.json(), list):
            for it in resp.json(): self.schema(it, "PlanDTO", "plans: схема")
        resp = c("GET", "/v1/billing/subscription", token=tokA)
        if self.status(resp, 200, "GET billing/subscription"): self.schema(resp.json(), "SubscriptionDTO", "subscription: схема")
        big = dict(frec, id=uid(), ciphertext_size=LIMIT * 2, ciphertext_sha256="0" * 64)
        resp = c("POST", "/v1/files", token=tokA, body=big)
        if resp.status == 413:
            j = resp.json() or {}
            r.add(j.get("code") == "quota_exceeded" and isinstance(j.get("limit_bytes"), int) and j["limit_bytes"] > 0, "413 quota_exceeded несёт limit_bytes > 0", resp.body[:150])
        else:
            r.add(False, "квота: файл 2 ГБ -> 413 quota_exceeded", "статус %s (если у плана лимит больше 2 ГБ - игнорируйте)" % resp.status, warn=True)

        r.sec("5. Журнал")
        resp = c("POST", "/v1/audit", token=tokA, body={"kind": "caseUnlocked", "case_id": cid})
        self.status(resp, 204, "POST /v1/audit caseUnlocked -> 204")
        resp = c("GET", "/v1/audit?limit=50", token=tokA)
        if self.status(resp, 200, "GET /v1/audit?limit=50") and isinstance(resp.json(), list):
            for it in resp.json()[:20]: self.schema(it, "AuditEventDTO", "audit: схема AuditEventDTO")

        r.sec("6. Чат (идентичность, send / fetch / ack)")
        keyA, keyB = os.urandom(32), os.urandom(32)
        resp = c("PUT", "/v1/chat/identity", token=tokA, body={"public_key": b64(os.urandom(5))})
        self.error(resp, 400, "validation", "identity с ключом не 32 байта -> 400 validation")
        resp = c("PUT", "/v1/chat/identity", token=tokA, body={"public_key": b64(keyA)})
        if self.status(resp, 200, "PUT /v1/chat/identity (A)"):
            self.schema(resp.json(), "ChatUserDTO", "identity: схема ChatUserDTO")
            r.add(resp.json().get("identity_key") == b64(keyA), "identity_key == отправленному public_key")
        resp = c("PUT", "/v1/chat/identity", token=tokA, body={"public_key": b64(keyA)})
        self.status(resp, 200, "identity идемпотентна (повтор того же ключа)")
        resp = c("PUT", "/v1/chat/identity", token=tokB, body={"public_key": b64(keyB)})
        self.status(resp, 200, "PUT /v1/chat/identity (B)")
        resp = c("GET", "/v1/chat/users/" + idB, token=tokA)
        if self.status(resp, 200, "GET /v1/chat/users/{B}"):
            self.schema(resp.json(), "ChatUserDTO", "findUser: схема"); r.add(resp.json().get("identity_key") == b64(keyB), "findUser отдаёт ключ B")
        resp = c("GET", "/v1/chat/users/" + uid(), token=tokA)
        self.error(resp, 404, "not_found", "findUser неизвестного -> 404 not_found")
        mid = uid(); t = now_iso(); exp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 30 * 86400))
        env = {"id": mid, "sender_id": idA, "recipient_id": idB, "version": 1, "ciphertext": b64(b"\x00\x00\x00\x01" + os.urandom(40)),
               "sent_at": t, "expires_at": exp}
        resp = c("POST", "/v1/chat/messages", token=tokA, body=dict(env, sender_id=idB, id=uid()))
        self.error(resp, 403, "forbidden", "send с чужим sender_id -> 403 forbidden")
        resp = c("POST", "/v1/chat/messages", token=tokA, body=dict(env, recipient_id=uid(), id=uid()))
        self.error(resp, 404, "not_found", "send неизвестному получателю -> 404 not_found")
        resp = c("POST", "/v1/chat/messages", token=tokA, body=env)
        self.status(resp, 204, "POST /v1/chat/messages -> 204")
        resp = c("POST", "/v1/chat/messages", token=tokA, body=env)
        self.status(resp, 204, "повтор send с тем же id -> 204 (идемпотентно)")
        resp = c("GET", "/v1/chat/messages?limit=100", token=tokB)
        if self.status(resp, 200, "B: GET /v1/chat/messages?limit=100") and isinstance(resp.json(), list):
            got = [x for x in resp.json() if x.get("id") == mid]
            r.add(len(got) == 1, "конверт у B ровно один раз (дедуп)", "найдено %d" % len(got))
            if got:
                self.schema(got[0], "ChatEnvelopeDTO", "fetch: схема ChatEnvelopeDTO")
                r.add(got[0]["ciphertext"] == env["ciphertext"] and got[0]["sender_id"] == idA and got[0]["recipient_id"] == idB,
                      "ciphertext/sender/recipient не искажены")
        resp = c("GET", "/v1/chat/messages?limit=100", token=tokB)
        if resp.status == 200: r.add(any(x["id"] == mid for x in resp.json()), "fetch не удаляет конверт до ack")
        resp = c("GET", "/v1/chat/messages?limit=100", token=tokA)
        if resp.status == 200: r.add(all(x["id"] != mid for x in resp.json()), "отправитель не видит чужую очередь")
        resp = c("POST", "/v1/chat/messages/ack", token=tokA, body={"ids": [mid]})
        self.status(resp, 204, "ack чужих id игнорируется (204)")
        resp = c("GET", "/v1/chat/messages?limit=100", token=tokB)
        if resp.status == 200: r.add(any(x["id"] == mid for x in resp.json()), "после чужого ack конверт остался у B")
        resp = c("POST", "/v1/chat/messages/ack", token=tokB, body={"ids": [mid]})
        self.status(resp, 204, "B: POST ack -> 204")
        resp = c("GET", "/v1/chat/messages?limit=100", token=tokB)
        if resp.status == 200: r.add(all(x["id"] != mid for x in resp.json()), "после ack конверта в очереди нет")

        r.sec("7. Контракт 1.3.0 (501 not_implemented допустим)")
        now = now_iso()
        j = self.ok_or_501(c("POST", "/v1/security-events", token=tokA, body=dict(_load("SecurityEventDTO"), case_id=cid, at=now)), 204, "POST /v1/security-events")
        resp = c("POST", "/v1/security-events", token=tokA, body={"kind": "bogusKind", "at": now})
        if resp.status != 501: self.error(resp, 400, "validation", "security-events: неизвестный kind -> 400")
        self.ok_or_501(c("GET", "/v1/backups", token=tokA), 200, "GET /v1/backups", "BackupInfoDTO", True)
        self.ok_or_501(c("GET", "/v1/invites", token=tokA), 200, "GET /v1/invites", "CaseInviteDTO", True)
        self.ok_or_501(c("GET", "/v1/cases/%s/members" % cid, token=tokA), 200, "GET /v1/cases/{id}/members", "CaseMemberDTO", True)
        resp = c("GET", "/v1/cases/%s/wrapped-key" % cid, token=tokA)
        if resp.status == 501: self.ok_or_501(resp, 200, "GET wrapped-key")
        else: self.status(resp, {200, 404}, "GET wrapped-key (200 {wrapped_key} или 404)")
        self.ok_or_501(c("GET", "/v1/chat/groups", token=tokA), 200, "GET /v1/chat/groups", "GroupDTO", True)
        gid = uid()
        grp = dict(_load("GroupDTO"), id=gid, member_ids=[idA, idB], created_at=now)
        g1 = self.ok_or_501(c("POST", "/v1/chat/groups", token=tokA, body=grp), {200, 201}, "POST /v1/chat/groups", "GroupDTO")
        if g1 is not None:
            g2 = self.ok_or_501(c("POST", "/v1/chat/groups", token=tokA, body=grp), {200, 201}, "POST /v1/chat/groups повтор (идемпотентно по id)")
            r.add(g2 is not None and g2.get("id") == gid, "re-create группы вернул ту же группу")
            genv = dict(_load("GroupEnvelopeDTO"), id=uid(), group_id=gid, sender_id=idA, recipient_ids=[idB], sent_at=now)
            self.ok_or_501(c("POST", "/v1/chat/groups/%s/messages" % gid, token=tokA, body=genv), 204, "POST group message")
        bid = uid(); bblob = os.urandom(512); bsha = hashlib.sha256(bblob).hexdigest()
        info = dict(_load("BackupInfoDTO"), id=bid, sha256=bsha, size_bytes=len(bblob), created_at=now)
        resp = c("PUT", "/v1/backups/" + bid, token=tokA, raw=bblob, headers={"X-LK-Info": json.dumps(info, sort_keys=True), "X-LK-SHA256": bsha})
        if self.ok_or_501(resp, 204, "PUT /v1/backups/{id}") is not None or resp.status == 204:
            resp = c("PUT", "/v1/backups/" + bid, token=tokA, raw=bblob, headers={"X-LK-Info": json.dumps(info, sort_keys=True), "X-LK-SHA256": "0" * 64})
            self.error(resp, 422, "integrity_failed", "backup с неверным X-LK-SHA256 -> 422")
            resp = c("GET", "/v1/backups/%s/blob" % bid, token=tokA)
            if self.status(resp, 200, "GET backup blob"): r.add(resp.body == bblob, "backup blob идентичен")
            self.status(c("DELETE", "/v1/backups/" + bid, token=tokA), 204, "DELETE backup -> 204")

        r.sec("8. Очистка")
        self.status(c("DELETE", "/v1/files/" + fid, token=tokA), 204, "DELETE /v1/files/{id} -> 204")
        resp = c("GET", "/v1/files/%s/blob" % fid, token=tokA)
        self.error(resp, 404, "not_found", "blob удалённого файла -> 404")
        self.status(c("DELETE", "/v1/cases/" + cid, token=tokA), 204, "DELETE /v1/cases/{id} -> 204")
        resp = c("DELETE", "/v1/cases/" + cid, token=tokA)
        self.status(resp, {204, 404}, "повторный DELETE кейса -> 404 (или 204, если идемпотентно)")
        sess = c("GET", "/v1/account/sessions", token=tokA)
        self.status(c("POST", "/v1/account/sessions/revoke-others", token=tokA), 204, "POST sessions/revoke-others -> 204")
        self.status(c("POST", "/v1/auth/logout", token=tokB), 204, "POST /v1/auth/logout (Bearer) -> 204")
        self.error(c("POST", "/v1/auth/logout"), 401, "unauthorized", "logout без Bearer -> 401")

# ───────────────────────── мок-сервер ─────────────────────────
class MockState:
    def __init__(self):
        self.lock = threading.Lock()
        self.users = {}; self.tokens = {}; self.refresh = {}; self.sessions = {}
        self.cases = {}; self.files = {}; self.blobs = {}; self.queue = {}; self.identity = {}; self.audit = []

class MockHandler(BaseHTTPRequestHandler):
    S = MockState()
    def log_message(self, *a): pass
    def _send(self, status, obj=None, raw=None, ctype="application/json"):
        body = raw if raw is not None else (b"" if obj is None else json.dumps(obj).encode())
        self.send_response(status)
        if status != 204:
            self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body)))
        else: self.send_header("Content-Length", "0")
        self.end_headers()
        if status != 204: self.wfile.write(body)
    def _err(self, status, code, msg, **extra):
        self._send(status, dict({"code": code, "message": msg}, **extra))
    def _user(self):
        h = self.headers.get("Authorization", "")
        uid_ = self.S.tokens.get(h[7:]) if h.startswith("Bearer ") else None
        if not uid_: self._err(401, "unauthorized", "Требуется вход"); return None
        return self.S.users[uid_]
    def _session(self, u):
        sid = str(uuid.uuid4()); acc, ref = "acc-" + uuid.uuid4().hex, "ref-" + uuid.uuid4().hex
        self.S.tokens[acc] = u["id"]; self.S.refresh[ref] = u["id"]
        self.S.sessions.setdefault(u["id"], []).append({"id": sid, "token": acc, "created": now_iso()})
        return {"access_token": acc, "refresh_token": ref, "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 3600)),
                "account": self._acc(u)}
    @staticmethod
    def _acc(u): return {k: u[k] for k in ("id", "email", "username", "mfa_enabled", "created_at", "backup_email") if u.get(k) is not None}
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def _json(self):
        try:
            d = json.loads(self._body().decode() or "null"); return d if isinstance(d, dict) else None
        except Exception: return None

    def do_GET(self): self._route("GET")
    def do_POST(self): self._route("POST")
    def do_PUT(self): self._route("PUT")
    def do_PATCH(self): self._route("PATCH")
    def do_DELETE(self): self._route("DELETE")

    def _route(self, m):
        path, _, qs = self.path.partition("?")
        with self.S.lock:
            try: self._dispatch(m, path, qs)
            except Exception as e: self._err(500, "server", "mock error: %r" % e)

    def _dispatch(self, m, p, qs):
        S = self.S
        # --- без авторизации
        if (m, p) == ("POST", "/v1/auth/register"):
            b = self._json() or {}
            if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", str(b.get("email", ""))) or not b.get("username") or len(str(b.get("password", ""))) < 6:
                return self._err(400, "validation", "Проверьте email, имя и пароль (от 6 символов)")
            if any(u["email"] == b["email"] or u["username"] == b["username"] for u in S.users.values()):
                return self._err(400, "validation", "Такой пользователь уже есть")
            u = {"id": str(uuid.uuid4()), "email": b["email"], "username": b["username"], "password": b["password"], "mfa_enabled": False, "created_at": now_iso()}
            S.users[u["id"]] = u; return self._send(200, self._session(u))
        if (m, p) == ("POST", "/v1/auth/login"):
            b = self._json() or {}
            u = next((x for x in S.users.values() if b.get("identifier") in (x["email"], x["username"]) and x["password"] == b.get("password")), None)
            if not u: return self._err(401, "unauthorized", "Неверный логин или пароль")
            return self._send(200, {"session": self._session(u)})
        if (m, p) == ("POST", "/v1/auth/refresh"):
            b = self._json() or {}; uid_ = S.refresh.get(b.get("refresh_token"))
            if not uid_: return self._err(401, "unauthorized", "Сессия истекла")
            return self._send(200, self._session(S.users[uid_]))
        if (m, p) == ("POST", "/v1/auth/password-reset"): return self._send(204)
        if (m, p) == ("POST", "/v1/auth/mfa/verify"): return self._err(401, "mfa_invalid", "Неверный код")
        u = self._user()
        if not u: return
        me = u["id"]
        # --- auth / account
        if (m, p) == ("POST", "/v1/auth/logout"):
            h = self.headers.get("Authorization", "")[7:]; S.tokens.pop(h, None); return self._send(204)
        if p == "/v1/account" and m == "GET": return self._send(200, self._acc(u))
        if p == "/v1/account" and m == "PATCH":
            b = self._json() or {}
            if "backup_email" not in b: return self._err(400, "validation", "Нет поля backup_email")
            u["backup_email"] = b["backup_email"]; return self._send(200, self._acc(u))
        if p == "/v1/account/storage":
            per = {}; used = 0
            for f in S.files.values():
                if f["_owner"] == me and f["id"] in S.blobs: per[f["case_id"]] = per.get(f["case_id"], 0) + f["ciphertext_size"]
            used = sum(per.values())
            return self._send(200, {"used_bytes": used, "limit_bytes": LIMIT, "per_case": [{"case_id": k, "bytes": v} for k, v in per.items()]})
        if p == "/v1/account/sessions" and m == "GET":
            cur = self.headers.get("Authorization", "")[7:]
            return self._send(200, [{"id": s["id"], "device_name": "mock", "platform": "ios", "created_at": s["created"], "last_active_at": s["created"],
                                     "is_current": s["token"] == cur} for s in S.sessions.get(me, [])])
        if (m, p) == ("POST", "/v1/account/sessions/revoke-others"):
            cur = self.headers.get("Authorization", "")[7:]
            S.sessions[me] = [s for s in S.sessions.get(me, []) if s["token"] == cur]; return self._send(204)
        mm = re.match(r"^/v1/account/sessions/([^/]+)$", p)
        if mm and m == "DELETE":
            before = len(S.sessions.get(me, [])); S.sessions[me] = [s for s in S.sessions.get(me, []) if s["id"] != mm.group(1)]
            return self._send(204) if len(S.sessions[me]) < before else self._err(404, "not_found", "Нет такого сеанса")
        # --- billing / audit
        if p == "/v1/billing/plans": return self._send(200, [{"id": "free", "title": "Бесплатный", "storage_bytes": LIMIT, "price_minor": 0, "currency": "USD", "period": "free"}])
        if p == "/v1/billing/subscription": return self._send(200, {"plan_id": "free", "status": "active"})
        if p == "/v1/audit" and m == "GET":
            return self._send(200, [{k: v for k, v in a.items() if k != "_u" and v is not None} for a in reversed(S.audit) if a["_u"] == me])
        if p == "/v1/audit" and m == "POST":
            b = self._json() or {}
            if not b.get("kind"): return self._err(400, "validation", "kind обязателен")
            S.audit.append({"_u": me, "id": str(uuid.uuid4()), "kind": b["kind"], "case_id": b.get("case_id"), "device_name": "mock", "at": now_iso()}); return self._send(204)
        # --- cases
        if p == "/v1/cases" and m == "GET":
            return self._send(200, [self._case(c) for c in S.cases.values() if c["_owner"] == me])
        if p == "/v1/cases" and m == "POST":
            b = self._json() or {}
            if not b.get("id") or not self._isb64(b.get("sealed_header")): return self._err(400, "validation", "id и sealed_header обязательны")
            ex = S.cases.get(b["id"])
            if ex: return self._send(200, self._case(ex)) if ex["_owner"] == me else self._err(403, "forbidden", "Чужой id")
            c = {"id": b["id"], "sealed_header": b["sealed_header"], "recovery_wrapped_key": b.get("recovery_wrapped_key"), "revision": 1,
                 "created_at": now_iso(), "updated_at": now_iso(), "_owner": me}
            S.cases[c["id"]] = c; return self._send(200, self._case(c))
        mm = re.match(r"^/v1/cases/([^/]+)$", p)
        if mm:
            c = S.cases.get(mm.group(1))
            if not c or c["_owner"] != me: return self._err(404, "not_found", "Кейс не найден")
            if m == "PUT":
                try: exp = int(self.headers.get("If-Match", ""))
                except ValueError: return self._err(400, "validation", "Нужен If-Match")
                if exp != c["revision"]: return self._err(409, "conflict", "Версия устарела")
                b = self._json() or {}
                c["sealed_header"] = b.get("sealed_header", c["sealed_header"]); c["recovery_wrapped_key"] = b.get("recovery_wrapped_key", c["recovery_wrapped_key"])
                c["revision"] += 1; c["updated_at"] = now_iso(); return self._send(200, self._case(c))
            if m == "DELETE":
                for fid in [f for f, r in S.files.items() if r["case_id"] == c["id"]]: S.files.pop(fid); S.blobs.pop(fid, None)
                S.cases.pop(c["id"]); return self._send(204)
        mm = re.match(r"^/v1/cases/([^/]+)/files$", p)
        if mm and m == "GET":
            c = S.cases.get(mm.group(1))
            if not c or c["_owner"] != me: return self._err(404, "not_found", "Кейс не найден")
            return self._send(200, [self._file(f) for f in S.files.values() if f["case_id"] == c["id"] and not f.get("deleted_at")])
        if p == "/v1/trash/files": return self._send(200, [self._file(f) for f in S.files.values() if f["_owner"] == me and f.get("deleted_at")])
        # --- files
        if (m, p) == ("POST", "/v1/files"):
            b = self._json() or {}
            if not re.match(r"^[0-9a-f]{64}$", str(b.get("ciphertext_sha256", ""))) or not b.get("id") or not isinstance(b.get("ciphertext_size"), int):
                return self._err(400, "validation", "Некорректные поля файла")
            c = S.cases.get(b.get("case_id"))
            if not c or c["_owner"] != me: return self._err(404, "not_found", "Кейс не найден")
            ex = S.files.get(b["id"])
            if ex: return self._send(200, self._file(ex)) if ex["_owner"] == me else self._err(403, "forbidden", "Чужой id")
            used = sum(f["ciphertext_size"] for f in S.files.values() if f["_owner"] == me)
            if used + b["ciphertext_size"] > LIMIT: return self._err(413, "quota_exceeded", "Недостаточно места", limit_bytes=LIMIT)
            f = {"id": b["id"], "case_id": b["case_id"], "sealed_metadata": b.get("sealed_metadata", ""), "ciphertext_size": b["ciphertext_size"],
                 "ciphertext_sha256": b["ciphertext_sha256"], "revision": 1, "created_at": now_iso(), "updated_at": now_iso(), "_owner": me}
            S.files[f["id"]] = f; return self._send(200, self._file(f))
        mm = re.match(r"^/v1/files/([^/]+)(/blob|/trash|/restore|/versions)?$", p)
        if mm:
            f = S.files.get(mm.group(1)); sub = mm.group(2)
            if not f or f["_owner"] != me: return self._err(404, "not_found", "Файл не найден")
            if sub is None and m == "PUT":
                try: exp = int(self.headers.get("If-Match", ""))
                except ValueError: return self._err(400, "validation", "Нужен If-Match")
                if exp != f["revision"]: return self._err(409, "conflict", "Версия устарела")
                f["sealed_metadata"] = (self._json() or {}).get("sealed_metadata", f["sealed_metadata"]); f["revision"] += 1; f["updated_at"] = now_iso()
                return self._send(200, self._file(f))
            if sub is None and m == "DELETE": S.files.pop(f["id"]); S.blobs.pop(f["id"], None); return self._send(204)
            if sub == "/blob" and m == "PUT":
                data = self._body(); sha = hashlib.sha256(data).hexdigest()
                if not (sha == self.headers.get("X-Content-SHA256") == f["ciphertext_sha256"] and len(data) == f["ciphertext_size"]):
                    return self._err(422, "integrity_failed", "Контрольная сумма не совпала")
                S.blobs[f["id"]] = data; return self._send(204)
            if sub == "/blob" and m == "GET":
                if f["id"] not in S.blobs: return self._err(404, "not_found", "Нет данных")
                return self._send(200, raw=S.blobs[f["id"]], ctype="application/octet-stream")
            if sub == "/trash" and m == "POST":
                f["deleted_at"] = now_iso(); f["revision"] += 1; return self._send(204)
            if sub == "/restore" and m == "POST":
                f.pop("deleted_at", None); f["revision"] += 1; return self._send(200, self._file(f))
            if sub == "/versions" and m == "GET": return self._send(200, [])
        # --- chat
        if (m, p) == ("PUT", "/v1/chat/identity"):
            try: raw = base64.b64decode((self._json() or {}).get("public_key", ""), validate=True)
            except Exception: raw = b""
            if len(raw) != 32: return self._err(400, "validation", "Ключ должен быть 32 байта")
            if me in S.identity and S.identity[me] != raw: return self._err(403, "forbidden", "Ключ уже зарегистрирован")
            S.identity[me] = raw; return self._send(200, {"id": me, "username": u["username"], "identity_key": b64(raw)})
        mm = re.match(r"^/v1/chat/users/([^/]+)$", p)
        if mm:
            t = S.users.get(mm.group(1))
            if not t or t["id"] not in S.identity: return self._err(404, "not_found", "Пользователь не найден")
            return self._send(200, {"id": t["id"], "username": t["username"], "identity_key": b64(S.identity[t["id"]])})
        if (m, p) == ("POST", "/v1/chat/messages"):
            b = self._json() or {}
            if b.get("sender_id") != me: return self._err(403, "forbidden", "sender_id не совпадает с пользователем")
            if b.get("recipient_id") not in S.users: return self._err(404, "not_found", "Получатель не найден")
            if not b.get("id") or not self._isb64(b.get("ciphertext")): return self._err(400, "validation", "Некорректный конверт")
            q = S.queue.setdefault(b["recipient_id"], [])
            if not any(e["id"] == b["id"] and e["sender_id"] == me for e in q): q.append(b)
            return self._send(204)
        if (m, p) == ("GET", "/v1/chat/messages"):
            lim = 100
            for kv in qs.split("&"):
                if kv.startswith("limit=") and kv[6:].isdigit(): lim = int(kv[6:])
            return self._send(200, S.queue.get(me, [])[:lim])
        if (m, p) == ("POST", "/v1/chat/messages/ack"):
            ids = set((self._json() or {}).get("ids", [])); S.queue[me] = [e for e in S.queue.get(me, []) if e["id"] not in ids]; return self._send(204)
        # --- 1.3.0: не реализовано
        if re.match(r"^/v1/(security-events|backups|invites|chat/groups)(/|$)", p) or re.match(r"^/v1/cases/[^/]+/(members|invites|wrapped-key)", p):
            return self._err(501, "not_implemented", "not_implemented")
        return self._err(404, "not_found", "Нет такого маршрута")

    @staticmethod
    def _isb64(s):
        try: base64.b64decode(s, validate=True); return isinstance(s, str)
        except Exception: return False
    def _case(self, c):
        fs = [f for f in self.S.files.values() if f["case_id"] == c["id"] and not f.get("deleted_at")]
        d = {k: v for k, v in c.items() if not k.startswith("_") and v is not None}
        d["file_count"] = len(fs)
        d["storage_bytes"] = sum(f["ciphertext_size"] for f in self.S.files.values() if f["case_id"] == c["id"] and f["id"] in self.S.blobs)
        return d
    @staticmethod
    def _file(f): return {k: v for k, v in f.items() if not k.startswith("_")}

def start_mock():
    MockHandler.S = MockState()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d" % srv.server_address[1]

# ───────────────────────── main ─────────────────────────
def main():
    ap = argparse.ArgumentParser(description="loKEY backend contract check")
    ap.add_argument("--base-url", help="например http://localhost:8080 (без хвостового /)")
    ap.add_argument("--token", help="access-токен пользователя A (по умолчанию скрипт сам регистрирует двух пользователей)")
    ap.add_argument("--mock", action="store_true", help="запустить встроенный мок-сервер и проверить скрипт на нём")
    a = ap.parse_args()
    srv = None
    if a.mock: srv, base = start_mock(); print("Мок-сервер: " + base)
    elif a.base_url: base = a.base_url
    else: ap.error("нужен --base-url или --mock")
    missing = [n for n in ("AccountDTO", "SessionDTO", "CaseRecordDTO", "FileRecordDTO") if not os.path.exists(os.path.join(FIX_DIR, n + ".json"))]
    if missing: print("Нет фикстур в %s: %s" % (FIX_DIR, missing)); return 1
    chk = Checker(base, a.token)
    try: chk.run()
    except Exception as e:
        chk.r.add(False, "скрипт упал", repr(e))
    if srv: srv.shutdown()
    rows = chk.r.rows
    npass = sum(1 for x in rows if x[0] == "PASS"); nwarn = sum(1 for x in rows if x[0] == "WARN"); fails = chk.r.fails()
    print("\n" + "=" * 60)
    print("Итого: %d PASS, %d WARN (не реализовано/необязательно), %d FAIL" % (npass, nwarn, len(fails)))
    for t, s, n, d in fails: print("  FAIL [%s] %s: %s" % (s, n, d))
    print("РЕЗУЛЬТАТ: " + ("ОК" if not fails else "ЕСТЬ ПРОВАЛЫ"))
    return 0 if not fails else 1

if __name__ == "__main__":
    sys.exit(main())
