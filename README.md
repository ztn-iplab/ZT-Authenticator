# ZT-Authenticator

ZT-Authenticator is a research-oriented Zero Trust take on time-based one-time passwords (TOTP). It combines classic TOTP factors with device-bound cryptographic proofs, so login approvals require both the shared secret and possession of the enrolled device key.

## Repository structure
- **backend/** – HTTPS API, enrollment, verification, and recovery flows. See the [backend README](backend/README.md) for setup, database initialization, and protocol details.
- **mobile/** – Flutter client for enrollment and approving sign-in challenges. See the [mobile README](mobile/README.md) for emulator/handset notes and QR formats.
- **docs/** – Additional background and experiments, including adoption notes and research artifacts.
- **docker-compose.yml** – Local dependencies (PostgreSQL and Redis) for development.
- **scripts/** – Utility scripts used by the backend.

## Quick start
1. **Bring up local dependencies**
   ```bash
   podman compose up -d
   ```
2. **Run the backend** by following the steps in the [backend README](backend/README.md) (virtualenv, environment variables, TLS cert generation, and schema bootstrap).
3. **Run the mobile app** using the [mobile README](mobile/README.md) (emulator target, backend URL, and setup key inputs).

## What makes it Zero Trust
- Every login requires a device-bound signature over the server nonce, relying party ID, and OTP, preventing OTP replay and tying approvals to the enrolled device.
- Recovery codes exist as a deliberate offline fallback and are consumed server-side when used.
- The backend logs audit-style events for TOTP verification, Zero Trust verification, recovery flows, and key rotations to support operational insight.

## Additional reading
- **Adoption guidance:** [docs/ADOPTION.md](docs/ADOPTION.md)
- **Research notes and experiments:** [docs/EXPERIMENTS.md](docs/EXPERIMENTS.md)

For questions about a specific area, start with the README in that folder, then return here for the big-picture context.
