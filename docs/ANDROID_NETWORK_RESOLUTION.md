# Android Network Resolution Maintenance Note

Last validated: 2026-06-30 (Asia/Tokyo)

## Problem Observed

The phone browser could open `https://poia.test:8443`, but ZT-Authenticator
reported `Failed host lookup: poia.test` for enrollment, login polling, TOTP
reset, and PoIA signing.

ADB confirmed that Android's system resolver could not resolve the name:

```bash
adb -s RF8N404KRRB shell ping -c 1 poia.test
```

The phone had received two DNS servers: an IPv6 resolver from the ELECOM router
and the Ubuntu lab's IPv4 resolver. The router returned no local record, while
the Ubuntu resolver knew `poia.test`. A browser could still appear to work from
its own DNS cache or resolver.

Earlier builds concealed this condition by accepting a raw-IP API fallback.
That approach was removed because a DHCP address became stale when the lab host
moved between networks.

## Implemented Behavior

1. The client first calls Android's normal resolver.
2. Only after a `SocketException` does the Android fallback run.
3. The fallback obtains IPv4 DNS servers from the active Android network and
   asks each for an A record using dnsjava.
4. The successful address is used only as the socket destination.
5. HTTPS still uses the original URI hostname for SNI and certificate
   validation, for example `poia.test`.

The fallback does not replace the account's `api_base_url`, RP ID, or TLS
identity with an IP address. On networks where normal DNS works, including the
existing Mac-hosted environment, the fallback is not invoked.

## Files Changed

- `mobile/android/app/src/main/AndroidManifest.xml`
  - grants `INTERNET` and `ACCESS_NETWORK_STATE` to release APKs;
- `mobile/android/app/build.gradle.kts`
  - includes `dnsjava:dnsjava:3.6.5`;
- `mobile/android/app/proguard-rules.pro`
  - suppresses only dnsjava's unreachable desktop-provider warnings;
- `mobile/android/app/src/main/kotlin/com/example/zt_totp_mobile/MainActivity.kt`
  - exposes the Android-only `zt_network_resolver` method channel;
  - queries active-network IPv4 DNS servers off the UI thread;
- `mobile/lib/network_resolver.dart`
  - bridges Flutter to the Android resolver fallback;
- `mobile/lib/http_client.dart`
  - tries normal DNS first;
  - creates the socket using the fallback address when necessary;
  - preserves `uri.host` during `SecureSocket.secure`;
- `mobile/test/widget_test.dart`
  - checks release permissions and TLS-hostname preservation.

## Routine USB Run

From `ZT-Authenticator/mobile`:

```bash
flutter test
flutter run -d RF8N404KRRB --no-devtools
```

To leave the app running while detaching Flutter, press `d` in the Flutter
terminal. Do not press `q`, which terminates the phone application.

## Release APK

```bash
flutter build apk --release
adb -s RF8N404KRRB install -r \
  build/app/outputs/flutter-apk/app-release.apk
```

Use `-r` and do not uninstall first when preserving enrolled account storage
and Android Keystore keys.

## Diagnostic Commands

```bash
adb devices -l

adb -s RF8N404KRRB shell \
  'ping -c 1 -W 3 poia.test; dumpsys connectivity | grep -E "DnsAddresses|192\\.168\\."'

adb -s RF8N404KRRB shell dumpsys package com.example.zt_totp_mobile | \
  grep -E 'versionName=|android.permission.INTERNET|android.permission.ACCESS_NETWORK_STATE'
```

A failed Android `ping` with successful ZT-Authenticator requests demonstrates
that the fallback is handling a system-resolver conflict. A certificate error
is a different failure and must not be bypassed by replacing the hostname with
an IP address.

## Security Invariants

- Never persist a DHCP address as the RP or API identity.
- Never disable TLS verification to solve DNS resolution.
- Keep `PUBLIC_BASE_URL`, RP ID, and certificate hostname stable.
- Treat fallback DNS answers only as transport addresses; TLS authenticates the
  hostname independently.
- Preserve application storage during updates unless an intentional fresh
  enrollment is required.
