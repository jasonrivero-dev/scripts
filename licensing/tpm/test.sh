# ==============================================================================
# FUNCTION: get_stable_hardware_id
# PURPOSE: Extracts a highly stable, unique machine identifier.
#          Attempts to use hardware-rooted TPM 2.0 Endorsement Key (EK) first.
#          Falls back to a stable OS/CPU hash if the TPM is unavailable.
# RETURNS: Outputs a 64-character SHA256 string prefixed with 'tpm_' or 'fb_'.
# ==============================================================================
get_stable_hardware_id() {
    # ---------------------------------------------------------
    # 1. ATTEMPT TPM 2.0 HARDWARE ROOT OF TRUST
    # ---------------------------------------------------------
    if command -v tpm2_createek >/dev/null 2>&1 && command -v tpm2_readpublic >/dev/null 2>&1; then
        local tpm_dir
        tpm_dir=$(mktemp -d)
        local ek_ctx="$tpm_dir/ek.ctx"
        local ek_pub="$tpm_dir/ek.pem"

        # Silently create transient EK context and extract the public key
        if tpm2_createek -G rsa -c "$ek_ctx" >/dev/null 2>&1 && \
           tpm2_readpublic -c "$ek_ctx" -f pem -o "$ek_pub" >/dev/null 2>&1; then
            
            local tpm_hash
            tpm_hash=$(sha256sum "$ek_pub" | awk '{print $1}')
            
            if [ -n "$tpm_hash" ]; then
                rm -rf "$tpm_dir"
                echo "tpm_${tpm_hash}"
                return 0
            fi
        fi
        # Cleanup temporary files on silent failure to prepare for fallback
        rm -rf "$tpm_dir"
    fi

    # ---------------------------------------------------------
    # 2. FALLBACK: OS & CPU FINGERPRINT (Node-Lock)
    # ---------------------------------------------------------
    local fallback_data=""
    
    # Anchor 1: Linux Machine ID (Generated at OS install)
    if [ -f "/etc/machine-id" ]; then
        fallback_data=$(cat /etc/machine-id)
    fi
    
    # Anchor 2: CPU Model String (Hardware stability)
    if [ -f "/proc/cpuinfo" ]; then
        local cpu_anchor
        # Grab the first processor's model name, strip whitespace for consistency
        cpu_anchor=$(awk -F: '/^model name/ {print $2; exit}' /proc/cpuinfo | tr -d ' ' 2>/dev/null)
        fallback_data="${fallback_data}_${cpu_anchor}"
    fi

    local fallback_hash
    # Hash the combined anchors to ensure uniform 64-character output
    fallback_hash=$(echo -n "$fallback_data" | sha256sum | awk '{print $1}')
    
    if [ -n "$fallback_hash" ]; then
        echo "fb_${fallback_hash}"
        return 0
    fi

    # ---------------------------------------------------------
    # 3. ABSOLUTE LAST RESORT (Extreme Edge Case)
    # ---------------------------------------------------------
    echo "unknown_device_id"
    return 1
}

get_stable_hardware_id