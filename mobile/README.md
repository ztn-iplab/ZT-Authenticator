# ZT-Authenticator Mobile

## Quick start

```bash
cd /Users/patrick-m/Documents/ZT-Authenticator/mobile
flutter run -d emulator-5554
```

## ZT research flow

1) **Scan Enrollment QR**  
   The app generates a device-bound keypair, enrolls the device, and registers TOTP.
2) **ZT Verify**  
   Requests a nonce, signs `<nonce>|<device_id>|<rp_id>|<otp>`, then verifies.

## Notes

- The emulator reaches the backend on `http://10.0.2.2:8000`.
- For a real Android phone, update `apiBaseUrl` in `mobile/lib/main.dart` to your laptop's LAN IP (e.g., `http://192.168.1.20:8000`).
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
