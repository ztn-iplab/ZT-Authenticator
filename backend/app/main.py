import logging

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError

from app import db
from app.config import load_settings
from app.errors import validation_exception_handler
from app.logging_config import configure_logging
from app.routes import router

settings = load_settings()
configure_logging(settings.log_level)
logger = logging.getLogger(__name__)

app = FastAPI(title="ZT-TOTP Backend", version="0.1.0")
app.state.settings = settings
app.include_router(router)
app.add_exception_handler(RequestValidationError, validation_exception_handler)


@app.on_event("startup")
async def startup() -> None:
    # Connect early so startup fails fast if the DB is unavailable.
    db.initialize(settings.database_url)
    await db.ping()
    logger.info("startup complete env=%s", settings.app_env)


@app.on_event("shutdown")
async def shutdown() -> None:
    await db.close()
    logger.info("shutdown complete")


@app.get("/health")
async def health() -> dict:
    await db.ping()
    return {"status": "ok"}


@app.get("/")
async def root() -> dict:
    return {
        "service": "ZT-TOTP Backend",
        "docs": "/docs",
        "health": "/health",
    }
