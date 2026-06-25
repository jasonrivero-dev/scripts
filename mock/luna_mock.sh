#!/bin/bash

# Target Files derived from vector.toml paths
LUNA_BE_LOG="/var/log/novarc/luna/luna_be_metrics_mock.log"
LUNA_FE_LOG="/var/log/novarc/luna/luna_fe_metrics_mock.log"

# Fresh timestamps
TS_ISO=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
TS_LOG=$(date -u +"%Y-%m-%d %H:%M:%SZ")

echo "Emitting fresh log lines with timestamp: $TS_ISO"

# 1. Luna BE - Standard Operations Array Loop (Matches short logs exactly)
echo '{"metadata":{"swr":"SWR-1843","region":"us-west-2","os":"linux","stage":"prod"},"metrics":[{"dimensions":{"function":"read_float","variable":"weld_Mode_Current"},"key":"latency","timestamp":"'"$TS_ISO"'","unit":"µs","value":10328},{"dimensions":{"function":"read_bool","variable":"Estop_Pressed"},"key":"latency","timestamp":"'"$TS_ISO"'","unit":"µs","value":5900},{"dimensions":{"function":"read_bool","variable":"Tig_Camera_Cooler_Error"},"key":"latency","timestamp":"'"$TS_ISO"'","unit":"µs","value":3822}],"timestamp":"'"$TS_LOG"'"}' >> "$LUNA_BE_LOG"

# 2. Luna BE - High-Latency Authenticate and Lifecycle Block
echo '{"metadata":{"swr":"SWR-1843","region":"us-west-2","os":"linux","stage":"prod"},"metrics":[{"dimensions":{"function":"authenticate"},"key":"latency","timestamp":"'"$TS_ISO"'","unit":"µs","value":66328},{"dimensions":{"function":"read_int","variable":"NovEye_License"},"key":"latency","timestamp":"'"$TS_ISO"'","unit":"µs","value":5959},{"dimensions":{"function":"read_int","variable":"Number_Of_Positioners"},"key":"latency","timestamp":"'"$TS_ISO"'","unit":"µs","value":2}],"timestamp":"'"$TS_LOG"'"}' >> "$LUNA_BE_LOG"

# 3. Luna FE - Button Click Counter Interjections
echo '{"metadata":{"swr":"SWR-1843","region":"us-west-2","os":"linux","stage":"prod"},"metrics":[{"dimensions":{"button":"login"},"key":"button_press","timestamp":"'"$TS_ISO"'","unit":"count","value":1}],"timestamp":"'"$TS_LOG"'"}' >> "$LUNA_FE_LOG"
echo '{"metadata":{"swr":"SWR-1843","region":"us-west-2","os":"linux","stage":"prod"},"metrics":[{"dimensions":{"nav_to":"Monitoring"},"key":"button_press","timestamp":"'"$TS_ISO"'","unit":"count","value":1},{"dimensions":{"button":"cold_run"},"key":"button_press","timestamp":"'"$TS_ISO"'","unit":"count","value":1}],"timestamp":"'"$TS_LOG"'"}' >> "$LUNA_FE_LOG"

echo "Done! Check Grafana for metric names 'latency' or 'button_press' under PROGRAM='LunaBE'."