#!/usr/bin/env bash

# Generate matching time configurations dynamically
TS_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TS_LOG=$(date +"%Y-%m-%dT%H:%M:%S.000000000%:z")

# Extract the current date in YYYY-MM-DD format dynamically
LOG_DATE=$(date +"%Y-%m-%d")

# Construct the dynamic file path matching Vector's include pattern glob
CAMERA_LOG="/var/log/novarc/cameranode/cameranode-metrics_${LOG_DATE}.log"

echo "Emitting fresh CameraNode metric array to dynamic target: $CAMERA_LOG"

# Append payload with capitalized metadata keys matching production schema
echo '{"metadata":{"Customer":"copilot","Location":"stillcreek","OS":"linux","Region":"TBD","Stage":"UNKNOWN","SWR":"SWR-1843","Program":"CameraNode"},"metrics":[{"dimensions":{"camera_type":"Tig","ip":"192.168.10.22","type":"camera_cooler_error_check"},"key":"latency","timestamp":"'"$TS_LOG"'","unit":"us","value":3822}],"timestamp":"'"$TS_ISO"'"}' >> "$CAMERA_LOG"
