# Sophos XGS Let's Encrypt

Automated Let's Encrypt SSL certificate issuance and renewal for Sophos XGS firewalls using [acme.sh](https://github.com/acmesh-official/acme.sh).

Sophos removed the built-in Let's Encrypt support that existed in the UTM product line. This project brings it back by running the entire renewal process directly on the XGS appliance -- no external host required.

Certificates are issued via HTTP-01 challenge and renewed daily through a background service that starts automatically on boot.

## Use Cases

- **VPN portal SSL:** Employees connect to `vpn.company.com` through the XGS web interface. A Let's Encrypt certificate eliminates browser security warnings without purchasing a commercial certificate.
- **Multiple services, single appliance:** OWA (Outlook Web Access), Exchange, VPN, and other services published through XGS can each have their own certificate defined in `config.csv`.
- **Unattended renewal:** After initial setup, the entire lifecycle is automatic -- boot-time startup, daily renewal checks, httpd reload. No manual intervention required.
- **Firmware upgrade recovery:** XGS firmware upgrades delete `/var/acme`. Re-running `setup.sh` restores everything; existing account registration and configuration are preserved.

## How It Works

The XGS runs Linux Kernel 4.14 with BusyBox and includes Python 3. Since port 80 is either used by the built-in httpd or dropped by Sophos iptables rules, the scripts use a NAT PREROUTING rule to temporarily redirect port 80 traffic to a Python HTTP server on port 8000 during ACME validation.

```
Boot --> S01lets --> renew.sh (infinite loop)
                        |
                        +-- Start Python HTTP server on :8000
                        +-- iptables NAT: redirect :80 --> :8000
                        +-- Run acme.sh (HTTP-01 challenge)
                        +-- Write cert to /conf/certificate/
                        +-- Cleanup (iptables, HTTP server)
                        +-- Reload httpd (SIGHUP)
                        +-- Sleep 24 hours, repeat
```

1. **setup.sh** validates the environment (root, network, required commands), downloads acme.sh, registers a Let's Encrypt account with email validation, and installs a boot service at `/etc/rc.d/S01lets`. All operations are logged to `/var/acme/setup.log`.
2. **S01lets** starts the renewal process automatically on each boot.
3. **renew.sh** runs in an infinite loop, processing each certificate defined in `config.csv` once per day. For each certificate it:
   - Starts a Python 3 HTTP server on port 8000 and waits for it to become ready
   - Redirects port 80 to 8000 via iptables NAT (with defensive stale-rule cleanup)
   - Runs acme.sh with HTTP-01 challenge
   - Writes the certificate to `/conf/certificate/<name>.pem` and key to `/conf/certificate/private/<name>.key`
   - Cleans up the iptables rule and HTTP server (guaranteed via signal traps)
   - Reloads httpd to apply the new certificate
   - Logs all operations with timestamps to `/var/acme/renew.log`

## Requirements

- Sophos XGS firewall with SSH access
- Internet connectivity on port 80 (for HTTP-01 challenge)

## Installation

1. Log in to your Sophos XGS via SSH and open the Advanced Shell (`5. Device Management` -> `3. Advanced Shell`).

2. Run the one-liner installer:

```sh
sh -c "$(curl https://raw.githubusercontent.com/KilimcininKorOglu/sophos-fw-letsencrypt/main/setup.sh)"
```

The setup script will:
1. Verify root privileges, required commands, and network connectivity.
2. Download acme.sh and project scripts to `/var/acme`.
3. Prompt for your Let's Encrypt account email address (validated before registration).
4. Install the boot service at `/etc/rc.d/S01lets`.

The installer is safe to re-run: existing `config.csv` and account registration are preserved.

## Configuration

Edit `/var/acme/config.csv` to define your certificates. The format is semicolon-delimited with no header row:

```
certificateName;domain1,domain2,domain3
```

| Field             | Description                                                                  |
|-------------------|------------------------------------------------------------------------------|
| `certificateName` | Must match the certificate name in the Sophos web interface (case-sensitive) |
| `domains`         | Comma-separated list of domain names (SANs)                                  |

Lines starting with `#` are treated as comments. Blank lines are ignored. Leading and trailing whitespace is trimmed automatically.

