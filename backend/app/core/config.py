"""Settings come from environment variables prefixed with LOKEY_ (or a .env file)."""
from functools import lru_cache

from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """No secret has a default: they come from the environment / .env only (see scripts/init-env.sh)."""
    model_config = SettingsConfigDict(env_prefix="LOKEY_", env_file=".env", extra="ignore")

    env: str = "dev"  # "dev" | "test" | "prod"
    database_url: str  # LOKEY_DATABASE_URL, contains the DB password

    # Server-side secret: encrypts TOTP secrets at rest. Random, 32+ chars, private.
    secret_key: str  # LOKEY_SECRET_KEY

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
        if "[" in self.secret_key or "[" in self.database_url:
            raise ValueError("Replace the [PLACEHOLDER] values in .env (or run: sh scripts/init-env.sh)")
        if len(self.secret_key) < 32:
            raise ValueError("LOKEY_SECRET_KEY must be a random value of 32+ chars")
        if self.allow_test_purchases is None:
            self.allow_test_purchases = self.env != "prod"
        return self

    @property
    def is_dev(self) -> bool:
        return self.env == "dev"


@lru_cache
def get_settings() -> Settings:
    return Settings()
