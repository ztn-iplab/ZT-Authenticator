import secrets
from datetime import datetime, timedelta, timezone
from uuid import UUID

from app.crypto_utils import (
    build_device_proof_message,
    verify_ed25519_signature,
    verify_p256_signature,
)
from app.repositories import challenges, device_keys, relying_parties

DEFAULT_TTL_SECONDS = 300


def generate_nonce() -> str:
    return secrets.token_urlsafe(32)


def expires_at(ttl_seconds: int = DEFAULT_TTL_SECONDS) -> datetime:
    return datetime.now(timezone.utc) + timedelta(seconds=ttl_seconds)


async def issue_challenge(pool, device_id: UUID, rp_id: str) -> dict:
    await challenges.prune_expired(pool)
    nonce = generate_nonce()
    challenge = await challenges.insert_challenge(
        pool=pool,
        device_id=device_id,
        rp_id=rp_id,
        nonce=nonce,
        expires_at=expires_at(),
    )
    return challenge


async def device_key_exists(pool, device_id: UUID, rp_id: str) -> bool:
    rp = await relying_parties.get_by_rp_id(pool, rp_id)
    if rp is None:
        return False
    row = await device_keys.get_by_device_and_rp(pool, device_id, rp.id)
    return row is not None


async def get_device_key(pool, device_id: UUID, rp_id: str):
    rp = await relying_parties.get_by_rp_id(pool, rp_id)
    if rp is None:
        return None
    return await device_keys.get_by_device_and_rp(pool, device_id, rp.id)


def verify_device_proof(
    *,
    key_type: str,
    public_key: str,
    nonce: str,
    device_id: UUID,
    rp_id: str,
    otp: str,
    signature: str,
) -> bool:
    message = build_device_proof_message(
        nonce=nonce,
        device_id=str(device_id),
        rp_id=rp_id,
        otp=otp,
    )
    if key_type == "ed25519":
        return verify_ed25519_signature(public_key, message, signature)
    if key_type == "p256":
        return verify_p256_signature(public_key, message, signature)
    return False
