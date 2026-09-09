# Build & run

From a fresh clone to a running app, in order.

---

## 1. Prerequisites

- **Flutter** stable SDK (`flutter doctor` should be green for your target
  platforms). See https://docs.flutter.dev/get-started/install.
- For mobile: Android Studio + SDK, or Xcode + a macOS host for iOS.
- For local inference: a `llama-server` binary for your platform (see below).

---

## 2. Install dependencies

```bash
flutter pub get
```

---

## 3. Configure environment

```bash
cp env.example .env
```

Edit `.env` and set at least:

- `REOWN_PROJECT_ID` — required for mobile wallet modal sign-in.
- `EREBRUS_WEB_ORIGIN` — required for desktop web login.
- `GATEWAY_URL` — defaults to `https://gateway.erebrus.io` if omitted.

For Google/Apple sign-in, also fill in the social OAuth variables.
See [AUTH.md](AUTH.md) for details.

---

## 4. Run UI-only (screens pass)

```bash
flutter analyze      # expect: No issues found!
flutter test         # expect: All tests passed!
flutter run          # desktop target by default on macOS/Windows/Linux
```

At this point the Flutter UI and auth/org integration screens run. **Local
inference** needs the `llama.cpp` server binary (next step).

---

## 5. Local inference binary (`llama-server`)

The app expects a `llama.cpp` server binary per platform. Binaries are not
committed; build or download them once.

| Platform | Expected path | How to obtain |
|----------|---------------|---------------|
| macOS arm64 | `assets/llama-bin/llama-server-darwin-arm64` | `./scripts/build-llama-macos.sh` |
| macOS x64 | `assets/llama-bin/llama-server-darwin-x64` | `./scripts/build-llama-macos.sh --x64` |
| Windows x64 | `assets/llama-bin/llama-server-windows-x64.exe` | `./scripts/build-llama-windows.sh` |
| Linux x64 | `assets/llama-bin/llama-server-linux-x64` | `./scripts/build-llama-linux.sh` |

> These scripts will be added as the inference service is implemented. Until
> then, place a prebuilt binary in the path above and add it to `pubspec.yaml`
> assets.

---

## 6. Platform-specific notes

### macOS

```bash
flutter run -d macos
```

- Sign-in uses **web login** (`erebrusai://auth` callback), not Reown.
- The app registers `erebrusai` as a URL scheme in `macos/Runner/Info.plist`.

### Windows / Linux

```bash
flutter run -d windows
flutter run -d linux
```

- Same web-login path as macOS.
- Linux may need `pkg-config` and GTK development headers for Flutter.

### iOS

```bash
flutter run -d <iphone-device-id>
```

- Reown / WalletConnect and social sign-in require the Apple Developer portal
  entitlements and reverse-domain URL scheme setup.
- Sign-in with Apple requires the bundle id and service id configured.

#### Building for TestFlight / App Store
To produce an archive or IPA for TestFlight distribution:

```bash
flutter build ipa --release --export-options-plist=ios/ExportOptions.plist
```

Or open `ios/Runner.xcworkspace` in Xcode, select **Any iOS Device (arm64)**, and go to **Product > Archive**. Ensure your Apple Developer Team and Provisioning Profiles are selected under the **Signing & Capabilities** tab.

### Android

```bash
flutter run                         # debug, playstore flavor by default
```

- The `erebrusai://auth` intent filter is declared in
  `android/app/src/main/AndroidManifest.xml`.

Release builds use two signing flavors (see `android/key.properties.example`):

```bash
./scripts/build-android-release.sh                 # both stores
./scripts/build-android-release.sh playstore       # Google Play AAB
./scripts/build-android-release.sh dappstore       # Solana dApp Store APK
```

Artifacts (version from `pubspec.yaml`):

- `dist/ErebrusAI-android-playstore-vX.Y.Z.aab` — Play Console
- `dist/ErebrusAI-android-dappstore-vX.Y.Z.apk` — Solana dApp Store

```bash
flutter build appbundle --flavor playstore --release --target-platform android-arm64
flutter build apk --flavor dappstore --release --target-platform android-arm64
```
- Solana Mobile Wallet Adapter is detected at runtime on Seeker / Saga devices.

---

## 7. Icons

App icons are generated from `assets/icons/erebrus-ai-icon-1024.png` using
`flutter_launcher_icons`:

```bash
dart run flutter_launcher_icons:main
```

---

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `No .env file found` | Copy `env.example` to `.env` and set the variables. |
| Reown modal shows "project id missing" | Set `REOWN_PROJECT_ID` in `.env` or as `--dart-define`. |
| Desktop web login doesn't return | Ensure `erebrusai` URL scheme is registered for the platform. |
| `flutter test` fails on sign-in test | Real auth plugins don't run in tests; the smoke tests toggle `AppState.signedIn` directly. |
| Android build fails with secure storage | Make sure `minSdkVersion` is at least the value required by `flutter_secure_storage` (21). |
