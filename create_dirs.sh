#!/bin/bash
DIRS=(
/var/opt/novarc/celeste
/var/log/novarc/celeste
/var/opt/novarc/celeste/replay
/var/opt/novarc/celeste/learning
/var/opt/novarc/celeste/nn
/var/opt/novarc/celeste/nn
)

for d in "${DIRS}"; do
    sudo mkdir -p "${d}"
    sudo chown $(id -u):$(id -g) "${d}"
done
