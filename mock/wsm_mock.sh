#!/bin/bash

WSM_LOG="/var/log/novarc/weldsessionmanager/wsm-metrics.log"

# Fresh dynamic timestamps
TS_ISO=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
TS_LOG=$(date -u +"%Y-%m-%dT%H:%M:%S.000000000+00:00")

echo "Emitting fresh WSM telemetry arrays with timestamp: $TS_ISO"

# Emits complete metrics payload block matching production layout exactly
echo '{"metadata":{"os":"Linux","region":"stillcreek","stage":"UNKNOWN","swr":"NovAI-249"},"metrics":[{"count":101,"dimensions":{"message_type":"NovAiData"},"interval":{"unit":"s","value":1.0},"key":"messages_published","timestamp":"'"$TS_LOG"'","unit":"count","value":101.0},{"count":101,"dimensions":{"message_type":"NovAiData","source_port":"0.0.0.0:9112"},"interval":{"unit":"s","value":1.0},"key":"messages_received","timestamp":"'"$TS_LOG"'","unit":"count","value":101.0},{"count":101,"dimensions":{"dest_url":"\"ipc:///tmp/novai_data.ipc\""},"interval":{"unit":"s","value":1.0},"key":"latency","timestamp":"'"$TS_LOG"'","unit":"us","value":{"avg":31.970297029702962,"max":102.0,"min":16.0}}],"timestamp":"'"$TS_ISO"'"}' >> "$WSM_LOG"

echo "Done! Run Vector configuration validation checks next."