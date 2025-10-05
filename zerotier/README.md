# ZeroTier for PiKVM

A small helper that installs and wires up ZeroTier on a PiKVM. When it finishes, your PiKVM is in the ZeroTier network, identity files live in persistent storage, and the root filesystem is back to read-only.

Source repository: <https://github.com/nyok1912/PiKVM-Scripts/tree/main/zerotier>

## Before you start

- PiKVM based on Arch Linux with `pacman`, `kvmd-pstrun`, and `systemd` available.
- Internet access plus a valid 16-character ZeroTier Network ID

## What the script handles for you

- Installs `zerotier-one` when it is missing and enables the service.
- Generates or reuses the ZeroTier identity and persists it through `kvmd-pstrun`.
- Creates the `networks.d` config files for the given network.
- Lets you enable DNS (`allowDNS=1`) automatically with `--force-dns` or manually via an interactive prompt.
- Mounts `/var/lib/zerotier-one` as `tmpfs`, drops a systemd override to hydrate the runtime directory on boot, and cleans it every start.
- Keeps a persistent `devicemap` so the interface name stays predictable (for example `zta1b2c3d4e`).
- Can enable IPv4 forwarding and NAT (`--ip-forward`) by adding iptables rules and saving them to `/etc/iptables/iptables.rules`.

## Flags you can use

| Flag | Purpose |
| --- | --- |
| `--network-id <ID>` | Target network (16 hex chars). Mandatory with `--unattended`. |
| `--force-dns` | Writes `allowDNS=1` without asking. |
| `--ip-forward` | Turns on `net.ipv4.ip_forward=1`, adds NAT for the detected uplink, and saves the rules. |
| `--unattended` | Runs with zero prompts. Requires `--network-id`. |
| `--no-wait-approval` | Skips the approval wait loop at the end. |
| `--help`, `-h` | Prints usage and exits. |

## Ways to run it

### 1. Download first (interactive)

```bash
curl -fsSL https://raw.githubusercontent.com/nyok1912/PiKVM-Scripts/main/zerotier/setup.sh -o setup.sh
chmod +x setup.sh
sudo ./setup.sh
```

You will be asked whether to run `pikvm-update`, which network to join, whether to enable DNS, whether to enable IPv4 forwarding/NAT, and if you want to wait for approval.

### 2. Download first (unattended)

```bash
sudo ./setup.sh \
  --network-id a1b2c3d4e5f60789 \
  --force-dns \
  --ip-forward \
  --no-wait-approval \
  --unattended
```

When `--unattended` is present the script skips every prompt, only refreshes the package database (no `pikvm-update`), and expects the network ID up front.

### 3. Stream it (interactive)

```bash
curl -fsSL https://raw.githubusercontent.com/nyok1912/PiKVM-Scripts/main/zerotier/setup.sh | sudo bash
```

Same experience as the local download, just without keeping the file on disk.

### 4. Stream it (unattended)

```bash
curl -fsSL https://raw.githubusercontent.com/nyok1912/PiKVM-Scripts/main/zerotier/setup.sh | sudo bash -s -- \
  --network-id=a1b2c3d4e5f60789 \
  --ip-forward \
  --force-dns \
  --no-wait-approval \
  --unattended
```

Mix and match the flags you need. If you forget `--network-id`, unattended mode stops immediately.

### 5. Run it again later

The script is idempotent. If identities or configs already exist they are reused, so you can rerun it with extra flags (for example `--ip-forward`) to apply new settings.

## Enabling IPv4 forwarding and NAT

![ZeroTier IP forwarding in my.zerotier.com panel](imgs/ZeroTier%20IP%20Forwarding.jpg)

Passing `--ip-forward` tells the script to prepare PiKVM as a tiny router between your ZeroTier network and the physical uplink:

- Enables `net.ipv4.ip_forward=1` immediately and persists it in `/etc/sysctl.d/99-zerotier.conf`.
- Detects the outbound (physical) interface and the ZeroTier interface, then adds:
  - `MASQUERADE` on the outbound interface in the `nat` table.
  - Symmetric `FORWARD` rules to allow traffic between ZeroTier and the uplink.
- Saves the firewall state to `/etc/iptables/iptables.rules` and enables the `iptables` service so the rules survive reboots.

After joining your network, approve the node in ZeroTier Central and publish routes there as described in the [ZeroTier routing guide](https://docs.zerotier.com/route-between-phys-and-virt/).

## Quick workflow

1. Confirm the PiKVM has Internet access and can reach ZeroTier.
2. Pick the execution style above that suits you.
3. Answer the prompts or supply flags for unattended mode.
4. Approve the member in ZeroTier Central if your network is private.
5. Use the CLI commands below to double-check the status.

## Handy commands afterwards

```bash
systemctl status zerotier-one.service
zerotier-cli listnetworks
journalctl -u zerotier-one.service -f
ip a show zt*
iptables -t nat -L -n
```

## Variant cheat sheet

| Scenario | Command | Notes |
| --- | --- | --- |
| Local, interactive | `sudo ./setup.sh` | Walks you through every question. |
| Streamed, interactive | `curl https://raw.githubusercontent.com/nyok1912/PiKVM-Scripts/main/zerotier/setup.sh \| sudo bash` | Same flow, no local file. |
| Local, unattended | `sudo ./setup.sh --network-id <ID> --unattended` | Provide any extra flags you want. |
| Streamed, unattended | `curl https://raw.githubusercontent.com/nyok1912/PiKVM-Scripts/main/zerotier/setup.sh \| sudo bash -s -- --network-id=<ID> --unattended` | Handy for remote automation. |
| Add NAT routing | Append `--ip-forward` | Enables forwarding and saves iptables rules. |
| Force DNS | Append `--force-dns` | Writes `allowDNS=1` immediately. |

## Credits

- Original script and upkeep: [nyok1912](https://github.com/nyok1912).
- Persistent storage and service override workflow inspired by [aelindeman's PiKVM ZeroTier guide](https://gist.github.com/aelindeman/a0a195494d63181642954ef0e99034d4).

## Sources

- [PiKVM Handbook – Persistent storage](https://docs.pikvm.org/pst/)
- [ZeroTier – Client Configuration](https://docs.zerotier.com/config/#configuration-files)
- [ZeroTier – Routing between physical and virtual networks](https://docs.zerotier.com/route-between-phys-and-virt/)
