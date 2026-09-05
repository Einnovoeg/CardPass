# Changelog — CardPass

All notable changes are documented here. Follows Keep-a-Changelog and SemVer.

## [2.0.0] — 2026-09-04

### Added
- **True-black UI**: main window + Advanced pane now use `blackColor` (`0,0,0`) instead of `0.13/0.11` gray; `hexTextView` / `readersTextView` / `rawHexView` / `preTruncateView` are white-on-black with black scroll backgrounds; labels use `whiteColor` / `0.7-0.8` light gray for contrast. Tahoe `DarkAqua` retained for controls.
- **Larger gold chip**: app icon `icon.png` (1024) + `icon_256.png` + `AppIcon.icns` regenerated with 15% larger chip (`≈72%` width, `55%` height on 1024) in gold `#D4AF37`, engraved divider lines (`#B48C1E`), pure black background.
- **5 white asterisk stars**: masked-password `*****` asterisks (not generic stars) in pure white, exactly five, below the chip in dock icon and menu-bar icon; drawn via thick line-asterisk (`draw_asterisk_v2`) for bold appearance.
- **Menu-bar icon**: now **black** chip (`template=NO`, size `18×18`) with inverted 5 white `*` (previously white template). `Resources/MenuIcon.png` (22) / `MenuIcon@2x.png` (44) rebuilt.
- **Delay controls**: `delayField` + `delayStepper` (0.2–10 s, step 0.5) now properly created in window (`main.m:1184-1205`) on the Truncate row, persisted via `NSUserDefaults` (`CPAutoTypeDelay`), with delegate handling.
- **Info label**: `encodingInfoLabel` now `9pt`, `0.65` gray, `lineBreakMode` truncate, widened to 225pt to avoid clipping.

### Fixed
- **Jumbled / overlapping layout** (`main.m:841-1207`): rewrote `setupWindow` with clean Y-map and 8-14px gaps per row. `hexLabel` moved from `242` (which collided with `Truncate` at `238`) to `202`; `readersScroll` `288-356` (68h); Row1 `257-279` (Output/Hash); Row2 `228-250` (Truncate/Delay/Info); `hexScroll` `148-198` (50h); buttons `108`; separator `90`; toggles `60`; coffee `12`. All frames now use `NSViewMaxYMargin`/`WidthSizable` consistently; spinner moved to `480,390`. Verified via `screencapture -R` (520×502) — no overlap.
- **Reader compatibility for diverse hardware** (`pcsc_reader.c:376-526`, `main.m:1783-1825`): `SCardConnect` now tries `SHARED` → `EXCLUSIVE` → `DIRECT` with `T0|T1` → `T0` → `T1` → `RAW` (fixes `0x80100066` `SCARD_W_RESET_CARD` on Generic USB2.0-CRW, SD bridges, and exclusive-lock readers); fallback to ATR via `SCardGetStatusChange` (500ms) without handle guarantees hex for any present card; `SCardGetStatusChange` timeout `250→500ms` for slow contact readers (Omnikey, Cherry, Feitian); `handleCardReadResult` now shows cached ATR as `Card ATR ✓` when `Connect failed` but ATR is cached, preserving auto-copy/hash.
- **PII / secrets**: removed absolute local volume paths from committed files (`main.m:43`, `README.md`, `CHANGELOG.md`, `.gitignore`); replaced with generic `~/Library/CardPass` / “centralized Library location”.

### Changed
- `main.m` header docs now reference centralized library generically, not personal path.
- `Info.plist` bumped to `CFBundleShortVersionString 2.0.0`, `CFBundleVersion 6`.
- `README.md` rewritten for 2.0 (What’s New, architecture `520×470`, troubleshooting, help-wanted imploring PRs, coffee link in multiple places).
- `THIRD_PARTY_NOTICES.md` expanded with full author/copyright lines for pyscard LGPL-2.1, pyperclip/rumps/pyautogui BSD, py2app MIT, and Apple framework table.
- `Makefile` now copies `MenuIcon.png`/`@2x` + `icon*.png` into `CardPass.app` (previously only `AppIcon.icns`).

