#!/usr/bin/env bash

# Usage: ./sync_telemetry_batched.sh SWR-1843
if [ -z "$1" ]; then
    echo "Error: Missing parameter. Usage: $0 <ROBOT_ID>"
    exit 1
fi

ROBOT_ID=$1
SOURCE_PROFILE="ssm-test"
SOURCE_USER="novarc"
FOLDERS=("celeste" "luna" "cameranode" "odium_pm" "weldsessionmanager")
REMOTE_TEMP="/tmp/telemetry_bundle.tar"
LOCAL_TEMP="/tmp/telemetry_bundle.tar"

echo "Bundling files on $ROBOT_ID..."

# 1. SSH into robot, find files, and tar them up in one command
# We use 'find' to locate the latest 20 metrics files per folder and add them to the tar
novarc-ops run --profile "$SOURCE_PROFILE" --user "$SOURCE_USER" --robot "$ROBOT_ID" \
    --cmd "find /var/log/novarc/ -maxdepth 2 \( -name 'celeste' -o -name 'luna' -o -name 'cameranode' -o -name 'odium_pm' -o -name 'weldsessionmanager' \) -type f -name '*metrics*' | xargs tar -cf $REMOTE_TEMP"

# 2. Transfer the single bundle (Only one password prompt)
echo "Transferring bundle..."
novarc-ops copy --profile "$SOURCE_PROFILE" --user "$SOURCE_USER" \
    --source "$ROBOT_ID:$REMOTE_TEMP" \
    --dest "$LOCAL_TEMP"

# 3. Untar into your local path
echo "Unpacking into /var/log/novarc/..."
tar -xf "$LOCAL_TEMP" -C /

# 4. Cleanup
echo "Cleaning up..."
novarc-ops run --profile "$SOURCE_PROFILE" --user "$SOURCE_USER" --robot "$ROBOT_ID" --cmd "rm $REMOTE_TEMP"
rm "$LOCAL_TEMP"

echo "Sync Complete!"