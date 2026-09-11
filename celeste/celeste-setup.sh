#!/usr/bin/env bash
# celeste-setup.sh -- one-shot local dev environment setup, following Paolo's
# working config for SW-3035 verification (video plays, no PLC hang).
#
# Adapts Paolo's config (originally /home/paolo/NovEye/...) to this machine, wires
# up the AI model files at the path celeste's compiled-in defaults expect
# (/opt/novarc/apps/ai_nn/share/*.pt), and deploys the config to
# /opt/novarc/apps/celeste/etc/noveye.cfg per Paolo's instructions. Idempotent --
# re-run any time celeste-files/noveye.cfg is edited to redeploy it.
#
# Source files expected at ~/dev/celeste-files/ (ai_nn/, noveye.cfg, original_image_mig.mp4).
set -e

SCRIPT_PATH=$(readlink -f "$0")
SCRIPTS_DIR=$(dirname "$SCRIPT_PATH")
source "${SCRIPTS_DIR}/../lib/dev-log-lib"

CELESTE_FILES="${HOME}/dev/celeste-files"
NOVEYE_DIR="${CELESTE_FILES}/NovEye"
OPT_APPS="/opt/novarc/apps"
OPT_ETC="${OPT_APPS}/celeste/etc"

if [[ ! -d "${CELESTE_FILES}/ai_nn/share" ]]; then
    error "Expected AI model files at ${CELESTE_FILES}/ai_nn/share -- not found."
    exit 1
fi
if [[ ! -f "${CELESTE_FILES}/original_image_mig.mp4" ]]; then
    error "Expected video at ${CELESTE_FILES}/original_image_mig.mp4 -- not found."
    exit 1
fi

log "Creating local NovEye data directories under ${NOVEYE_DIR}..."
mkdir -p "${NOVEYE_DIR}/logs" "${NOVEYE_DIR}/captures" "${NOVEYE_DIR}/learning" "${NOVEYE_DIR}/nn"

log "Generating ${CELESTE_FILES}/noveye.cfg (Paolo's config, paths adapted to ${HOME})..."
cat > "${CELESTE_FILES}/noveye.cfg" <<EOF
# NOTE: Paths are relative
#[Non Tagged cfg parameters] Must be declared first at top of file

arc on timeout = 0               	#Default = 0
console = true                   	#Default = false
log path = ${NOVEYE_DIR}/logs	#Default = logs
log level = debug

# NOTE: Sink and source can both be files but must be different directories.
sink = b 		# [v]ision (default), [f]iles, or [b]oth
sink file type = m 	# [m]p4 (default) - [r]aw , [b]oth
source = m  		# [c]amera (default) or [f]iles or [m]p4 file

pass = root                        #Default = plc Read in from PLC, can be set according to default_config.h constexpr for debug
direction = n                      #Default = n Can be set according to default_config.h constexpr for debug: [r]ightward, [l]eftward, [n]odir
base path = ${NOVEYE_DIR}

[camera]
image height = 1240 #1240 # 1080
image width = 1680 #1680 # 1440
type = v

[analysis]
ai mode = autonomy
drop strategy = latency			#default is legacy

[capture]
path = ${NOVEYE_DIR}/captures	#Default = captures NOTE: Path to sink files

[display]
enabled = true
x = 2                     #Default = 2
y = 116                   #Default = 116
vid burn in stt peak = false
vid burn in stt background = false
vid burn in tailout = false
vid burn in params arccontrol = false
vid burn ctwd stick out = false
vid burn in params trim = false

[plc]
data port = 51000         #Default = 9882
enable comm = false       #Default = true
enable data = false       #Default = true
ip = 127.0.0.1      	  #Default = 192.168.250.1
local data port = 8008    #Default = 8008
local port = 8004         #Default = 8004
port = 9865               #Default = 9875

[replay]
fps = 35		  #Default = 31.6 NOTE: FPS to assume for calculating timestamps if frame files do not contain them


# ------------------------
# ------ VIDEO PATH ------
video path = ${CELESTE_FILES}/original_image_mig.mp4
# ------------------------
# ------------------------


# --- For feature/1.2-autonomy ---
[noveye]
license = true

[learning]
save root = ${NOVEYE_DIR}/learning
#video config = original_image:1440:1080:30:MJPG

[pass]
num threads = 1
overlay_png_path = ${NOVEYE_DIR}/nn/overlay_output.png
overlay_png enable = false

feature root LEARNING_LOGGER enable = false
EOF

log "Wiring up /opt/novarc/apps (sudo needed -- this is where celeste's compiled-in AI model defaults look)..."
sudo mkdir -p "${OPT_ETC}"
sudo ln -sfn "${CELESTE_FILES}/ai_nn" "${OPT_APPS}/ai_nn"

# Only back up when actually about to overwrite something different -- otherwise
# re-running this script (it's meant to be re-run after editing
# celeste-files/noveye.cfg) would leave a new timestamped backup every time, even
# when nothing changed, since the deployed file is a plain copy, not a symlink.
if [[ -f "${OPT_ETC}/noveye.cfg" ]] && ! cmp -s "${CELESTE_FILES}/noveye.cfg" "${OPT_ETC}/noveye.cfg"; then
    backup="${OPT_ETC}/noveye.cfg.bak-$(date +%Y%m%d%H%M%S)"
    log "Deployed config differs -- backing up existing ${OPT_ETC}/noveye.cfg to ${backup}..."
    sudo cp "${OPT_ETC}/noveye.cfg" "${backup}"
    log "Deploying config to ${OPT_ETC}/noveye.cfg..."
    sudo cp "${CELESTE_FILES}/noveye.cfg" "${OPT_ETC}/noveye.cfg"
else
    log "${OPT_ETC}/noveye.cfg already up to date, nothing to deploy."
fi

log "Done. Launch with:"
log "  ~/dev/scripts/celeste/dev-build.sh -l -f ${OPT_ETC}/noveye.cfg"
