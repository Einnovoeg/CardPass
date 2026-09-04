# CardPass — Tap Any Smart Card to Fill Password Fields

**CardPass** is a native macOS app that turns *any* PC/SC smart card, chip card, or SIM into a hardware password token. Insert a card → CardPass reads hex and auto-types it into the active password field (like a keyboard wedge), while also copying it to the clipboard.

> 💛 Love CardPass? Support the work at **[buymeacoffee.com/einnovoeg](https://buymeacoffee.com/einnovoeg)** — every coffee keeps the reader running!

![macOS](https://img.shields.io/badge/macOS-10.13%2B-blue) ![License](https://img.shields.io/badge/license-MIT-green) ![Native](https://img.shields.io/badge/native-Cocoa%20%2F%20PCSC-lightgrey)

---

## What it does

- **Detects readers** via system `PCSC.framework` (`SCardListReaders` + `SCardGetStatusChange`) — e.g., Identive SCR33xx, YubiKey OTP+FIDO+CCID
- **Reads any card** with a universal cascade:
  1. `FF CA 00 00 00` UID (MIFARE / contactless / many hybrids)
  2. Known AIDs (`A0 00 00 03 10 10` etc.) → `GET RESPONSE` / `READ BINARY`
  3. Telecom paths: `MF 3F00`, `EF ICCID 2FE2`, `EF IMSI 6F07`, `GET DATA`, `GET CHALLENGE`, NDEF — great for SIMs
  4. **ATR fallback** — guarantees stable hex even for YubiKeys/security keys that refuse all APDUs
- **Clipboard + auto-type**: copies instantly; after 1s delay types into the frontmost field via `CGEvent` (requires Accessibility permission)
- **UI**: Dock window (520×440) + menu-bar status item — both stay crash-free

---

## Install

### Requirements

- macOS 10.13+ (tested on macOS 15–26, arm64)
- Xcode Command Line Tools: `xcode-select --install`
- A PC/SC reader plugged in (e.g., Identive SCR33xx). No extra drivers on macOS.
- For auto-type: grant **System Settings → Privacy & Security → Accessibility → CardPass**

### Quick build

```bash
git clone https://github.com/Einnovoeg/CardPass.git
cd CardPass

# Build the standalone binary
clang -fobjc-arc \
  -framework Cocoa -framework CoreGraphics -framework ApplicationServices -framework PCSC \
  main.m pcsc_reader.c -o CardPass

# Make the app bundle (optional)
mkdir -p CardPass.app/Contents/MacOS CardPass.app/Contents/Resources
cp CardPass CardPass.app/Contents/MacOS/
cp Resources/AppIcon.icns CardPass.app/Contents/Resources/
cp Info.plist CardPass.app/Contents/  # or the one already in repo
codesign --force --deep --sign - CardPass.app

./CardPass                  # run binary
open CardPass.app           # or run bundle
# Copy to Applications:
cp -R CardPass.app ~/Applications/
```

> The app also ships as a pre-built `CardPass-1.0.0-macOS-arm64.zip` on the [Releases](https://github.com/Einnovoeg/CardPass/releases) page.

### No pip needed

The native app has **zero** pip dependencies. `requirements.txt` is only for the legacy `deprecated/` Python demos (pyscard/pyperclip).

---

## Usage

1. Open **CardPass** — window appears; menu-bar shows “Ready”.
2. Insert any smart card / SIM / chip card.
3. Wait for **“Card Read”** — hex appears in window and is copied.
4. Click into any password field → after ~1s CardPass types the hex.
5. Window buttons: **Copy to Clipboard**, **Type into Field**, **Clear**, **Refresh**.
6. Toggles: **Auto-copy** / **Auto-type** (both on by default). Uncheck Auto-type if you only want clipboard.
7. Menu bar: **Show CardPass Window**, **Type**, **Auto-type ON/OFF**, **Readers detail**, **Check Accessibility**, **❤️ Buy Me a Coffee**, **Quit**.

If auto-type does nothing, open **System Settings → Privacy & Security → Accessibility** and enable CardPass, then try **Check Accessibility Permission** in the menu.

---

## Architecture

```
CardPass.app (Cocoa, ARC)
 ├─ main.m — AppDelegate, NSWindow + NSStatusItem, GCD polling, clipboard/CGEvent
 └─ pcsc_reader.h/c — PC/SC wrapper (thread-safe, system PCSC.framework only)
deprecated/ — legacy Python (rumps/pyscard) kept locally, not shipped
Resources/ — AppIcon.icns, icon.png
```

Polling: 1.5 s timer → `pcsc_list_readers()` on background queue → ATR-change detection → `pcsc_read_card()` per new card → main-queue UI. Handles always-present YubiKeys by reading only when ATR changes.

---

## Build from source / Developer notes

- **Header:** `pcsc_reader.h` is the public API — installable to `/Volumes/Mac Stick/Library/CardPass/` for reuse by other local tools.
- **Comments:** both C and Obj-C sources are fully commented (file, function, security notes). See top of each file.
- **Security:** bounded buffers, NUL checks, per-call `SCARDCONTEXT`/`SCARDHANDLE`, `SCARD_LEAVE_CARD`. See `THIRD_PARTY_NOTICES.md`.
- **Icon:** `Resources/AppIcon.icns` is generated from `icon_256.png` via `iconutil`.

---

## Known Issues & Help Wanted

CardPass 1.0 is stable on the tested readers, but smart-card ecosystems are huge. Please help fix what you find!

- **YubiKey / FIDO keys** always report “present” — CardPass now returns their ATR hex (stable per key) rather than error. If your flow needs *no* data for security keys, open an issue.
- **MIFARE Classic with custom keys** — UID reads via `FF CA`, but sector auth (`FF 86`) is not attempted. PRs to add key-file auth are welcome.
- **SIM PIN-locked cards** — `pcsc_read_card` does not send `VERIFY PIN`. Reading ICCID/IMSI may require PIN; we should surface a PIN prompt.
- **Long hex** (>512 bytes) is truncated to 1024 hex chars by design; file-backed reads could stream instead.
- **Window reopen** via Dock click uses `applicationShouldHandleReopen`; if hidden, use menu **Show CardPass Window**. Spotlight re-activation edge cases need testing.
- **AppleScript quit** — standard `terminate:` via menus works; `osascript -e 'tell application "CardPass" to quit'` is not scriptable beyond NSApplication defaults — use menu/⌘Q.
- **Reader hot-plug** on sleep/wake is not yet fully tested; please report.

**Please file issues and PRs!** Even a reader name + ATR hex dump + `log stream --predicate 'process == "CardPass"'` snippet helps. If you fix something, add a changelog entry and keep the Buy Me a Coffee link intact.

---

## Support

If CardPass saves you typing, consider buying the author a coffee: **https://buymeacoffee.com/einnovoeg** ☕️❤️ — link is also in the app (menu bar → ❤️ Buy Me a Coffee).

---

## License & Credits

- **Project license:** MIT — see `LICENSE` (Copyright © 2026 CardPass Contributors).
- **Third-party:** PCSC.framework, Cocoa etc. are Apple system frameworks. Legacy Python packages (pyscard LGPL-2.1, pyperclip/rumps/pyautogui BSD) are listed in `THIRD_PARTY_NOTICES.md` with full attribution as required.
- **Icon:** custom; no external license.
- **Contributors:** yours could be here — PRs welcome!

---

## Troubleshooting

- **No readers?** `system_profiler SPUSBDataType | grep -i -A2 card` and check Console → CardPass.
- **No data?** Try another card/SIM; some cards need PIN or custom AID — please file an issue with ATR.
- **Auto-type silent?** Grant Accessibility permission and retry **Check Accessibility Permission**.
- **Crash?** Should be fixed in 1.0 — if you still hit SIGSEGV, capture crash log and open an issue.

---

*Built natively for macOS — no Python runtime, no electron, just PC/SC + Cocoa.*
