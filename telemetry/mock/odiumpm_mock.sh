#!/usr/bin/env bash

# 1. Generate active high-precision time parameters matching host server clock
TS_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TS_LOG=$(date +"%Y-%m-%dT%H:%M:%S.000000000%:z")

# 2. Extract dynamic Year, Month, and Day tokens for directory layout structure
DIR_YEAR=$(date +"%Y")
DIR_MONTH=$(date +"%m") # Note: use %m for numeric month if %M was an oversight for minutes
DIR_DAY=$(date +"%d")
FILE_DATE=$(date +"%Y-%m-%d")
FILE_TIME=$(date +"%H-%M-%S.000")

# 3. Construct the exact multi-level directory paths safely
ODIUMPM_BASE_DIR="/var/log/novarc/odium_pm"
ODIUMPM_DYNAMIC_DIR="${ODIUMPM_BASE_DIR}/${DIR_YEAR}/${DIR_MONTH}/${DIR_DAY}"
ODIUMPM_LOG="${ODIUMPM_DYNAMIC_DIR}/odium_pmd_metrics_${FILE_DATE}_${FILE_TIME}.log"

# 4. Execute safe path creation step before appending payloads
echo "Creating dynamic directory path structure: $ODIUMPM_DYNAMIC_DIR"
mkdir -p "$ODIUMPM_DYNAMIC_DIR"

echo "Emitting fresh OdiumPM metric array to target: $ODIUMPM_LOG"

# 5. Append array payload matching your exact log baseline schema
echo '{"metadata":{"os":"linux","region":"TBD","stage":"STAGE_ODIUM","swr":"SWR-1843"},"metrics":[{"dimensions":{"node":"camera_baumer"},"key":"node_started","timestamp":"'"$TS_LOG"'","unit":"count","value":1}],"timestamp":"'"$TS_ISO"'"}' >> "$ODIUMPM_LOG"
