#!/usr/bin/env bash

# 1. Source the logging library at the absolute beginning
LIB_PATH="$HOME/dev/scripts/lib/dev-log-lib"
if [[ -f "$LIB_PATH" ]]; then
    source "$LIB_PATH"
else
    echo "[ERROR] Telemetry environment helper failed: Log library not found at $LIB_PATH"
    return 1 2>/dev/null || exit 1
fi

# 2. Enforce Sourcing Check (Using the library's error wrapper)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    error "CRITICAL: This script alters environment variables and MUST be sourced, not executed!"
    error "Correct Usage: source ./vector-test.sh [-c/--config /path/to/configure]"
    exit 1
fi

mkdir -p /tmp/vector-data

cleanup() { :; }
trap cleanup EXIT

# 3. Help Menu Layout
show_help() {
    log "========================================================"
    log "             VECTOR TELEMETRY DEVELOPMENT HELPER        "
    log "========================================================"
    log "Usage: source ./vector-test.sh [options]"
    log ""
    log "Options:"
    log "  -c, --config <path>   Explicit path to a robot configure file."
    log "                        (e.g., ../configure.robot)"
    log "  -h, --help            Display this help configuration overview."
    log ""
    log "Defaults:"
    log "  If no config parameter is given, the script automatically defaults"
    log "  to the global production location: /var/opt/novarc/configure"
    log "========================================================"
}

how_it_works() 
{
    log ""
    log "========================================================"
    log "                 HOW TO RUN THIS STUFF                  "
    log "========================================================"
    log "1. Standard Run (Silent local console, sends to AWS):"
    log "   vector --config ./vector.toml"
    log ""
    log "2. See Extracted JSON Metrics on Console (Enables the console sink):"
    log "   VECTOR_DEBUG_SINK=true vector --config ./vector.toml"
    log ""
    log "3. Debug Vector Itself (See parsing, SDK errors, connection logs):"
    log "   VECTOR_LOG=debug vector --config ./vector.toml"
    log ""
    log "4. Going Full Nuclear (See raw console metrics AND debug internal engine):"
    log "   VECTOR_DEBUG_SINK=true VECTOR_LOG=debug vector --config ./vector.toml"
    log "========================================================"
}

# 4. Parse Input Parameters
CONFIG_FILE=""
GLOBAL_DEFAULT_CONFIG="/var/opt/novarc/configure"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            return 0 2>/dev/null
            ;;
        -c|--config)
            if [[ -n "$2" && "$2" != -* ]]; then
                CONFIG_FILE="$2"
                shift 2
            else
                error "Argument for $1 is missing."
                return 1 2>/dev/null
            fi
            ;;
        *)
            error "Unsupported parameter provided: $1"
            show_help
            return 1 2>/dev/null
            ;;
    esac
done

# 5. Apply Default Configuration Path Location
if [[ -z "$CONFIG_FILE" ]]; then
    log "No configuration parameter provided. Defaulting to production global path..."
    CONFIG_FILE="$GLOBAL_DEFAULT_CONFIG"
fi

# 6. Validate File Existence before Ingestion
if [[ -f "$CONFIG_FILE" ]]; then
    log "Sourcing configuration matrix variables from: ${CONFIG_FILE}"
    set -a
    source "$CONFIG_FILE"
    set +a
else
    error "Configuration Error: File target could not be opened at '${CONFIG_FILE}'"
    return 1 2>/dev/null
fi

unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
export AWS_ACCESS_KEY_ID="$AWS_IAM_ID"
export AWS_SECRET_ACCESS_KEY="$AWS_IAM_KEY"

# Verify AWS Testing Credentials
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
    error "AWS testing credentials are not set! Export your keys before continuing."
    return 1 2>/dev/null || exit 1
fi

log "Initializing local testing environment configuration..."

# 1. Base Directory Mappings
export TELEMETRY_CONFIG_DIR="$(pwd)"
export VECTOR_DATA_DIR="/tmp/vector-data"

# 3. AWS Destination Variables
# export AWS_PROMETHEUS_ENDPOINT="https://aps-workspaces.us-west-2.amazonaws.com/workspaces/ws-351bc544-bb2b-4ad6-b15f-8abc5332b0fb/api/v1/remote_write"
export AWS_PROMETHEUS_ENDPOINT="https://aps-workspaces.us-west-2.amazonaws.com/workspaces/ws-19c31f7d-a52e-4e54-94f6-3ec8f87b5150/api/v1/remote_write"
export AWS_DEFAULT_REGION="us-west-2"


# 4. Comprehensive Metric Configuration Output
log "========================================================"
log "TELEMETRY_CONFIG_DIR   : ${TELEMETRY_CONFIG_DIR}"
log "VECTOR_DATA_DIR        : ${VECTOR_DATA_DIR}"
log "SWR_CUSTOMER           : ${SWR_CUSTOMER}"
log "SWR_LOCATION           : ${SWR_LOCATION}"
log "SWR_TYPE               : ${SWR_TYPE}"
log "SWR_ID                 : ${SWR_ID}"
log "AWS_PROMETHEUS_ENDPOINT: ${AWS_PROMETHEUS_ENDPOINT}"
log "AWS_DEFAULT_REGION     : ${AWS_DEFAULT_REGION}"
log "AWS_ACCESS_KEY_ID      : ${AWS_ACCESS_KEY_ID}"
log "AWS_SECRET_ACCESS_KEY  : [REDACTED]"
log "========================================================"
log "Environment variables successfully set up for current path context."

# 5. Quick Execution Help
how_it_works
