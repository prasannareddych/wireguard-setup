#!/bin/bash

read -p "Are you sure you want to reset WireGuard config? This will DELETE clients, IP allocations, and reset configs. (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Reset cancelled."
  exit 0
fi

echo "# Resetting WireGuard configuration..."

WG_DIR="/etc/wireguard"

# Bring down wg0 interface if up
if wg show wg0 &>/dev/null; then
  echo "Bringing down wg0 interface..."
  wg-quick down wg0
fi

# Stop the service
systemctl stop wg-quick@wg0

# Remove clients directory safely
if [ -d $WG_DIR ]; then
  echo "Removing all files in $WG_DIR/"
  rm -rf $WG_DIR/*
fi

echo "# Reset complete."
