#!/bin/bash

IP_ALLOC_FILE="/etc/wireguard/ip_allocations.txt"

# === Step 1: Get username ===
if [ -z "$1" ]; then
  read -p "Enter VPN user name to remove: " USERNAME
  if [ -z "$USERNAME" ]; then
    echo "[!] Empty username. Exit."
    exit 1
  fi
else
  USERNAME="$1"
fi

CLIENT_DIR="/etc/wireguard/clients/$USERNAME"
WG_CONF="/etc/wireguard/wg0.conf"

# === Step 2: Check client exists ===
if [ ! -d "$CLIENT_DIR" ]; then
  echo "[!] Client '$USERNAME' does not exist."
  exit 1
fi

CLIENT_CONF="$CLIENT_DIR/$USERNAME.conf"
if [ ! -f "$CLIENT_CONF" ]; then
  echo "[!] Client config not found: $CLIENT_CONF"
  exit 1
fi

CLIENT_PUBKEY=$(grep '^PublicKey' "$CLIENT_CONF" | awk '{print $3}')
if [ -z "$CLIENT_PUBKEY" ]; then
  echo "[!] Could not extract public key from $CLIENT_CONF"
  exit 1
fi

# === Step 3: Remove peer block from wg0.conf ===
TMP_CONF=$(mktemp)
awk -v pubkey="$CLIENT_PUBKEY" '
  BEGIN {skip=0}
  /^\[Peer\]/ {buffer=""; match=0; skip=1}
  skip {
    buffer = buffer $0 "\n"
    if ($1 == "PublicKey" && $3 == pubkey) {
      match = 1
    }
    next
  }
  {
    if (skip && match) {
      skip = 0
      next
    } else if (skip) {
      print buffer
      skip = 0
    }
    print
  }
' "$WG_CONF" > "$TMP_CONF"

mv "$TMP_CONF" "$WG_CONF"

# === Step 4: Remove client directory ===
rm -rf "$CLIENT_DIR"

# === Step 5: Remove IP allocation entry ===
if [ -f "$IP_ALLOC_FILE" ]; then
  sed -i "/^$USERNAME /d" "$IP_ALLOC_FILE"
fi

# === Step 6: Restart WireGuard ===
systemctl restart wg-quick@wg0

echo "[+] Client '$USERNAME' removed successfully."
