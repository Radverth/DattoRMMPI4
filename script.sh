#!/bin/bash
# ============================================================
# Datto RMM Network Node via Docker - Raspberry Pi 4 (32-bit / armhf)
# ============================================================
# Place this script in the same directory as AgentSetup_Managed.sh
# before running.
#
# Run as root: sudo bash install-datto-rmm-docker.sh
# ============================================================

set -e

# --- Configuration ---
# Hostname the agent will appear as in Datto RMM
AGENT_HOSTNAME="pi-network-node"

# Docker image name (built locally)
IMAGE_NAME="drmm-agent-armhf"
CONTAINER_NAME="drmm-agent"

# Pinned Docker version - v28 is the last to support armhf
# Do NOT change this to 'latest' - v29+ dropped armhf support
DOCKER_VERSION="5:28.3.3-1~raspbian.12~bookworm"

LOG_FILE="/var/log/datto-rmm-docker-install.log"

# ============================================================
# Logging
# ============================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ============================================================
# Pre-flight checks
# ============================================================
log "Starting Datto RMM Docker installation for Raspberry Pi 4 (32-bit)"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root. Use: sudo bash $0"
    exit 1
fi

# Locate AgentSetup_Managed.sh — must be in the same directory as this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_SETUP="$SCRIPT_DIR/AgentSetup_Managed.sh"

if [ ! -f "$AGENT_SETUP" ]; then
    log "================================================================"
    log "ERROR: AgentSetup_Managed.sh not found."
    log "Expected location: $AGENT_SETUP"
    log "Place AgentSetup_Managed.sh in the same directory as this script"
    log "and re-run."
    log "================================================================"
    exit 1
fi

log "Found agent installer: $AGENT_SETUP"

# Verify we're on armhf
DETECTED_ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
log "Detected architecture: $DETECTED_ARCH"
if [[ "$DETECTED_ARCH" != "armhf" && "$DETECTED_ARCH" != "arm" ]]; then
    log "WARNING: Expected armhf, got $DETECTED_ARCH."
    log "If you're on arm64, you don't need Docker — install the agent directly."
fi

# Check OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    log "OS: $PRETTY_NAME"
    CODENAME="${VERSION_CODENAME:-bookworm}"
else
    log "WARNING: Cannot determine OS version. Assuming bookworm."
    CODENAME="bookworm"
fi

# ============================================================
# System update and dependencies
# ============================================================
log "Updating package list..."
apt-get update -y >> "$LOG_FILE" 2>&1

log "Installing dependencies..."
apt-get install -y \
    ca-certificates \
    curl \
    wget \
    gnupg \
    lsb-release \
    >> "$LOG_FILE" 2>&1

# ============================================================
# Install Docker Engine — PINNED to v28 (last armhf release)
# ============================================================
if command -v docker &> /dev/null; then
    INSTALLED_DOCKER=$(docker --version 2>&1)
    log "Docker already installed: $INSTALLED_DOCKER"
    DOCKER_MAJOR=$(docker --version | grep -oP '\d+\.\d+' | head -1 | cut -d. -f1)
    if [ "$DOCKER_MAJOR" -ge 29 ]; then
        log "================================================================"
        log "WARNING: Docker v29+ detected. armhf is not supported in v29+."
        log "Downgrade with: sudo apt-get install docker-ce=$DOCKER_VERSION"
        log "================================================================"
    fi
else
    log "Installing Docker Engine (pinned to v28 — last armhf-supported release)..."

    # Remove any conflicting packages
    for pkg in docker.io docker-compose docker-doc podman-docker containerd runc; do
        apt-get remove -y "$pkg" >> "$LOG_FILE" 2>&1 || true
    done

    # Add Docker's official GPG key and raspbian repo
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/raspbian/gpg \
        -o /etc/apt/keyrings/docker.asc >> "$LOG_FILE" 2>&1
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/raspbian ${CODENAME} stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y >> "$LOG_FILE" 2>&1

    log "Available Docker v28 packages:"
    apt-cache madison docker-ce | grep "28\." | head -5 | tee -a "$LOG_FILE" || true

    if apt-get install -y \
        docker-ce="$DOCKER_VERSION" \
        docker-ce-cli="$DOCKER_VERSION" \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin >> "$LOG_FILE" 2>&1; then
        log "Docker v28 installed successfully."
    else
        log "Exact pinned version not found. Trying latest available v28..."
        LATEST_V28=$(apt-cache madison docker-ce | grep "28\." | head -1 | awk '{print $3}')
        if [ -n "$LATEST_V28" ]; then
            apt-get install -y \
                docker-ce="$LATEST_V28" \
                docker-ce-cli="$LATEST_V28" \
                containerd.io \
                docker-buildx-plugin \
                docker-compose-plugin >> "$LOG_FILE" 2>&1
            log "Installed Docker: $LATEST_V28"
        else
            log "ERROR: No Docker v28 packages found for this OS/arch."
            log "Check: https://download.docker.com/linux/raspbian/dists/${CODENAME}/pool/stable/armhf/"
            exit 1
        fi
    fi

    # Pin Docker at v28 to prevent accidental upgrade to v29+
    log "Pinning Docker at v28 to prevent auto-upgrade..."
    cat > /etc/apt/preferences.d/docker-pin << 'EOF'
Package: docker-ce docker-ce-cli
Pin: version 5:28.*
Pin-Priority: 1001
EOF

    systemctl enable docker >> "$LOG_FILE" 2>&1
    systemctl start docker  >> "$LOG_FILE" 2>&1
    log "Docker service started."
fi

# Verify Docker works
log "Testing Docker installation..."
docker run --rm hello-world >> "$LOG_FILE" 2>&1 && log "Docker hello-world OK." || {
    log "ERROR: Docker hello-world failed. Check Docker installation."
    exit 1
}

