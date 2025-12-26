import base64
import hashlib

from cryptography.exceptions import InvalidSignature
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


def fernet_from_key(key: str) -> Fernet:
    raw = key.encode("utf-8")
    return Fernet(raw)


def hash_recovery_code(code: str, pepper: str) -> str:
    data = (code + pepper).encode("utf-8")
    return hashlib.sha256(data).hexdigest()


def generate_master_key() -> str:
    return Fernet.generate_key().decode("utf-8")


def build_device_proof_message(
    nonce: str,
    device_id: str,
    rp_id: str,
    otp: str,
) -> bytes:
    payload = f"{nonce}|{device_id}|{rp_id}|{otp}"
    return payload.encode("utf-8")


def verify_ed25519_signature(
    public_key_b64: str,
    message: bytes,
    signature_b64: str,
) -> bool:
    try:
        public_key_bytes = base64.b64decode(public_key_b64)
        signature_bytes = base64.b64decode(signature_b64)
    except (ValueError, TypeError):
        return False

    try:
        if len(public_key_bytes) == 32:
            key = Ed25519PublicKey.from_public_bytes(public_key_bytes)
        else:
            key = serialization.load_der_public_key(public_key_bytes)
            if not isinstance(key, Ed25519PublicKey):
                return False
        key.verify(signature_bytes, message)
        return True
    except (InvalidSignature, ValueError):
        return False


def verify_p256_signature(
    public_key_b64: str,
    message: bytes,
    signature_b64: str,
) -> bool:
    try:
        public_key_bytes = base64.b64decode(public_key_b64)
        signature_bytes = base64.b64decode(signature_b64)
    except (ValueError, TypeError):
        return False

    try:
        key = serialization.load_der_public_key(public_key_bytes)
        if not isinstance(key, ec.EllipticCurvePublicKey):
            return False
        key.verify(signature_bytes, message, ec.ECDSA(hashes.SHA256()))
        return True
    except (InvalidSignature, ValueError):
        return False
