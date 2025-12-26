# ZT-TOTP Backend

## Setup

```bash
cd /Users/patrick-m/Documents/ZT-Authenticator/backend
source .venv/bin/activate
cp .env.example .env
```

Generate a master key (Fernet) and set it in `.env`:

```bash
python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

Set a recovery pepper (any long random string).

## Run

```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

## Initialize database schema

```bash
psql "postgresql://zt_user:zt_pass@localhost:5432/zt_totp" -f db/bootstrap.sql
```

## ZT device proof (Ed25519)

The server verifies a device-bound proof using the enrolled public key.
The signature input is the UTF-8 string:

```
<nonce>|<device_id>|<rp_id>|<otp>
```

The public key stored during enrollment can be either:
- base64-encoded raw 32-byte Ed25519 public key (preferred), or
- base64-encoded DER SubjectPublicKeyInfo (what Android Keystore returns).

For Android Keystore we currently recommend P-256 (secp256r1) keys with
`SHA256withECDSA` signatures. Set `key_type` to `p256` for this flow.

## ZT flow overview (research path)

1) **Enroll device**: client generates a device-bound keypair and sends the public key to `/enroll`.
2) **Register TOTP**: server issues a secret and recovery codes at `/totp/register`.
3) **Request nonce**: device asks `/zt/challenge` for a short-lived nonce.
4) **Sign proof**: device signs `<nonce>|<device_id>|<rp_id>|<otp>`.
5) **Verify**: server validates OTP + nonce + signature at `/zt/verify`.

## Key rotation (device-bound keys)

Use `/zt/rotate-key` to rotate the public key when a device is re-imaged or a key is refreshed.
This updates the stored device key for the same `device_id` + `rp_id`.

## Recovery codes

Recovery codes are one-time use tokens. Verify (and consume) them via:

```
POST /totp/recovery/verify
```

## Metrics / logging

The backend logs audit-style events for:
- `totp_verify` (ok/denied + duration)
- `zt_verify` (ok/denied + duration)
- `totp_recovery` (ok/denied)
- `zt_rotate_key` (ok)

Example to generate a keypair and signature for testing:

```bash
python - <<'PY'
import base64
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

nonce = "NONCE_FROM_CHALLENGE"
device_id = "DEVICE_UUID"
rp_id = "example.com"
otp = "123456"

message = f"{nonce}|{device_id}|{rp_id}|{otp}".encode()

private_key = Ed25519PrivateKey.generate()
public_key = private_key.public_key()

public_bytes = public_key.public_bytes(
    encoding=serialization.Encoding.Raw,
    format=serialization.PublicFormat.Raw,
)
public_b64 = base64.b64encode(public_bytes).decode()
signature_b64 = base64.b64encode(private_key.sign(message)).decode()

print("public_key:", public_b64)
print("signature:", signature_b64)
PY
```