# ============================================================
# Build Datto RMM Docker image (armhf)
# Copies AgentSetup_Managed.sh into the image and runs it
# at container startup rather than downloading at runtime.
# Ubuntu 20.04 — last LTS with armhf support and libssl1.1
# ============================================================
log "Preparing Docker build context..."

BUILD_DIR="/opt/drmm-docker-build"
mkdir -p "$BUILD_DIR"

# Copy the agent installer into the build context
cp "$AGENT_SETUP" "$BUILD_DIR/AgentSetup_Managed.sh"
chmod +x "$BUILD_DIR/AgentSetup_Managed.sh"

log "Copied AgentSetup_Managed.sh to build context."

cat > "$BUILD_DIR/Dockerfile" << 'DOCKERFILE'
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

RUN apt-get update && apt-get install -y \
    apt-utils \
    apt-transport-https \
    ca-certificates \
    curl \
    wget \
    gnupg \
    dnsutils \
    dmidecode \
    libssl1.1 \
    net-tools \
    iproute2 \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Install Mono from official repo (required by Datto RMM Linux agent)
RUN apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 \
        --recv-keys 3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF \
    && echo "deb https://download.mono-project.com/repo/ubuntu stable-focal main" \
        > /etc/apt/sources.list.d/mono-official-stable.list \
    && apt-get update \
    && apt-get install -y mono-devel \
    && rm -rf /var/lib/apt/lists/*

# Copy agent installer and entrypoint into image at build time
COPY AgentSetup_Managed.sh /AgentSetup_Managed.sh
COPY run_cag.sh /run_cag.sh
RUN chmod +x /AgentSetup_Managed.sh /run_cag.sh

ENTRYPOINT ["/run_cag.sh"]
DOCKERFILE

cat > "$BUILD_DIR/run_cag.sh" << 'ENTRYPOINT'
#!/bin/bash
set -e

# Only install the agent on first boot; skip reinstall on container restarts
if [ ! -f /opt/CentraStage/.installed ]; then
    echo "[$(date)] Installing Datto RMM agent from bundled installer..."
    bash /AgentSetup_Managed.sh
    touch /opt/CentraStage/.installed
    echo "[$(date)] Agent installed."
else
    echo "[$(date)] Agent already installed, starting service..."
    service CentraStage start 2>/dev/null || \
    systemctl start CentraStage 2>/dev/null || \
    /opt/CentraStage/bin/start.sh 2>/dev/null || true
fi

echo "[$(date)] Keeping container alive..."

# Tail agent logs if available
AGENT_LOG="/var/log/CentraStage"
if [ -d "$AGENT_LOG" ]; then
    tail -F "$AGENT_LOG"/*.log 2>/dev/null &
fi

# Monitor agent process and restart if it dies
# Note: pgrep uses ERE so | (not \|) is the OR operator
while true; do
    if ! pgrep -f "CentraStage|AEMAgent|cagservice" > /dev/null 2>&1; then
        echo "[$(date)] Agent process not found. Attempting restart..."
        service CentraStage start 2>/dev/null || \
        systemctl start CentraStage 2>/dev/null || \
        /opt/CentraStage/bin/start.sh 2>/dev/null || true
    fi
    sleep 60
done
ENTRYPOINT

log "Building Docker image (this may take several minutes on Pi hardware)..."
docker build --platform linux/arm/v7 -t "$IMAGE_NAME" "$BUILD_DIR/" 2>&1 | tee -a "$LOG_FILE"

log "Docker image built successfully: $IMAGE_NAME"

# ============================================================
# Run the container
# --network host   — shares the Pi's real network stack so the
#                    agent sees the actual LAN subnet, ARP tables,
#                    and MAC addresses needed for Network Node
#                    scanning, SNMP, and DHCP fingerprinting.
# --privileged     — required for network scanning operations
# ============================================================
log "Starting Datto RMM agent container..."

docker rm -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 || true

docker run -dit \
    --name "$CONTAINER_NAME" \
    --hostname "$AGENT_HOSTNAME" \
    --restart always \
    --privileged \
    --network host \
    "$IMAGE_NAME"

log "Container started: $CONTAINER_NAME"

# ============================================================
# Systemd service for boot persistence
# ============================================================
log "Creating systemd service for boot persistence..."

cat > /etc/systemd/system/drmm-agent.service << EOF
[Unit]
Description=Datto RMM Agent (Docker)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
RemainAfterExit=yes
ExecStart=/usr/bin/docker start -a ${CONTAINER_NAME}
ExecStop=/usr/bin/docker stop ${CONTAINER_NAME}
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload >> "$LOG_FILE" 2>&1
systemctl enable drmm-agent.service >> "$LOG_FILE" 2>&1

# ============================================================
# Done
# ============================================================
log "============================================"
log "Installation complete."
log ""
log "Container status:"
docker ps --filter "name=$CONTAINER_NAME" | tee -a "$LOG_FILE"
log ""
log "View live agent logs:"
log "  docker logs -f $CONTAINER_NAME"
log ""
log "NEXT STEPS:"
log "  1. Wait 2-3 minutes for the agent to register"
log "  2. Log in to Datto RMM > Sites > [Your Site] > Devices"
log "  3. Agent will appear as: $AGENT_HOSTNAME"
log "  4. Select the device > Network Node Settings > Network Node (with scanning)"
log ""
log "KNOWN LIMITATIONS (unsupported deployment):"
log "  - OS monitoring reports container stats, not host Pi stats"
log "  - If container restarts it may re-register as a new device;"
log "    delete the old device entry in Datto RMM if this happens"
log "  - Docker v28 is pinned; do not upgrade or armhf support breaks"
log ""
log "Log file: $LOG_FILE"
log "============================================"
