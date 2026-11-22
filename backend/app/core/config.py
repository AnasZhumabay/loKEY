"""Settings come from environment variables prefixed with LOKEY_ (or a .env file)."""
from functools import lru_cache

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

DEV_SECRET = "dev-only-insecure-secret-change-me"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="LOKEY_", env_file=".env", extra="ignore")

    env: str = "dev"  # "dev" | "test" | "prod"
    database_url: str = "postgresql+asyncpg://lokey:lokey@localhost:5432/lokey"

    # Server-side secret: encrypts TOTP secrets at rest. Must be random and private in prod.
    secret_key: str = DEV_SECRET

    # Tokens (opaque random strings, only their SHA-256 is stored)
    access_token_ttl_seconds: int = 3600  # contract: access token lives ~1 h
    refresh_token_ttl_days: int = 30
    mfa_challenge_ttl_seconds: int = 300

    # Storage
    blob_dir: str = "./data/blobs"
    free_plan_bytes: int = 5_000_000_000  # 5 GB (decimal), same as the app's PlanDTO "free"
    max_versions_per_file: int = 20
    trash_retention_days: int = 30
    orphan_file_hours: int = 24  # file records whose blob never arrived

    # Chat
    chat_max_ciphertext_bytes: int = 8_000_000  # ~5 MB attachment + overhead (Docs/CHAT.md)
    chat_ttl_days: int = 30

    # Background cleanup (trash, orphans, expired chat/sessions); 0 = disabled (e.g. run `python -m app.jobs` by cron)
    cleanup_interval_seconds: int = 3600

    # Requests
    max_json_body_bytes: int = 12_000_000

    # Billing: accept purchases without a verified App Store transaction (StoreKit isn't wired in the app yet)
    allow_test_purchases: bool | None = None  # default: True outside prod

    @model_validator(mode="after")
    def _check(self) -> "Settings":
        if self.env == "prod" and (self.secret_key == DEV_SECRET or len(self.secret_key) < 32):
            raise ValueError("LOKEY_SECRET_KEY must be set to a random value of 32+ chars in prod")
        if self.allow_test_purchases is None:
            self.allow_test_purchases = self.env != "prod"
        return self

    @property
    def is_dev(self) -> bool:
        return self.env == "dev"


@lru_cache
def get_settings() -> Settings:
    return Settings()
