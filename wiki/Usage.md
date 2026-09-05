# Usage

1. Open CardPass. The window shows the reader list and `Ready`.
2. Insert a card. The `Card Data (password)` field appears and is copied to the clipboard.
3. Paste with `⌘V` in any password field.

## Window

- **Readers** — list of connected readers and their status. When two readers are connected, use the dropdown to select `Auto (any reader)` or a specific reader.
- **Output, Hash, Truncate, Delay** — configure how the card data is transformed and how long to wait before auto-type.
- **Card Data (password)** — the final password. Always copied to the clipboard.
- **Buttons** — `Copy to Clipboard`, `Type into Field`, `Clear`, `Refresh`.
- **Auto-copy / Auto-type** — toggles. Auto-type needs Accessibility permission.
- **Advanced** — shows raw and encoded data.

## Menu Bar

The menu bar icon provides quick access to Show Window, Copy, Type, Auto-type, Readers, Advanced, Check Permission, and Support.

## Permissions

Clipboard (`⌘V`) works without permission. For auto-type, grant **System Settings → Privacy & Security → Accessibility** (macOS Tahoe: **Device Control and Data Access**) and relaunch the app.

Check the current permission via the menu: **Check Auto-Type Permission**.
