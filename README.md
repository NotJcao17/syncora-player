<div align="center">

# 🎵 Syncora Player

**A free, private, and premium-quality music player for Windows and Android.**

*Stream from YouTube. Own your library. No subscriptions.*

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20Windows-brightgreen)](https://flutter.dev)
[![License](https://img.shields.io/badge/License-Private-lightgrey)]()

> **Download**: *(coming soon)*

</div>

---

## What is Syncora Player?

Syncora Player is a native music player for **Windows and Android** that lets users build and manage personal music libraries for free, without ads or subscriptions. Audio is streamed directly from YouTube using a resilient extraction engine, and playlists are synced to the cloud via Supabase.

The core philosophy: **privacy-first, premium design, zero cost to the user.**

---

## ✨ Features

### Core
- 🎵 **Stream any song** from YouTube — no account, no ads
- 📚 **Personal playlists** with full cloud sync across devices
- 📥 **Download for offline playback** (selectable audio quality)
- ❤️ Liked songs playlist and offline mode
- 🔀 Normal, Shuffle, and Repeat modes
- 🎙️ **Gapless playback** and Skip Silence support
- 🔔 Native OS controls — lock screen, Google Assistant, Windows System Media Transport Controls (SMTC)
- 🗂️ Import playlists from Spotify/Apple Music (CSV/text via TuneMyMusic, Soundiiz)
- 📤 Export any playlist to CSV for full data portability

### AI-Powered (Gemini)
- 💬 Generate playlists or playback queues from a text prompt
- 🔍 Find a song by typing a lyric fragment
- ✏️ Edit playlists with natural language ("remove all songs by this artist")

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

The extraction engine is the most critical subsystem of Syncora Player. It is responsible for obtaining a playable audio URL from YouTube without requiring API keys, accounts, or maintaining brittle scrapers.

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
| `assets/js/youtubei.bundle.js` | The compiled `youtubei.js` library. Knows YouTube's Innertube protocol and handles signature deciphering. **This is the only file that changes when YouTube updates.** |
| `lib/core/extraction/js_bundle_loader.dart` | Loads the bundle and injects pure-JS polyfills for Web APIs that QuickJS doesn't include natively (`URL`, `fetch`, `TextEncoder`, `setTimeout`, etc.). |
| `lib/core/extraction/extraction_isolate.dart` | Runs QuickJS inside a dedicated `Isolate` (secondary Dart thread) to keep the UI at 60 FPS. Manages the client fallback hierarchy (`ANDROID → ANDROID_VR → WEB`). |
| `lib/core/extraction/dart_fetch_bridge.dart` | The network bridge. Intercepts `fetch()` calls from JavaScript and executes them natively in Dart via `Dio`, handling redirects, session cookies, and decompression. |
| `lib/core/extraction/retry_policy.dart` | Guard against 403 loops. Allows exactly **1 retry** on network/rate-limit errors, then pauses immediately to protect the user's IP from being banned. |

### Resilience and OTA Updates

The extraction engine is designed for **zero-APK-update maintenance** when YouTube changes its internals. The only file that ever needs to change in response to YouTube updates is `assets/js/youtubei.bundle.js`. This file can be served and updated remotely from the Supabase Storage bucket — the app downloads it at runtime, without requiring a new release on any app store.

| Possible YouTube change | Solved by OTA `youtubei.js` update? | Dart/Flutter code change needed? |
| :--- | :---: | :---: |
| **Signature algorithm change** (`n-sig` / `s` decipher) | ✅ Yes — no APK update needed | None |
| **PoToken / BotGuard extended to new clients** | ✅ Mostly — bundle tracks exempt clients | Minor: update client list in `extraction_isolate.dart` |
| **Switch to DASH / HLS manifest format** | ✅ Extraction side | Configure player to receive manifest URL |
| **New Web APIs required by `youtubei.js`** | ❌ No | Add missing polyfill to `js_bundle_loader.dart` |
| **CDN / HTTP header policy change (ExoPlayer)** | ❌ No | Adjust header injection in the native player layer |

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
# Edit .env with your Supabase credentials

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

## 🔐 Security & API Keys

> **Note on GitHub Secret Scanning:** The `assets/js/youtubei.bundle.js` file contains the string `AIzaSyAO_...` which GitHub flags as a "Google API Key". This is a **false positive**. It is YouTube's own public client API key, embedded in all YouTube clients (web and mobile). It is not a private credential and does not belong to this project.

Secrets used by Syncora Player (Supabase URL, anon key, Gemini key) are **never committed**. They are loaded from a `.env` file at runtime (excluded via `.gitignore`).

---

## 🗺️ Development Roadmap

| Phase | Description | Status |
| :--- | :--- | :---: |
| **Phase 0** | Project setup, dependencies, architecture | ✅ Done |
| **Phase 1** | Resilient extraction engine (YouTube → audio URL) | ✅ Done |
| **Phase 2** | Audio state management + OS controls integration | 🔜 Next |
| **Phase 3** | Core UI and navigation | ⬜ |
| **Phase 4** | Data layer — Deezer metadata + local DB (Drift/SQLite) | ⬜ |
| **Phase 5** | Cloud sync, auth, and online-first architecture (Supabase) | ⬜ |
| **Phase 6** | Offline mode and batch downloads | ⬜ |
| **Phase 7** | Premium experience — AI features, crossfade, Wrapped stats | ⬜ |

---

## 📄 License

This project is private and not licensed for public distribution at this time. A license will be added upon public release.

---

<div align="center">
  Built with ❤️ using Flutter · Powered by <a href="https://github.com/LuanRT/YouTube.js">youtubei.js</a>
</div>
