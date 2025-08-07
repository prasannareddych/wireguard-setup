#!/bin/bash
set -e

WG_DIR="/etc/wireguard"
CLIENTS_DIR="$WG_DIR/clients"
WG_CONF="$WG_DIR/wg0.conf"
LAST_IP_FILE="$WG_DIR/last_used_ip.var"
ENDPOINT_FILE="$WG_DIR/endpoint.var"
DNS_FILE="$WG_DIR/dns.var"
WAN_IF_FILE="$WG_DIR/wan_interface_name.var"
LISTEN_PORT_FILE="$WG_DIR/listen_port.var"
SERVER_PRIVKEY_FILE="$WG_DIR/server_private.key"
SERVER_PUBKEY_FILE="$WG_DIR/server_public.key"

function require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root"
    exit 1
  fi
}

function init_server() {
  require_root
  echo "[*] Installing WireGuard and dependencies..."
  apt update && apt install wireguard qrencode -y

  echo "[*] Enabling IP forwarding..."
  sysctl -w net.ipv4.ip_forward=1
  sed -i 's/^#*net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf

  mkdir -p "$WG_DIR"
  cd "$WG_DIR"

  umask 077

  echo "[*] Generating server keys..."
  SERVER_PRIVKEY=$(wg genkey)
  SERVER_PUBKEY=$(echo "$SERVER_PRIVKEY" | wg pubkey)
  echo "$SERVER_PRIVKEY" > "$SERVER_PRIVKEY_FILE"
  echo "$SERVER_PUBKEY" > "$SERVER_PUBKEY_FILE"

  # Get endpoint fqdn or IP + port from user
  read -p "Enter public endpoint (FQDN or IP) (e.g. vpn.example.com): " ENDPOINT_HOST
  while [[ -z "$ENDPOINT_HOST" ]]; do
    echo "Endpoint cannot be empty."
    read -p "Enter public endpoint (FQDN or IP): " ENDPOINT_HOST
  done

  read -p "Enter WireGuard listen port [51820]: " LISTEN_PORT
  LISTEN_PORT=${LISTEN_PORT:-51820}

  echo "${ENDPOINT_HOST}:${LISTEN_PORT}" > "$ENDPOINT_FILE"
  echo "$LISTEN_PORT" > "$LISTEN_PORT_FILE"

  # Get VPN server IP
  read -p "Enter server VPN IP address [10.8.0.1]: " SERVER_IP
  SERVER_IP=${SERVER_IP:-10.8.0.1}

  # Extract VPN subnet prefix (assume /24)
  VPN_SUBNET=$(echo "$SERVER_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')

  # Save VPN subnet for later use
  echo "$VPN_SUBNET" > "$WG_DIR/vpn_subnet.var"

  # DNS server for clients
  read -p "Enter DNS server for clients [1.1.1.1]: " DNS_SERVER
  DNS_SERVER=${DNS_SERVER:-1.1.1.1}
  echo "$DNS_SERVER" > "$DNS_FILE"

  # Track last used IP (start with 2 since .1 is server)
  echo 1 > "$LAST_IP_FILE"

  # Auto detect WAN interface
  AUTO_WAN_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1); exit}')
  if [[ -z "$AUTO_WAN_IF" ]]; then
    read -p "Could not auto detect WAN interface. Enter WAN interface name: " WAN_INTERFACE_NAME
  else
    read -p "Detected WAN interface '$AUTO_WAN_IF'. Use this? [Y/n]: " yn
    if [[ "$yn" =~ ^[Nn] ]]; then
      read -p "Enter WAN interface name: " WAN_INTERFACE_NAME
    else
      WAN_INTERFACE_NAME="$AUTO_WAN_IF"
    fi
  fi
  echo "$WAN_INTERFACE_NAME" > "$WAN_IF_FILE"

  # Create WireGuard config file
  cat > "$WG_CONF" <<EOF
[Interface]
Address = $SERVER_IP/24
ListenPort = $LISTEN_PORT
PrivateKey = $SERVER_PRIVKEY
SaveConfig = true

