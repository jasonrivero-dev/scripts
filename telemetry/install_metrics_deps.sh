#!/usr/bin/env bash
set -euo pipefail

# Color codes for clean output logging
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

function log() {
    echo -e "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] [${GREEN}INFO${NC}] $@"
}

function warn() {
    echo -e "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] [${YELLOW}WARN${NC}] $@"
}

function error() {
    echo -e "[$(date -u +"%Y-%m-%d %H:%M:%S UTC")] [${RED}ERROR${NC}] $@" >&2
    exit 1
}

# Ensure script runs as root
if [ "$EUID" -ne 0 ]; then
    error "This setup utility must be run with elevated privileges (sudo)."
fi

log "Beginning telemetry infrastructure dependency verification..."

# 1. Install ACL (POSIX Access Control Lists)
if command -v setfacl &> /dev/null; then
    log "ACL package utilities are already installed."
else
    log "ACL utility not found. Provisioning via apt..."
    apt-get update -qy
    apt-get install -qy acl
    log "ACL successfully provisioned."
fi

# 2. Install Docker CE
if command -v docker &> /dev/null; then
    log "Docker engine binary is already installed: $(docker --version)"
else
    log "Docker CE not found. Initializing official Docker installation stream..."
    apt-get update -qy
    apt-get install -qy ca-certificates curl gnupg
    
    # Set up Docker's official GPG key & repository
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.p/docker.list > /dev/null

    apt-get update -qy
    apt-get install -qy docker-ce docker-ce-cli containerd.io
    log "Docker CE successfully installed and brought online."
fi

# 3. Target and Install Vector 0.56.0
TARGET_VECTOR_VERSION="0.56.0"
VECTOR_INSTALLED=false

if command -v vector &> /dev/null; then
    CURRENT_VERSION=$(vector --version 2>/dev/null | awk '{print $2}' || true)
    if [[ "$CURRENT_VERSION" == "$TARGET_VECTOR_VERSION" ]]; then
        log "Vector engine version match validated ($TARGET_VECTOR_VERSION)."
        VECTOR_INSTALLED=true
    else
        warn "Vector version mismatch detected. Found: $CURRENT_VERSION, Required: $TARGET_VECTOR_VERSION"
    fi
fi

if [ "$VECTOR_INSTALLED" = false ]; then
    log "Downloading and provisioning Vector DEB bundle variant: $TARGET_VECTOR_VERSION..."
    TEMP_DIR=$(mktemp -d)
    
    # Target path for the exact 0.56.0 x86_64 architecture package
    VECTOR_DEB_URL="https://packages.timber.io/vector/${TARGET_VECTOR_VERSION}/vector_${TARGET_VECTOR_VERSION}-1_amd64.deb"
    
    if ! wget -q --show-progress -O "${TEMP_DIR}/vector.deb" "$VECTOR_DEB_URL"; then
        # Fallback to secondary download schema if needed
        VECTOR_DEB_URL="https://github.com/vectordotdev/vector/releases/download/v${TARGET_VECTOR_VERSION}/vector-${TARGET_VECTOR_VERSION}-amd64.deb"
        wget -q --show-progress -O "${TEMP_DIR}/vector.deb" "$VECTOR_DEB_URL" || error "Failed to acquire Vector binary via network mirrors."
    fi
    
    log "Installing Vector baseline package..."
    dpkg -i "${TEMP_DIR}/vector.deb" || apt-get install -fy
    rm -rf "$TEMP_DIR"
    log "Vector $TARGET_VECTOR_VERSION successfully bound to host platform."
fi

log "All underlying prerequisite telemetry dependencies are satisfied."