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
- **Clipboard + auto-type**: copies instantly to clipboard (⌘V to paste — needs no permission); auto-type after 1 s via `CGEvent` is optional and needs Device Control / Accessibility
- **Smart encoding**: choose **Hex (Base16)**, **Base62** (alphanumeric, ~30% shorter, never rejected), **Base58** (no ambiguous 0/O/I/l, for humans), **Base64** (+/ with padding); optionally **Hash with SHA-256** (32 bytes → always 43 Base62 chars, truncatable to 16-24) and **Truncate** to any length — so hex’s 2-chars-per-byte is eliminated
- **UI**: Dock window (520×500) + menu-bar status item — both stay crash-free

---

## Install

### Requirements

- macOS 10.13+ (tested on macOS 15–26, arm64)
- Xcode Command Line Tools: `xcode-select --install`
- A PC/SC reader plugged in (e.g., Identive SCR33xx). No extra drivers on macOS.
- For auto-type (optional): grant **System Settings → Privacy & Security → Accessibility** (on Tahoe: **Device Control and Data Access**) → CardPass, then quit and reopen CardPass. Clipboard paste via ⌘V needs no permission.

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
4. Choose output encoding in the window: **Output:** `Hex` → `Base62` (recommended for passwords, alphanumeric only), `Base58` (human-friendly), `Base64` — then optionally tick **Hash SHA-256** (condenses any card to 32 bytes → 43 Base62 chars, ideal for huge data) and set **Truncate** (e.g. 24 or 16) to fit strict password length limits. Info label shows `23 raw → 31 Base62 → 24`.
5. Adjust **Delay** (0.2-10 s, default 1.0 s) next to Auto-type — how long to wait before typing, so you can click the target field.
6. For raw inspection, click **Advanced ▶** (or **View → Show Advanced Pane** / **Status Menu → Advanced → Show Raw Hex…**) — a pane slides out to the right showing **Raw Hex** (exact bytes, non-encoded) and **Encoded + Hashed (pre-truncate)**. Main **Card Data (password)** field (left) stays as final truncated output, unchanged per spec. Raw is also accessible via **View → Show Raw Hex…** sheet.
7. Click into any password field → press **⌘V** to paste (clipboard is instant). If Auto-type is on and Device Control permission is granted, CardPass also auto-types after the chosen delay.
8. Window buttons: **Copy to Clipboard**, **Type into Field**, **Clear**, **Refresh** — all respect the chosen encoding/hash/truncate/delay.
9. Toggles: **Auto-copy** / **Auto-type** (both on by default). Uncheck **Auto-type** if you only want clipboard — no permission needed.
10. Menu bar: **Show CardPass Window**, **Type**, **Auto-type ON/OFF**, **Readers detail**, **Advanced** (Show Advanced Pane, Raw Hex…), **Check Auto-Type Permission (Device Control)**…, **❤️ Buy Me a Coffee**, **Quit**.

If auto-type does nothing, it’s expected: clipboard still works (⌘V). To enable auto-type, open **System Settings → Privacy & Security → Accessibility** (Tahoe: **Device Control and Data Access**) and enable CardPass, then **quit and reopen CardPass**. Use menu **Check Auto-Type Permission** to verify.

---

## Architecture

```
CardPass.app (Cocoa, ARC, DarkAqua 520×470 + 300 slide-out)
 ├─ main.m — AppDelegate, NSWindow + NSStatusItem, GCD polling, clipboard/CGEvent, Base62/58/64 + SHA-256 + truncate, delay (0.2-10 s), Advanced pane (raw + pre-truncate, slide-out)
 └─ pcsc_reader.h/c — PC/SC wrapper (thread-safe, system PCSC.framework only)
deprecated/ — legacy Python (rumps/pyscard) kept locally, not shipped
Resources/ — AppIcon.icns (card + stars, dark), icon.png
```

Polling: 1.5 s timer → `pcsc_list_readers()` on background queue → ATR-change detection → `pcsc_read_card()` per new card → main-queue UI. Handles always-present YubiKeys by reading only when ATR changes.

---

## Build from source / Developer notes

- **Header:** `pcsc_reader.h` is the public API — installable to `/Volumes/Mac Stick/Library/CardPass/` for reuse by other local tools.
- **Comments:** both C and Obj-C sources are fully commented (file, function, security notes). See top of each file.
- **Security:** bounded buffers, NUL checks, per-call `SCARDCONTEXT`/`SCARDHANDLE`, `SCARD_LEAVE_CARD`. See `THIRD_PARTY_NOTICES.md`.
- **Icon:** `Resources/AppIcon.icns` is generated from `icon_256.png` via `iconutil`.

---

## Password Encoding Tips

- **If your hex is 32-64 chars** (e.g. 16-32 bytes): use **Base62** — alphanumeric only, ~30% shorter than hex, never rejected.
- **If hex is hundreds of chars** and you don’t need to decode: tick **Hash SHA-256 → Base62** → always 43 chars; then **Truncate** to 16-24 for strict fields. Hash is uniformly distributed, so truncation is cryptographically safe.
- **If humans must read/type:** use **Base58** (no 0/O/I/l).

## Known Issues & Help Wanted

CardPass 1.0 is stable on the tested readers, but smart-card ecosystems are huge. Please help fix what you find!

- **YubiKey / FIDO keys** always report “present” — CardPass now returns their ATR hex (stable per key) rather than error. If your flow needs *no* data for security keys, open an issue.
- **MIFARE Classic with custom keys** — UID reads via `FF CA`, but sector auth (`FF 86`) is not attempted. PRs to add key-file auth are welcome.
- **SIM PIN-locked cards** — `pcsc_read_card` does not send `VERIFY PIN`. Reading ICCID/IMSI may require PIN; we should surface a PIN prompt.
- **Long hex** (>512 bytes) is truncated to 1024 hex chars by design (before encoding); file-backed reads could stream instead. Hash+truncate already mitigates this for passwords.
- **Encoding edge:** Base62/Base58 preserve leading zero bytes as `0`/`1`; please report if your reader’s data has unusual leading zeros.
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
- **Auto-type silent?** This is now expected if Device Control is off — use **⌘V** to paste. To enable auto-type, grant **System Settings → Privacy & Security → Device Control and Data Access** (or Accessibility on older macOS) and **quit/reopen** CardPass. Check via menu **Check Auto-Type Permission**. If toggle is already on and it still shows not trusted, toggle off/on and reopen.
- **Crash?** Should be fixed in 1.0 — if you still hit SIGSEGV, capture crash log and open an issue.

---

*Built natively for macOS — no Python runtime, no electron, just PC/SC + Cocoa.*