PostUp = iptables -I INPUT -p udp --dport $LISTEN_PORT -j ACCEPT
PostUp = iptables -I FORWARD -i $WAN_INTERFACE_NAME -o wg0 -j ACCEPT
PostUp = iptables -I FORWARD -i wg0 -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -o $WAN_INTERFACE_NAME -j MASQUERADE

PostDown = iptables -D INPUT -p udp --dport $LISTEN_PORT -j ACCEPT
PostDown = iptables -D FORWARD -i $WAN_INTERFACE_NAME -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $WAN_INTERFACE_NAME -j MASQUERADE
EOF

  # Create clients dir
  mkdir -p "$CLIENTS_DIR"

  systemctl enable wg-quick@wg0

  echo "[+] WireGuard server initialized."
  echo "Start it with: systemctl start wg-quick@wg0"
  echo "Endpoint: $ENDPOINT_HOST:$LISTEN_PORT"
}

function ip_in_use() {
  local ip=$1
  # Check if IP is assigned to any client
  grep -q "$ip" "$WG_CONF" && return 0 || return 1
}

function get_next_ip() {
  # Return the next available IP (last_used_ip + 1) if free, else scan forward
  last_ip=$(cat "$LAST_IP_FILE")
  base_subnet=$(cat "$WG_DIR/vpn_subnet.var" | sed 's|/24||;s|\.[0-9]\+$|.|')

  candidate_ip="$base_subnet$last_ip"
  while ip_in_use "$candidate_ip/32"; do
    ((last_ip++))
    candidate_ip="$base_subnet$last_ip"
    if (( last_ip > 254 )); then
      echo "No free IP addresses available."
      exit 1
    fi
  done

  echo "$last_ip"
}

function add_user() {
  require_root
  local username="$1"
  if [[ -z "$username" ]]; then
    read -p "Enter VPN username: " username
    if [[ -z "$username" ]]; then
      echo "Username cannot be empty."
      exit 1
    fi
  fi

  if [[ -d "$CLIENTS_DIR/$username" ]]; then
    echo "User '$username' already exists. Choose a different name."
    exit 1
  fi

  mkdir -p "$CLIENTS_DIR/$username"
  cd "$CLIENTS_DIR/$username"
  umask 077

  local client_preshared_key=$(wg genpsk)
  local client_privkey=$(wg genkey)
  local client_pubkey=$(echo "$client_privkey" | wg pubkey)

  echo "$client_preshared_key" > "${username}_preshared.key"
  echo "$client_privkey" > "${username}_private.key"
  echo "$client_pubkey" > "${username}_public.key"

  local server_pubkey
  server_pubkey=$(cat "$SERVER_PUBKEY_FILE")

  local dns_server
  dns_server=$(cat "$DNS_FILE")

  local endpoint
  endpoint=$(cat "$ENDPOINT_FILE")

  # Get next free IP
  local next_ip_int
  next_ip_int=$(get_next_ip)
  local base_subnet
  base_subnet=$(cat "$WG_DIR/vpn_subnet.var" | sed 's|/24||;s|\.[0-9]\+$|.|')
  local client_ip="$base_subnet$next_ip_int/32"

  echo "$next_ip_int" > "$LAST_IP_FILE"

  # Create client config file
  cat > "${username}.conf" <<EOF
[Interface]
PrivateKey = $client_privkey
Address = $client_ip
DNS = $dns_server

[Peer]
PublicKey = $server_pubkey
PresharedKey = $client_preshared_key
AllowedIPs = 0.0.0.0/0
Endpoint = $endpoint
PersistentKeepalive = 25
EOF

  # Add client to server config
  cat >> "$WG_CONF" <<EOF

[Peer]
PublicKey = $client_pubkey
PresharedKey = $client_preshared_key
AllowedIPs = $client_ip
EOF

  systemctl restart wg-quick@wg0

  echo "[+] User '$username' added."
  echo "Client config:"
  cat "${username}.conf"
  echo -e "\nQR code:"
  qrencode -t ansiutf8 < "${username}.conf"
}

