# ZT-Authenticator Mobile

## Quick start

```bash
cd /Users/patrick-m/Documents/ZT-Authenticator/mobile
flutter run -d emulator-5554
```

## ZT research flow

1) **ZT Enroll Device**  
   Generates a device-bound keypair in Android Keystore and registers the public key.
2) **Register TOTP**  
   Requests a TOTP secret and saves it locally.
3) **ZT Verify**  
   Requests a nonce, signs `<nonce>|<device_id>|<rp_id>|<otp>`, then verifies.

## Notes

- The emulator reaches the backend on `http://10.0.2.2:8000`.
- Use **Clear local accounts** from the FAB menu to wipe local state.
