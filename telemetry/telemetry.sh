#!/usr/bin/env bash
set -euo pipefail

# Color formatting for clean status tracking
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

SERVICE_NAME="novarc-telemetry.service"

function log() {
    echo -e "[$(date +"%H:%M:%S")] [${GREEN}INFO${NC}] $@"
}

function warn() {
    echo -e "[$(date +"%H:%M:%S")] [${YELLOW}WARN${NC}] $@"
}

function display_usage() {
    echo "Usage: $0 {start|stop|restart|reset|status|tail}"
    echo "  start   : Spin up the telemetry service"
    echo "  stop    : Shut down the telemetry service"
    echo "  restart : Standard operational service restart"
    echo "  reset   : Stop, wipe all persistent database/file checkpoints, and start fresh from 'end'"
    echo "  status  : View active engine process tree and memory allocations"
    echo "  tail    : Stream live telemetry logging output to the console"
    exit 0
}

# Ensure a parameter was provided
if [ $# -lt 1 ]; then
    display_usage
fi

COMMAND=$1

case "$COMMAND" in
    start)
        log "Launching ${SERVICE_NAME}..."
        sudo systemctl start "$SERVICE_NAME"
        log "Service launch command issued."
        ;;
        
    stop)
        log "Stopping ${SERVICE_NAME}..."
        sudo systemctl stop "$SERVICE_NAME"
        log "Service stop command completed."
        ;;
        
    restart)
        log "Restarting ${SERVICE_NAME}..."
        sudo systemctl restart "$SERVICE_NAME"
        log "Service restart completed."
        ;;
        
    reset)
        warn "CRITICAL OPERATION: Initiating complete checkpoint wipe sequence..."
        log "Stopping background processing..."
        sudo systemctl stop "$SERVICE_NAME"
        
        log "Obliterating Vector tracking records, buffers, and system database states..."
        sudo rm -rf /var/lib/vector/*
        sudo rm -rf /var/log/vector/*
        
        log "Ignition: Restarting service fresh to anchor targets to log 'end' positions..."
        sudo systemctl start "$SERVICE_NAME"
        log "Telemetry engine has been fully reset. Tailing live streaming execution loop:"
        echo "----------------------------------------------------------------------"
        sudo journalctl -u "$SERVICE_NAME" -n 15 -f
        ;;
        
    status)
        echo -e "${GREEN}=== Systemd Service Allocation State ===${NC}"
        sudo systemctl status "$SERVICE_NAME" --no-pager || true
        ;;

    tail)
        echo -e "${GREEN}=== Tailing Live Streaming Telemetry Loop (Ctrl+C to exit) ===${NC}"
        echo "----------------------------------------------------------------------"
        sudo journalctl -u "$SERVICE_NAME" -n 50 -f
        ;;
        
    *)
        display_usage
        ;;
esac