# Changelog — CardPass

All notable changes are documented here.

## [3.0.0] — 2026-10-09

### Added
- **New encoding formats**: Base64 URL-safe, ASCII85, Pseudo-random alphanumeric, and Pseudo-random + keyboard symbols — configurable via Encoding dropdown.
- **New hash algorithms**: SHA-224 and SHA-384 — now available alongside SHA-1, SHA-256, SHA-512, and MD5 in the Hash dropdown.
- **Multi-reader support**: Dropdown appears when two or more readers are connected; options include `Auto (any reader)` and per-reader selection; selection persists via `NSUserDefaults` `CPSelectedReader` and is respected by `pollInBackground`.
- **Configurable auto-type delay**: 0.2–10 second delay adjustable via stepper on the main window; persisted to `NSUserDefaults` `CPAutoTypeDelay`.
- **Per-reader data caching**: `rawDataByReader`, `hexByReader`, `lastAtrByReader` stores ensure the Card Data and Advanced pane update immediately when switching readers.
- **Enhanced ATR fallback**: `get_atr_via_status()` now uses 500ms `SCardGetStatusChange` timeout for slower contact readers (Generic USB2.0-CRW, Omnikey, Feitian) and works without an active SCardConnect handle.
- **Robust SCardConnect**: Tries SHARED → EXCLUSIVE → DIRECT with protocol fallbacks (T0|T1 → T0 → T1 → RAW); handles `SCARD_W_RESET_CARD` / `0x80100066` on readers that reject SHARED.
- **Hot-plug reader race fix**: `pcsc_list_readers()` handles `SCARD_E_INSUFFICIENT_BUFFER` during hot-plug with retry and larger buffer (`+2` safety, 8192 limit), and handles `SCARD_E_NO_SERVICE`/`SCARD_E_SERVICE_STOPPED` with brief retry.
- **Reader selection syncs UI**: `readerSelectionChanged:` immediately shows cached data for the newly selected reader or triggers a fresh `pollReaders` + clears `lastAtrByReader` to force re-read; `updateTransformedDisplay` ensures `Card Data (password)` and Advanced views reflect the chosen reader's card.
- **Window stay-visible fix**: Auto-type and manual "Type into Field" no longer hide the main/advanced windows via `orderOut:` — the window stays visible in background and just activates the target app.

### Fixed
- Layout issues where text could overlap — `setupWindow` rewritten with clean Y-map and 8–14px gaps per row.
- Support for different PC/SC readers, including readers that require different sharing modes and protocols; added fallback via ATR ensures a card still produces data.
- Cases where two readers could show "No readers" — `SCardListReaders` now handles `SCARD_E_INSUFFICIENT_BUFFER` race during hot-plug.
- Window moving to the background after a card is read with two readers connected — window now stays visible.
- Reader selection not updating the displayed card data and Advanced pane when switching readers — per-reader caches and `readerSelectionChanged:` ensure immediate sync.

### Changed
- Documentation updated to reflect new encoding/hash options and multi-reader workflow.
- Build configuration: `Makefile` copies all Resources into the app bundle automatically.
- Reader dropdown now hidden when only a single reader is connected (keeps UI clean per spec).
- Encoding info label updated to 9pt, 0.65 gray, widened to 225pt to avoid clipping.
- Info.plist `CFBundleShortVersionString` updated to `3.0.0`; `CFBundleVersion` to `7`.

## [1.0.1] — 2026-09-03

### Added
- Customizable auto-type delay
- Advanced pane

### Fixed
- Device Control permission handling on macOS Tahoe

## [1.0.0] — 2026-09-03

### Added
- Native macOS app with menu bar and Dock support
- Universal card reading
- Clipboard and auto-type support
- Password encoding and hashing

---