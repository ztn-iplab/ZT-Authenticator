import secrets
from typing import List
from uuid import UUID

import pyotp

from app.crypto_utils import fernet_from_key, hash_recovery_code
from app.repositories import totp


def generate_recovery_codes(count: int = 8) -> List[str]:
    return [secrets.token_hex(4) for _ in range(count)]


def build_otpauth_uri(
    secret: str,
    account_name: str,
    issuer: str,
) -> str:
    totp = pyotp.TOTP(secret)
    return totp.provisioning_uri(name=account_name, issuer_name=issuer)


def encrypt_secret(secret: str, master_key: str) -> str:
    fernet = fernet_from_key(master_key)
    token = fernet.encrypt(secret.encode("utf-8"))
    return token.decode("utf-8")


def decrypt_secret(secret_encrypted: str, master_key: str) -> str:
    fernet = fernet_from_key(master_key)
    secret = fernet.decrypt(secret_encrypted.encode("utf-8"))
    return secret.decode("utf-8")


async def register_totp(
    pool,
    user_id: UUID,
    rp_id: str,
    account_name: str,
    issuer: str,
    master_key: str,
    recovery_pepper: str,
) -> tuple[str, List[str]]:
    secret = pyotp.random_base32()
    secret_encrypted = encrypt_secret(secret, master_key)

    await totp.insert_secret(pool, user_id, rp_id, secret_encrypted)

    recovery_codes = generate_recovery_codes()
    for code in recovery_codes:
        code_hash = hash_recovery_code(code, recovery_pepper)
        await totp.insert_recovery_code(pool, user_id, code_hash)

    otpauth_uri = build_otpauth_uri(secret, account_name, issuer)
    return otpauth_uri, recovery_codes


def verify_totp(secret: str, otp: str) -> bool:
    # Allow small clock drift between device and server.
    totp_obj = pyotp.TOTP(secret)
    return bool(totp_obj.verify(otp, valid_window=2))


def current_totp(secret: str) -> str:
    totp_obj = pyotp.TOTP(secret)
    return totp_obj.now()


async def verify_recovery_code(
    pool,
    user_id: UUID,
    code: str,
    recovery_pepper: str,
) -> bool:
    code_hash = hash_recovery_code(code, recovery_pepper)
    row = await totp.get_unused_recovery_code(pool, user_id, code_hash)
    if row is None:
        return False
    await totp.consume_recovery_code(pool, row["id"])
    return True
