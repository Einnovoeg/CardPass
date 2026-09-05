# Installation

## Requirements

- macOS 10.13 or later
- Xcode Command Line Tools
- A PC/SC reader

Install the tools:

```bash
xcode-select --install
```

## From Releases

1. Go to [Releases](https://github.com/Einnovoeg/CardPass/releases).
2. Download `CardPass-2.0.0-macOS-arm64.zip`.
3. Unzip and open `CardPass.app`.

## From Source

```bash
git clone https://github.com/Einnovoeg/CardPass.git
cd CardPass
make
./CardPass
```

To build the app bundle:

```bash
make app
open CardPass.app
```

No additional dependencies. See `requirements.txt` only for the legacy Python demos in `deprecated/`.
