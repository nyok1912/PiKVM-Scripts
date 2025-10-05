# PiKVM Automation Scripts

This repository collects utility scripts for PiKVM. Each component lives in its own folder with a dedicated helper script and documentation. Use this top-level README as a quick index; drill into each subdirectory for the detailed guide and usage examples.

## Repository layout

| Folder | Purpose | Entry point |
| --- | --- | --- |
| `zerotier/` | Automates ZeroTier installation, persistent identity setup, optional DNS/NAT handling, and provides an English README plus troubleshooting tips. | [`zerotier/setup.sh`](zerotier/setup.sh) |
| `oled/` | Prepares the PiKVM OLED panel by enabling I²C, installing `i2c-tools`, and activating the kvmd OLED services. | [`oled/setup-oled.sh`](oled/setup-oled.sh) |

> Each folder contains its own `README.md` with full instructions, flags (when relevant), example invocations, and post-install checks.

## Getting started

1. Pick the feature you want to enable (for example, ZeroTier connectivity or the OLED display).
2. Open the corresponding subdirectory and read the README.
3. Run the helper script from your PiKVM as root, following the options described there.

All scripts are written for the Arch-based PiKVM environment and follow the same conventions:

- Flip the filesystem to read/write while applying changes and restore read-only afterwards (when `rw`/`ro` helpers exist).
- Offer optional system updates via `pikvm-update` before making adjustments.
- Provide clear summaries and next steps at the end of each run.

## Roadmap

More automation helpers will be added over time—expect additional folders to appear for features such as other VPN integration or hardware add-ons.

If you have suggestions or contributions, feel free to open issues or PRs in the main repository: <https://github.com/nyok1912/PiKVM-Scripts>.
