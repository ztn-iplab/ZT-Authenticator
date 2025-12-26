from uuid import UUID, uuid4

import asyncpg

from app.models import RelyingPartyCreate, RelyingPartyOut


def _row_to_rp(row: asyncpg.Record) -> RelyingPartyOut:
    return RelyingPartyOut(
        id=row["id"],
        rp_id=row["rp_id"],
        display_name=row["display_name"],
        created_at=row["created_at"],
    )


async def create(pool: asyncpg.Pool, payload: RelyingPartyCreate) -> RelyingPartyOut:
    rp_uuid = uuid4()
    row = await pool.fetchrow(
        """
        INSERT INTO relying_parties (id, rp_id, display_name)
        VALUES ($1, $2, $3)
        RETURNING id, rp_id, display_name, created_at
        """,
        rp_uuid,
        payload.rp_id,
        payload.display_name,
    )
    return _row_to_rp(row)


async def get_by_id(pool: asyncpg.Pool, rp_uuid: UUID) -> RelyingPartyOut | None:
    row = await pool.fetchrow(
        """
        SELECT id, rp_id, display_name, created_at
        FROM relying_parties
        WHERE id = $1
        """,
        rp_uuid,
    )
    if row is None:
        return None
    return _row_to_rp(row)


async def get_by_rp_id(pool: asyncpg.Pool, rp_id: str) -> RelyingPartyOut | None:
    row = await pool.fetchrow(
        """
        SELECT id, rp_id, display_name, created_at
        FROM relying_parties
        WHERE rp_id = $1
        """,
        rp_id,
    )
    if row is None:
        return None
    return _row_to_rp(row)
