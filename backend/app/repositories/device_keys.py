from uuid import UUID, uuid4

import asyncpg

from app.models import DeviceKeyCreate, DeviceKeyOut


def _row_to_device_key(row: asyncpg.Record) -> DeviceKeyOut:
    return DeviceKeyOut(
        id=row["id"],
        device_id=row["device_id"],
        rp_id=row["rp_id"],
        key_type=row["key_type"],
        public_key=row["public_key"],
        created_at=row["created_at"],
    )


async def create(pool: asyncpg.Pool, payload: DeviceKeyCreate) -> DeviceKeyOut:
    key_id = uuid4()
    row = await pool.fetchrow(
        """
        INSERT INTO device_keys (id, device_id, rp_id, key_type, public_key)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id, device_id, rp_id, key_type, public_key, created_at
        """,
        key_id,
        payload.device_id,
        payload.rp_id,
        payload.key_type,
        payload.public_key,
    )
    return _row_to_device_key(row)


async def get_by_id(pool: asyncpg.Pool, key_id: UUID) -> DeviceKeyOut | None:
    row = await pool.fetchrow(
        """
        SELECT id, device_id, rp_id, key_type, public_key, created_at
        FROM device_keys
        WHERE id = $1
        """,
        key_id,
    )
    if row is None:
        return None
    return _row_to_device_key(row)


async def get_by_device_and_rp(
    pool: asyncpg.Pool,
    device_id: UUID,
    rp_id: UUID,
) -> DeviceKeyOut | None:
    row = await pool.fetchrow(
        """
        SELECT id, device_id, rp_id, key_type, public_key, created_at
        FROM device_keys
        WHERE device_id = $1 AND rp_id = $2
        """,
        device_id,
        rp_id,
    )
    if row is None:
        return None
    return _row_to_device_key(row)


async def upsert_by_device_and_rp(
    pool: asyncpg.Pool,
    device_id: UUID,
    rp_id: UUID,
    key_type: str,
    public_key: str,
) -> DeviceKeyOut:
    existing = await get_by_device_and_rp(pool, device_id, rp_id)
    if existing is None:
        return await create(
            pool,
            DeviceKeyCreate(
                device_id=device_id,
                rp_id=rp_id,
                key_type=key_type,
                public_key=public_key,
            ),
        )
    row = await pool.fetchrow(
        """
        UPDATE device_keys
        SET key_type = $1, public_key = $2
        WHERE id = $3
        RETURNING id, device_id, rp_id, key_type, public_key, created_at
        """,
        key_type,
        public_key,
        existing.id,
    )
    return _row_to_device_key(row)
