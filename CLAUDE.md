# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ChameleonUltra is a dual-frequency RFID emulation/reader platform built on the nRF52840 MCU. It has two main components: ARM embedded firmware (C) and a Python CLI client. Two hardware variants exist: **Ultra** (full reader+emulator) and **Lite** (emulator only).

## Build Commands

### Firmware (Nix — recommended)

```bash
nix develop                        # Enter devShell (ARM GCC, nrfutil, etc.)
nix build                          # Build firmware, outputs DFU zips to ./result/
nix run .#flash                    # Flash via DFU over USB (enters DFU mode automatically)
```

### Firmware (Make — inside devShell or with manual toolchain)

```bash
cd firmware
make -C bootloader -j              # Build bootloader only
make -C application -j             # Build application only
./build.sh                         # Full build: bootloader + app + DFU zip packaging
```

Output goes to `firmware/objects/` — `.hex` files and DFU zips (`ultra-dfu-app.zip`, `ultra-dfu-full.zip`).

Set `CURRENT_DEVICE_TYPE=lite` to build for the Lite variant (default is `ultra`).

### Firmware (Docker)

```bash
cd firmware
docker compose run ultra           # Build for Ultra
docker compose run lite            # Build for Lite
```

### Python CLI

```bash
cd software
uv sync --dev                      # Install dependencies
uv run ruff check                  # Lint
uv run ruff format --check         # Format check
uv run pyrefly check               # Type check
python script/chameleon_cli_main.py  # Run CLI
```

### C Crypto Libraries (used by CLI for key recovery attacks)

```bash
cd software/src
cmake -B build && cmake --build build
```

Binaries are placed in `software/script/bin/` for the CLI to invoke.

### Tests

```bash
cd software
python -m pytest script/tests/     # Requires a connected device for integration tests
```

## Architecture

### Firmware (`firmware/`)

The firmware runs on an nRF52840 with the Nordic SoftDevice S140 BLE stack.

**Application** (`firmware/application/src/`):
- `app_main.c` — Entry point, initialization, main event loop, button/LED/power management
- `app_cmd.c` — Command dispatcher. Uses `cmd_data_map_t` structs mapping command IDs to before/process/after callback triplets
- `ble_main.c` — BLE stack: Nordic UART Service (NUS) for data transport, Battery Service, LESC pairing
- `usb_main.c` — USB CDC transport (same frame protocol as BLE)
- `rfid_main.c` — Mode switching between TAG (emulation) and READER modes. Reconfigures antennas/peripherals
- `settings.c` — Persistent config via Nordic FDS (Flash Data Storage)

**RFID subsystem** (`firmware/application/src/rfid/`):
- `nfctag/hf/` — HF emulation: ISO14443-A base (`nfc_14a.c`), MIFARE Classic (`nfc_mf1.c`), NTAG/MF0 (`nfc_mf0_ntag.c`)
- `nfctag/lf/` — LF emulation: GPIO-based carrier modulation for EM410X, HID Prox, Viking, IOProx
- `reader/hf/` — HF reader via SPI-connected RC522 (`rc522.c`), plus attack toolbox (`mf1_toolbox.c` — Darkside, Nested, HardNested)
- `reader/lf/` — LF reader via ADC sampling + FSK/Manchester demodulation
- `nfctag/tag_emulation.c` — 8-slot tag management, tag type registration, load/save callbacks
- `nfctag/tag_persistence.c` — Flash persistence for slot data

**Bootloader** (`firmware/bootloader/`): Nordic Secure DFU bootloader. Entered via `GPREGRET` register flag (`0xB1`).

**Common** (`firmware/common/`): Hardware abstraction — GPIO mapping, device type detection (Ultra vs Lite), LED/button control.

### Communication Protocol

Defined in `firmware/application/src/utils/netdata.h`. Variable-length frames:

```
SOF(1) | LRC1(1) | CMD(2) | STATUS(2) | LEN(2) | LRC2(1) | DATA(n) | LRC3(1)
0x11     checksum   u16BE    u16BE       u16BE    checksum   bytes     checksum
```

Command ID ranges (`data_cmd.h`):
- **1000-1999** — Device management (version, slots, settings, BLE, bootloader)
- **2000-2999** — HF reader (14443-A scan, MIFARE auth/read/write, attacks)
- **3000-3999** — LF reader (EM410X, HID, Viking, IOProx scan/write)
- **4000-4999** — HF emulator config (block data, anti-collision, detection logging, write modes)
- **5000-5999** — LF emulator config (set/get emulated IDs)

### Python CLI (`software/`)

- `script/chameleon_cli_main.py` — Interactive CLI entry point (prompt-toolkit)
- `script/chameleon_com.py` — Serial/TCP transport with threading (receive, transmit, timeout)
- `script/chameleon_cmd.py` — Command implementations wrapping the protocol
- `script/chameleon_enum.py` — Enums mirroring firmware constants (commands, statuses, tag types)
- `script/chameleon_cli_unit.py` — CLI command tree and handlers (largest file, ~286KB)
- `src/` — C crypto libraries (crapto1, mfkey, nested/darkside/hardnested attacks) built via CMake

## Conventions

- **Package manager:** UV is required for Python dependency changes (update `pyproject.toml` + `uv.lock`)
- **Type checking:** pyrefly (not mypy). CI runs `pyrefly check` on PRs touching `software/`
- **Formatting:** ruff for Python. `.editorconfig` specifies 4-space indent for C/H/PY files
- **Commits:** Conventional commits recommended. Atomic PRs preferred
- **Firmware versioning:** Git tags (semver). Nix flake overrides version via `makeFlags` since sandbox lacks `.git`
- **Command IDs:** Must stay synchronized between `firmware/application/src/data_cmd.h` and `software/script/chameleon_enum.py`
