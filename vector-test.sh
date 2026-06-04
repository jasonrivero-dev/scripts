#!/usr/bin/env bash

cleanup()
{
    :
}
trap cleanup EXIT

LIB_PATH="$HOME/dev/scripts/dev-log-lib"

# Source the custom logging library
if [ -f "$LIB_PATH" ]
then
    source "$LIB_PATH"
else
    echo -e "[error] Log library not found at $LIB_PATH"
    return 1 2>/dev/null || exit 1
fi

# Verify AWS Testing Credentials
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ] || [ -z "$AWS_SESSION_TOKEN" ]; then
    error "AWS testing credentials are not set! Export your keys before continuing."
    return 1 2>/dev/null || exit 1
fi

log "Initializing local testing environment configuration..."

# 1. Base Directory Mappings
export TELEMETRY_CONFIG_DIR="$(pwd)"
export VECTOR_DATA_DIR="/tmp/vector-data"

# 2. Identity Labels
export SWR_CUSTOMER="$(whoami)"
export SWR_LOCATION="$(hostname)"
export SWR_TYPE="dev_laptop"
export SWR_ID="SWR-LAPTOP"

# 3. AWS Destination Variables
export AWS_PROMETHEUS_ENDPOINT="https://aps-workspaces.us-west-2.amazonaws.com/workspaces/ws-351bc544-bb2b-4ad6-b15f-8abc5332b0fb/api/v1/remote_write"
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
log "========================================================"
log "Environment variables successfully set up for current path context."

# 5. Quick Execution Help
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