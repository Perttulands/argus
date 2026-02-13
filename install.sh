#!/usr/bin/env bash
set -euo pipefail

# install.sh — Install Argus as a systemd service

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_FILE="${SCRIPT_DIR}/argus.service"
SYSTEMD_DIR="/etc/systemd/system"
ENV_FILE="${SCRIPT_DIR}/argus.env"
ENV_EXAMPLE="${SCRIPT_DIR}/argus.env.example"

echo "===== Argus Installation ====="
echo ""

# Check if running with appropriate permissions
if [[ ! -w "$SYSTEMD_DIR" ]] && [[ $EUID -ne 0 ]]; then
    echo "⚠️  This script requires sudo to install the systemd service."
    echo "You will be prompted for your password."
    echo ""
fi

# Make scripts executable
echo "Making scripts executable..."
chmod +x "${SCRIPT_DIR}/argus.sh"
chmod +x "${SCRIPT_DIR}/collectors.sh"
chmod +x "${SCRIPT_DIR}/actions.sh"

# Check for environment file
if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ Environment file not found: $ENV_FILE"
    echo ""
    echo "Please create argus.env from the example file:"
    echo "  cp argus.env.example argus.env"
    echo "  nano argus.env  # Add your TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID"
    echo ""
    exit 1
fi

# Create log directory
echo "Creating log directory..."
mkdir -p "${SCRIPT_DIR}/logs"

# Create observation directory
echo "Creating observation directory..."
mkdir -p "$HOME/.openclaw/workspace/state/argus"

# Install systemd service
echo "Installing systemd service..."
sudo cp "$SERVICE_FILE" "${SYSTEMD_DIR}/argus.service"

# Reload systemd daemon
echo "Reloading systemd daemon..."
sudo systemctl daemon-reload

# Enable service
echo "Enabling argus service..."
sudo systemctl enable argus.service

# Ask if user wants to start the service now
echo ""
read -p "Start Argus service now? (y/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Starting argus service..."
    sudo systemctl start argus.service
    echo ""
    echo "✓ Argus service started"
    sleep 2
    echo ""
    echo "Service status:"
    sudo systemctl status argus.service --no-pager -l
else
    echo "Skipping service start. To start manually:"
    echo "  sudo systemctl start argus.service"
fi

echo ""
echo "===== Installation Complete ====="
echo ""
echo "Useful commands:"
echo "  sudo systemctl status argus   # Check service status"
echo "  sudo systemctl stop argus     # Stop the service"
echo "  sudo systemctl restart argus  # Restart the service"
echo "  sudo journalctl -u argus -f   # Follow logs"
echo "  tail -f ${SCRIPT_DIR}/logs/argus.log  # Follow application logs"
echo "  ${SCRIPT_DIR}/argus.sh --once # Test a single monitoring cycle"
echo ""
