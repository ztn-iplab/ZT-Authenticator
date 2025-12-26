from uuid import UUID, uuid4

import asyncpg

from app.models import UserCreate, UserOut


def _row_to_user(row: asyncpg.Record) -> UserOut:
    return UserOut(
        id=row["id"],
        email=row["email"],
        created_at=row["created_at"],
    )


async def create(pool: asyncpg.Pool, payload: UserCreate) -> UserOut:
    user_id = uuid4()
    row = await pool.fetchrow(
        """
        INSERT INTO users (id, email)
        VALUES ($1, $2)
        RETURNING id, email, created_at
        """,
        user_id,
        payload.email,
    )
    return _row_to_user(row)


async def get_by_id(pool: asyncpg.Pool, user_id: UUID) -> UserOut | None:
    row = await pool.fetchrow(
        """
        SELECT id, email, created_at
        FROM users
        WHERE id = $1
        """,
        user_id,
    )
    if row is None:
        return None
    return _row_to_user(row)


async def get_by_email(pool: asyncpg.Pool, email: str) -> UserOut | None:
    row = await pool.fetchrow(
        """
        SELECT id, email, created_at
        FROM users
        WHERE email = $1
        """,
        email,
    )
    if row is None:
        return None
    return _row_to_user(row)
