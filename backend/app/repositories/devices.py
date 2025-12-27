from uuid import UUID, uuid4

import asyncpg

from app.models import DeviceCreate, DeviceOut


def _row_to_device(row: asyncpg.Record) -> DeviceOut:
    return DeviceOut(
        id=row["id"],
        user_id=row["user_id"],
        device_label=row["device_label"],
        platform=row["platform"],
        created_at=row["created_at"],
    )


async def create(pool: asyncpg.Pool, payload: DeviceCreate) -> DeviceOut:
    device_id = uuid4()
    row = await pool.fetchrow(
        """
        INSERT INTO devices (id, user_id, device_label, platform)
        VALUES ($1, $2, $3, $4)
        RETURNING id, user_id, device_label, platform, created_at
        """,
        device_id,
        payload.user_id,
        payload.device_label,
        payload.platform,
    )
    return _row_to_device(row)


async def get_by_id(pool: asyncpg.Pool, device_id: UUID) -> DeviceOut | None:
    row = await pool.fetchrow(
        """
        SELECT id, user_id, device_label, platform, created_at
        FROM devices
        WHERE id = $1
        """,
        device_id,
    )
    if row is None:
        return None
    return _row_to_device(row)


async def get_latest_for_user(pool: asyncpg.Pool, user_id: UUID) -> DeviceOut | None:
    row = await pool.fetchrow(
        """
        SELECT id, user_id, device_label, platform, created_at
        FROM devices
        WHERE user_id = $1
        ORDER BY created_at DESC
        LIMIT 1
        """,
        user_id,
    )
    if row is None:
        return None
    return _row_to_device(row)
