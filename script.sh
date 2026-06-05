#!/bin/bash
# ============================================================
# Datto RMM Network Node via Docker - Raspberry Pi 4 (32-bit / armhf)
# ============================================================
# Workaround for Datto RMM not supporting armhf natively.
# Runs the agent inside a Docker container.
#
# IMPORTANT: This is an unsupported community approach.
# Based on: https://github.com/ozskywalker/drmm-docker
#
# Run as root: sudo bash install-datto-rmm-docker.sh
# ============================================================

set -e

# --- Configuration ---
# Your Datto RMM Site ID (GUID from the agent download URL)
# How to find it:
#   1. Log in to Datto RMM
#   2. Go to Sites > [Your Site] > Add Device > Linux
#   3. Copy the download link — the GUID is the long string in the URL
#      e.g. https://your-platform.rmm.datto.com/.../<GUID>/agent.sh
DRMM_SITE_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

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

# Verify we're on armhf
DETECTED_ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
log "Detected architecture: $DETECTED_ARCH"
if [[ "$DETECTED_ARCH" != "armhf" && "$DETECTED_ARCH" != "arm" ]]; then
    log "WARNING: Expected armhf, got $DETECTED_ARCH."
    log "If you're on arm64, you don't need Docker — install the agent directly."
fi

# Check Site ID has been set
if [[ "$DRMM_SITE_ID" == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" ]]; then
    log "================================================================"
    log "ERROR: You must set DRMM_SITE_ID at the top of this script."
    log "Find it in: Datto RMM > Sites > [Your Site] > Add Device > Linux"
    log "It is the GUID in the agent download URL."
    log "================================================================"
    exit 1
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
    git \
    gnupg \
    lsb-release \
    >> "$LOG_FILE" 2>&1

# ============================================================
# Install Docker Engine — PINNED to v28 (last armhf release)
# ============================================================
if command -v docker &> /dev/null; then
    INSTALLED_DOCKER=$(docker --version 2>&1)
    log "Docker already installed: $INSTALLED_DOCKER"
    log "Checking version is v28 or below..."
    DOCKER_MAJOR=$(docker --version | grep -oP '\d+\.\d+' | head -1 | cut -d. -f1)
    if [ "$DOCKER_MAJOR" -ge 29 ]; then
        log "================================================================"
        log "WARNING: Docker v29+ detected. armhf is not supported in v29+."
        log "You may need to downgrade to Docker v28."
        log "Run: sudo apt-get install docker-ce=$DOCKER_VERSION"
        log "================================================================"
    fi
else
    log "Installing Docker Engine (pinned to v28 — last armhf-supported release)..."

    # Remove any conflicting packages
    for pkg in docker.io docker-compose docker-doc podman-docker containerd runc; do
        apt-get remove -y "$pkg" >> "$LOG_FILE" 2>&1 || true
    done

    # Add Docker's official GPG key and repo for Raspberry Pi OS (raspbian)
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/raspbian/gpg \
        -o /etc/apt/keyrings/docker.asc >> "$LOG_FILE" 2>&1
    chmod a+r /etc/apt/keyrings/docker.asc

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/raspbian ${CODENAME} stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -y >> "$LOG_FILE" 2>&1

    # List available versions for troubleshooting
    log "Available Docker v28 packages:"
    apt-cache madison docker-ce | grep "28\." | head -5 | tee -a "$LOG_FILE" || true

    # Attempt to install pinned version; fall back to latest v28 available if exact string differs
    if apt-get install -y \
        docker-ce="$DOCKER_VERSION" \
        docker-ce-cli="$DOCKER_VERSION" \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin >> "$LOG_FILE" 2>&1; then
        log "Docker v28 installed successfully."
    else
        log "Exact pinned version not found. Attempting to install latest available v28..."
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
            log "ERROR: Could not find any Docker v28 packages for this OS/arch."
            log "Check: https://download.docker.com/linux/raspbian/dists/${CODENAME}/pool/stable/armhf/"
            exit 1
        fi
    fi

    # Pin Docker at current version to prevent accidental upgrade to v29+
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
# Based on the archived ozskywalker/drmm-docker project
# We build locally since the Docker Hub image is gone
# ============================================================
log "Building Datto RMM agent Docker image for armhf..."

BUILD_DIR="/opt/drmm-docker-build"
mkdir -p "$BUILD_DIR"

# Write the Dockerfile — Ubuntu 20.04 is the last LTS with good armhf support
# and is one of Datto's supported Linux distros for the agent
cat > "$BUILD_DIR/Dockerfile" << 'DOCKERFILE'
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install Mono and dependencies (Datto RMM Linux agent requirement)
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

# Install Mono from official repo
RUN apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 \
        --recv-keys 3FA7E0328081BFF6A14DA29AA6A19B38D3D831EF \
    && echo "deb https://download.mono-project.com/repo/ubuntu stable-focal main" \
        > /etc/apt/sources.list.d/mono-official-stable.list \
    && apt-get update \
    && apt-get install -y mono-devel \
    && rm -rf /var/lib/apt/lists/*

# Copy and set up entrypoint
COPY run_cag.sh /run_cag.sh
RUN chmod +x /run_cag.sh

ENTRYPOINT ["/run_cag.sh"]
DOCKERFILE

# Write the entrypoint script
cat > "$BUILD_DIR/run_cag.sh" << 'ENTRYPOINT'
#!/bin/bash
# Datto RMM agent container entrypoint
# Adapted from ozskywalker/drmm-docker

set -e

SITE_ID="${DRMMSITE}"
PLATFORM_BASE="https://concord.centrastage.net"

if [ -z "$SITE_ID" ]; then
    echo "ERROR: DRMMSITE environment variable not set."
    echo "Pass your Datto RMM Site GUID as: -e DRMMSITE=your-guid"
    exit 1
fi

echo "[$(date)] Downloading Datto RMM agent for site: $SITE_ID"
wget -q -O /tmp/agent.sh \
    "${PLATFORM_BASE}/csm/profile/downloadLinuxAgent/${SITE_ID}"

if [ ! -s /tmp/agent.sh ]; then
    echo "ERROR: Agent download failed or empty. Check your Site ID."
    exit 1
fi

chmod +x /tmp/agent.sh

echo "[$(date)] Installing Datto RMM agent..."
bash /tmp/agent.sh

echo "[$(date)] Agent installed. Keeping container alive..."

# Keep container running and tail logs
AGENT_LOG="/var/log/CentraStage"
if [ -d "$AGENT_LOG" ]; then
    tail -F "$AGENT_LOG"/*.log 2>/dev/null &
fi

# Monitor the CentraStage service and restart if needed
while true; do
    if ! pgrep -f "CentraStage\|AEMAgent\|cagservice" > /dev/null 2>&1; then
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
# ============================================================
log "Starting Datto RMM agent container..."

# Remove existing container if present
docker rm -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 || true

docker run -dit \
    --name "$CONTAINER_NAME" \
    --hostname "$AGENT_HOSTNAME" \
    --restart always \
    --privileged \
    -e DRMMSITE="$DRMM_SITE_ID" \
    "$IMAGE_NAME"

log "Container started: $CONTAINER_NAME"

# ============================================================
# Create a systemd service to ensure container starts on boot
# (Docker restart=always handles most cases but this is belt-and-braces)
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
log "  4. Assign as Network Node if required"
log ""
log "KNOWN LIMITATIONS (unsupported deployment):"
log "  - OS monitoring reports container stats, not host Pi stats"
log "  - If container restarts, it may re-register as a new device"
log "    (delete the old device entry in Datto RMM if this happens)"
log ""
log "Log file: $LOG_FILE"
log "============================================"
