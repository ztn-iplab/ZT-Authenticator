# ZT-TOTP Protocol Verification Report (Template)

## Scope

- Enrollment (device key + seed registration)
- Challenge + device-bound proof verification
- Recovery code fallback

## Threat Model Assumptions

- Dolev-Yao network attacker (intercepts, replays, forges messages)
- Optional compromise actions:
  - Seed compromise (attacker learns TOTP seed)
  - Device key compromise (attacker learns device private key)
- Honest server stores seed and public keys

## Proof Goals

1) **Authentication**: server accepts only if device signed with enrolled key.
2) **RP binding**: proofs are bound to the correct RP identifier.
3) **Replay resistance**: nonces are single-use.
4) **Seed compromise resilience**: seed alone cannot authorize.
5) **Recovery correctness**: recovery code accepts only if issued.

## Results Summary

- Authentication: (PASS/FAIL)
- RP binding: (PASS/FAIL)
- Replay: (PASS/FAIL)
- Seed compromise: (PASS/FAIL)
- Recovery correctness: (PASS/FAIL)

## Notes / Limitations

- OTP modeled as `h(seed, t)` where `t` is server-issued.
- Assumes secure enrollment channel for seed + key registration.
