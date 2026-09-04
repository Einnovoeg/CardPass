# Third-Party Notices — CardPass

CardPass is MIT-licensed (see `LICENSE`). It builds on system frameworks and,
for the legacy Python reference, a handful of open-source packages. Full
attribution is given here to satisfy each dependency's license.

## Native macOS app (active)

| Component | License | Author / Source | Notes |
|-----------|---------|-----------------|-------|
| **PCSC.framework** (`PCSC/winscard.h`) | Apple Proprietary (ships with macOS) | Apple Inc. | System smart-card service; used via `SCardEstablishContext` etc. No distribution needed; linked dynamically on macOS. |
| **Cocoa / AppKit / Foundation / CoreGraphics / ApplicationServices** | Apple Proprietary (ships with macOS) | Apple Inc. | UI, clipboard (`NSPasteboard`), accessibility (`AXIsProcessTrusted`), synthetic typing (`CGEvent`). |

No additional attribution is required at runtime for Apple frameworks.

## Legacy Python reference (deprecated/ — not required for the native app)

These were used only by `deprecated/CardMenuApp.py`, `card_autotyper.py`, `read_card.py`
and are **not** linked into the built `CardPass.app`. Listed for completeness.

| Package | License | Authors | Link |
|---------|---------|---------|------|
| **pyscard** (`smartcard`) 2.3.1 | **GNU LGPL-2.1** | Ludovic Rousseau et al. | https://github.com/LudovicRousseau/pyscard — `smartcard` Python bindings for PC/SC. LGPL-2.1 allows dynamic use; if you distribute a modified `pyscard` you must provide source under LGPL. |
| **pyperclip** 1.11.0 | **BSD-3-Clause** | Al Sweigart | https://github.com/asweigart/pyperclip — BSD permits use with retention of copyright notice. |
| **pyautogui** (legacy) | **BSD-3-Clause** | Al Sweigart | https://github.com/asweigart/pyautogui — used only in deprecated Python demo for auto-typing. |
| **rumps** (legacy) | **BSD-2-Clause** | Jake Dean | https://github.com/jaredks/rumps — menu-bar helper for legacy Python `CardMenuApp.py`. |
| **py2app** (legacy, `setup.py`) | **MIT** | Ronald Oussoren et al. | https://github.com/ronaldoussoren/py2app — used to bundle legacy Python app. |

### How we comply

- **This project** does not bundle or modify the above Python packages in its releases. `CardPass.app` is pure Objective-C / C and links only to Apple system frameworks, so no LGPL source-distribution obligation is triggered by the native binary.
- If you choose to run the deprecated Python demos, install them yourself via `pip` and honor each package's license (e.g., keep BSD notices, provide LGPL source on request if you redistribute a modified `pyscard`).
- All Apple framework usage is dynamic linking against the user's macOS — no redistribution.

## Icons

App icon derived from system SF Symbols / custom rendering. No external icon license encumbrance.

---

If you contributed code under MIT and want your name added here, open a PR. For questions about licensing, please file an issue.

Support the project: https://buymeacoffee.com/einnovoeg ❤️
