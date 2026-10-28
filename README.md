
<p align="center">
  <img src="https://afkdev.app/hero-image.webp" alt="AFK - Vibe coding from your couch" width="600">
</p>
<h1 align="center">
  <img src="assets/app_icon.png" alt="" width="28" style="vertical-align: middle;">
  AFK Host
</h1>

<p align="center">
  <strong>Remote desktop host for <a href="https://afkdev.app">AFK</a></strong><br>
  Stream your Mac, Windows, or Linux screen to your phone and control it with touch and voice.
</p>

<p align="center">
  <a href="https://afkdev.app">Website</a> •
  <a href="https://apps.apple.com/app/afk-remote/id6756719961">App Store</a> •
  <a href="https://play.google.com/store/apps/details?id=app.afkdev.afk">Google Play</a> •
  <a href="https://afkdev.app/download">Download</a>
</p>

---


## What is AFK?


AFK is a remote desktop app designed for **vibe coding** — directing AI agents like Claude Code from your phone using voice commands while lounging on your couch.

This repo contains the **host application** that runs on your computer and streams your screen to the AFK mobile app.

## Features

- 🖥️ **Low-latency Streaming** — WebRTC-powered screen sharing with adaptive quality
- 🎤 **Voice Control** — Speak commands to control your computer
- 🖱️ **Touch Input** — Full mouse and keyboard control from your phone
- 🪟 **Window Switcher** — Quickly switch between windows with touch
- 🔔 **CLI Notifications** — Get notified when Claude Code or Pi needs attention
- 🔒 **End-to-End Encryption** — Secure connection between devices

## Supported Platforms

| Platform | Status |
|----------|--------|
| macOS | ✅ Stable |
| Windows | 🚧 In development |
| Linux (Wayland) | 🧪 Work in progress — KDE Plasma 6 works; GNOME has a video freeze. See [docs/LINUX.md](docs/LINUX.md) |

## Quick Start

1. **Download** the pre-built host app from [afkdev.app/download](https://afkdev.app/download)
2. **Install** and grant screen recording permission when prompted
3. **Get the mobile app** on [iOS](https://apps.apple.com/app/afk-remote/id6756719961) or [Android](https://play.google.com/store/apps/details?id=app.afkdev.afk)
4. **Pair** by entering the 6-digit code shown on your computer

For detailed setup instructions, visit [afkdev.app](https://afkdev.app).

## Build from Source

Requires [Flutter](https://flutter.dev/docs/get-started/install) 3.10+

```bash
# Clone the repo
git clone https://github.com/liboshen/afk-host.git
cd afk-host

# Install dependencies
flutter pub get

# Run
flutter run -d macos    # macOS
flutter run -d windows  # Windows (rough edges)
flutter run -d linux    # Linux (Wayland, experimental)

# Build release
flutter build macos
flutter build windows
flutter build linux
```

## License

MIT License — see [LICENSE](LICENSE) for details.

---

<p align="center">
  <a href="https://afkdev.app">afkdev.app</a>
</p>
