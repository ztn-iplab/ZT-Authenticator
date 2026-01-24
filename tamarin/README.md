# ZT-TOTP Protocol Verification (Tamarin)

This folder contains a research-ready Tamarin Prover model for the ZT-TOTP
protocol used by ZT-Authenticator. The model captures:

- Enrollment (device key + seed registration)
- ZT-TOTP verification (nonce + device-bound proof)
- Recovery codes (offline fallback)
- Adversary capabilities (seed or device-key compromise)

## Files

- `zt_totp_protocol.spthy` – full protocol model and lemmas
- `REPORT_TEMPLATE.md` – report scaffold for findings

## Run (local)

Install Tamarin and run:

```bash
tamarin-prover --prove zt_totp_protocol.spthy
```

## Run (container)

If Tamarin is not installed locally:

```bash
docker run --rm -v "$PWD":/work tamarinprover/tamarin-prover:1.10.0 \
  tamarin-prover --prove /work/zt_totp_protocol.spthy
```

## Notes

- The model abstracts the OTP as `h(seed, t)` where `t` is a server-issued
  time window from the challenge.
- RP binding is modeled by including `rp_id` in the signed proof.
- Recovery codes are modeled as one-time tokens that bypass device proof.
