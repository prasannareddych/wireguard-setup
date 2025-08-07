#!/bin/bash

# Update packages and install dependencies
apt update && apt install wireguard qrencode -y

# Enable IP forwarding
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
sed -i 's/^#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf

# Prepare WireGuard config directory
mkdir -p /etc/wireguard
cd /etc/wireguard || exit 1
umask 077

# Generate server keys
SERVER_PRIVKEY=$(wg genkey)
SERVER_PUBKEY=$(echo "$SERVER_PRIVKEY" | wg pubkey)

echo "$SERVER_PRIVKEY" > server_private.key
echo "$SERVER_PUBKEY"  > server_public.key

# Get public IP for endpoint
ENDPOINT=$(curl -s checkip.amazonaws.com)
if [ -z "$ENDPOINT" ]; then
  echo "[!] Failed to get public IP. Exiting."
  exit 1
fi
echo "$ENDPOINT" > endpoint.var

# Get server VPN IP (e.g., 10.8.0.1)
read -p "Enter the server VPN IP address [default: 10.8.0.1]: " SERVER_IP
SERVER_IP=${SERVER_IP:-10.8.0.1}
echo "$SERVER_IP" > vpn_server_ip.var

# Extract subnet prefix (e.g., 10.8.0.0/24)
VPN_SUBNET=$(echo "$SERVER_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
echo "$VPN_SUBNET" > vpn_subnet.var

# DNS server for clients
read -p "Enter DNS server for clients [default: 1.1.1.1]: " DNS
DNS=${DNS:-1.1.1.1}
echo "$DNS" > dns.var

# Track last used peer IP
echo 2 > last_used_ip.var  # 10.8.0.2 will be first peer

# Auto-detect WAN interface
AUTO_WAN_INTERFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1); exit}')
if [ -z "$AUTO_WAN_INTERFACE" ]; then
  echo "[!] Could not auto-detect WAN interface."
  read -p "Enter WAN interface name manually: " WAN_INTERFACE_NAME
else
  read -p "Detected WAN interface as '$AUTO_WAN_INTERFACE'. Use this? [Y/n]: " CONFIRM_WAN
  if [[ "$CONFIRM_WAN" =~ ^[Nn] ]]; then
    read -p "Enter WAN interface name manually: " WAN_INTERFACE_NAME
  else
    WAN_INTERFACE_NAME="$AUTO_WAN_INTERFACE"
  fi
fi

# Optionally validate WAN interface exists
if ! ip link show "$WAN_INTERFACE_NAME" > /dev/null 2>&1; then
  echo "[!] Interface '$WAN_INTERFACE_NAME' does not exist. Exiting."
  exit 1
fi

echo "$WAN_INTERFACE_NAME" > wan_interface_name.var

# Get WireGuard listen port
read -p "Enter WireGuard listen port [default: 51820]: " SERVER_LISTEN_PORT
SERVER_LISTEN_PORT=${SERVER_LISTEN_PORT:-51820}
echo "$SERVER_LISTEN_PORT" > listen_port.var

# Generate wg0.conf
cat > wg0.conf <<EOF
[Interface]
Address = $SERVER_IP/24
ListenPort = $SERVER_LISTEN_PORT
PrivateKey = $SERVER_PRIVKEY
SaveConfig = true

PostUp = iptables -I INPUT -p udp --dport $SERVER_LISTEN_PORT -j ACCEPT
PostUp = iptables -I FORWARD -i $WAN_INTERFACE_NAME -o wg0 -j ACCEPT
PostUp = iptables -I FORWARD -i wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o $WAN_INTERFACE_NAME -j MASQUERADE

PostDown = iptables -D INPUT -p udp --dport $SERVER_LISTEN_PORT -j ACCEPT
PostDown = iptables -D FORWARD -i $WAN_INTERFACE_NAME -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $WAN_INTERFACE_NAME -j MASQUERADE
EOF

# Enable WireGuard at boot
systemctl enable wg-quick@wg0

echo -e "\n[+] WireGuard server setup complete!"
echo "[*] You can start the server with: systemctl start wg-quick@wg0"
echo "[*] Server public key:"
cat server_public.key
