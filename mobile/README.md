# ZT-Authenticator Mobile

## Quick start

```bash
cd /Users/<user>/Documents/ZT-Authenticator/mobile
flutter run -d emulator-5554
```

## Enrollment flow

1) **Scan Enrollment QR or paste the enrollment link**  
   The app enrolls the device (device-bound) and registers TOTP.
2) **Login approvals**  
   Approve sign-in challenges with device-bound signatures.

## Notes

- The emulator reaches the backend on `https://10.0.2.2:8000`.
- On a real phone, use the **enrollment link** (it includes the correct API base URL).
- If you are using a self-signed cert for local dev, enable **Allow self-signed TLS** in Settings.
- Use **Clear local accounts** from the FAB menu to wipe local state.

## Enrollment QR format

Generate a QR code containing this JSON:

```json
{
  "type": "zt_totp_enroll",
  "rp_id": "example.com",
  "rp_display_name": "Example RP",
  "email": "alice@example.com",
  "issuer": "Example",
  "account_name": "alice@example.com",
  "device_label": "Research Phone"
}
```

## Setup key input

You can also paste any of the following into **Setup key**:
- the **enrollment link** (`https://<host>/api/auth/enroll-code/<code>`)
- an `otpauth://` URI (local-only)
- a base32 secret (local-only)
