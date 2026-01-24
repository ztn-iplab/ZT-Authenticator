# ZT-Authenticator Adoption Guide (Requirements)

This document explains what a relying party (RP) or developer must do to adopt
ZT-Authenticator while keeping standard TOTP behavior unchanged.

## Core principle

- **TOTP generation stays offline and unchanged.**
- ZT-TOTP adds a **device-bound proof** at verification time only.

## What an RP must implement

1) **Enrollment QR generation**
   - Generate a QR containing the JSON payload below.
   - Show it to the user during setup.
   - Include `api_base_url` so each account routes to the correct backend (multi-tenant).

```
{
  "type": "zt_totp_enroll",
  "rp_id": "example.com",
  "api_base_url": "https://auth.example.com/api/auth",
  "rp_display_name": "Example RP",
  "email": "alice@example.com",
  "issuer": "Example",
  "account_name": "alice@example.com",
  "device_label": "Research Phone"
}
```

2) **Server-side enrollment**
   - The app scans the QR, generates a device keypair, and calls:
     - `POST /enroll`
     - `POST /totp/register`

3) **Login verification**
   - Use the **classic login form / API**:
     - `POST /login` with `email` + `otp`
   - The server creates a pending challenge and waits for device approval.
   - The device signs the nonce and approves via:
     - `POST /login/approve`

4) **Recovery handling**
   - Provide a recovery path for offline or lost devices.
   - Recovery codes are issued at TOTP registration and verified via:
   - `POST /login/recover`

## PoIA intent approvals (optional, for high-risk actions)

PoIA is a separate authorization layer for sensitive actions (payments, record changes, admin operations). It is not required for TOTP login, but it can be enabled per user in the RP application.

### RP requirements
1) **Expose PoIA intent endpoints**
   - `GET /api/poia/pending?user_id=...` returns the current pending intent.
   - `POST /api/poia/approve` accepts a device-signed proof.
   - `POST /api/poia/deny` records a denial.

2) **Bind intents to the RP**
   - Each intent includes `context.rp_id` and `context.user_id`.
   - The server verifies approvals match both values.

3) **Device-bound proof verification**
   - The app signs a proof hash derived from the intent, nonce, and expiry.
   - The server verifies the signature against the enrolled device key.

### Intent shape (recommended)
```
{
  "action": "transfer",
  "scope": {
    "amount": 100.0,
    "currency": "USD",
    "account_id": 2,
    "counterparty": "ACME Bank"
  },
  "context": {
    "rp_id": "poia-demo-bank",
    "user_id": 7
  },
  "constraints": {
    "expires_in_seconds": 60
  }
}
```

### Pending response (server -> app)
```
{
  "status": "pending",
  "intent_id": "...",
  "intent": { ... },
  "nonce": "...",
  "rp_id": "poia-demo-bank",
  "expires_at": 1710000000,
  "expires_in": 60
}
```

### Approval payload (app -> server)
```
{
  "intent_id": "...",
  "device_id": "10",
  "rp_id": "poia-demo-bank",
  "nonce": "...",
  "signature": "base64-signature",
  "intent_hash": "hex-proof-hash"
}
```

### Proof hash construction (server and app must match)
1) Canonical JSON of `intent` (sorted keys, compact separators).
2) Compute `intent_hash_b64 = base64url(sha256(intent_canonical_json))`.
3) Build `proof_payload` JSON:
```
{
  "intent_hash": "<intent_hash_b64>",
  "nonce": "<nonce>",
  "expires_at": 1710000000
}
```
4) Compute `proof_hash_hex = sha256(proof_payload_canonical_json).hexdigest()`.

### Signature input
The device signs the following message string (UTF-8):
```
<proof_hash_hex>|<device_id>|<rp_id>|<nonce>
```
The RP may optionally accept a fallback ordering for compatibility:
```
<nonce>|<device_id>|<rp_id>|<proof_hash_hex>
```

### Multi-tenant routing rules
- Each enrolled account stores its `api_base_url` from the QR payload.
- ZT-Authenticator maps approvals by `rp_id` and uses the stored base URL.
- If an account has no mapping (manual base32 or legacy record), the app falls back to the global base URL in Settings.

### UX expectations
- ZT-Authenticator displays the intent details (action + key scope fields).
- Approve and Deny are explicit user actions.
- The RP should close the modal immediately on approval or denial.

### Failure handling (suggested reasons)
- `expired` (intent TTL exceeded)
- `rp_mismatch` (wrong relying party)
- `device_not_enrolled` (device key not registered)
- `invalid_signature` (signature mismatch)
- `hash_mismatch` (proof hash does not match intent + nonce + expiry)

### Audit logging (recommended)
Record at least:
- user_id, rp_id, intent_id, action, status, latency_ms
- device_id used for approval
- reason code for denials

## What the ZT-Authenticator app does

