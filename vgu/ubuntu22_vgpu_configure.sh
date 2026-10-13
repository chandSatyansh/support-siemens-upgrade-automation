#!/bin/bash

set -euo pipefail

# Usage:
# ./configure-vgpu.sh <api-fqdn> <auth-token> <host-uuid> <pf-addresses>
#
# Example:
# ./configure-vgpu.sh \
#   test-du-testbed-only-5113369-lon.app.qa-pcd.platform9.com \
#   "$AUTH_TOKEN" \
#   57e7c005-c80d-40e1-8f6d-e5a1bbade747 \
#   "0000:b1:00.0,0000:ca:00.0"

if [ "$#" -ne 4 ]; then
    echo "Usage:"
    echo "  $0 <api-fqdn> <auth-token> <host-uuid> <pf-addresses>"
    echo
    echo "Arguments:"
    echo "  api-fqdn      Resource Manager API FQDN"
    echo "  auth-token    OpenStack authentication token"
    echo "  host-uuid     UUID of the GPU host"
    echo "  pf-addresses  PCI addresses of the GPU PFs, comma-separated"
    echo
    echo "To find PF addresses on the GPU host, run:"
    echo "  nvidia-smi vgpu"
    echo
    echo "Use the Bus-Id values of the GPUs you want to configure."
    echo "For example:"
    echo "  00000000:B1:00.0"
    echo "  00000000:CA:00.0"
    echo
    echo "Convert them to PCI format by removing the extra leading zeros:"
    echo "  0000:b1:00.0"
    echo "  0000:ca:00.0"
    echo
    echo "For multiple GPUs, provide them as a comma-separated list:"
    echo '  "0000:b1:00.0,0000:ca:00.0"'
    echo
    echo "Example:"
    echo "  $0 <api-fqdn> <auth-token> <host-uuid> \"0000:b1:00.0,0000:ca:00.0\""
    exit 1
fi

API_FQDN="$1"
AUTH_TOKEN="$2"
HOST_UUID="$3"
PF_ADDRESSES="$4"


# ================================================================
# WARNING / CONFIRMATION
# ================================================================

echo
echo "======================================================================"
echo "                              WARNING"
echo "======================================================================"
echo
echo "This is a ONE-TIME PATCH activity required after upgrading to the"
echo "August 2026 release."
echo
echo "IMPORTANT:"
echo "  * Execute this script ON EACH GPU HOST individually."
echo "  * Execute this script ONLY after the GPU host has been upgraded"
echo "    successfully to the August 2026 release."
echo "  * Do NOT execute this script on a host that has not completed"
echo "    the upgrade successfully."
echo
echo "This script will update the vGPU/mdev configuration for this host"
echo "in Platform9 Resource Manager."
echo
echo "======================================================================"

read -r -p "Has this GPU host been successfully upgraded to the August 2026 release? [yes/no]: " CONFIRM
echo

if [[ "$CONFIRM" != "yes" ]]; then
    echo "[INFO] Confirmation not received. Exiting without making any changes."
    exit 0
fi

echo "[INFO] Confirmation received. Proceeding with the patch..."
echo


# ================================================================
# Configuration
# ================================================================

ROLE="pf9-ostackhost-neutron"

URL="https://${API_FQDN}/resmgr/v1/hosts/${HOST_UUID}/roles/${ROLE}"

echo "[INFO] API FQDN: ${API_FQDN}"
echo "[INFO] Host UUID: ${HOST_UUID}"
echo "[INFO] PF addresses: ${PF_ADDRESSES}"


# ================================================================
# GET existing configuration
# ================================================================

echo "[INFO] Fetching current host configuration..."

if ! CURRENT_CONFIG=$(curl -ksS --fail-with-body \
    -H "X-Auth-Token: ${AUTH_TOKEN}" \
    "$URL"); then
    echo "[ERROR] Failed to fetch host configuration from Resource Manager."
    echo "[ERROR] URL: ${URL}"
    exit 1
fi

if [ -z "$CURRENT_CONFIG" ]; then
    echo "[ERROR] GET request succeeded but returned an empty response."
    exit 1
fi

# Validate that response is valid JSON
if ! echo "$CURRENT_CONFIG" | jq empty >/dev/null 2>&1; then
    echo "[ERROR] GET request returned invalid JSON."
    exit 1
fi


# ================================================================
# Extract existing mdev configuration
# ================================================================

