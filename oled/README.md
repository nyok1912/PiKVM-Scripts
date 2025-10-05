# PiKVM OLED Setup

Script that prepares a PiKVM for the official OLED panel: it enables the I²C bus, installs the required tooling, and activates the kvmd OLED service units.

Source repository: <https://github.com/nyok1912/PiKVM-Scripts/tree/main/zerotier/oled>

## What the script handles for you

- Turns on the I²C overlays by adding `dtparam=i2c1=on` and `dtparam=i2c_arm=on` to `/boot/config.txt`.
- Ensures the `i2c-dev` kernel module autoloads via `/etc/modules-load.d/raspberrypi.conf`.
- Installs `i2c-tools` (skips the step when it is already present).
- Enables and starts `kvmd-oled`, `kvmd-oled-reboot`, and `kvmd-oled-shutdown`.
- Switches the root filesystem to read/write during the run and safely back to read-only at the end.
- Offers to run `pikvm-update` before doing anything else, mirroring the ZeroTier setup workflow.

## Ways to run it

### 1. Download first

```bash
curl -fsSL https://raw.githubusercontent.com/nyok1912/PiKVM-Scripts/main/zerotier/oled/setup.sh -o setup.sh
chmod +x setup.sh
sudo ./setup.sh
```

You will be asked whether to run `pikvm-update` and whether to reboot after the OLED services are configured.

### 2. Stream it

```bash
curl -fsSL https://raw.githubusercontent.com/nyok1912/PiKVM-Scripts/main/zerotier/oled/setup.sh | sudo bash
```

Same experience as the local download, without keeping the file on disk.

## Workflow summary

1. Confirm the PiKVM has network access (if you plan to run `pikvm-update`).
2. Execute the script using any of the methods above.
3. Approve or decline the optional update, then let the script enable I²C and OLED services.
4. Decide whether to reboot when prompted.
5. Enjoy the live status on the OLED panel.

## Handy commands afterwards

```bash
systemctl status kvmd-oled.service
journalctl -u kvmd-oled.service -f
i2cdetect -y 1
```
