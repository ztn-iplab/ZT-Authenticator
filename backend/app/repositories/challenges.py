from datetime import datetime, timezone
from uuid import UUID, uuid4

import asyncpg


def _row_to_challenge(row: asyncpg.Record) -> dict:
    return {
        "id": row["id"],
        "device_id": row["device_id"],
        "rp_id": row["rp_id"],
        "nonce": row["nonce"],
        "expires_at": row["expires_at"],
        "created_at": row["created_at"],
    }


async def insert_challenge(
    pool: asyncpg.Pool,
    device_id: UUID,
    rp_id: str,
    nonce: str,
    expires_at: datetime,
) -> dict:
    challenge_id = uuid4()
    row = await pool.fetchrow(
        """
        INSERT INTO device_challenges (id, device_id, rp_id, nonce, expires_at)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id, device_id, rp_id, nonce, expires_at, created_at
        """,
        challenge_id,
        device_id,
        rp_id,
        nonce,
        expires_at,
    )
    return _row_to_challenge(row)


async def get_valid_challenge(
    pool: asyncpg.Pool,
    device_id: UUID,
    rp_id: str,
    nonce: str,
) -> dict | None:
    row = await pool.fetchrow(
        """
        SELECT id, device_id, rp_id, nonce, expires_at, created_at
        FROM device_challenges
        WHERE device_id = $1 AND rp_id = $2 AND nonce = $3 AND expires_at > NOW()
        ORDER BY created_at DESC
        LIMIT 1
        """,
        device_id,
        rp_id,
        nonce,
    )
    if row is None:
        return None
    return _row_to_challenge(row)


async def consume_challenge(pool: asyncpg.Pool, challenge_id: UUID) -> None:
    await pool.execute(
        """
        DELETE FROM device_challenges
        WHERE id = $1
        """,
        challenge_id,
    )


async def prune_expired(pool: asyncpg.Pool) -> None:
    await pool.execute(
        """
        DELETE FROM device_challenges
        WHERE expires_at < NOW()
        """,
    )
