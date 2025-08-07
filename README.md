# WireGuard VPN Setup Scripts

Automated scripts to install, configure, manage, and reset a WireGuard VPN server and clients.

---

## Overview

This project contains bash scripts to:

- Install WireGuard and dependencies
- Initialize server configuration
- Add VPN clients with automatic IP management
- Reset and uninstall the VPN server safely
- Generate client configs and QR codes for easy import

---

## Prerequisites

- Ubuntu/Debian-based server
- Root or sudo privileges
- Internet connection for package installation

---

## Scripts

| Script          | Description                                                  |
|-----------------|--------------------------------------------------------------|
| `install.sh`    | Installs WireGuard and sets up the server keys and config   |
| `initial.sh`    | Runs a full reset, installation, and adds the first client   |
| `add_client.sh` | Adds a new VPN client with IP allocation and config generation |
| `reset.sh`      | Resets server config, removes all clients and IP allocations  |
| `uninstall.sh`  | Stops service, removes WireGuard packages and configuration   |

---

## Usage

### Initial Setup

```bash
sudo ./initial.sh
