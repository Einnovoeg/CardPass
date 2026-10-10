# CardPass

Tap any smart card to fill password fields on macOS.

CardPass reads any PC/SC card and copies its data to the clipboard. Optionally, it types the data into the frontmost field.

> Support the project: [buymeacoffee.com/einnovoeg](https://buymeacoffee.com/einnovoeg)

![macOS](https://img.shields.io/badge/macOS-10.13%2B-blue) ![License](https://img.shields.io/badge/license-MIT-green) ![Version](https://img.shields.io/badge/version-3.0.0-brightgreen)

## What It Does

CardPass is a native macOS app that turns any PC/SC smart card, chip card, or SIM into a hardware password token. It reads data from the card via a universal cascade of APDU strategies:

1. **UID** via `FF CA` (MIFARE, contactless cards)
2. **AID/SELECT** with `GET RESPONSE` / `READ BINARY` (banking cards, common applets)
3. **SIM/telecom** paths — MF 3F00, EF ICCID 2FE2, EF IMSI 6F07 (SIM cards)
4. **ATR fallback** — always produces stable hex from the card's Answer-to-Reset

The raw card data can be transformed through multiple encodings (Hex, Base62, Base58, Base64, Base32, Base36, Base64URL, ASCII85) and optional hashes (SHA-256, SHA-512, SHA-1, MD5). Output can be truncated to any length. Two or more readers can be connected at once, with a dropdown to select which reader handles the active card.

## Features

- Works with any PC/SC reader (Identive, YubiKey, Generic CCID, etc.)
- Universal card reading cascade — most cards work without configuration
- Multiple encodings and hashing options
- Supports multiple readers with per-reader selection
- Per-card custom text override
- Menu bar and Dock interface
- No Python runtime — pure Cocoa + PC/SC (C/Objective-C)

## Requirements

- macOS 10.13 or later
- Xcode Command Line Tools: `xcode-select --install`
- A PC/SC reader and a smart card

## Installation

**From Releases**

Download the latest disk image from [Releases](https://github.com/Einnovoeg/CardPass/releases), open it, and drag `CardPass.app` to your Applications folder.

**From Source**

```bash
git clone https://github.com/Einnovoeg/CardPass.git
cd CardPass
make app
open CardPass.app
```

No external dependencies. See `requirements.txt` for the legacy Python reference (not needed for the native app).

## Usage

1. Open CardPass. The window shows reader status.
2. Insert a card. The password appears and is copied to the clipboard.
3. Paste with `⌘V`. If auto-type is enabled and permission is granted, CardPass will type after the configured delay.

Use the dropdown to select a reader when two are connected. Adjust `Output`, `Hash`, `Length`, and `Delay` as needed. Use `Advanced` to inspect raw data.

### Permissions

Clipboard copy (`⌘V`) works without any special permission. For auto-type, grant **System Settings → Privacy & Security → Accessibility** (macOS Tahoe: **Device Control and Data Access**) and relaunch the app. Check via menu: **Check Auto-Type Permission**.

## What Doesn't Work / Known Issues

- **Auto-type into fields is unreliable** on macOS Tahoe. The `CGEvent` typing path and AppleScript fallback are inconsistent across apps, especially web browsers. **Clipboard `⌘V` is the reliable path** — it always works without configuration. This is tracked in [Issue #1](https://github.com/Einnovoeg/CardPass/issues/1).
- **SIM PIN support is not implemented.** Cards requiring a PIN will not produce data.
- **MIFARE Classic authentication** is not supported (no custom key files / `FF 86`).
- **Large data is truncated** to 512 bytes (1024 hex chars). Truncation + hashing mitigates this, but full streaming reads are not implemented.
- **Reader hot-plug during sleep/wake** is not fully tested with `SCardGetStatusChange`.
- **Auto-type may type into the wrong field** if CardPass's window is frontmost when it fires.

## Contributing — Help Wanted

**Please help fix these issues!** File issues and pull requests are welcome. When reporting a problem, include the reader name, card ATR, and log output:

```bash
log stream --predicate 'process == "CardPass"'
```

**Especially needed:**
- Re-testing the auto-type path (`CGPreflightPostEventAccess` / `AXIsProcessTrusted` sequencing, `CGEvent` vs `AXValue` vs `Cmd+V` for web fields)
- MIFARE Classic sector key support
- SIM PIN handling
- Notarization / Developer ID signing documentation

Keep the support link in all distributions and documentation.

## Documentation

The [Wiki](https://github.com/Einnovoeg/CardPass/wiki) has detailed installation and troubleshooting guides.

## License

MIT — see [LICENSE](LICENSE). Third-party notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

*Built natively for macOS — no Python runtime, no Electron. Uses only Apple system frameworks (Cocoa, PCSC, CoreGraphics, CommonCrypto).*
