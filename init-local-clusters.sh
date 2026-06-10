#!/bin/bash

# Ensure we are currently logged into the Hub
if ! oc cluster-info &>/dev/null; then
  echo "❌ Error: You are not currently logged into your ACM Hub cluster. Please log in first."
  exit 1
fi

echo "🔄 Initializing a clean standalone configuration template..."

# 1. Start a fresh file containing ONLY the current active hub details
oc config view --minify --flatten > /tmp/clean.kubeconfig

# 2. Rename the active hub context inside the temp file to 'acm-hub'
OLD_HUB_CTX=$(KUBECONFIG=/tmp/clean.kubeconfig oc config current-context)
KUBECONFIG=/tmp/clean.kubeconfig oc config rename-context "$OLD_HUB_CTX" acm-hub &>/dev/null

# 3. Loop through all managed clusters using your ACTIVE session
for cluster in $(oc get managedclusters -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep -v 'local-cluster'); do
  
  echo "🔍 Fetching credentials for managed cluster: $cluster..."
  
  # Find the secret name dynamically
  SECRET_NAME=$(oc get secret -n "$cluster" -o jsonpath="{.items[?(@.metadata.name=='$cluster-admin-kubeconfig')].metadata.name}" 2>/dev/null)
  if [ -z "$SECRET_NAME" ]; then
    SECRET_NAME=$(oc get secrets -n "$cluster" -o custom-columns=NAME:.metadata.name --no-headers | grep -E "^${cluster}-.*-admin-kubeconfig$" | head -n 1)
  fi

  if [ ! -z "$SECRET_NAME" ]; then
    echo "🎯 Found credentials secret. Extracting $cluster..."
    
    # Extract managed cluster's config to a separate temporary working file
    oc get secret -n "$cluster" "$SECRET_NAME" -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/incoming.config
    
    # --- FIX CRITICAL: Isolate User block along with Context and Cluster ---
    OLD_CONTEXT=$(KUBECONFIG=/tmp/incoming.config oc config current-context)
    OLD_USER=$(KUBECONFIG=/tmp/incoming.config oc config view -o jsonpath='{.contexts[?(@.name=="'"$OLD_CONTEXT"'")].context.user}')
    
    # Rename Context
    KUBECONFIG=/tmp/incoming.config oc config rename-context "$OLD_CONTEXT" "$cluster" &>/dev/null
    
    # Explicitly map a completely new unique user entry to avoid colliding with Hub's 'admin'
    KUBECONFIG=/tmp/incoming.config oc config set-context "$cluster" --cluster="$cluster" --user="user-$cluster" &>/dev/null
    
    # Use sed to clean up the users block entry name inside the temp file
    sed -i "s/name: $OLD_USER/name: user-$cluster/g" /tmp/incoming.config
    
    # Flatten/Merge this clean data directly into our template
    KUBECONFIG=/tmp/clean.kubeconfig:/tmp/incoming.config oc config view --flatten > /tmp/clean_merged
    mv /tmp/clean_merged /tmp/clean.kubeconfig
    
    rm /tmp/incoming.config
    echo "✅ Successfully prepared and isolated: $cluster"
  else
    echo "⚠️  Skipping $cluster (No admin-kubeconfig secret found on Hub)"
  fi
done

# 4. SWAP: Overwrite your real configuration file now that isolation is complete
echo "🧹 Replacing ~/.kube/config with the fresh, isolated version..."
mv /tmp/clean.kubeconfig ~/.kube/config

# Return the active selector back to the hub safely
oc config use-context acm-hub &>/dev/null

echo -e "\n🎉 Configuration rebuilt perfectly! Run your validation tests now."