function delete_user() {
  require_root
  local username="$1"
  if [[ -z "$username" ]]; then
    echo "Please specify the username to delete."
    exit 1
  fi

  if [[ ! -d "$CLIENTS_DIR/$username" ]]; then
    echo "User '$username' does not exist."
    exit 1
  fi

  # Remove client directory
  rm -rf "$CLIENTS_DIR/$username"

  # Remove peer from wg0.conf by PublicKey
  local pubkey_file="$CLIENTS_DIR/$username/${username}_public.key"
  if [[ -f "$pubkey_file" ]]; then
    local pubkey
    pubkey=$(cat "$pubkey_file")
    # Remove the Peer block that contains the public key
    # Assumes the format:
    # [Peer]
    # PublicKey = ...
    # PresharedKey = ...
    # AllowedIPs = ...
    sed -i "/^\[Peer\]/,/\[/{/PublicKey = $pubkey/,+2d}" "$WG_CONF"
    systemctl restart wg-quick@wg0
  fi

  echo "[+] User '$username' deleted."
}

function list_users() {
  if [[ ! -d "$CLIENTS_DIR" ]]; then
    echo "No users found."
    exit 0
  fi

  echo "VPN users:"
  ls "$CLIENTS_DIR"
}

function show_user() {
  local username="$1"
  if [[ -z "$username" ]]; then
    echo "Please specify the username."
    exit 1
  fi

  local user_dir="$CLIENTS_DIR/$username"
  local conf_file="$user_dir/${username}.conf"
  if [[ ! -f "$conf_file" ]]; then
    echo "User '$username' does not exist or has no config."
    exit 1
  fi

  local endpoint
  endpoint=$(cat "$ENDPOINT_FILE")
  local dns_server
  dns_server=$(cat "$DNS_FILE")

  local client_privkey
  client_privkey=$(cat "$user_dir/${username}_private.key")
  local client_preshared_key
  client_preshared_key=$(cat "$user_dir/${username}_preshared.key")
  local server_pubkey
  server_pubkey=$(cat "$SERVER_PUBKEY_FILE")
  local client_ip
  client_ip=$(grep '^Address' "$conf_file" | awk '{print $3}')

  # Recreate client config on the fly to update endpoint or dns if changed
  cat > /tmp/"$username".conf <<EOF
[Interface]
PrivateKey = $client_privkey
Address = $client_ip
DNS = $dns_server

[Peer]
PublicKey = $server_pubkey
PresharedKey = $client_preshared_key
AllowedIPs = 0.0.0.0/0
Endpoint = $endpoint
PersistentKeepalive = 25
EOF

  echo "Client config for user '$username':"
  cat /tmp/"$username".conf

  echo -e "\nQR code:"
  qrencode -t ansiutf8 < /tmp/"$username".conf

  rm /tmp/"$username".conf
}

function update_endpoint() {
  require_root
  echo "Current endpoint: $(cat $ENDPOINT_FILE)"
  read -p "Enter new endpoint (FQDN or IP:port): " NEW_ENDPOINT
  if [[ -z "$NEW_ENDPOINT" ]]; then
    echo "No endpoint entered. Aborting."
    exit 1
  fi

  echo "$NEW_ENDPOINT" > "$ENDPOINT_FILE"
  echo "[*] Endpoint updated to $NEW_ENDPOINT"

  # Restart wg-quick to reload endpoint for clients (clients keep old endpoints until reconnected)
  systemctl restart wg-quick@wg0

  echo "[*] Endpoint updated. Regenerating client configs..."

  for user_dir in "$CLIENTS_DIR"/*; do
    if [[ -d "$user_dir" ]]; then
      local username=$(basename "$user_dir")
      show_user "$username" > "$user_dir/${username}.conf"
    fi
  done

  echo "[+] All client configs regenerated with new endpoint."
}

function usage() {
  echo "Usage: $0 {init|add|delete|list|show|update-endpoint} [username]"
  exit 1
}

case "$1" in
  init) init_server ;;
  add) add_user "$2" ;;
  delete) delete_user "$2" ;;
  list) list_users ;;
  show) show_user "$2" ;;
  update-endpoint) update_endpoint ;;
  *) usage ;;
esac
