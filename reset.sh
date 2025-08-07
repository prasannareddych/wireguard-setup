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
if [ -d "$WG_DIR/clients" ]; then
  echo "Removing clients directory..."
  rm -rf "$WG_DIR/clients"
fi

# Remove IP allocations file if it exists
if [ -f "$WG_DIR/ip_allocations.txt" ]; then
  echo "Removing IP allocations file..."
  rm -f "$WG_DIR/ip_allocations.txt"
fi

# Reset IP counter file (optional, if you still want to keep it)
echo "1" > "$WG_DIR/last_used_ip.var"

# Restore server config template
if [ -f "$WG_DIR/wg0.conf.def" ]; then
  echo "Restoring server configuration from wg0.conf.def..."
  cp -f "$WG_DIR/wg0.conf.def" "$WG_DIR/wg0.conf"
else
  echo "[!] Warning: wg0.conf.def not found. Skipping restore."
fi

echo "# Reset complete."
