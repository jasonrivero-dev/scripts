#!/bin/bash

# 1. Establish the original production metric baseline as the default value
LATENCY_VAL=10328

# 2. Parse command line arguments to allow dynamic parameter injection for the demo
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --value) LATENCY_VAL="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

# Target Files derived from vector.toml paths
LUNA_BE_LOG="/var/log/novarc/luna/luna_be_metrics_mock.log"
LUNA_FE_LOG="/var/log/novarc/luna/luna_fe_metrics_mock.log"

# Fresh timestamps
TS_ISO=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")
TS_LOG=$(date -u +"%Y-%m-%d %H:%M:%SZ")

echo "Emitting fresh log lines with latency value set to: $LATENCY_VAL"

# 1. Luna BE - Standard Operations Array Loop (Injecting our dynamic variable cleanly into the original schema)
echo '{"metadata":{"swr":"SWR-1843","region":"us-west-2","os":"linux","stage":"prod"},"metrics":[{"dimensions":{"function":"read_float","variable":"weld_Mode_Current"},"key":"latency","timestamp":"'"$TS_ISO"'","unit":"µs","value":'$LATENCY_VAL'},{"dimensions":{"function":"read_bool","variable":"Estop_Pressed"},"key":"latency","timestamp":"'"$TS_ISO"'","unit":"µs","value":5900},{"dimensions":{"function":"read_bool","variable":"Tig_Camera_Cooler_Error"},"key":"latency","timestamp":"'"$TS_ISO"'","unit":"µs","value":3822}],"timestamp":"'"$TS_LOG"'"}' >> "$LUNA_BE_LOG"

# 2. Luna BE - High-Latency Authenticate and Lifecycle Block (Unchanged)
echo '{"metadata":{"swr":"SWR-1843","region":"us-west-2","os":"linux","stage":"prod"},"metrics":[{"dimensions":{"function":"authenticate"},"key":"latency","timestamp":"'"$TS_ISO"'","unit":"µs","value":66328},{"dimensions":{"function":"read_int","variable":"NovEye_License"},"key":"latency","timestamp":"'"$TS_ISO"'","unit":"µs","value":5959},{"dimensions":{"function":"read_int","variable":"Number_Of_Positioners"},"key":"latency","timestamp":"'"$TS_ISO"'","unit":"µs","value":2}],"timestamp":"'"$TS_LOG"'"}' >> "$LUNA_BE_LOG"

# 3. Luna FE - Button Click Counter Interjections (Unchanged)
echo '{"metadata":{"swr":"SWR-1843","region":"us-west-2","os":"linux","stage":"prod"},"metrics":[{"dimensions":{"button":"login"},"key":"button_press","timestamp":"'"$TS_ISO"'","unit":"count","value":1}],"timestamp":"'"$TS_LOG"'"}' >> "$LUNA_FE_LOG"
echo '{"metadata":{"swr":"SWR-1843","region":"us-west-2","os":"linux","stage":"prod"},"metrics":[{"dimensions":{"nav_to":"Monitoring"},"key":"button_press","timestamp":"'"$TS_ISO"'","unit":"count","value":1},{"dimensions":{"button":"cold_run"},"key":"button_press","timestamp":"'"$TS_ISO"'","unit":"count","value":1}],"timestamp":"'"$TS_LOG"'"}' >> "$LUNA_FE_LOG"

echo "Done! Check Grafana for metric names 'latency' or 'button_press' under PROGRAM='LunaBE'."