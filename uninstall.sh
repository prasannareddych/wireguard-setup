#!/bin/bash

echo "# Removing WireGuard service and configuration..."

# Bring down the WireGuard interface if running
if wg show wg0 &>/dev/null; then
  echo "Bringing down wg0 interface..."
  wg-quick down wg0
fi

# Stop and disable the WireGuard service
systemctl stop wg-quick@wg0
systemctl disable wg-quick@wg0

# Remove WireGuard packages
echo "Removing WireGuard packages..."
apt update
yes | apt autoremove wireguard

# Remove configuration files securely
echo "Removing /etc/wireguard directory..."
rm -rf /etc/wireguard

echo "# WireGuard uninstall complete."