- Generates a non-exportable device keypair (Android Keystore).
- Registers the public key with the server.
- Generates TOTP offline (standard RFC 6238 behavior).
- Signs server nonces for device-bound verification.
- Optionally requires explicit user approval (recommended).
- Approves PoIA intents using the same device key when PoIA is enabled by the RP.

## Security expectations

- A **stolen TOTP seed alone is not enough** to login.
- A login succeeds only if:
  - The OTP is valid, and
  - The device-bound signature is valid, and
  - The proof is bound to the correct `rp_id`.

## Worst-case scenarios and mitigations

### Seed compromise (attacker extracts TOTP seed)
- **Impact**: attacker can generate valid OTPs.
- **Mitigation**: OTP alone is insufficient; server requires device-bound proof
  (signature over nonce + RP + device).

### Real-time relay phishing (OTP forwarded in real time)
- **Impact**: attacker can relay OTP to login form.
- **Mitigation**: server requires a device proof over the nonce and RP ID.
  Relay without the enrolled device fails.

### Device loss or replacement
- **Impact**: legitimate user cannot approve logins.
- **Mitigation**: recovery codes provide offline fallback; user can re-enroll
  and rotate device keys.

### Device malware / key theft
- **Impact**: if the private key is stolen, attacker can approve logins.
- **Mitigation**: keys are stored in Android Keystore (non-exportable).
  Support key rotation and revocation on compromise.

### Database compromise
- **Impact**: attacker obtains encrypted seeds and recovery-code hashes.
- **Mitigation**: seeds are encrypted with a server master key; recovery codes
  are stored as hashes with a pepper. DB alone is insufficient.

### Secret manager compromise (pepper/master key leak)
- **Impact**: attacker can verify guesses offline and decrypt seeds.
- **Mitigation**: rotate secrets, audit access, and monitor anomalous use.

### Replay attacks
- **Impact**: reuse of valid proof.
- **Mitigation**: nonces are single-use and expire; server rejects reused or
  expired nonces.

### RP misbinding (cross‑service replay)
- **Impact**: proof for one RP reused for another.
- **Mitigation**: RP ID is included in the signed message; proofs are RP-bound.

### Network outage / offline device
- **Impact**: device cannot approve logins.
- **Mitigation**: recovery codes allow access; pending logins expire.

### Clock drift
- **Impact**: OTP validation failures.
- **Mitigation**: server uses a small valid window and logs failures.

### Denial of service (login spam)
- **Impact**: user receives many approval prompts.
- **Mitigation**: pending logins have short TTL and can be rate‑limited at the
  service edge (deployment responsibility).

## Research argument: why a handshake is necessary

### Classic TOTP (no handshake)
Classic TOTP relies on a shared seed and time synchronization. The server
recomputes the OTP and compares it with the user-submitted code. This design
requires **no server challenge**, which is why it is simple and offline‑friendly.

### Limitation of classic TOTP
Because the OTP is derived solely from the seed and time, **any device with the
seed can generate a valid OTP**. Therefore, the server cannot distinguish the
legitimate device from a cloned device based on the OTP alone.

### ZT‑TOTP requirement
ZT‑TOTP preserves offline OTP generation but adds a **nonce challenge** at
verification time. The device signs the nonce (and RP identifier) with a
non‑exportable key. This **device‑bound proof** is what enforces Zero Trust
properties (seed‑compromise resilience and relay‑phishing resistance).

### Security rationale
The handshake is not an extra attack surface; it is the **minimum mechanism**
required to bind an OTP to the enrolled device and RP. Without it, device
possession cannot be verified.

## Recovery code storage & threat model

- Recovery codes are **not stored in plaintext**. The server stores only
  `hash(code + pepper)` (SHA‑256).
- Hashes are **one-way**; they are not reversible. An attacker cannot “decode”
  or “decrypt” a hash back into the original code.

### If the database is leaked
- The attacker gets only hashes, which are **not usable** directly.
- To recover a code, they must **guess** it and hash guesses to find a match.
- Our codes are random (8 hex bytes) which makes guessing impractical.

### If both database and pepper are leaked
- The attacker can perform **offline guessing** more effectively.
- This is why the pepper **must remain secret** and never be committed to Git.
- Treat the pepper like a password or encryption key and store it securely.

### Mitigations
- Use strong, random recovery codes (already implemented).
- Mark codes **one‑time use** (`used_at`).
- Rotate recovery codes after use or when compromise is suspected.

## Minimal deployment checklist

- Backend running and reachable by users.
- RP can render and rotate enrollment QR codes.
- Mobile clients can reach the backend (LAN/IP or public domain).
- Recovery codes are stored securely and treated as high-value secrets.

## Integration endpoints (summary)

- `POST /enroll`
- `POST /totp/register`
- `POST /login` (email + otp)
- `POST /login/approve`
- `POST /login/recover`
- `POST /zt/verify` (direct ZT verification flow)
