# Development

## Architecture

```
CardPass.app (Cocoa, ARC, 520×470 + Advanced 360×470)
 ├─ main.m — AppDelegate, window, menu bar, polling, encoding
 └─ pcsc_reader.h/c — PC/SC wrapper (thread-safe, system PCSC.framework)
```

Polling: 1.5 s → `pcsc_list_readers()` in background → `pcsc_read_card()` on ATR change → main-queue UI.

## Building

```bash
git clone https://github.com/Einnovoeg/CardPass.git
cd CardPass
make
make app
```

## Code Style

- Objective-C with ARC
- Bounded buffers, `snprintf`/`strncpy` with NUL checks
- Per-call `SCARDCONTEXT`/`SCARDHANDLE`, `SCARD_LEAVE_CARD`

## Contributing

Issues and pull requests are welcome. Keep the `buymeacoffee.com/einnovoeg` link.

## License

MIT — see `LICENSE`. Third-party notices in `THIRD_PARTY_NOTICES.md`.
