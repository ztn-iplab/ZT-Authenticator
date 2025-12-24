from fastapi import FastAPI
from dotenv import load_dotenv

from app import db

load_dotenv()

app = FastAPI(title="ZT-TOTP Backend", version="0.1.0")


@app.on_event("startup")
async def startup() -> None:
    await db.ping()


@app.on_event("shutdown")
async def shutdown() -> None:
    await db.close()


@app.get("/health")
async def health() -> dict:
    await db.ping()
    return {"status": "ok"}
