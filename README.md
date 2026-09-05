# CardPass — Tap Any Smart Card to Fill Password Fields

**CardPass** is a native macOS app that turns *any* PC/SC smart card, chip card, or SIM into a hardware password token. Insert a card → CardPass reads stable hex and auto-copies it to the clipboard, then (optionally) auto-types it into the frontmost password field like a hardware keyboard wedge. No Python runtime, no Electron — just Cocoa + PC/SC.

> 💛 Love CardPass? Support the work at **[buymeacoffee.com/einnovoeg](https://buymeacoffee.com/einnovoeg)** — every coffee keeps the reader running! Link is also in the app: **Menu bar → ❤️ Buy Me a Coffee** and **CardPass → Support — Buy Me a Coffee ❤️**.

![macOS](https://img.shields.io/badge/macOS-10.13%2B-blue) ![License](https://img.shields.io/badge/license-MIT-green) ![Native](https://img.shields.io/badge/native-Cocoa%20%2F%20PCSC-lightgrey) ![Version](https://img.shields.io/badge/version-2.0.0-brightgreen)

---

## What’s New in 2.0

- **True-black UI** — window + advanced pane are now pure `blackColor` (OLED-friendly); password hex is **white** on black for contrast.
- **Larger gold chip** — app icon `icon.png`/`icon_256.png` and header `AppIcon.icns` now show a 15% larger gold chip (`#D4AF37`) with engraved dividers; black background.
- **5 white asterisk stars** — masked-password `*****` asterisks (not generic stars) in white, exactly five, below the chip in both dock icon and menu-bar icon. Menu-bar icon is **black** (`template=NO`) with inverted white asterisks per spec.
- **De-jumbled layout** — every row has a dedicated Y-range with 8-14px gaps (Status → Readers → Output/Hash → Truncate/Delay/Info → Card Data → Buttons → Toggles). No more overlapping `Card Data`/`Truncate` labels; `Delay` field + stepper now properly created and aligned.
- **Security & PII hardening** — removed absolute local volume paths from committed code, tightened bounds checks, and verified no secrets are committed.
- **Auto-type deferred** — filed as [Issue #1](https://github.com/Einnovoeg/CardPass/issues/1); clipboard `⌘V` remains the reliable path (needs no permission).

---

## What it does

- **Detects readers** via system `PCSC.framework` (`SCardListReaders` + `SCardGetStatusChange`) — e.g., Identive SCR33xx v2.0, YubiKey OTP+FIDO+CCID, generic CCID.
- **Reads any card** with a universal cascade (see `pcsc_reader.c:8-22`):
  1. `FF CA 00 00 00` UID (MIFARE / contactless / many hybrids)
  2. Known AIDs (`A0 00 00 03 10 10` etc.) → `GET RESPONSE` / `READ BINARY`
  3. Telecom paths: `MF 3F00`, `EF ICCID 2FE2`, `EF IMSI 6F07`, `GET DATA`, `GET CHALLENGE`, NDEF
  4. **ATR fallback** — guarantees stable hex even for YubiKeys/security keys that refuse all APDUs
- **Clipboard + optional auto-type**: copies instantly to `NSPasteboard` (⌘V to paste — needs no permission); auto-type after delay via `CGEvent` is optional and needs **Device Control / Accessibility** (see § Usage).
- **Smart encoding** (`main.m:385-555`): choose **Hex**, **Base62** (alphanumeric, ~30% shorter), **Base58** (no 0/O/I/l), **Base64**, **Base32**, **Base36**; optionally **Hash** (`SHA-256` / `SHA-512` / `SHA-1` / `MD5`) and **Truncate** to any length — so hex’s 2-chars-per-byte waste is eliminated.
- **UI**: Dock window (`520×470`, now pure black) + menu-bar status item (black icon, 5 white `*`) — both crash-free, ATR-change detection prevents YubiKey re-read loops.

---

## Install

### Requirements

- macOS 10.13+ (tested on macOS 15–26, arm64/x64)
- Xcode Command Line Tools: `xcode-select --install`
- A PC/SC reader plugged in (e.g., Identive SCR33xx). No extra drivers on macOS.
- For _optional_ auto-type: grant **System Settings → Privacy & Security → Accessibility** (on macOS 26 Tahoe: **Device Control and Data Access**) → CardPass, then **quit and reopen** CardPass. Clipboard `⌘V` needs no permission.

### Quick build (2.0)

```bash
git clone https://github.com/Einnovoeg/CardPass.git
cd CardPass

# Build the standalone binary (no pip needed)
clang -fobjc-arc \
  -framework Cocoa -framework CoreGraphics -framework ApplicationServices -framework PCSC \
  main.m pcsc_reader.c -o CardPass

# Make the app bundle
make app
# — creates CardPass.app with Resources/AppIcon.icns + Resources/MenuIcon.png/@2x
# — adhoc codesigns: codesign --force --deep --sign - CardPass.app

./CardPass                  # run binary
open CardPass.app           # or run bundle
# Copy to Applications:
cp -R CardPass.app ~/Applications/
# or:
make install
```

> Pre-built `CardPass-2.0.0-macOS-arm64.zip` is on the [Releases](https://github.com/Einnovoeg/CardPass/releases) page.

### No pip needed

The native app has **zero** pip dependencies. `requirements.txt` is only for the legacy `deprecated/` Python demos (pyscard/pyperclip). See `THIRD_PARTY_NOTICES.md`.

---

## Usage

1. Open **CardPass** — black window appears; menu-bar shows “Ready” with black chip + 5 `*`.
2. Insert any smart card / SIM / chip card.
3. Wait for **“Card Read”** — hex appears in white-on-black `Card Data (password)` field and is copied.
4. Choose **Output** `Hex` → `Base62` (recommended for passwords, alphanumeric only), `Base58` (human-friendly), `Base64`/32/36 — then optionally pick **Hash** (`SHA-256` 32 bytes → 43 Base62 chars, ideal for huge data) and **Truncate** (e.g., `20` or `24`) to fit strict length limits. Info label shows `34 raw → 32 hash → 20 chars`.
5. Adjust **Delay** (0.2–10 s, default 1.0 s, stepper 0.5 s) — how long to wait before typing so you can focus the target field.
6. For raw inspection, click **Advanced ▶** (or **View → Show Advanced Pane** ⌘⇧A / **Status Menu → Advanced → Show Raw Hex…**) — a pane slides out to the right showing **Raw Hex** (exact bytes, non-encoded) and **Encoded + Hashed (pre-truncate)**. Main `Card Data` field stays as final truncated output.
7. Click into any password field → press **⌘V** to paste (clipboard is instant). If Auto-type is on and Device Control permission is granted, CardPass also auto-types after the chosen delay (currently deferred — see Known Issues).
8. Buttons: **Copy to Clipboard**, **Type into Field**, **Clear**, **Refresh** — all respect encoding/hash/truncate/delay.
9. Toggles: **Auto-copy** / **Auto-type** (both on by default). Uncheck Auto-type if you only want clipboard — no permission needed.
10. Menu bar: **Show CardPass Window**, **Copy Hex**, **Type**, **Auto-type ON/OFF**, **Readers detail**, **Advanced** submenu, **Check Auto-Type Permission (Device Control)…**, **❤️ Buy Me a Coffee** (`https://buymeacoffee.com/einnovoeg`), **Quit**.

If auto-type does nothing, it’s expected: clipboard still works (⌘V). To enable auto-type, open **System Settings → Privacy & Security → Accessibility** (Tahoe: **Device Control and Data Access**) and enable CardPass, then **quit and reopen** CardPass. Use menu **Check Auto-Type Permission** to verify.

---

## Architecture

```
CardPass.app (Cocoa, ARC, pure black 520×470 + Advanced 360×470 slide-out)
 ├─ main.m — AppDelegate (NSWindow+NSStatusItem), GCD polling, clipboard/CGEvent,
 │           Base62/58/64/32/36 + SHA-256/512/SHA-1/MD5 + truncate + delay,
 │           Advanced pane (raw + pre-truncate, white-on-black), custom per-card text
 └─ pcsc_reader.h/c — PC/SC wrapper (thread-safe, system PCSC.framework only, bounded buffers)
deprecated/ — legacy Python (rumps/pyscard) kept locally, NOT shipped (gitignored)
Resources/ — AppIcon.icns (gold chip + 5* on black), icon.png, icon_256.png, MenuIcon.png/@2x (black chip + 5*)
```

Polling: 1.5 s timer → `pcsc_list_readers()` on background queue → ATR-change detection → `pcsc_read_card()` per new card → main-queue UI. Handles always-present YubiKeys by reading only when ATR changes.

---

## Build from source / Developer notes

- **Header:** `pcsc_reader.h` is the public API — installable to a centralized Library location (e.g., `~/Library/CardPass/`) for reuse by other local tools.
- **Comments:** both C and Obj-C sources are fully commented (file header, per-function security notes, UI layout map). See top of each file.
- **Security:** bounded `snprintf`/`strncpy`, NUL termination, per-call `SCARDCONTEXT`/`SCARDHANDLE`, `SCARD_LEAVE_CARD` disconnects, no card data persisted, no logging of hex beyond length. See `THIRD_PARTY_NOTICES.md`.
- **Icon:** `Resources/AppIcon.icns` generated from `icon.png` (`1024`) via `iconutil` (all sizes 16-1024). Menu icons `MenuIcon.png` (22) / `@2x` (44) are black chip + 5 white `*`, `template=NO`.
- **Code style:** Objective-C ARC, `NSAppearanceNameDarkAqua`, pure black backgrounds, white password text, gold `#D4AF37` chip.

---

## Password Encoding Tips

- **32–64 hex chars** (16–32 bytes): use **Base62** — alphanumeric only, ~30% shorter, never rejected.
- **Hundreds of chars** and you don’t need to decode: tick **Hash SHA-256 → Base62** → always 43 chars; then **Truncate** to 16–24 for strict fields. Hash is uniformly distributed, so truncation is safe.
- **Humans must read/type:** use **Base58** (no 0/O/I/l).

---

## Known Issues & Help Wanted — Please Help Fix What You Find!

**CardPass 2.0 is stable on the tested readers, but smart-card ecosystems are huge. We *need your help* — please file issues and PRs! Every reader name + ATR hex dump + `log stream --predicate 'process == "CardPass"'` snippet helps.**

> 🙏 **Implore:** If you use CardPass and find a bug, please open an issue or PR — even a one-line fix. Keep the Buy Me a Coffee link intact.

- **Auto-type / Type into Field — DEFERRED (#1)**: `CGEvent` typing + `AXValue` + `Cmd+V` + AppleScript paths are currently unreliable on Tahoe (Device Control vs Accessibility gating). See [Issue #1](https://github.com/Einnovoeg/CardPass/issues/1). **Clipboard `⌘V` is the reliable path today.** Help wanted: re-test `CGPreflightPostEventAccess`/`AXIsProcessTrusted` sequencing and `lastFrontmostApp` re-activation.
- **YubiKey / FIDO keys** always report “present” — CardPass returns ATR hex (stable per key) rather than error. If you need *no* data for security keys, open an issue (filter toggle wanted).
- **MIFARE Classic with custom keys** — UID reads via `FF CA`, but sector auth (`FF 86`) is not attempted. PRs to add key-file auth are welcome.
- **SIM PIN-locked cards** — `pcsc_read_card` does not send `VERIFY PIN`. Reading ICCID/IMSI may require PIN; we should surface a PIN prompt UI.
- **Long hex** (>512 bytes) truncated to 1024 hex chars by design (before encoding); file-backed reads could stream instead. Hash+truncate mitigates for passwords.
- **Encoding edge:** Base62/Base58 preserve leading zero bytes as `0`/`1`; please report leading-zero quirks.
- **Window reopen** via Dock click uses `applicationShouldHandleReopen`; Spotlight re-activation edge cases need testing.
- **AppleScript quit** — `terminate:` via menus works; `osascript -e 'tell application "CardPass" to quit'` not scriptable beyond `NSApplication` defaults — use menu/⌘Q.
- **Reader hot-plug** on sleep/wake not yet fully tested; please report `SCARD_E_SERVICE_STOPPED` handling.
- **Menu-bar visibility** — 2.0 menu icon is black with 5 white `*` (per spec) so it is *invisible* on dark menu bars except the stars; light menu bars show it correctly. Feedback welcome.

**Please file issues and PRs!** Keep `buymeacoffee.com/einnovoeg` link in README + app menus, and add a `CHANGELOG.md` entry for any fix.

---

## Support

If CardPass saves you typing, consider buying the author a coffee: **https://buymeacoffee.com/einnovoeg** ☕️❤️ — also in the app (menu bar → ❤️ Buy Me a Coffee). Thank you!

---

## License & Credits

- **Project license:** MIT — see `LICENSE` (Copyright © 2026 CardPass Contributors).
- **Third-party:** `PCSC.framework`, `Cocoa` etc. are Apple system frameworks (dynamic, no redistribution). Legacy Python packages (`pyscard` LGPL-2.1, `pyperclip`/`rumps`/`pyautogui` BSD, `py2app` MIT) are listed in `THIRD_PARTY_NOTICES.md` with full attribution as required by each license. No LGPL source-distribution is triggered by the native binary (pure Obj-C/C).
- **Icon:** custom gold chip (`#D4AF37`) + 5 white `*` on black — no external license.
- **Contributors:** yours could be here — PRs welcome! By contributing you agree your code is MIT-licensed.

---

## Troubleshooting

- **No readers?** `system_profiler SPUSBDataType | grep -i -A2 card` and Console → CardPass.
- **No data?** Try another card/SIM; some need PIN or custom AID — please file an issue with ATR.
- **Auto-type silent?** Expected if Device Control is off — use **⌘V**. To enable, grant **System Settings → Privacy & Security → Device Control and Data Access** (or Accessibility on older macOS) and **quit/reopen** CardPass. Check via menu **Check Auto-Type Permission**. If toggle is on and still “not trusted,” toggle off/on and reopen.
- **Crash?** Should be fixed in 2.0 — if you still hit SIGSEGV, capture crash log and open an issue.

---

*Built natively for macOS — no Python runtime, no Electron, just PC/SC + Cocoa. Support at [buymeacoffee.com/einnovoeg](https://buymeacoffee.com/einnovoeg).*
