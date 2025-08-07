#!/bin/bash

# === Step 1: Get VPN username ===
if [ -z "$1" ]; then
  read -p "Enter VPN user name: " USERNAME
  if [ -z "$USERNAME" ]; then
    echo "[!] Empty VPN user name. Exit."
    exit 1
  fi
else
  USERNAME="$1"
fi

# Check for duplicate username
if [ -d "/etc/wireguard/clients/$USERNAME" ]; then
  echo "[!] Client '$USERNAME' already exists. Exiting."
  exit 1
fi

cd /etc/wireguard || exit 1

# === Step 2: Load server configuration variables ===
read -r DNS < ./dns.var
read -r ENDPOINT < ./endpoint.var
read -r VPN_SUBNET < ./vpn_subnet.var
read -r SERVER_PUBLIC_KEY < ./server_public.key

# === Step 3: Ask user for AllowedIPs configuration ===
echo
echo "Configure client routing (AllowedIPs):"
echo "  1) Full tunnel (route all traffic via VPN) - 0.0.0.0/0"
echo "  2) VPN subnet only ($VPN_SUBNET)"
echo "  3) VPN subnet + custom CIDRs (e.g., local LAN)"
echo "  4) Custom only (you define all allowed networks)"
read -p "Choose option [1-4, default: 1]: " ALLOWED_CHOICE

case "$ALLOWED_CHOICE" in
  2)
    ALLOWED_IP="$VPN_SUBNET"
    ;;
  3)
    read -p "Enter additional AllowedIPs (e.g. 192.168.1.0/24,10.0.0.0/8): " CUSTOM_ALLOWED
    if [ -z "$CUSTOM_ALLOWED" ]; then
      echo "[!] No custom IP entered. Using VPN subnet only."
      ALLOWED_IP="$VPN_SUBNET"
    else
      ALLOWED_IP="$VPN_SUBNET,$CUSTOM_ALLOWED"
    fi
    ;;
  4)
    read -p "Enter full AllowedIPs list (e.g. 192.168.1.0/24): " ALLOWED_IP
    if [ -z "$ALLOWED_IP" ]; then
      echo "[!] No IPs entered. Exiting."
      exit 1
    fi
    ;;
  *)
    ALLOWED_IP="0.0.0.0/0"
    ;;
esac

echo "Using AllowedIPs: $ALLOWED_IP"

# === Step 4: Prepare client config directory ===
mkdir -p "./clients/$USERNAME"
cd "./clients/$USERNAME" || exit 1
umask 077

# === Step 5: Generate client keys ===
CLIENT_PRESHARED_KEY=$(wg genpsk)
CLIENT_PRIVKEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(echo "$CLIENT_PRIVKEY" | wg pubkey)

# === Step 6: Assign client IP ===
read -r OCTET_IP < /etc/wireguard/last_used_ip.var
CLIENT_OCTET_IP=$((OCTET_IP + 1))
echo "$CLIENT_OCTET_IP" > /etc/wireguard/last_used_ip.var

# Build client IP (e.g. 10.8.0.2/32)
BASE_IP=$(echo "$VPN_SUBNET" | cut -d'/' -f1)
IP_PREFIX=$(echo "$BASE_IP" | cut -d'.' -f1-3)
CLIENT_IP="${IP_PREFIX}.${CLIENT_OCTET_IP}/32"

# === Step 7: Write client .conf file ===
cat > "$USERNAME.conf" << EOF
[Interface]
PrivateKey = $CLIENT_PRIVKEY
Address = $CLIENT_IP
DNS = $DNS

[Peer]
PublicKey = $SERVER_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
AllowedIPs = $ALLOWED_IP
Endpoint = $ENDPOINT
PersistentKeepalive = 25
EOF

# === Step 8: Append client to wg0.conf (server) ===
cat >> /etc/wireguard/wg0.conf << EOF

# $USERNAME
[Peer]
PublicKey = $CLIENT_PUBLIC_KEY
PresharedKey = $CLIENT_PRESHARED_KEY
AllowedIPs = ${CLIENT_IP}
EOF

# === Step 9: Restart WireGuard to apply changes ===
systemctl restart wg-quick@wg0

# === Step 10: Output results ===
echo
echo "[+] VPN client '$USERNAME' added"
echo "[*] IP address: $CLIENT_IP"
echo "[*] AllowedIPs: $ALLOWED_IP"
echo "[*] Config file: /etc/wireguard/clients/$USERNAME/$USERNAME.conf"
echo
echo "[*] QR Code:"
qrencode -t ansiutf8 < "$USERNAME.conf"

echo
echo "# === $USERNAME.conf ==="
cat "$USERNAME.conf"
