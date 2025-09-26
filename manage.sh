#!/bin/bash
set -e

WG_DIR="/etc/wireguard"
CLIENTS_DIR="$WG_DIR/clients"
WG_CONF="$WG_DIR/wg0.conf"
ENDPOINT_FILE="$WG_DIR/endpoint.var"
DNS_FILE="$WG_DIR/dns.var"
WAN_IF_FILE="$WG_DIR/wan_interface_name.var"
SERVER_PRIVKEY_FILE="$WG_DIR/server_private.key"
SERVER_PUBKEY_FILE="$WG_DIR/server_public.key"
VPN_SUBNET_FILE="$WG_DIR/vpn_subnet.var"
IP_ALLOCATIONS_FILE="$WG_DIR/ip_allocations.txt"

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

  read -p "Enter public endpoint (FQDN or IP) (e.g. vpn.example.com), or leave empty to auto-detect: " ENDPOINT_HOST
  if [[ -z "$ENDPOINT_HOST" ]]; then
    ENDPOINT_HOST=$(curl -fsSL checkip.amazonaws.com)
    if [[ -z "$ENDPOINT_HOST" ]]; then
      echo "[!] Could not auto-detect public IP. Aborting."
      exit 1
    fi
    echo "Detected public IP: $ENDPOINT_HOST"
    read -p "Use this as endpoint? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
      echo "[!] No endpoint provided. Aborting."
      exit 1
    fi
  fi

  read -p "Enter WireGuard listen port [51820]: " LISTEN_PORT
  LISTEN_PORT=${LISTEN_PORT:-51820}
  echo "${ENDPOINT_HOST}:${LISTEN_PORT}" > "$ENDPOINT_FILE"


  # Get VPN server IP
  read -p "Enter server VPN IP address [10.8.0.1]: " SERVER_IP
  SERVER_IP=${SERVER_IP:-10.8.0.1}

  # Extract VPN subnet prefix (assume /24)
  VPN_SUBNET=$(echo "$SERVER_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
  echo "$VPN_SUBNET" > "$VPN_SUBNET_FILE"

  # DNS server for clients
  read -p "Enter DNS server for clients [1.1.1.1]: " DNS_SERVER
  DNS_SERVER=${DNS_SERVER:-1.1.1.1}
  echo "$DNS_SERVER" > "$DNS_FILE"

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
Address = $SERVER_IP/32
ListenPort = $LISTEN_PORT
PrivateKey = $SERVER_PRIVKEY
SaveConfig = false

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
  touch "$IP_ALLOCATIONS_FILE"

  systemctl enable wg-quick@wg0
  echo "[+] WireGuard server initialized."
  echo "Start it with: systemctl start wg-quick@wg0"
  echo "Endpoint: $ENDPOINT_HOST:$LISTEN_PORT"
}

function get_next_ip() {
  used_ips=$(cut -d ':' -f2 "$IP_ALLOCATIONS_FILE")
  for i in $(seq 2 254); do
    ip="10.8.0.$i"
    if ! echo "$used_ips" | grep -q "$ip"; then
      echo "$ip"
      return
    fi
  done
  echo "No available IPs" >&2
  exit 1
}

function add_user() {
  require_root
  local username="$1"
  if [[ -z "$username" ]]; then
    read -p "Enter VPN username: " username
    [[ -z "$username" ]] && echo "Username cannot be empty." && exit 1
  fi

  if grep -q "^$username:" "$IP_ALLOCATIONS_FILE"; then
    echo "User '$username' already exists."
    exit 1
  fi

  client_ip=$(get_next_ip)
  echo "$username:$client_ip" >> "$IP_ALLOCATIONS_FILE"
  mkdir -p $CLIENTS_DIR
  userconf="$CLIENTS_DIR/$username.conf"

  client_privkey=$(wg genkey)
  client_pubkey=$(echo "$client_privkey" | wg pubkey)
  client_preshared_key=$(wg genpsk)

  server_pubkey=$(cat "$SERVER_PUBKEY_FILE")
  dns_server=$(cat "$DNS_FILE")
  endpoint=$(cat "$ENDPOINT_FILE")
  subnet=$(cat "$VPN_SUBNET_FILE")  
  echo "[*] Choose AllowedIPs for client:"
  echo "1) Full tunnel (0.0.0.0/0)"
  echo "2) VPN subnet only [$subnet]"
  echo "3) VPN client only [$client_ip/32]"
  echo "4) Custom"
  read -p "Selection [1-4]: " mode
  case $mode in
    2) allowed_ips=$(cat "$VPN_SUBNET_FILE") ;;
    3) allowed_ips="$client_ip/32" ;;
    4) read -p "Enter custom AllowedIPs (comma-separated): " allowed_ips ;;
    *) allowed_ips="0.0.0.0/0" ;;
  esac
  cat > $userconf <<EOF
