# Changelog — CardPass

All notable changes to this project are documented here. Follows Keep-a-Changelog and SemVer.

## [1.0.1] — 2026-09-03

### Fixed
- **Permissions UI bug (Tahoe):** Menu bar no longer sticks on “Need Permission” and Check dialog no longer points to missing Accessibility pane. Tahoe moved the toggle to **Privacy & Security → Device Control and Data Access** (pre-Tahoe: Accessibility). CardPass now gracefully degrades: clipboard copy (⌘V) always works without permission; auto-type is optional and only attempts `CGEvent` when `AXIsProcessTrusted` is true.
- **Auto-type nag:** Removed automatic modal on every card scan when not trusted. Now shows “Copied ✓ — press ⌘V to paste (enable Device Control for auto-type)” and returns to Ready after 2.5 s. Manual “Type” button explains the fallback and offers to copy again.
- **Settings opener:** `requestTypingPermission()` now tries `openPrivacySettingsDirectly()` with Tahoe + pre-Tahoe URLs (`com.apple.settings.PrivacySecurity.extension?Privacy_DeviceControl` / `Privacy_Accessibility`) in addition to the standard `AXIsProcessTrustedWithOptions` prompt, so “Open Settings” lands in the right place on macOS 27 (Darwin 27.0.0, Build 26A5425a).
- **UX copy:** Updated `Info.plist` `NSAppleEventsUsageDescription`, window hint, and menu titles (“Check Auto-Type Permission (Device Control)…”) to make it clear that Device Control is optional. Documented quit/reopen requirement when toggling.

### Changed
- `README.md` installation/usage/troubleshooting now notes Tahoe path and that clipboard needs no permission.

## [1.0.0] — 2026-09-03

### Added
- **Native macOS app** (`main.m` + `pcsc_reader.h/c`): Dock window + menu-bar status item, written in Objective-C/C with ARC, no Python runtime.
- **Universal card reading** in `pcsc_reader.c`: UID `FF CA` → AID SELECT → SIM/EF (MF `3F00`, ICCID `2FE2`, IMSI `6F07`, `GET DATA`, `NDEF`) → ATR fallback. Any PC/SC card/SIM now yields hex usable as a password token.
- **Hardware wedge behavior**: auto-copy to clipboard + 1s-delay auto-type into frontmost field via `CGEvent` (requires Accessibility permission, prompted gracefully).
- **Robust polling**: 1.5s interval, background GCD, ATR-change detection to avoid re-reading always-present YubiKeys; thread-safe PC/SC (per-call context/handle).
- **Full app chrome**: `NSWindow` 520×440 with reader list, hex view, Copy/Type/Clear/Refresh, Auto-copy/Type switches; `NSStatusItem` with icon + dynamic menu; `NSApplication` main menu with Show Window, Accessibility check, and **Buy Me a Coffee** link.
- **App bundle**: `Info.plist` with `CFBundleIconFile`, `LSUIElement=false` (Dock+Menu), `NSAppleEventsUsageDescription`; `Resources/AppIcon.icns` + `icon.png` set.
- **Documentation**: new `README.md`, `LICENSE` (MIT), `THIRD_PARTY_NOTICES.md`, `requirements.txt`, `.gitignore`, `CHANGELOG.md`.
- **Support**: “❤️ Buy Me a Coffee” menu item + window button linking to https://buymeacoffee.com/einnovoeg
- **Library centralization**: reusable `pcsc_reader.h/c` also installed to `/Volumes/Mac Stick/Library/CardPass/` for other local tools.

### Changed
- Migrated from Python `rumps`/`CardMenuApp.py` to pure Cocoa. Deprecated Python files moved to `deprecated/` (gitignored) and kept only as reference.
- Build now requires `-fobjc-arc -framework ApplicationServices -framework PCSC`.

### Fixed
- **Crash (SIGSEGV)** from `statusItem.button` dangling access: now retains `statusButton` and dispatches all UI to main queue (`main.m: state management`).
- UI thread safety and nil guards throughout; handles invalid reader indices and empty reader names.
- YubiKey / security keys no longer show “Error”: ATR fallback returns stable hex instead of failure.

### Security
- Bounds-checked `snprintf`/`strncpy`, NUL termination, handle validation, `SCARD_LEAVE_CARD` disconnects.
- No card data persisted to disk; clipboard/type only on user action.
- Accessibility typing gated by `AXIsProcessTrustedWithOptions`; random delays and `pyautogui.FAILSAFE` preserved in deprecated demos.

### Known Issues & What Needs Work
See README “Known Issues & Help Wanted” — please file PRs.

[1.0.0]: https://github.com/Einnovoeg/CardPass/releases/tag/v1.0.0
