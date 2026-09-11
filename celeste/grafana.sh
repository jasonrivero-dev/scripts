#!/usr/bin/env bash
set -euo pipefail

# 1. Define the target logging directory
TARGET_DIR="/var/log/novarc/celeste"

# Ensure all timestamps are generated in UTC to avoid local timezone offsets
export TZ=UTC

# 2. Generate current timestamps to satisfy Prometheus constraints
# Since your metadata log indicates Ubuntu-22.04, we can use standard GNU date flags.
TS1_METRIC=$(date -u +"%Y-%m-%d %H:%M:%SZ")
TS1_OUTER=$(date -u -d "+5 seconds" +"%Y-%m-%d %H:%M:%SZ")

TS2_METRIC=$(date -u -d "+1 second" +"%Y-%m-%d %H:%M:%SZ")
TS2_OUTER=$(date -u -d "+6 seconds" +"%Y-%m-%d %H:%M:%SZ")

# 3. Create the automated, unique filename matching your scheme (UTC)
FILE_TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S_%Y-%m-%d")
TARGET_FILE="${TARGET_DIR}/celeste-metrics.${FILE_TIMESTAMP}.log"

echo "Creating log file with current timestamps: ${TARGET_FILE}"

# 4. Write massaged data directly to the new log file
cat << EOF > "${TARGET_FILE}"
{"metadata":{"OS":"Ubuntu-22.04","SWR":"unknown","ip":"127.0.0.1","program":"celeste","type":"unknown"},"metrics":[{"count":94,"dimensions":{},"interval":{"unit":"ns","value":5000000000},"key":"ai_frames_processed","timestamp":"${TS1_METRIC}","unit":"","value":94.0}],"timestamp":"${TS1_OUTER}"}
{"metadata":{"OS":"Ubuntu-22.04","SWR":"unknown","ip":"127.0.0.1","program":"celeste","type":"unknown"},"metrics":[{"count":151,"dimensions":{},"interval":{"unit":"ns","value":5000000000},"key":"vision_frames_received","timestamp":"${TS1_METRIC}","unit":"","value":151.0}],"timestamp":"${TS1_OUTER}"}
{"metadata":{"OS":"Ubuntu-22.04","SWR":"unknown","ip":"127.0.0.1","program":"celeste","type":"unknown"},"metrics":[{"count":151,"dimensions":{},"interval":{"unit":"ns","value":5000000000},"key":"vision_frames_processed","timestamp":"${TS1_METRIC}","unit":"","value":151.0}],"timestamp":"${TS1_OUTER}"}
{"metadata":{"OS":"Ubuntu-22.04","SWR":"unknown","ip":"127.0.0.1","program":"celeste","type":"unknown"},"metrics":[{"count":151,"dimensions":{},"interval":{"unit":"ns","value":5000000000},"key":"ai_queue_length","timestamp":"${TS1_METRIC}","unit":"","value":{"avg":2.35,"max":5.0,"min":0.0}}],"timestamp":"${TS1_OUTER}"}
{"metadata":{"OS":"Ubuntu-22.04","SWR":"unknown","ip":"127.0.0.1","program":"celeste","type":"unknown"},"metrics":[{"count":151,"dimensions":{},"interval":{"unit":"ns","value":5000000000},"key":"non_vision_frames_received","timestamp":"${TS1_METRIC}","unit":"","value":151.0}],"timestamp":"${TS1_OUTER}"}
{"metadata":{"OS":"Ubuntu-22.04","SWR":"unknown","ip":"127.0.0.1","program":"celeste","type":"unknown"},"metrics":[{"count":151,"dimensions":{},"interval":{"unit":"ns","value":5000000000},"key":"frame_object_count","timestamp":"${TS1_METRIC}","unit":"","value":{"avg":4.09,"max":6.0,"min":1.0}}],"timestamp":"${TS1_OUTER}"}
{"metadata":{"OS":"Ubuntu-22.04","SWR":"unknown","ip":"127.0.0.1","program":"celeste","type":"unknown"},"metrics":[{"count":152,"dimensions":{},"interval":{"unit":"ns","value":5000000000},"key":"video_player_frame_count","timestamp":"${TS1_METRIC}","unit":"","value":152.0}],"timestamp":"${TS1_OUTER}"}
{"metadata":{"OS":"Ubuntu-22.04","SWR":"unknown","ip":"127.0.0.1","program":"celeste","type":"unknown"},"metrics":[{"count":78,"dimensions":{},"interval":{"unit":"ns","value":5000000000},"key":"ffmpeg_frames_processed","timestamp":"${TS2_METRIC}","unit":"","value":78.0}],"timestamp":"${TS2_OUTER}"}
{"metadata":{"OS":"Ubuntu-22.04","SWR":"unknown","ip":"127.0.0.1","program":"celeste","type":"unknown"},"metrics":[{"count":101,"dimensions":{"type":"nng_publisher"},"interval":{"unit":"ns","value":5000000000},"key":"ai_output_sent_count","timestamp":"${TS2_METRIC}","unit":"","value":101.0}],"timestamp":"${TS2_OUTER}"}
{"metadata":{"OS":"Ubuntu-22.04","SWR":"unknown","ip":"127.0.0.1","program":"celeste","type":"unknown"},"metrics":[{"count":101,"dimensions":{},"interval":{"unit":"ns","value":5000000000},"key":"ai_latency","timestamp":"${TS2_METRIC}","unit":"","value":{"avg":86.02,"max":165.0,"min":1.0}}],"timestamp":"${TS2_OUTER}"}
EOF

echo "Done! Data safely injected into Vector's pipeline loop."