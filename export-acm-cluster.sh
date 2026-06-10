#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- CONFIGURATION ---
CLUSTER_NAME="${1}"
OUTPUT_DIR="./exported-cluster-${CLUSTER_NAME}"

if [ -z "$CLUSTER_NAME" ]; then
    echo "Usage: $0 <managed-cluster-name>"
    exit 1
fi

echo "================================================================="
echo "Starting RHACM export for cluster: ${CLUSTER_NAME}"
echo "Output Directory: ${OUTPUT_DIR}"
echo "================================================================="

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Function to clean up Kubernetes metadata/status clutter for clean IaC/GitOps
sanitize_yaml() {
    # Removes status blocks and dynamic metadata fields added by Kubernetes at runtime
    sed -e '/^status:/,$d' \
        -e '/^  uid:/d' \
        -e '/^  resourceVersion:/d' \
        -e '/^  creationTimestamp:/d' \
        -e '/^  generation:/d' \
        -e '/^  managedFields:/,/^[^ ]/ { /^  managedFields:/d; /^ /d; }'
}

# --- 1. EXPORT CLUSTER-SCOPED RESOURCES ---
echo "--> Exporting cluster-scoped ManagedCluster CR..."
if oc get managedcluster "${CLUSTER_NAME}" &>/dev/null; then
    oc get managedcluster "${CLUSTER_NAME}" -o yaml | sanitize_yaml > "${OUTPUT_DIR}/01-managedcluster.yaml"
else
    echo "WARNING: ManagedCluster ${CLUSTER_NAME} not found!"
fi

# --- 2. EXPORT NAMESPACED RESOURCES ---
# Check if namespace exists
if ! oc get ns "${CLUSTER_NAME}" &>/dev/null; then
    echo "ERROR: Namespace '${CLUSTER_NAME}' does not exist on this Hub cluster."
    exit 1
fi

echo "--> Exporting ClusterDeployment..."
oc get clusterdeployment "${CLUSTER_NAME}" -n "${CLUSTER_NAME}" -o yaml | sanitize_yaml > "${OUTPUT_DIR}/02-clusterdeployment.yaml"

echo "--> Exporting MachinePools..."
oc get machinepools -n "${CLUSTER_NAME}" -o yaml | sanitize_yaml > "${OUTPUT_DIR}/03-machinepools.yaml"

# SyncSets / KlusterletAddonConfigs if they exist
echo "--> Exporting SyncSets and KlusterletAddonConfigs..."
oc get syncsets,klusterletaddonconfigs -n "${CLUSTER_NAME}" -o yaml | sanitize_yaml > "${OUTPUT_DIR}/04-addons-and-syncsets.yaml" 2>/dev/null || echo "    No SyncSets or KlusterletAddonConfigs found."

# --- 3. EXPORT REQUIRED INFRASTRUCTURE SECRETS ---
echo "--> Exporting deployment secrets (Pull Secrets, Cloud Credentials)..."
# We fetch secrets but intentionally KEEP the data block. 
# Note: In GitOps, you should encrypt these secrets (e.g., SealedSecrets, Vault) before committing!
SECRET_NAMES=$(oc get secrets -n "${CLUSTER_NAME}" -o jsonpath='{.items[*].metadata.name}')

for secret in $SECRET_NAMES; do
    # Skip default service account tokens to avoid bloating the export
    if [[ "$secret" == *"dockercfg"* ]] || [[ "$secret" == *"token"* ]]; then
        continue
    fi
    echo "    Exporting Secret: $secret"
    oc get secret "$secret" -n "${CLUSTER_NAME}" -o yaml | sanitize_yaml > "${OUTPUT_DIR}/secret-${secret}.yaml"
done

echo "================================================================="
echo "Export Complete!"
echo "All clean manifests are saved in: ${OUTPUT_DIR}"
echo "================================================================="
ls -l "${OUTPUT_DIR}"