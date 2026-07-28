#!/usr/bin/env bash

set -e

# Path to environment definition files
LICENSE_ENV="$HOME/dev/novarc-swr-license.keygen"
TOKEN_ENV="$HOME/dev/novarc-admin-token.keygen"

# Source the files if they exist
if [ -f "$LICENSE_ENV" ]; then
  source "$LICENSE_ENV"
else
  echo "Error: File $LICENSE_ENV not found." >&2
  exit 1
fi

if [ -f "$TOKEN_ENV" ]; then
  source "$TOKEN_ENV"
else
  echo "Error: File $TOKEN_ENV not found." >&2
  exit 1
fi

KEYGEN_ACCOUNT_ID="5bdb73d8-361d-4c77-a909-73118c88ed98"

echo "=================================================="
echo "Keygen Offline License Checkout Test"
echo "=================================================="
echo "Account Slug: $KEYGEN_ACCOUNT_ID"
echo "License ID:   $KEYGEN_DEV_TEST_LICENSE"
echo "=================================================="
echo ""

# Execute Keygen Checkout Action
curl -X POST "https://api.keygen.sh/v1/accounts/${KEYGEN_ACCOUNT_ID}/licenses/${KEYGEN_DEV_TEST_LICENSE}/actions/check-out" \
  -H "Authorization: Bearer ${KEYGEN_ADMIN_TOKEN}" \
  -H "Accept: application/vnd.api+json" \
  -H "Content-Type: application/vnd.api+json" | jq .