# ZT-TOTP Protocol Verification Report

## Scope

We verify the core ZT‑TOTP protocol for:

- Enrollment (seed + device key registration)
- Challenge issuance and device‑bound proof verification
- Recovery code fallback
- Adversary with full network control (Dolev‑Yao)
- Optional compromise events (seed reveal, device key reveal)

## Threat Model Assumptions

- The adversary controls the network and can replay or forge messages.
- The server is honest and stores the TOTP seed + device public key.
- Seeds and device keys can be compromised via explicit reveal rules.
- Nonces are modeled as fresh values with single‑use semantics.

## Proof Goals

1) **Authentication**: server acceptance implies a valid device proof.
2) **RP binding**: proofs are bound to the correct RP identifier.
3) **Replay resistance**: nonce reuse does not lead to double acceptance.
4) **Seed compromise resilience**: seed alone cannot authorize.
5) **Recovery correctness**: recovery logins require issued recovery codes.

## Model Summary

The model (see `zt_totp_protocol.spthy`) uses:

- `otp(seed, t)` abstracted as `h(seed, t)`
- Device proof signature over `<nonce, device_id, rp_id, otp>`
- Single‑use challenge tracked by `Challenge(uid, dev, rp, n, t)`
- Optional reveal rules: `SeedReveal` and `KeyReveal`

## Results (Tamarin)

Run summary (all-traces):

- **Authentication**: verified
- **RP binding**: verified (allows device key compromise as explicit exception)
- **Replay resistance**: verified
- **Seed compromise resilience**: verified
- **Recovery correctness**: verified

## Implications

- ZT‑TOTP adds a device‑bound cryptographic factor without changing OTP generation.
- RP‑bound signatures prevent cross‑service replay.
- Recovery codes remain a deliberate offline fallback and are modeled explicitly.
- If the device key is compromised, authorization can be forged; this is
  explicitly captured by the `KeyReveal` exception in the lemmas.

## Modeling notes

- The device signature is abstracted as a `Sig(device_id, rp_id, nonce, otp)` fact,
  produced only by the device or by the adversary after `KeyReveal`.
- This avoids relying on a concrete signature verification equation while
  preserving the security intent (device possession + RP binding).

## How to Run

```bash
./scripts/run_tamarin_zt_totp.sh
```

If `tamarin-prover` is not installed locally, the script will use the official container.
