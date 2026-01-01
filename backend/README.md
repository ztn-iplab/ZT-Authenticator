# ZT-TOTP Backend

## Setup

```bash
cd /Users/<user>/Documents/ZT-Authenticator/backend
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
./scripts/generate_dev_cert.sh
./run.sh
```

The development server uses HTTPS by default. For production, terminate TLS with
your load balancer or provide a trusted certificate.

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

## Classic login flow (email + OTP + RP + device)

Use `POST /login` with:
- `email`
- `otp`

The server creates a pending login challenge. The device approves it in the
background using a device-bound signature.

## Classic login form (web)

Open `https://<host>:8000/login-form` and submit only email + OTP.
The server derives the RP and device from the latest enrollment for that user.
The ZT-Authenticator app silently approves the login in the background.

If the device is offline, use a recovery code in the same form. Recovery codes
are one-time use and bypass the device approval step.

## Security design notes (academic detail)

### Compatibility with existing authenticators
- **TOTP generation remains offline and unchanged.** The OTP is still derived
  from the shared seed and time, exactly as in standard authenticators.
- The **Zero Trust layer** is added only at **verification time**, by requiring
  a device-bound signature over the server nonce.

### Cryptographic material
- **TOTP seed**: shared secret between server and device; stored encrypted server-side.
- **Device keypair**: generated and stored on-device in the Android Keystore.
  - **Private key** is non-exportable and used only for signing.
  - **Public key** is registered server-side and bound to `(device_id, rp_id)`.

### Protocol (ZT-TOTP proof)
Let `K_priv` be the device private key and `K_pub` the enrolled public key.

1) Server issues a fresh **nonce** `n` with expiration `t_exp`.
2) Device computes the current OTP `otp` and signs:
   ```
   m = n || "|" || device_id || "|" || rp_id || "|" || otp
   σ = Sign(K_priv, m)
   ```
3) Device sends `{otp, n, σ}` to the server.
4) Server verifies:
   - `otp` is valid for the stored seed (within time window).
   - `n` exists, is unexpired, and unused.
   - `Verify(K_pub, m, σ)` succeeds.

### Security properties
- **Seed compromise resilience**: A stolen seed yields valid OTPs, but **cannot**
  produce a valid signature without the device private key.
- **Relay phishing mitigation**: A relayed OTP is insufficient without a
  device-bound signature over the nonce and RP identifier.
- **Device binding**: Login success implies possession of the enrolled device key.

### Classic login with hidden device proof
The web form accepts only `email + OTP`, but the server creates a pending
challenge. The enrolled device must approve by signing the nonce. Without
device approval, logins remain pending and expire.

### Recovery codes
Recovery codes are one-time tokens bound to the user, intended for offline
fallback when the device is unavailable. They bypass device proof by design
and should be treated as high-value secrets.

### Role of the RP (relying party)
- The **RP identifier** is included in the signed message so a proof is bound
  to the intended relying party.
- This prevents a proof generated for one RP from being replayed against another.
- The RP identifier is stored server-side and linked to device keys, enforcing
  device enrollment per RP.

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
