# CardPass

Tap any smart card to fill password fields on macOS.

CardPass reads any PC/SC card and copies its data to the clipboard. Optionally, it can type the data into the frontmost field.

> Support the project: [buymeacoffee.com/einnovoeg](https://buymeacoffee.com/einnovoeg)

![macOS](https://img.shields.io/badge/macOS-10.13%2B-blue) ![License](https://img.shields.io/badge/license-MIT-green)

## Installation

Requires macOS 10.13+ and Xcode Command Line Tools.

```bash
xcode-select --install
```

**From Releases**

Download the latest zip from [Releases](https://github.com/Einnovoeg/CardPass/releases), unzip, and open `CardPass.app`.

**From Source**

```bash
git clone https://github.com/Einnovoeg/CardPass.git
cd CardPass
make app
open CardPass.app
```

## Usage

1. Open CardPass.
2. Insert a card. The password appears and is copied to the clipboard.
3. Paste with `⌘V`. If auto-type is enabled and permission is granted, CardPass will type after the configured delay.

Use the dropdown to select a reader when two are connected. Adjust `Output`, `Hash`, `Truncate`, and `Delay` as needed. Use `Advanced` to inspect raw data.

To enable auto-type, grant **System Settings → Privacy & Security → Accessibility** (Tahoe: **Device Control and Data Access**) and relaunch the app.

## Documentation

Full documentation is available in the [Wiki](https://github.com/Einnovoeg/CardPass/wiki).

- [Installation](https://github.com/Einnovoeg/CardPass/wiki/Installation)
- [Usage](https://github.com/Einnovoeg/CardPass/wiki/Usage)
- [Troubleshooting](https://github.com/Einnovoeg/CardPass/wiki/Troubleshooting)

## Troubleshooting

- **No readers?** Check `system_profiler SPUSBDataType | grep -i -A2 card`.
- **No data?** Some cards need a PIN. File an issue with the ATR.
- **Auto-type does nothing?** Use `⌘V`.

See the [Wiki](https://github.com/Einnovoeg/CardPass/wiki/Troubleshooting) for more.

## Contributing

Issues and pull requests are welcome. Please include the reader name and ATR when reporting a problem.

## License

MIT — see [LICENSE](LICENSE). Third-party notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Support

[buymeacoffee.com/einnovoeg](https://buymeacoffee.com/einnovoeg)
