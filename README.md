# linux-bootstrap

Reusable bootstrap scripts and setup notes for Debian/Ubuntu systems.

A personal collection of small, idempotent shell scripts — tailored to my own
setups, but written generically enough to be useful elsewhere.

## Layout

```
.
├── scripts/    # maintenance and helper scripts (run repeatedly)
├── bootstrap/  # one-shot setup scripts for fresh systems
└── templates/  # config file templates
```

## Scripts

General-purpose scripts intended for repeated use.

| Script      | Purpose                                     |
| ----------- | ------------------------------------------- |
| `sysupdate` | Update apt packages and clean up afterwards |

## Bootstrap

One-shot scripts for setting up fresh Debian/Ubuntu installations.

| Setup                | Purpose                                                                                                                                     |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `debian-host/`       | Provision a freshly installed Debian 13 host: hostname, network, SSH, APT sources, default profile, sysupdate timer, optional data disk(s) |
| `github-deploy-key/` | Generate an SSH deploy key for root and wire up `/root/.ssh/config`                                                                         |
| `sysupdate-timer/`   | Install `scripts/sysupdate` and schedule it via systemd timer                                                                               |

## Templates

Configuration file templates.

| Template           | Used by                  |
| ------------------ | ------------------------ |
| `default-profile/` | `bootstrap/debian-host/` |

## Usage

Two patterns depending on what you want from the repo.

### Per-user (manual scripts)

```sh
git clone https://github.com/ww3d/linux-bootstrap-public.git ~/linux-bootstrap
ln -s ~/linux-bootstrap/scripts/<name> ~/.local/bin/<name>
```

For system-wide availability of an individual script:

```sh
sudo ln -s ~/linux-bootstrap/scripts/<name> /usr/local/bin/<name>
```

### System-wide (bootstrap setups)

```sh
sudo git clone https://github.com/ww3d/linux-bootstrap-public.git /opt/linux-bootstrap
sudo /opt/linux-bootstrap/bootstrap/<setup>/bootstrap.sh
```

To pick up updates later:

```sh
cd /opt/linux-bootstrap
sudo git pull
sudo bootstrap/<setup>/bootstrap.sh
```

The bootstrap scripts are idempotent — re-run after any `git pull`.

## Conventions

- `#!/usr/bin/env bash` and `set -euo pipefail` where appropriate.
- Executable scripts have no file extension (called as commands).
- Each subfolder contains a short README describing its contents.
- Comments in code are in English.

## Target systems

Primarily tested on Debian 11/12/13. Most scripts should work on any reasonably
recent Debian-family system.

## License

MIT
