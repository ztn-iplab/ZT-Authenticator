import os
from typing import Optional

import asyncpg

_pool: Optional[asyncpg.Pool] = None


def _database_url() -> str:
    url = os.getenv("DATABASE_URL")
    if not url:
        raise RuntimeError("DATABASE_URL is not set")
    return url


async def connect() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(dsn=_database_url(), min_size=1, max_size=5)
    return _pool


async def close() -> None:
    global _pool
    if _pool is not None:
        await _pool.close()
        _pool = None


async def ping() -> None:
    pool = await connect()
    async with pool.acquire() as conn:
        await conn.execute("SELECT 1")
