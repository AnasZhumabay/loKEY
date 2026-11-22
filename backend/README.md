# loKEY backend

FastAPI server for the loKEY iOS app, implementing **contract 1.3.0** — all 57 operations of
`../Docs/backend-kit/openapi.yaml` (sources: `../Docs/BACKEND_CONTRACT.md`, `../Docs/BACKEND_INTEGRATION.md`,
`../loKEY/Contract/*.swift`).

The server is zero-knowledge storage: it keeps ciphertext (`sealed_*`, blobs, wrapped keys, chat envelopes,
backups) and never tries to decrypt, parse or log it. All crypto happens in the app.

## Run (Docker, dev)

```bash
cd backend
docker compose up -d --build        # API on http://localhost:8080, Postgres on 127.0.0.1:5432
curl localhost:8080/health/ready    # {"status":"ready"}
xdg-open http://localhost:8080/docs # Swagger UI (dev only)
docker compose logs -f api
docker compose down                 # add -v to also wipe the DB and blobs
```

## Tests

```bash
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
docker compose up -d db
.venv/bin/pytest -q                 # 60 tests against a real Postgres (DB lokey_test)
.venv/bin/ruff check .
# official contract check (against the running API):
python3 -I ../Docs/backend-kit/contract_check.py --base-url http://localhost:8080
```

Current result: `contract_check.py` **137 PASS, 0 FAIL, 1 WARN** (the WARN is the 2 GB quota probe: the free plan is 5 GB).

## Production (HTTPS)

The app accepts only HTTPS. On a server with a domain pointing at it:

```bash
cp .env.prod.example .env           # LOKEY_DOMAIN, LOKEY_SECRET_KEY, POSTGRES_PASSWORD
docker compose -f docker-compose.yml -f docker-compose.prod.yml up -d --build
```

Caddy gets a Let's Encrypt certificate automatically. For a quick test from an iPhone without a server:
`cloudflared tunnel --url http://localhost:8080` gives a temporary `https://…trycloudflare.com` URL.

In the app (Mac): `loKEY/App/AppStore.swift`, `enum AppConfig` → `useMocks = false`, `apiBaseURL = URL(string: "https://<domain>")!`,
and fill in `loKEY/Core/Backend/LiveBackendV13.swift` (the 1.3.0 client calls are still stubs on the app side).

## Layout

| Path | What |
|---|---|
| `app/main.py` | app factory, routers, body-size limit, background cleanup |
| `app/core/config.py` | settings from `LOKEY_*` env vars (see `.env.example`) |
| `app/core/errors.py` | error envelope `{code, message, retry_after_seconds?, limit_bytes?}` |
| `app/core/security.py` | argon2id passwords, opaque tokens (only SHA-256 stored), AES-GCM for TOTP secrets |
| `app/core/ratelimit.py` | in-memory rate limiter (login, register, MFA, reset, chat send) |
| `app/schemas/types.py` | wire format: `UTCDateTime` (`…Z`, no fractions), `B64Bytes`, `ClientId`, `Sha256Hex` |
| `app/schemas/dto.py` | all DTOs, field-for-field from the Swift contract |
| `app/models.py` | tables; `migrations/` — Alembic (applied on container start) |
| `app/services/` | access rules for cases (owner / editor / viewer), quota, plans, audit |
| `app/routers/` | `auth`, `account`, `cases`, `files` (+blobs, trash, versions), `audit`, `billing`, `chat`, `groups`, `shared`, `backups`, `security_events` |
| `app/storage.py` | blob storage seam (`LocalBlobStorage`; S3/MinIO later); SHA-256 + size verified while streaming |
| `app/jobs.py` | cleanup: trash > 30 days, orphan records > 24 h, expired chat/sessions/challenges, audit > 1 year |
| `docker-compose.prod.yml`, `deploy/Caddyfile` | production with HTTPS |

## Decisions worth knowing

- **Tokens are opaque**, not JWT: the DB stores only their SHA-256. Revoking a session deletes its row and works immediately.
  Refresh tokens rotate on every refresh; reusing an old one kills the session (theft detection).
- **IDs accept any case.** The contract says lowercase UUIDs, but `BackupServiceImpl` sends `UUID().uuidString` (uppercase). Stored as sent.
- **Device name** — the 1.3.0 app sends no device info at login, so `SessionInfoDTO` is guessed from `User-Agent`
  ("iPhone"/"ios" + app build). Optional headers `X-Device-Name`, `X-Platform`, `X-App-Version` are honoured if the app adds them.
- **MFA**: TOTP (authenticator apps) with ±30 s drift, replay protection, 5 attempts per challenge. SMS → 400 (no SMS provider).
- **Chat identity key can't be replaced** (409) — silent replacement would allow impersonation. Reinstalling the app = new key,
  so a reset procedure is needed later (see open questions).
- **Shared cases**: active members see the case and its files; `editor` may write, `viewer` gets 403 on any write;
  usage counts against the owner. Security events are stored apart from the audit log (`duressUnlock` must not show up there).
- **Billing**: StoreKit isn't wired in the app, so purchases are accepted without Apple verification only when
  `LOKEY_ALLOW_TEST_PURCHASES` is on (default: on outside prod, off in prod).

## Open questions for the team

1. Password reset is a 204 stub — needs an email provider (SMTP). Note: it can never recover case keys.
2. Chat key reset after reinstall/new device (today: 409). Proposal: allow replacing the key after a fresh login with MFA, and notify contacts.
3. StoreKit 2: verify the signed transaction (JWS) on the server before raising the limit.
4. Push notifications: no endpoint in the contract (would be a MINOR version, e.g. `PUT /v1/account/push-token`).
5. Several API replicas would need Redis for the rate limiter (today: one process).
6. Group envelopes are delivered to recipients as normal envelopes with `version = 1` (the DTO has no version field).

## Progress

1. ✅ Skeleton, Docker, error envelope, format rules, blob storage
2. ✅ Auth: register / login / refresh / logout / MFA (TOTP) / sessions
3. ✅ Account + storage quota
4. ✅ Cases, files, blobs, trash, versions
5. ✅ Audit, billing
6. ✅ 1:1 chat
7. ✅ 1.3.0: shared cases, backups, groups, security events
8. ✅ Cleanup jobs, rate limiting, HTTPS deploy config — ⬜ actual hosting (server + domain) not chosen yet
