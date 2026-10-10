# Features

- **Any card** — reads PC/SC cards via a universal cascade (UID, AID, SIM, ATR fallback).
- **Any reader** — supports one or more readers; select a specific reader when two are connected.
- **Clipboard and auto-type** — copies instantly, optionally types after a delay.
- **Encoding and hashing** — Hex (upper/lower), Base62, Base58, Base64 (standard/URL-safe), Base32, Base36, ASCII85; SHA-224/256/384/512, SHA-1, MD5; truncate to any length.
- **Password-style output** — repeatable pseudo-random alphanumeric or printable-symbol strings, with uppercase/lowercase/digit (and symbol) classes included when the output length permits. Same card and settings produce the same string; this is not a fresh random generator or password KDF.
- **Per-reader handling** — polls every 1.5 s with ATR-change detection.
- **Custom text per card** — store a custom string for a specific card.