CURRENT_MDEV_CONFIG=$(echo "$CURRENT_CONFIG" | jq -r '.mdev_config // empty')

if [ -z "$CURRENT_MDEV_CONFIG" ]; then
    echo "[ERROR] mdev_config is missing from the GET response."
    exit 1
fi

# Validate mdev_config itself is valid JSON
if ! echo "$CURRENT_MDEV_CONFIG" | jq empty >/dev/null 2>&1; then
    echo "[ERROR] mdev_config from GET response is not valid JSON."
    exit 1
fi


# ================================================================
# Extract values from existing mdev configuration
# ================================================================

MDEV_NAME=$(echo "$CURRENT_MDEV_CONFIG" | jq -r '.[0].name // empty')

MAX_INSTANCES=$(echo "$CURRENT_MDEV_CONFIG" | jq -r '.[0].max_instances // empty')

if [ -z "$MDEV_NAME" ]; then
    echo "[ERROR] MDEV name is not present in the existing mdev_config."
    exit 1
fi

if [ -z "$MAX_INSTANCES" ]; then
    echo "[ERROR] max_instances is not present in the existing mdev_config."
    exit 1
fi

echo "[INFO] MDEV type: ${MDEV_NAME}"
echo "[INFO] Max instances: ${MAX_INSTANCES}"


# ================================================================
# Build new mdev_config
# ================================================================

MDEV_CONFIG=$(
    echo "$PF_ADDRESSES" |
    tr ',' '\n' |
    jq -R -s \
        --arg name "$MDEV_NAME" \
        --arg max_instances "$MAX_INSTANCES" '
        split("\n")
        | map(select(length > 0))
        | map({
            name: $name,
            max_instances: $max_instances,
            pf_address: .
        })
    '
)

echo
echo "[INFO] Generated mdev_config:"
echo "$MDEV_CONFIG" | jq .


# ================================================================
# Log mdev_config BEFORE PUT
# ================================================================

echo
echo "======================================================================"
echo "                       mdev_config BEFORE PUT"
echo "======================================================================"
echo "$CURRENT_MDEV_CONFIG" | jq .
echo "======================================================================"
echo


# ================================================================
# Update only mdev_config
# ================================================================

UPDATED_CONFIG=$(
    echo "$CURRENT_CONFIG" |
    jq --arg mdev_config "$(echo "$MDEV_CONFIG" | jq -c .)" \
       '.mdev_config = $mdev_config'
)


# ================================================================
# PUT updated configuration
# ================================================================

echo "[INFO] Updating host configuration..."

if ! curl -ksS --fail-with-body \
    -X PUT \
    -H "X-Auth-Token: ${AUTH_TOKEN}" \
    -H "Content-Type: application/json" \
    "$URL" \
    -d "$UPDATED_CONFIG"; then
    echo
    echo "[ERROR] Failed to update host configuration."
    echo "[ERROR] URL: ${URL}"
    exit 1
fi

echo
echo "[INFO] PUT completed successfully."


# ================================================================
# GET configuration after PUT for verification
# ================================================================

echo "[INFO] Fetching configuration after PUT for verification..."

if ! AFTER_CONFIG=$(curl -ksS --fail-with-body \
    -H "X-Auth-Token: ${AUTH_TOKEN}" \
    "$URL"); then
    echo "[ERROR] PUT succeeded, but failed to fetch configuration"
    echo "[ERROR] for post-PUT verification."
    exit 1
fi

if [ -z "$AFTER_CONFIG" ]; then
    echo "[ERROR] Post-PUT GET returned an empty response."
    exit 1
fi

if ! echo "$AFTER_CONFIG" | jq empty >/dev/null 2>&1; then
    echo "[ERROR] Post-PUT GET returned invalid JSON."
    exit 1
fi

AFTER_MDEV_CONFIG=$(echo "$AFTER_CONFIG" | jq -r '.mdev_config // empty')

if [ -z "$AFTER_MDEV_CONFIG" ]; then
    echo "[ERROR] mdev_config is missing from the post-PUT GET response."
    exit 1
fi


# ================================================================
# Log mdev_config AFTER PUT
# ================================================================

echo
echo "======================================================================"
echo "                        mdev_config AFTER PUT"
echo "======================================================================"
echo "$AFTER_MDEV_CONFIG" | jq .
echo "======================================================================"
echo


# ================================================================
# Final result
# ================================================================

echo "[INFO] vGPU configuration updated and verified successfully."
