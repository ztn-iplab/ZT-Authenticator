# PoIA ZT Hash Fix Build (2026-06-20)

The Android debug build containing the server-issued PoIA proof-hash fix is
kept locally at:

`artifacts/local-builds/20260620-zt-hash-fix/zt-authenticator-debug.apk`

The binary is intentionally ignored by Git. Its SHA-256 digest is:

`3c10bae0c7b0069c86cba9aeea08f3aaa93457d96cfefebd9800ae5517160c77`

Build command:

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
export PATH=/opt/homebrew/opt/openjdk@17/bin:$PATH
cd mobile
flutter test
flutter build apk --debug
```

Toolchain: Flutter 3.44.2, OpenJDK 17.0.19, Android command-line SDK with the
project-selected platform, build tools, NDK, and CMake components. Installation
over the existing debug application preserves the app's secure local account
store when the package identifier and signing key are unchanged.