Example:

```
# Main web services
OWA;owa.example.com,exchange.example.com
vpn;vpn.example.com

# Disabled for now
# portal;portal.example.com
```

Certificates are written to `/conf/certificate/<name>.pem` with private keys at `/conf/certificate/private/<name>.key`.

## First Run

After configuring `config.csv`, run the renewal script manually for the first time:

```sh
/var/acme/renew.sh
```

**If the certificate already exists in the Sophos web interface:** You are done. The script will overwrite the existing certificate files and reload httpd.

**If this is a new certificate:** You need to download it from the appliance and upload it through the Sophos web interface under *Certificates*:

```sh
scp admin@<SOPHOS_IP>:/conf/certificate/OWA.pem ./
scp admin@<SOPHOS_IP>:/conf/certificate/private/OWA.key ./
```

Upload the `.pem` and `.key` files via the web interface. Subsequent renewals will update the files in place automatically.

## Firmware Upgrades

After upgrading the XGS firmware, the `/var/acme` directory and the init script at `/etc/rc.d/S01lets` may be removed. Re-run the setup script to restore the installation:

```sh
sh -c "$(curl https://raw.githubusercontent.com/KilimcininKorOglu/sophos-fw-letsencrypt/main/setup.sh)"
```

Your account registration and `config.csv` will be preserved if they still exist; otherwise, reconfigure them.

## Logging

All operations are logged with timestamps and severity levels to dedicated log files and stdout.

| Script     | Log File              |
|------------|-----------------------|
| `setup.sh` | `/var/acme/setup.log` |
| `renew.sh` | `/var/acme/renew.log` |

Log format:

```
[2026-03-16 14:30:00] [INFO] Certificate issued/renewed successfully: OWA
[2026-03-16 14:30:01] [ERROR] acme.sh failed for vpn (exit: 1)
```

Log levels: `INFO`, `WARN`, `ERROR`.

## Reliability Features

Both `setup.sh` and `renew.sh` share these reliability patterns:

- **Signal handling:** Graceful shutdown on SIGTERM/SIGINT/SIGHUP with guaranteed resource cleanup (mount states, iptables rules, HTTP server processes).
- **Pre-flight checks:** Validates the environment on startup (root privileges, required commands, network connectivity for setup; acme.sh, config.csv, certificate directories for renewal).
- **Mount state tracking:** Filesystem mount changes (`/var` exec/noexec, `/` rw/ro) are tracked and automatically restored on exit or signal, preventing the system from being left in an insecure state.
- **Idempotent operations:** Both scripts are safe to re-run after partial failures.

Additionally, `renew.sh` provides:

- **Lockfile protection:** Prevents multiple instances from running simultaneously using an atomic mkdir-based lock at `/var/acme/renew.lock`.
- **Stale rule cleanup:** Before adding an iptables NAT rule, any leftover rule from a previous crash is defensively removed.
- **HTTP server readiness check:** Waits for the Python HTTP server to become responsive before proceeding with the ACME challenge.

## Known Limitations

- **Certificate expiry in web interface:** The expiry date shown in the Sophos web interface is not updated after renewal. The actual certificate on disk is renewed correctly.
- **No HTTPS redirect during validation:** While the ACME challenge is in progress, HTTP requests on port 80 are served by the validation server instead of being redirected to HTTPS.
- **No log rotation:** Log files at `/var/acme/setup.log` and `/var/acme/renew.log` grow indefinitely. Monitor their size or truncate periodically.

## File Overview

| File         | Purpose                                                                      |
|--------------|------------------------------------------------------------------------------|
| `setup.sh`   | One-time installer: validates environment, downloads deps, registers account |
| `renew.sh`   | Main renewal loop: issues/renews certs, manages iptables and HTTP server     |
| `S01lets`    | Init script for `/etc/rc.d/` (boot-time startup)                             |
| `config.csv` | Certificate definitions (semicolon-delimited, supports comments)             |

## Disclaimer

Modifying the internals of your Sophos XGS firewall may void your warranty. The scripts manipulate iptables rules and remount filesystems. Review the code and test carefully before deploying in production.