### Security
- Bounds-checked `snprintf`/`strncpy` with NUL clamp retained; per-call `SCARDCONTEXT`/`SCARDHANDLE`, `SCARD_LEAVE_CARD`.
- No card data persisted to disk; clipboard/type only on user action; `CGEvent` typing remains gated by `isTrustedForTyping()` (`CGPreflightPostEventAccess` + `AXIsProcessTrusted`) but deferred per Issue #1 — clipboard remains the secure default (no permission needed).
- Verified `grep -R` clean for secrets, tokens, private keys, emails — only `buymeacoffee.com/einnovoeg` remains by design.

### Known Issues & What Needs Work
See README “Known Issues & Help Wanted” — please file PRs! Auto-type is deferred to Issue #1; menu-bar black icon is invisible on dark menu bars except the stars (by spec).

[2.0.0]: https://github.com/Einnovoeg/CardPass/releases/tag/v2.0.0

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
- **Universal card reading** in `pcsc_reader.c`: UID `FF CA` → AID SELECT → SIM/EF (MF `3F00`, ICCID `2FE2`, IMSI `6F07`, `GET DATA`, `NDEF`) → ATR fallback.
- **Hardware wedge behavior**: auto-copy to clipboard + 1s-delay auto-type into frontmost field via `CGEvent`. Clipboard always works (⌘V) without permission; auto-type optionally needs Device Control / Accessibility.
- **Robust polling**: 1.5s interval, background GCD, ATR-change detection to avoid re-reading always-present YubiKeys; thread-safe PC/SC (per-call context/handle).
- **Full app chrome**: `NSWindow` 520×500 with reader list, password view, Copy/Type/Clear/Refresh, Auto-copy/Type switches; `NSStatusItem` with icon + dynamic menu; `NSApplication` main menu with Show Window and **Buy Me a Coffee** link.
- **Password encoding pipeline**: optional encodings **Hex (Base16)**, **Base62** (`0-9A-Za-z`, ~30% shorter than hex, never rejected), **Base58** (Bitcoin alphabet without 0/O/I/l, for humans), **Base64** (+/ with `=` padding, ~33% shorter); plus optional **Hash SHA-256** (condenses any length to 32 bytes → always 43 Base62 chars, truncatable to 16-24 for strict fields) and **Truncate** to N chars (0 = full). UI: Output popup, Hash SHA-256 switch, Truncate field+stepper, info label.
- **App bundle**: `Info.plist` with `CFBundleIconFile`, `LSUIElement=false` (Dock+Menu), `NSAppleEventsUsageDescription`; `Resources/AppIcon.icns` + `icon.png` set.
- **Documentation**: `README.md` with install/usage/encoding tips/known-issues & help-wanted + Buy Me a Coffee, `LICENSE` (MIT), `THIRD_PARTY_NOTICES.md`, `requirements.txt`, `.gitignore`, `CHANGELOG.md`.
- **Support**: “❤️ Buy Me a Coffee” menu item + window button linking to https://buymeacoffee.com/einnovoeg
- **Library centralization**: reusable `pcsc_reader.h/c` also installable to a centralized Library location for other local tools.

### Changed
- Migrated from Python `rumps`/`CardMenuApp.py` to pure Cocoa. Deprecated Python files moved to `deprecated/` (gitignored) and kept only as reference.
- Build now requires `-fobjc-arc -framework ApplicationServices -framework PCSC`.
- Window enlarged to 520×500 to fit encoding bar.

### Fixed
- **Crash (SIGSEGV)** from `statusItem.button` dangling access: now retains `statusButton` and dispatches all UI to main queue.
- **Permissions UI bug (Tahoe, 27.0):** Menu bar no longer sticks on “Need Permission” and Check dialog no longer points to missing Accessibility pane.
- **Auto-type nag:** Removed automatic modal on every card scan when not trusted.
- YubiKey / security keys no longer show “Error”: ATR fallback returns stable hex instead of failure.

### Security
- Bounds-checked `snprintf`/`strncpy`, NUL termination, handle validation, `SCARD_LEAVE_CARD` disconnects; no card data persisted to disk.
- No card data logged beyond length counts; clipboard/type only on user action.
- Typing gated by `AXIsProcessTrustedWithOptions`; random delays preserved.

[1.0.0]: https://github.com/Einnovoeg/CardPass/releases/tag/v1.0.0
