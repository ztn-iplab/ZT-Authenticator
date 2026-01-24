# ZT-Authenticator

ZT-Authenticator is a research-oriented Zero Trust take on time-based one-time passwords (TOTP). It combines classic TOTP factors with device-bound cryptographic proofs, so login approvals require both the shared secret and possession of the enrolled device key.

## Repository structure
- **backend/** – HTTPS API, enrollment, verification, and recovery flows. See the [backend README](backend/README.md) for setup, database initialization, and protocol details.
- **mobile/** – Flutter client for enrollment and approving sign-in challenges. See the [mobile README](mobile/README.md) for emulator/handset notes and QR formats.
- **docs/** – Additional background and experiments, including adoption notes and research artifacts.
- **docker-compose.yml** – Local dependencies (PostgreSQL and Redis) for development.
- **scripts/** – Utility scripts used by the backend.
- **tamarin/** – Formal protocol verification models and report templates.

## PoIA intent approvals (optional)
ZT-Authenticator can approve PoIA (Proof-of-Intent Authorization) actions. PoIA is a transaction-level authorization layer that protects high-risk actions (payments, record changes, admin operations) even after the user is already logged in. It is separate from TOTP login approvals.

What PoIA adds:
- Action binding: approvals are signed over the exact intent contents.
- Device binding: approvals require the enrolled device key.
- RP binding: approvals are tied to the relying party ID.

PoIA support requires:
- The user enrolls the device as usual (QR-based enrollment).
- The RP exposes PoIA intent endpoints (see `docs/ADOPTION.md`).
- The app can reach the PoIA base URL (stored per RP during enrollment).

High-level flow:
1) RP creates an intent with `intent_id`, `intent`, `nonce`, and `expires_at`.
2) ZT-Authenticator polls `/api/poia/pending` and shows the intent details.
3) The user approves or denies in the app.
4) The app signs a device-bound proof and POSTs to `/api/poia/approve`.
5) The RP verifies the proof, records an audit entry, and completes the action.

Security checks the RP should enforce:
- Intent TTL has not expired.
- The approval matches `rp_id` and `user_id` from the intent context.
- The device key used is enrolled for the same RP.
- The proof hash matches the intent, nonce, and expiry.

## Quick start
1. **Bring up local dependencies**
   ```bash
   podman compose up -d
   ```
2. **Run the backend** by following the steps in the [backend README](backend/README.md) (virtualenv, environment variables, TLS cert generation, and schema bootstrap).
3. **Run the mobile app** using the [mobile README](mobile/README.md) (emulator target, backend URL, and setup key inputs).

## Formal verification (Tamarin)

ZT-TOTP protocol models and lemmas are in `tamarin/zt_totp_protocol.spthy`.
Run:

```bash
./scripts/run_tamarin_zt_totp.sh
```

## What makes it Zero Trust
- Every login requires a device-bound signature over the server nonce, relying party ID, and OTP, preventing OTP replay and tying approvals to the enrolled device.
- Recovery codes exist as a deliberate offline fallback and are consumed server-side when used.
- The backend logs audit-style events for TOTP verification, Zero Trust verification, recovery flows, and key rotations to support operational insight.

## Additional reading
- **Adoption guidance:** [docs/ADOPTION.md](docs/ADOPTION.md)
- **Research notes and experiments:** [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md)

For questions about a specific area, start with the README in that folder, then return here for the big-picture context.
