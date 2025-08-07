#!/bin/bash
set -e

read -p "This will reset and reinstall WireGuard, deleting all clients. Continue? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
  echo "Installation cancelled."
  exit 0
fi

echo "# Starting WireGuard initial setup..."

chmod +x ./reset.sh ./install.sh ./add_client.sh

./reset.sh
./install.sh
./add_client.sh

echo "# WireGuard installation and initial client setup complete."
