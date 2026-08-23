<div align="center">

# 🎵 Syncora Player

**A free, open-source, and premium-quality music player for Windows and Android.**

*Stream public audio. Own your library. No subscriptions.*

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20Windows-brightgreen)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)

> **Download**: *(coming soon)*

</div>

---

## What is Syncora Player?

Syncora Player is an open-source, native music player for **Windows and Android** that allows users to build and manage personal music libraries without ads or subscriptions. Audio is streamed client-side from public sources using a resilient extraction engine, and playlists are synced to the cloud via Supabase.

The core philosophy: **privacy-first, open source, premium design, zero cost to the user.**

> **A note on scale:** Syncora Player is a non-commercial hobby project running entirely on free-tier infrastructure. Streaming, downloads, and the fully offline/no-account mode are **unlimited** for everyone. Cloud accounts (sync across devices, AI features) are capped at the **first 250 signups**, to stay within the free database tier — the cap can be raised anytime without a redeploy if the project outgrows it. See [Documento_Maestro.md §4.5](docs/Documento_Maestro.md#45-límite-de-cuentas-y-modo-sin-cuenta-decisión-de-producto) for the full rationale.

---

## ✨ Features

### Core
- 🎵 **Stream public audio** — no account required, no ads, no limits
- 📴 **Fully offline / local mode** — build and edit playlists without ever creating an account (unlimited)
- ☁️ **Optional cloud account** for sync across devices and AI features — open to the **first 250 signups** while the project runs on free-tier infrastructure
- 📚 **Personal playlists** with cloud sync across devices
- 📥 **Download for offline playback** (selectable audio quality)
- ❤️ Liked songs playlist and offline mode
- 🔀 Normal, Shuffle, and Repeat modes
- 🎙️ **Gapless playback** and Skip Silence support
- 🔔 Native OS controls — lock screen, Google Assistant, Windows System Media Transport Controls (SMTC)
- 🗂️ Import playlists from Spotify/Apple Music (CSV/text via TuneMyMusic, Soundiiz)
- 📤 Export any playlist to CSV for full data portability

### AI-Powered (Gemini API)
- 💬 Generate playlists or playback queues from a text prompt
- 🔍 Find a song by typing a lyric fragment
- ✏️ Edit playlists with natural language ("remove all songs by this artist")
- 🔑 **BYOK (Bring Your Own Key) Support**: The initial version comes with default AI integration, while also allowing users to supply their own Google AI Studio key (BYOK) for unlimited usage as the app scales.

### Premium Experience
- 🎨 Waveform visualizer, fullscreen player, animated mini-player
- 🔁 Crossfade between downloaded/cached tracks
- 🔀 Smart Shuffle (AI-assisted suggestions)
- 📊 Yearly Wrapped-style listening stats

---

## 🛠️ Tech Stack

| Layer | Android | Windows |
| :--- | :--- | :--- |
| **Framework** | Flutter (Dart) | Flutter (Dart) |
| **Audio Engine** | `just_audio` + ExoPlayer | `media_kit` (libmpv) |
| **OS Controls** | `audio_service` | `smtc_windows` |
| **Extraction Engine** | `youtubei.js` + QuickJS (`flutter_js`) | ← Same |
| **Metadata** | Deezer API | ← Same |
| **Lyrics** | LRCLib (`lrclib.net`, open-source) | ← Same |
| **Cloud / Auth** | Supabase (PostgreSQL) | ← Same |
| **Local Cache** | Drift (SQLite) | ← Same |
| **AI** | Google AI Studio (Gemini) | ← Same |

---

## 🔩 Extraction Engine Architecture

The extraction engine is a critical subsystem of Syncora Player. It is responsible for obtaining a playable audio stream URL from public web clients without requiring maintainers to release new application builds for minor upstream changes.

### How it works

```
┌──────────────────────────────────────────────────┐
│         ExtractionService / Player UI            │
└─────────────────────┬────────────────────────────┘
                      │ 1. extractUrl(videoId)
                      ▼
┌──────────────────────────────────────────────────┐
│      ExtractionIsolate (Dart secondary thread)   │
│  Runs QuickJS in isolation — 0 UI jank           │
└─────────────────────┬────────────────────────────┘
                      │ 2. Load polyfills + bundle
                      ▼
┌──────────────────────────────────────────────────┐
│         JsBundleLoader (Polyfill layer)          │
│  Injects Web APIs into QuickJS:                  │
│  URL, fetch, TextEncoder, setTimeout, etc.       │
└─────────────────────┬────────────────────────────┘
                      │ 3. JS calls fetch()
                      ▼
┌──────────────────────────────────────────────────┐
│         DartFetchBridge (Native HTTP via Dio)    │
│  Handles redirects, cookies, GZIP, Brotli        │
└─────────────────────┬────────────────────────────┘
                      │ 4. HTTP requests to YouTube
                      ▼
               ┌──────────────┐
               │   YouTube    │
               └──────────────┘
```

### Source Files

| File | Role |
| :--- | :--- |
| `assets/js/youtubei.bundle.js` | The compiled `youtubei.js` library. Handles the public Innertube protocol and signature deciphering. **This is the main file updated during upstream engine updates.** |
| `lib/core/extraction/js_bundle_loader.dart` | Loads the bundle and injects pure-JS polyfills for Web APIs that QuickJS doesn't include natively (`URL`, `fetch`, `TextEncoder`, `setTimeout`, etc.). |
| `lib/core/extraction/extraction_isolate.dart` | Runs QuickJS inside a dedicated `Isolate` (secondary Dart thread) to keep the UI at 60 FPS. Manages the client fallback hierarchy (`ANDROID → ANDROID_VR → WEB`). |
| `lib/core/extraction/dart_fetch_bridge.dart` | The network bridge. Intercepts `fetch()` calls from JavaScript and executes them natively in Dart via `Dio`, handling redirects, session cookies, and decompression. |
| `lib/core/extraction/retry_policy.dart` | Guard against 403 loops. Allows exactly **1 retry** on network/rate-limit errors, then pauses immediately to protect the user's IP from rate limits. |

### Resilience and Maintenance Matrix

The extraction engine is designed for **zero-APK-update maintenance** when upstream signature scripts change. The bundle file (`assets/js/youtubei.bundle.js`) can be updated over-the-air (OTA) from a public Storage bucket without releasing a new application build.

| Event / Upstream Change | Solved by OTA `youtubei.js` update? | Code Change Required in App? |
| :--- | :---: | :---: |
| **Signature algorithm change** (`n-sig` / `s` decipher) | ✅ Yes — no APK update needed | None |
| **BotGuard / PoToken policy changes** | ✅ Mostly — bundle tracks exempt clients | Minor: update client hierarchy in `extraction_isolate.dart` if needed |
| **Manifest format updates (DASH / HLS)** | ✅ Extraction side | Configure native player layer for manifest URLs |
| **New Web APIs required by JS engine** | ❌ No | Add missing polyfill to `js_bundle_loader.dart` |
| **ExoPlayer / Native HTTP header policies** | ❌ No | Adjust native audio layer / manifest headers |

---

## 🏗️ Project Structure

```
syncora-player/
├── assets/
│   └── js/
│       └── youtubei.bundle.js       # Core extraction library
├── android/
│   └── app/src/main/
│       ├── AndroidManifest.xml
│       └── res/xml/
│           └── network_security_config.xml  # Permits just_audio local proxy
├── lib/
│   ├── core/
│   │   ├── extraction/
│   │   │   ├── dart_fetch_bridge.dart       # Native HTTP bridge (Dio)
│   │   │   ├── extraction_isolate.dart      # QuickJS isolated thread
│   │   │   ├── extraction_provider.dart     # Riverpod provider
│   │   │   ├── extraction_service.dart      # Public service facade
│   │   │   ├── js_bundle_loader.dart        # Polyfill layer for QuickJS
│   │   │   ├── retry_policy.dart            # 403 guard and retry logic
│   │   │   └── models/
│   │   │       ├── extraction_request.dart
│   │   │       └── extraction_result.dart
│   │   └── theme/
│   └── features/
│       └── player/
│           └── debug/
│               └── extraction_debug_screen.dart  # Temporary debug UI (Phase 1)
├── test/
│   └── core/extraction/
│       ├── retry_policy_test.dart
│       ├── dart_fetch_bridge_test.dart
│       └── multi_song_extraction_test.dart
└── docs/
    ├── Documento_Maestro.md
    ├── investigacion_y_pitfalls.md
    ├── matriz_de_pruebas.md
    └── fases/
        ├── fase_0.md
        └── fase_1.md
```

---

## 🚀 Getting Started (Development)

### Prerequisites
- [Flutter SDK](https://docs.flutter.dev/get-started/install) (3.x or later)
- Android device or emulator (API 21+) **or** Windows 10+
- USB debugging enabled on Android (for physical device testing)

### Setup

```bash
# 1. Clone the repository
git clone https://github.com/NotJcao17/syncora-player.git
cd syncora-player

# 2. Install dependencies
flutter pub get

# 3. Copy and fill in environment variables
cp .env.example .env

# 4. Run on Android
flutter run --device-id <your-device-id>

# 5. Run on Windows
flutter run -d windows
```

### Running Tests

```bash
# Unit tests (RetryPolicy, DartFetchBridge)
flutter test test/core/extraction/retry_policy_test.dart
flutter test test/core/extraction/dart_fetch_bridge_test.dart

# Multi-song extraction benchmark (requires network)
flutter test test/core/extraction/multi_song_extraction_test.dart --timeout 4m
```

---

## ⚠️ Security Notice & False Positive Alert

> **Note on GitHub Secret Scanning:** The `assets/js/youtubei.bundle.js` file contains the public string `AIzaSyAO_...` which automated tools may flag as a "Google API Key". This is a **false positive**. It is YouTube's public web client API key embedded in open-source YouTube client libraries. It is not a private credential and does not grant access to any private cloud resources or personal accounts.

---

## ⚖️ Legal Disclaimer

**Syncora Player** is developed by **Juan Carlos Orozco Nieto** for educational, personal, and research purposes only.

- Syncora Player **does not host, store, upload, or distribute** any audio or video files or copyrighted material.
- All media streaming requests are performed client-side by the end-user using public web protocols.
- The author and contributors are **not responsible** for how end-users choose to use this application, nor for any potential violations of third-party terms of service or copyright laws caused by individual usage.

---

## 📄 License

Copyright (c) 2026 **Juan Carlos Orozco Nieto**.

This project is licensed under the **MIT License**. Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files, to deal in the Software without restriction, subject to the condition that the above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

---

<div align="center">
  Built with ❤️ using Flutter · Created by <b>Juan Carlos Orozco Nieto</b> · Powered by <a href="https://github.com/LuanRT/YouTube.js">youtubei.js</a>
</div>
