# Changelog — CardPass

All notable changes to this project are documented here. Follows Keep-a-Changelog and SemVer.

## [1.0.1] — 2026-09-03

### Added
- **Customizable auto-type delay:** Delay field (0.2-10.0 s, stepper 0.5 s) next to Auto-type toggle; persisted in `NSUserDefaults` (`CPAutoTypeDelay`), used for `dispatch_after` before `CGEvent` typing. Default 1.0 s.
- **Advanced pane (slide-out to the right):** Button `Advanced ▶` expands window from 520 to 820 width, showing **Raw Hex (non-encoded, non-hashed, non-truncated)** and **Encoded + Hashed (pre-truncate)** in separate scroll views, with `Copy Raw Hex` / `Copy Encoded` buttons. Accessible via window button, **View → Show Advanced Pane** (⌘⇧A) and **Status Menu → Advanced → Show Raw Hex… / Copy Raw Hex**. Main password field (left) remains unchanged as final truncated output.
- **Darker, more compact theme:** Window `DarkAqua` appearance, dark `0.13` background, header `0.16`, advanced pane `0.11`; window resized to 520×470 (was 520×500) with tighter 48-pt header and compact bottom bar (Auto-copy/Auto-type + Delay + Advanced on one row). Feels denser, better for OLED.
- **New app icon:** Smart card with gold stars (password) on dark background, generated for all sizes (16-1024) via `iconutil`, replaces plain card icon.

### Fixed
- **Tahoe Device Control permission:** `isTrustedForTyping()` now checks `CGPreflightPostEventAccess` (Tahoe’s Device Control) via runtime `dlsym` before `AXIsProcessTrusted`; `requestTypingPermission()` tries `CGRequestPostEventAccess` then fallback. `tahoeSettingsPath` removed (unused). Alerts now correctly say `System Settings → Privacy & Security → Device Control and Data Access` (Tahoe) vs Accessibility (pre-Tahoe) and explain restart needed. Menu titles updated to `Check Auto-Type Permission (Device Control)…` with tooltip `Clipboard copy via ⌘V needs no permission`.

### Changed
- `README.md` installation/usage now notes delay and advanced pane; `Info.plist` → 1.0.1 (b5).

## [1.0.0] — 2026-09-03

### Added
- **Native macOS app** (`main.m` + `pcsc_reader.h/c`): Dock window + menu-bar status item, written in Objective-C/C with ARC, no Python runtime.
- **Universal card reading** in `pcsc_reader.c`: UID `FF CA` → AID SELECT → SIM/EF (MF `3F00`, ICCID `2FE2`, IMSI `6F07`, `GET DATA`, `NDEF`) → ATR fallback. Any PC/SC card/SIM now yields hex usable as a password token.
- **Hardware wedge behavior**: auto-copy to clipboard + 1s-delay auto-type into frontmost field via `CGEvent`. Clipboard always works (⌘V) without permission; auto-type optionally needs Device Control / Accessibility.
- **Robust polling**: 1.5s interval, background GCD, ATR-change detection to avoid re-reading always-present YubiKeys; thread-safe PC/SC (per-call context/handle).
- **Full app chrome**: `NSWindow` 520×500 with reader list, password view, Copy/Type/Clear/Refresh, Auto-copy/Type switches; `NSStatusItem` with icon + dynamic menu; `NSApplication` main menu with Show Window and **Buy Me a Coffee** link.
- **Password encoding pipeline**: optional encodings **Hex (Base16)**, **Base62** (`0-9A-Za-z`, ~30% shorter than hex, never rejected), **Base58** (Bitcoin alphabet without 0/O/I/l, for humans), **Base64** (+/ with `=` padding, ~33% shorter); plus optional **Hash SHA-256** (condenses any length to 32 bytes → always 43 Base62 chars, truncatable to 16-24 for strict fields) and **Truncate** to N chars (0 = full). UI: Output popup, Hash SHA-256 switch, Truncate field+stepper, info label shows `raw → encoded` lengths; settings persisted in `NSUserDefaults`.
- **App bundle**: `Info.plist` with `CFBundleIconFile`, `LSUIElement=false` (Dock+Menu), `NSAppleEventsUsageDescription`; `Resources/AppIcon.icns` + `icon.png` set.
- **Documentation**: `README.md` with install/usage/encoding tips/known-issues & help-wanted + Buy Me a Coffee, `LICENSE` (MIT), `THIRD_PARTY_NOTICES.md`, `requirements.txt`, `.gitignore`, `CHANGELOG.md`.
- **Support**: “❤️ Buy Me a Coffee” menu item + window button linking to https://buymeacoffee.com/einnovoeg
- **Library centralization**: reusable `pcsc_reader.h/c` also installed to `/Volumes/Mac Stick/Library/CardPass/` for other local tools.

### Changed
- Migrated from Python `rumps`/`CardMenuApp.py` to pure Cocoa. Deprecated Python files moved to `deprecated/` (gitignored) and kept only as reference.
- Build now requires `-fobjc-arc -framework ApplicationServices -framework PCSC`.
- Window enlarged to 520×500 to fit encoding bar; `README.md` installation/usage now notes Tahoe path and clipboard-first workflow.

### Fixed
- **Crash (SIGSEGV)** from `statusItem.button` dangling access: now retains `statusButton` and dispatches all UI to main queue.
- **Permissions UI bug (Tahoe, 27.0):** Menu bar no longer sticks on “Need Permission” and Check dialog no longer points to missing Accessibility pane. Tahoe moved the toggle to **Privacy & Security → Device Control and Data Access** (pre-Tahoe: Accessibility). CardPass now gracefully degrades: clipboard copy (⌘V) always works without permission; auto-type only attempts `CGEvent` when `AXIsProcessTrusted` is true. `Info.plist` `NSAppleEventsUsageDescription` updated. Settings opener now tries Tahoe URLs (`com.apple.settings.PrivacySecurity.extension?Privacy_DeviceControl`).
- **Auto-type nag:** Removed automatic modal on every card scan when not trusted. Now shows “Copied ✓ — press ⌘V to paste (enable Device Control for auto-type)” and returns to Ready after 2.5 s.
- YubiKey / security keys no longer show “Error”: ATR fallback returns stable hex instead of failure.
- UI thread safety and nil guards throughout; handles invalid reader indices and empty reader names.

### Security
- Bounds-checked `snprintf`/`strncpy`, NUL termination, handle validation, `SCARD_LEAVE_CARD` disconnects; no card data persisted to disk.
- No card data logged beyond length counts; clipboard/type only on user action.
- Typing gated by `AXIsProcessTrustedWithOptions`; random delays preserved.
- Hash feature uses `CommonCrypto` `CC_SHA256`; truncation is safe due to uniform distribution.

### Known Issues & What Needs Work
See README “Known Issues & Help Wanted” — please file PRs.

[1.0.0]: https://github.com/Einnovoeg/CardPass/releases/tag/v1.0.0
