import os
from dataclasses import dataclass
from typing import Optional

from dotenv import load_dotenv


@dataclass(frozen=True)
class Settings:
    app_env: str
    log_level: str
    database_url: str
    redis_url: Optional[str]
    master_key: str
    recovery_pepper: str


def load_settings() -> Settings:
    load_dotenv()

    # Environment-driven configuration keeps secrets out of code.
    app_env = os.getenv("APP_ENV", "development")
    log_level = os.getenv("LOG_LEVEL", "INFO")
    database_url = os.getenv("DATABASE_URL")
    redis_url = os.getenv("REDIS_URL")
    master_key = os.getenv("MASTER_KEY")
    recovery_pepper = os.getenv("RECOVERY_PEPPER")

    if not database_url:
        raise RuntimeError("DATABASE_URL is not set")
    if not master_key:
        raise RuntimeError("MASTER_KEY is not set")
    if not recovery_pepper:
        raise RuntimeError("RECOVERY_PEPPER is not set")

    return Settings(
        app_env=app_env,
        log_level=log_level,
        database_url=database_url,
        redis_url=redis_url,
        master_key=master_key,
        recovery_pepper=recovery_pepper,
    )
