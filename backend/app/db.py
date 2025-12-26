from typing import Optional

import asyncpg

_pool: Optional[asyncpg.Pool] = None
_dsn: Optional[str] = None


def initialize(dsn: str) -> None:
    global _dsn
    # Explicit init prevents hidden env lookups in lower layers.
    _dsn = dsn


async def connect() -> asyncpg.Pool:
    global _pool
    if _dsn is None:
        raise RuntimeError("Database DSN not initialized")
    if _pool is None:
        _pool = await asyncpg.create_pool(dsn=_dsn, min_size=1, max_size=5)
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
