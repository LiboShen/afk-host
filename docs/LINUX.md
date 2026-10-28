# Linux (Wayland) — status and notes

**Status: work in progress, not maintained (2026-10-27).** This builds on the portal-based Linux input
that shipped in v1.5.3 and fixes enough to make KDE Plasma 6 usable. GNOME is not done. These notes
record what works, what doesn't, and what was tried, so someone else can pick it up.

## What was tested

"Reported" means the result was recorded in the fork's README on 2026-06-28 from manual testing. It has
not been re-verified on this branch. The branch itself is verified only to `flutter analyze` and
`flutter build linux` on Arch (2026-10-27).

| Environment | Screen | Mouse | Keyboard | Evidence |
| --- | --- | --- | --- | --- |
| KDE Plasma 6, Wayland (Arch) | ✅ | ✅ absolute, pixel-exact on one monitor | not separately recorded | Reported |
| GNOME 47, Wayland (RHEL 10) | ✅ | ⚠️ works, but video freezes shortly after input starts | not separately recorded | Reported |
| X11 session (LXQt) | ✅ via libwebrtc's XCB path | ❌ no input path | ❌ | Reported |
| wlroots (Sway, Hyprland, labwc) | expected ✅ | ❌ `xdg-desktop-portal-wlr` has no RemoteDesktop | ❌ | Untested, inferred |
| Multi-monitor | — | possibly offset | — | Untested |
| macOS / Windows after this change | — | — | — | Untested (see "Cross-platform changes") |

## Requirements

- PipeWire, plus `xdg-desktop-portal` with a backend that implements **both** RemoteDesktop and
  ScreenCast (`xdg-desktop-portal-kde` or `-gnome`).
- Node.js 22.6+ for the `afk` CLI (`--experimental-strip-types`).
- RHEL/Fedora: SELinux blocks WebRTC UDP by default. For testing, run `sudo setenforce 0`. Otherwise
  build a policy: `sudo ausearch -m avc -ts today | audit2allow -M afk_host && sudo semodule -i afk_host.pp`.

## What changed

- **Absolute mouse.** `NotifyPointerMotionAbsolute` is now the only path. The relative-motion fallback
  was removed because it drifted. The phone sends normalized 0–1 coordinates, which are scaled by the
  **portal stream size** from the `Start` response, not the display size. KDE fractional scaling makes
  these differ: a 1920×1080 display at 1.25× scale gives a 1536×864 stream.
- **Session teardown.** `stopSession()` now calls `org.freedesktop.portal.Session.Close`, and
  `RemoteSessionManager` disposes `LinuxInputHandler` on disconnect. Before this, reconnecting left a
  stale portal session and KDE showed two screen-sharing indicators.
- **Black frames on Wayland.** `linux/runner/my_application.cc` unsets `DISPLAY` when `WAYLAND_DISPLAY`
  is set. Otherwise libwebrtc picks XWayland capture, which gives black frames, instead of PipeWire.
- **CLI install on Linux.** CMake bundles `cli/` next to the executable, and the settings UI symlinks it
  to `/usr/local/bin/afk`. If that's denied, it shows the `sudo ln -sf` command instead.

### Cross-platform changes (untested on macOS and Windows)

- `RemoteSessionManager` no longer treats `RTCPeerConnectionStateDisconnected` as terminal. Only
  `Failed` tears the session down. Disconnected is transient, and libwebrtc promotes it to Failed if ICE
  can't recover. This stopped a reconnect loop on Linux.
- `getDisplayMedia` constraints changed from `mandatory: {minWidth: 1920, minHeight: 1080, frameRate: 30}`
  to `frameRate: {ideal: 30, max: 30}`. The minimums failed on Linux at scaled resolutions.
- `flutter_webrtc` was bumped from `^1.3.0` to `^1.4.1`.

## Known problems

- **GNOME video freeze (open).** There are two ScreenCast sessions running at once: ours (combined
  RemoteDesktop+ScreenCast, needed so `NotifyPointerMotionAbsolute` has a stream node) and the one
  libwebrtc opens inside `getDisplayMedia`. When input starts, Mutter appears to stall one of them. KDE
  tolerates both. The likely fix is to use only our session: open the PipeWire stream with
  `OpenPipeWireRemote` and feed its frames into WebRTC as a custom video source. flutter_webrtc has no
  public API for that, so it needs an upstream flutter_webrtc change or a native plugin. Hypothesis,
  unverified: the freeze is caused by the two sessions.
- **Sessions drop after ~1–2 minutes on LAN without a TURN server.** Not diagnosed. It could be ICE
  consent refresh, or the GNOME stall above.
- **No input on X11 or wlroots.** The X11 fix is XTest. wlroots needs `zwlr_virtual_pointer_v1` and
  `zwp_virtual_keyboard_v1`.
- **Not implemented on Linux:** paste text, window switcher, cursor sync.

## Dead ends (don't repeat these)

- **uinput doesn't work on Wayland.** libinput's udev backend skips devices under `/devices/virtual/`,
  so compositors never see uinput devices. It works on X11 only.
- **PipeWire → v4l2loopback → `getUserMedia`** was an attempt to share one stream between video and
  input. It was built, and then removed from this branch. libwebrtc's Linux V4L2 capture ignored the
  requested `deviceId` and opened `/dev/video0` (the webcam) instead. Root cause not found; it may be
  device-ID matching on `bus_info`.

## If you pick this up: getting the PipeWire fd in Dart

Owning the stream requires the session's PipeWire fd, and getting it has two catches:

1. `OpenPipeWireRemote` must be called on the **same D-Bus connection** that created the session.
   Calling it from another connection or process returns `AccessDenied: Invalid session`.
2. The fd comes back as a `DBusUnixFd`, and in Dart SDK 3.12 there was no way to get the raw int from it
   (`ResourceHandle.toRawHandle()` was missing). The workaround: list `/proc/self/fd` before and after
   the call, diff the two, and immediately `dup()` the new fd through FFI so GC can't close it. Check
   each entry with `Link(...).targetSync()`, because the directory fd used by `listSync()` is closed and
   reused and would otherwise look new.

```dart
import 'dart:ffi' hide Size; // dart:ui also exports Size

final _dup = DynamicLibrary.open('libc.so.6')
    .lookupFunction<Int32 Function(Int32), int Function(int)>('dup');

Set<int> _scanOpenFds() {
  final fds = <int>{};
  for (final e in Directory('/proc/self/fd').listSync()) {
    final n = int.tryParse(e.path.split('/').last);
    if (n == null) continue;
    try { Link('/proc/self/fd/$n').targetSync(); fds.add(n); } catch (_) {}
  }
  return fds;
}
```

The full implementation, plus the C++ PipeWire consumer it fed, is in commit
[`b0acb52`](https://github.com/flyboy-byte/afk-host/commit/b0acb52) on the (archived) fork.