[Interface]
PrivateKey = $client_privkey
Address = $client_ip/32
DNS = $dns_server

[Peer]
PublicKey = $server_pubkey
PresharedKey = $client_preshared_key
AllowedIPs = $allowed_ips
Endpoint = $endpoint
PersistentKeepalive = 25
EOF

  cat >> "$WG_CONF" <<EOF

# $username
[Peer]
PublicKey = $client_pubkey
PresharedKey = $client_preshared_key
AllowedIPs = $client_ip/32
EOF

  systemctl restart wg-quick@wg0
  
  echo "[+] User '$username' added."
  echo -e "\nQR code:"
  qrencode -t ansiutf8 < $userconf
  cat $userconf

}

function delete_user() {
  require_root
  local username="$1"
  [[ -z "$username" ]] && echo "Specify username to delete." && exit 1

  local userconf="$CLIENTS_DIR/${username}.conf"
  [[ ! -f "$userconf" ]] && echo "User '$username' not found." && exit 1

  # Remove the [Peer] block tagged by the username
  sed -i "/^# $username$/,/^$/d" "$WG_CONF"

  # Remove from IP allocations
  grep -v "^$username:" "$IP_ALLOCATIONS_FILE" > "$IP_ALLOCATIONS_FILE.tmp" && mv "$IP_ALLOCATIONS_FILE.tmp" "$IP_ALLOCATIONS_FILE"

  # Remove config file
  rm -f "$userconf"

  systemctl restart wg-quick@wg0
  echo "[+] User '$username' deleted."
}


function list_users() {
  echo "VPN users:"
  cut -d ':' -f1 "$IP_ALLOCATIONS_FILE"
}

function show_user() {
  local username="$1"
  [[ -z "$username" ]] && echo "Specify username." && exit 1

  conf="$CLIENTS_DIR/$username.conf"
  [[ ! -f "$conf" ]] && echo "User config not found." && exit 1

  echo "Client config for '$username':"
  cat "$conf"
  echo -e "\nQR code:"
  qrencode -t ansiutf8 < "$conf"
}

function update_endpoint() {
  require_root

  read -p "Enter new public endpoint (FQDN or IP), or leave empty to auto-detect: " NEW_HOST

  if [[ -z "$NEW_HOST" ]]; then
    NEW_HOST=$(curl -fsSL checkip.amazonaws.com)
    echo "Detected public IP: $NEW_HOST"
    read -p "Use this as endpoint? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn] ]]; then
      echo "Aborted."
      exit 1
    fi
  fi

  read -p "Enter WireGuard listen port [51820]: " NEW_PORT
  NEW_PORT=${NEW_PORT:-51820}

  NEW_ENDPOINT="${NEW_HOST}:${NEW_PORT}"
  echo "[*] Updating all client configs with new endpoint: $NEW_ENDPOINT"

  for userconf in "$CLIENTS_DIR"/*.conf; do
    [[ -f "$userconf" ]] || continue

    # Edit Endpoint line in [Peer] section
    sed -i "s|^Endpoint = .*|Endpoint = $NEW_ENDPOINT|" "$userconf"
  done

  echo "[+] Endpoint updated in all client configs."
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
