#!/usr/bin/env bash

# gen-coverage-html.sh: Surgical Host-side Report Generator (LCOV 2.0+)
set -e

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
CELESTE_ROOT=$(dirname "$SCRIPT_DIR")/celeste

cd "$CELESTE_ROOT"

if [[ ! -f "coverage_filtered.info" ]]; then
    echo -e "[\033[0;31merror\033[0m] Tracefile not found! Run capture after tests."
    exit 1
fi

echo -e "[\033[0;32mlog\033[0m] Generating LCOV 2.0 report for Celeste..."

# REPLICATING SUCCESS: 
# 1. Maps Docker root (/app/) to local root
# 2. Maps relative Host paths (src/) to the 'back_end' folder where they live
genhtml ./coverage_filtered.info \
    --output-directory reports/host_coverage_report \
    --substitute "s|^/app/|${PWD}/|" \
    --substitute "s|^src/|${PWD}/back_end/src/|" \
    --substitute "s|^ai_module/|${PWD}/back_end/ai_module/|" \
    --ignore-errors source,unused \
    --synthesize-missing

echo -e "[\033[0;32mlog\033[0m] Surgical Success. Report: reports/host_coverage_report/index.html"