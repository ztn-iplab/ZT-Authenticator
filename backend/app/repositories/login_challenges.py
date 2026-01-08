from datetime import datetime
from uuid import UUID, uuid4

import asyncpg


def _row_to_challenge(row: asyncpg.Record) -> dict:
    return {
        "id": row["id"],
        "user_id": row["user_id"],
        "device_id": row["device_id"],
        "rp_id": row["rp_id"],
        "nonce": row["nonce"],
        "otp_hash": row["otp_hash"],
        "status": row["status"],
        "created_at": row["created_at"],
        "expires_at": row["expires_at"],
        "approved_at": row["approved_at"],
        "denied_reason": row["denied_reason"],
    }


async def insert(
    pool: asyncpg.Pool,
    user_id: UUID,
    device_id: UUID,
    rp_id: str,
    nonce: str,
    otp_hash: str,
    expires_at: datetime,
) -> dict:
    challenge_id = uuid4()
    row = await pool.fetchrow(
        """
        INSERT INTO login_challenges (id, user_id, device_id, rp_id, nonce, otp_hash, expires_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        RETURNING id, user_id, device_id, rp_id, nonce, otp_hash, status, created_at, expires_at, approved_at, denied_reason
        """,
        challenge_id,
        user_id,
        device_id,
        rp_id,
        nonce,
        otp_hash,
        expires_at,
    )
    return _row_to_challenge(row)


async def get_by_id(pool: asyncpg.Pool, challenge_id: UUID) -> dict | None:
    row = await pool.fetchrow(
        """
        SELECT id, user_id, device_id, rp_id, nonce, otp_hash, status, created_at, expires_at, approved_at, denied_reason
        FROM login_challenges
        WHERE id = $1
        """,
        challenge_id,
    )
    if row is None:
        return None
    return _row_to_challenge(row)


async def get_pending_for_user(pool: asyncpg.Pool, user_id: UUID) -> dict | None:
    row = await pool.fetchrow(
        """
        SELECT id, user_id, device_id, rp_id, nonce, otp_hash, status, created_at, expires_at, approved_at, denied_reason
        FROM login_challenges
        WHERE user_id = $1 AND status = 'pending' AND expires_at > NOW()
        ORDER BY created_at DESC
        LIMIT 1
        """,
        user_id,
    )
    if row is None:
        return None
    return _row_to_challenge(row)


async def mark_approved(pool: asyncpg.Pool, challenge_id: UUID) -> None:
    await pool.execute(
        """
        UPDATE login_challenges
        SET status = 'approved', approved_at = NOW()
        WHERE id = $1
        """,
        challenge_id,
    )


async def mark_denied(pool: asyncpg.Pool, challenge_id: UUID, reason: str) -> None:
    await pool.execute(
        """
        UPDATE login_challenges
        SET status = 'denied', denied_reason = $2
        WHERE id = $1
        """,
        challenge_id,
        reason,
    )


async def prune_expired(pool: asyncpg.Pool) -> None:
    await pool.execute(
        """
        UPDATE login_challenges
        SET status = 'denied', denied_reason = 'expired'
        WHERE status = 'pending' AND expires_at < NOW()
        """,
    )


async def clear_pending_for_user(pool: asyncpg.Pool, user_id: UUID) -> int:
    result = await pool.execute(
        """
        UPDATE login_challenges
        SET status = 'denied', denied_reason = 'user_cleared'
        WHERE user_id = $1 AND status = 'pending'
        """,
        user_id,
    )
    try:
        return int(result.split(" ")[-1])
    except (IndexError, ValueError):
        return 0
