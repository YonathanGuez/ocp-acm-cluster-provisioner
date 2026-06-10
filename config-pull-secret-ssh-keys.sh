#!/bin/bash
# Define paths
SECRET_DIR="./tmp-secrets"
PULL_SECRET_FILE="${SECRET_DIR}/pull-secret.txt" 
SSH_PRIV_FILE="./tmp-secrets/id_rsa"
SSH_PUB_FILE="./tmp-secrets/id_rsa.pub"

# Generate Pull Secret
mkdir -p ./tmp-secrets
if [ ! -f "$PULL_SECRET_FILE" ]; then
    echo "Attempting to fetch Pull Secret via OCM CLI..."
    echo "Check your Brower for the connection by SSO"
    ocm login --use-auth-code
    if ocm whoami &>/dev/null; then
        # Use POST instead of GET
        echo "{}" | ocm post /api/accounts_mgmt/v1/access_token > "$PULL_SECRET_FILE"
        
        # Check if the file is valid JSON and not an error message
        if grep -q "auths" "$PULL_SECRET_FILE"; then
            echo "✅ Pull Secret successfully fetched."
        else
            echo "❌ ERROR: Received an invalid response from API. Check permissions."
            cat "$PULL_SECRET_FILE"
            exit 1
        fi
    else
        echo "❌ ERROR: Not logged into OCM. Run 'ocm login' first."
        exit 1
    fi
else
     echo "✅ Pull Secret already created"
fi
if [[ ! -f "$SSH_PUB_FILE"  || ! -f "$SSH_PRIV_FILE"  ]]; then
    # Generate the keys in PEM format 
    ssh-keygen -m PEM -t rsa -b 4096 -f ./tmp-secrets/id_rsa -N ""

    head -n 1 ./tmp-secrets/id_rsa
else
     echo "✅ SSH keys already created"
fi