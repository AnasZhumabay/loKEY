# loKEY

### Your data. Your key.

**loKEY** is an end-to-end encrypted (E2EE) vault for files and images, with a built-in encrypted messenger.

The project follows a **zero-knowledge architecture**: everything is encrypted on the user's device before it is
uploaded. The server stores only ciphertext. It never sees file contents, file names or messages, and it never
receives encryption keys.

The goal is to keep users in full control of their sensitive data.

---

## Core Principles

- **End-to-End Encryption.** Data is encrypted on the device before it leaves it.
- **Zero-Knowledge Server.** The server cannot read files, metadata or messages, and it holds no keys.
- **Client-Side Key Management.** Keys are generated and stored on the device (iOS Keychain).
- **Data Integrity.** Authenticated encryption on the client, plus a SHA-256 check on the server for every upload.
- **Privacy by Design.** Security is part of the architecture from the start, not added afterwards.

## Architecture

```text
            CLIENT (iOS)
   ┌──────────────────────────┐
   │  SwiftUI app             │
   │  + Widgets, Share ext.   │
   │                          │
   │  Key management          │
   │  AES-256-GCM (CryptoKit) │
   │  E2EE chat (X25519)      │
   └────────────┬─────────────┘
                │  HTTPS / REST (JSON + ciphertext)
   ┌────────────▼─────────────┐
   │  Reverse proxy (TLS)     │
   └────────────┬─────────────┘
   ┌────────────▼─────────────┐
   │  FastAPI backend         │
   │                          │
   │  Authentication, MFA     │
   │  Access control          │
   │  Quotas, integrity check │
   │  Encrypted chat mailbox  │
   └──────┬────────────┬──────┘
          │            │
   ┌──────▼─────┐ ┌────▼────────────┐
   │ PostgreSQL │ │ Blob storage    │
   │ records,   │ │ ciphertext only │
   │ metadata   │ │                 │
   └────────────┘ └─────────────────┘
```

The app and the server talk only through a versioned API contract (`Docs/BACKEND_CONTRACT.md`,
`Docs/backend-kit/openapi.yaml`).

### Encryption Workflow

1. The user adds a file to a **Case**, an independent encrypted container.
2. The app encrypts the file and its metadata (name, type, notes) with that Case's key, using AES-256-GCM.
3. Only the ciphertext and its SHA-256 are sent to the server.
4. The server checks the hash and size of the upload and stores the ciphertext.
5. To open a file, the app downloads the ciphertext, checks it and decrypts it **in memory**. Decrypted data is
   never written to disk.

**Encryption keys are never sent to the server.**

## Technology Stack

| Component | Technology |
|---|---|
| Mobile client | Swift / SwiftUI (iOS 17+), CryptoKit, no third-party libraries |
| Backend | Python / FastAPI, Pydantic, SQLAlchemy (async) |
| Database | PostgreSQL + Alembic migrations |
| Blob storage | Server-side storage for ciphertext (S3-compatible storage planned) |
| Encryption | AES-256-GCM, X25519, HKDF-SHA256, PBKDF2 |
| Passwords | argon2id (server side) |
| Communication | REST API over HTTPS |
| Deployment | Docker Compose, reverse proxy with automatic TLS |

## Key Features

### Authentication & Security

- Registration and sign-in by email or username
- Device sessions: list them, revoke one, or sign out everywhere
- Optional multi-factor authentication (TOTP authenticator apps)
- Automatic locking of Cases after inactivity, plus Face ID / passcode
- Brute-force protection and rate limiting
- Coercion protection (duress PIN) and an optional key wipe after repeated failed unlocks

### Secure File Storage

- Client-side encryption of files and their metadata
- Upload and download with integrity verification
- File versions with restore
- Trash with recovery (permanently deleted after 30 days)
- Offline access to selected files
- Storage quota and plans

### Case Management

- Independent encrypted Cases, each with its own key
- Create, rename and delete Cases
- Key file export and a **recovery phrase**: a lost key can be restored on the device, never by the server
- **Shared Cases** with editor and viewer roles: the Case key is wrapped separately for each member

### Encrypted Messenger

