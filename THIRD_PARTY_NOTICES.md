# Third-Party Notices — CardPass 2.0

CardPass is **MIT-licensed** (see `LICENSE`, Copyright © 2026 CardPass Contributors). It builds on Apple system frameworks and, for the legacy Python reference only, a handful of open-source packages. This file provides **full attribution** as required by each dependency's license.

> **Support the project:** https://buymeacoffee.com/einnovoeg ❤️ — Buy Me a Coffee link must be preserved in docs & UI per maintainer instructions.

## Native macOS app (active, ships in releases)

The released `CardPass.app` (2.0) is **pure Objective-C/C** and links **only** to Apple system frameworks. No third-party binary code is bundled.

| Component | License | Author / Source | How we use it | Distribution note |
|-----------|---------|-----------------|---------------|-------------------|
| **PCSC.framework** (`PCSC/winscard.h`, `wintypes.h`) | Apple Proprietary — ships with macOS | Apple Inc. | Smart-card service via `SCardEstablishContext` / `SCardConnect` / `SCardTransmit` / `SCardStatus` / `SCardGetStatusChange`. Used in `pcsc_reader.h/c`. | Dynamic link against the user's macOS; no redistribution, no extra attribution required beyond this notice. |
| **Cocoa / AppKit / Foundation** | Apple Proprietary — ships with macOS | Apple Inc. | UI (`NSWindow`, `NSStatusItem`, `NSTextView`, `NSPasteboard`), app lifecycle. | Dynamic, system-provided. |
| **CoreGraphics / ApplicationServices** | Apple Proprietary — ships with macOS | Apple Inc. | Synthetic typing (`CGEventCreateKeyboardEvent`, `CGEventPost`), `AXIsProcessTrustedWithOptions`, `CGPreflightPostEventAccess` / `CGRequestPostEventAccess` (Tahoe). | Dynamic, system-provided. |
| **CommonCrypto** (`CommonDigest.h`) | Apple Proprietary — ships with macOS | Apple Inc. | `CC_SHA256` / `CC_SHA512` / `CC_SHA1` / `CC_MD5` for hash-before-encode. | Part of system `libSystem`; dynamic. |

**Result:** No additional attribution or source-distribution is required at runtime for Apple frameworks beyond this notice. The app is self-contained and does not redistribute Apple binaries.

## Custom assets (CardPass authors)

- **App & menu icons** (`Resources/AppIcon.icns`, `icon.png`/`icon_256.png`, `MenuIcon.png`/`@2x`): **Custom** — gold chip `#D4AF37` + 5 white asterisk `*` (`*****`) on pure black, drawn programmatically via Python PIL in this repo (see commit history). No external icon set is redistributed; no third-party icon license applies. If you fork, you may replace them freely under MIT.
- **Source code** (`main.m`, `pcsc_reader.h/c`, `Makefile`, `Info.plist`): © 2026 CardPass Contributors, MIT (see `LICENSE`).

## Legacy Python reference (deprecated/ — NOT shipped, not required)

These packages were used **only** by the deprecated Python demos under `deprecated/` (`CardMenuApp.py`, `card_autotyper.py`, `read_card.py`, `setup.py`). They are **not linked** into the native `CardPass.app` and are **not included** in GitHub releases. Listed here for completeness and to satisfy their licenses if you choose to run the legacy code.

| Package | Version | License | Authors / Copyright | Link & compliance note |
|---------|---------|---------|---------------------|------------------------|
| **pyscard** (`smartcard`) | 2.3.1 | **GNU LGPL-2.1** | Ludovic Rousseau, Jean-Daniel Aussel, and contributors — Copyright © 1996-2024 Ludovic Rousseau et al. | https://github.com/LudovicRousseau/pyscard — LGPL-2.1 requires that if you distribute a *modified* `pyscard`, you provide its source under LGPL. **CardPass does not bundle or modify `pyscard`**; the native app is pure C/ObjC. If you `pip install pyscard` yourself, honor LGPL (provide source on request for modifications). |
| **pyperclip** | 1.11.0 | **BSD-3-Clause** | Copyright (c) 2014 Al Sweigart | https://github.com/asweigart/pyperclip — Redistribution must retain copyright notice + disclaimer + no-endorsement clause. **Not bundled**; install via `pip` if needed. |
| **pyautogui** (legacy) | 0.9.54 | **BSD-3-Clause** | Copyright (c) 2014 Al Sweigart | https://github.com/asweigart/pyautogui — Same BSD-3 terms. Used only in `card_autotyper.py` for `typewrite`. |
| **rumps** | 0.4.0 | **BSD-2-Clause** | Copyright (c) 2011 Jake Dean / Jared Suttor | https://github.com/jaredks/rumps — Redistribution must retain copyright + disclaimer. Used only in legacy `CardMenuApp.py`. |
| **py2app** (legacy `setup.py`) | 0.28.6 | **MIT** | Copyright (c) 2004-2021 Ronald Oussoren, Bill Bumgarner, Jack Jansen, etc. | https://github.com/ronaldoussoren/py2app — MIT; keep copyright+permission notice. Used only to bundle the old Python app. |

### How we comply for the legacy demos

- **No bundling:** GitHub releases for the native app contain **zero** Python packages. `CardPass.app` links only to Apple frameworks, so **no LGPL source-distribution obligation is triggered**.
- **If you run `deprecated/` yourself:** `pip install -r requirements.txt` fetches the packages from PyPI; you are responsible for honoring each license (retain BSD notices, provide LGPL source for modified `pyscard`, etc.).
- **Notices preserved:** This file retains all required copyright lines and license names as required by BSD/LGPL/MIT.

## Full license texts (where required)

- **MIT (project + py2app):** See `LICENSE` in repo root. Permission to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software under MIT is granted with copyright notice retention.
- **BSD-2/3-Clause:** Require retention of copyright notice, list of conditions, and disclaimer. Full texts are available at the links above and in each package's `LICENSE` file.
- **LGPL-2.1 (pyscard):** Requires providing source for the LGPL-covered library if you distribute a modified version. Full text: https://www.gnu.org/licenses/lgpl-2.1.html
- **Apple frameworks:** Proprietary, proprietary, part of macOS; user must have a valid macOS license. No redistribution.

---

**Questions?** File an issue. If you contributed code under MIT and want your name listed here, open a PR.

Support the project: https://buymeacoffee.com/einnovoeg ❤️
