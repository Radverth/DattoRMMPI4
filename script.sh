#!/bin/bash
# ============================================================
# Datto RMM Network Node - Raspberry Pi 4 (32-bit / armhf)
# ============================================================
# Run as root: sudo bash install-datto-rmm-node.sh
# ============================================================

set -e

# --- Configuration ---
# Replace with your Datto RMM Platform URL and site token
PLATFORM_URL="https://YOUR-PLATFORM.rmm.datto.com"
SITE_TOKEN="YOUR_SITE_TOKEN_HERE"

# --- Derived ---
INSTALL_DIR="/opt/dattoagent"
LOG_FILE="/var/log/datto-rmm-node-install.log"
ARCH="armhf"

# ============================================================
# Logging
# ============================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ============================================================
# Pre-flight checks
# ============================================================
log "Starting Datto RMM Network Node install for Raspberry Pi 4 (32-bit)"

# Must run as root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root. Use: sudo bash $0"
    exit 1
fi

# Confirm 32-bit ARM
DETECTED_ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
log "Detected architecture: $DETECTED_ARCH"
if [[ "$DETECTED_ARCH" != "armhf" && "$DETECTED_ARCH" != "arm" ]]; then
    log "WARNING: Expected armhf, got $DETECTED_ARCH. Proceeding anyway — verify you have the right binary."
fi

# Check OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    log "OS: $PRETTY_NAME"
else
    log "WARNING: Cannot determine OS version."
fi

# ============================================================
# System update and dependencies
# ============================================================
log "Updating package list..."
apt-get update -y >> "$LOG_FILE" 2>&1

log "Installing dependencies..."
apt-get install -y \
    curl \
    wget \
    ca-certificates \
    gnupg2 \
    lsb-release \
    net-tools \
    iproute2 \
    dmidecode \
    >> "$LOG_FILE" 2>&1

# ============================================================
# libssl — try 1.1 first (Bullseye), fall back to 3 (Bookworm)
# ============================================================
log "Installing libssl..."
if apt-get install -y libssl1.1 >> "$LOG_FILE" 2>&1; then
    log "libssl1.1 installed."
elif apt-get install -y libssl3 >> "$LOG_FILE" 2>&1; then
    log "libssl1.1 not available in repos, libssl3 installed instead."
else
    log "WARNING: Could not install libssl1.1 or libssl3. Agent may fail to start."
fi

# ============================================================
# Java check (Network Node requires JRE)
# ============================================================
log "Checking for Java..."
if ! command -v java &> /dev/null; then
    log "Java not found. Installing OpenJDK 17 (headless)..."
    apt-get install -y openjdk-17-jre-headless >> "$LOG_FILE" 2>&1
else
    JAVA_VER=$(java -version 2>&1 | awk -F '"' '/version/ {print $2}')
    log "Java already installed: $JAVA_VER"
fi

# ============================================================
# Download Datto RMM Agent (armhf)
# ============================================================
log "Downloading Datto RMM agent installer..."

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Datto RMM Linux agent download URL pattern
# The armhf build is the correct one for 32-bit Pi OS
DOWNLOAD_URL="${PLATFORM_URL}/api/v2/account/agents/linux-armhf"

# Alternative: if your platform provides a direct download token URL, use that instead:
# DOWNLOAD_URL="https://concord.centrastage.net/csm/profile/downloadLinuxAgent/${SITE_TOKEN}"

log "Download URL: $DOWNLOAD_URL"

wget -q --show-progress \
    --header="Content-Type: application/octet-stream" \
    -O "datto-agent-armhf.sh" \
    "$DOWNLOAD_URL" >> "$LOG_FILE" 2>&1 || {
        log "ERROR: Download failed. Check your PLATFORM_URL and SITE_TOKEN."
        log "You may need to download the agent manually from:"
        log "  Datto RMM > Sites > [Your Site] > Devices > Add Device > Network Node"
        log "  Then copy the .sh installer to this Pi and run it directly."
        exit 1
    }

chmod +x datto-agent-armhf.sh

# ============================================================
# Install the agent
# ============================================================
log "Running Datto RMM agent installer..."
bash datto-agent-armhf.sh >> "$LOG_FILE" 2>&1

# ============================================================
# Verify service
# ============================================================
log "Checking agent service status..."

for SVC in datto-agent dagent cagent; do
    if systemctl list-units --type=service | grep -q "$SVC"; then
        log "Found service: $SVC"
        systemctl enable "$SVC" >> "$LOG_FILE" 2>&1 || true
        systemctl start "$SVC" >> "$LOG_FILE" 2>&1 || true
        systemctl status "$SVC" --no-pager | tee -a "$LOG_FILE"
        break
    fi
done

# ============================================================
# Network Node specific: open required ports (if ufw active)
# ============================================================
if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
    log "UFW detected. Opening required Datto RMM ports..."
    ufw allow out 443/tcp   comment 'Datto RMM HTTPS' >> "$LOG_FILE" 2>&1
    ufw allow out 8883/tcp  comment 'Datto RMM MQTT'  >> "$LOG_FILE" 2>&1
    ufw reload >> "$LOG_FILE" 2>&1
    log "UFW rules applied."
fi

# ============================================================
# Done
# ============================================================
log "============================================"
log "Installation complete."
log "Log file: $LOG_FILE"
log ""
log "NEXT STEPS:"
log "  1. Log in to Datto RMM"
log "  2. Go to Sites > [Your Site] > Devices"
log "  3. This Pi should appear as a new Network Node"
log "  4. Assign it as Network Node for the site"
log "============================================"