- One-to-one E2EE chat. Contacts are added in person via QR code.
- Keys come from X25519 key agreement. A new message key is derived for every message (forward secrecy along the chain).
- Safety-number verification by QR
- Disappearing messages, edits, reactions, replies
- Sending files from a Case

### Backup

- Encrypted backup archive, protected by a passphrase, kept on the server or in iCloud

## Security Model

The storage provider should never be able to access user content.

| Security Property | Implementation |
|---|---|
| Confidentiality | AES-256-GCM, a separate key per Case |
| Encryption location | Client only |
| Key ownership | Client only (Keychain) |
| Server knowledge | Ciphertext and minimal metadata (sizes, timestamps, who messages whom) |
| Integrity | Authenticated encryption + server-side SHA-256 verification |
| Account security | argon2id password hashes, revocable sessions, optional TOTP |
| Transport | HTTPS only |

### Important Security Considerations

- Encryption and decryption happen only on the client.
- Encryption keys are never exposed to backend services.
- Every request is authenticated and authorised separately; one account can never access another's data.
- Integrity is checked both before and after upload.
- Logs never contain user content, credentials or ciphertext.
- Server secrets are kept out of the repository (see *Getting Started*).

## Project Structure

```text
loKEY/
├── loKEY/                 # iOS app (SwiftUI)
│   ├── App/               # app state, navigation, configuration
│   ├── Contract/          # API contract: DTOs and service protocols
│   ├── Core/              # crypto, repositories, chat, backup, backend clients
│   ├── Domain/            # models and interfaces used by the UI
│   ├── DesignSystem/      # shared UI components
│   ├── Features/          # screens
│   ├── Resources/         # localisations
│   └── Shared/            # code shared with extensions
├── loKEYWidgets/          # home-screen widgets
├── loKEYShare/            # "Share to loKEY" extension
├── loKEYTests/            # unit tests
├── loKEYUITests/          # UI tests
│
├── backend/               # FastAPI server
│   ├── app/
│   │   ├── routers/       # API endpoints
│   │   ├── services/      # access rules, quotas, billing
│   │   ├── schemas/       # wire format (DTOs)
│   │   ├── core/          # config, errors, security, rate limiting
│   │   ├── models.py      # database tables
│   │   ├── storage.py     # ciphertext storage
│   │   └── jobs.py        # periodic cleanup
│   ├── migrations/        # database migrations
│   ├── tests/
│   └── deploy/            # production reverse-proxy config
│
├── Docs/                  # API contract, integration guide, backend kit
├── project.yml            # Xcode project definition (XcodeGen)
└── README.md
```

## Getting Started

### Backend

Requirements: Docker with Docker Compose, Python 3.12+.

```bash
cd backend
sh scripts/init-env.sh          # creates a local .env with random secrets (never committed)
docker compose up -d --build    # API on http://127.0.0.1:8080
```

Tests:

```bash
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/pytest -q
python3 -I ../Docs/backend-kit/contract_check.py --base-url http://localhost:8080
```

Production deployment and configuration are described in `backend/README.md`.

### iOS app

Requirements: macOS with Xcode, plus XcodeGen.

```bash
xcodegen generate   # then open loKEY.xcodeproj
```

By default the app runs against a built-in mock backend. To use a real server, set `useMocks` and `apiBaseURL`
in `AppConfig` (`loKEY/App/AppStore.swift`). The app accepts HTTPS only.

## Development Status

loKEY is under active development as a working demonstration of an E2EE storage system.

- [x] API contract between the app and the server
- [x] iOS client: Cases, files, encryption, key management, chat
- [x] Backend implementation (all contract endpoints, automated tests)
- [x] Integrity verification, trash, versions, quotas
- [x] Session security and MFA
- [ ] End-to-end testing of the app against the live backend
- [ ] Production deployment
- [ ] Independent security review

## Future Improvements

- Group chats in the app UI
- Push notifications that carry no message content
- Key rotation after revoking access to a shared Case
- Multi-device access to the same vault
- S3-compatible object storage for large files
- An independent cryptographic audit

## Disclaimer

loKEY is an educational and demonstration project.

It is not a replacement for professionally audited storage solutions. Its security has not been independently
reviewed, so it should not hold sensitive production data until it has been.

---

**loKEY — Your data. Your key.**
