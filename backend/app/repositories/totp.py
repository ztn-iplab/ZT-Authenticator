from uuid import UUID, uuid4

import asyncpg


def _row_to_secret(row: asyncpg.Record) -> dict:
    return {
        "id": row["id"],
        "user_id": row["user_id"],
        "rp_id": row["rp_id"],
        "secret_encrypted": row["secret_encrypted"],
        "created_at": row["created_at"],
    }


async def insert_secret(
    pool: asyncpg.Pool,
    user_id: UUID,
    rp_id: str,
    secret_encrypted: str,
) -> dict:
    secret_id = uuid4()
    row = await pool.fetchrow(
        """
        INSERT INTO totp_secrets (id, user_id, rp_id, secret_encrypted)
        VALUES ($1, $2, $3, $4)
        RETURNING id, user_id, rp_id, secret_encrypted, created_at
        """,
        secret_id,
        user_id,
        rp_id,
        secret_encrypted,
    )
    return _row_to_secret(row)


async def get_secret(
    pool: asyncpg.Pool,
    user_id: UUID,
    rp_id: str,
) -> dict | None:
    row = await pool.fetchrow(
        """
        SELECT id, user_id, rp_id, secret_encrypted, created_at
        FROM totp_secrets
        WHERE user_id = $1 AND rp_id = $2
        """,
        user_id,
        rp_id,
    )
    if row is None:
        return None
    return _row_to_secret(row)


async def get_latest_secret_for_user(
    pool: asyncpg.Pool,
    user_id: UUID,
) -> dict | None:
    row = await pool.fetchrow(
        """
        SELECT id, user_id, rp_id, secret_encrypted, created_at
        FROM totp_secrets
        WHERE user_id = $1
        ORDER BY created_at DESC
        LIMIT 1
        """,
        user_id,
    )
    if row is None:
        return None
    return _row_to_secret(row)


async def insert_recovery_code(
    pool: asyncpg.Pool,
    user_id: UUID,
    code_hash: str,
) -> None:
    code_id = uuid4()
    await pool.execute(
        """
        INSERT INTO recovery_codes (id, user_id, code_hash)
        VALUES ($1, $2, $3)
        """,
        code_id,
        user_id,
        code_hash,
    )


async def get_unused_recovery_code(
    pool: asyncpg.Pool,
    user_id: UUID,
    code_hash: str,
) -> dict | None:
    row = await pool.fetchrow(
        """
        SELECT id, user_id, code_hash, created_at, used_at
        FROM recovery_codes
        WHERE user_id = $1 AND code_hash = $2 AND used_at IS NULL
        LIMIT 1
        """,
        user_id,
        code_hash,
    )
    if row is None:
        return None
    return dict(row)


async def consume_recovery_code(pool: asyncpg.Pool, code_id: UUID) -> None:
    await pool.execute(
        """
        UPDATE recovery_codes
        SET used_at = NOW()
        WHERE id = $1
        """,
        code_id,
    )
