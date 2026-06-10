#!/bin/bash
# set -x # Uncomment for debugging

################################################################################
# Multi-Cluster Deployment Script
# Deploys multiple OpenShift clusters with different network configurations
################################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_ENV="${SCRIPT_DIR}/.env"

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

DRY_RUN=false
WAIT_FOR_DEPLOYMENT=true
DEPLOYMENT_WAIT_TIMEOUT=10
ENV_FILE=".env"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
SECRET_DIR="${SCRIPT_DIR}/tmp-secrets"
PULL_SECRET_FILE="${SECRET_DIR}/pull-secret.txt"
SSH_PRIV_FILE="${SECRET_DIR}/id_rsa"
SSH_PUB_FILE="${SECRET_DIR}/id_rsa.pub"

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] <cluster_name>

Deploy OpenShift clusters using ACM with cluster-specific configuration.

Arguments:
    cluster_name    Name of the cluster (e.g., cluster1, cluster2)
                   Looks for .env.<cluster_name> file with cluster config

Options:
    --dry-run           Run in dry-run mode (no 'oc' commands executed)
    --all               Deploy all clusters found in .env.cluster* files
    --set-config        Set Pull-secret and SSH keys
    --create-creds      Create credentials only (without deploying cluster)
    --no-wait           Skip deployment status monitoring (don't wait for result)
    --timeout <seconds> How long to wait for deployment status (default: 300s)
    --list              List available cluster configurations
    -h, --help          Show this help message

Examples:
    $0 cluster1                      # Deploy cluster1 and monitor status
    $0 --dry-run cluster2            # Dry-run for cluster2
    $0 --all                         # Deploy all configured clusters
    $0 --set-config                  # Create pull-secret and SSH key in folder tmp-secrets
    $0 --create-creds                # Create credentials only (no cluster deployment)
    $0 --timeout 600 cluster1        # Deploy with 10-minute timeout
    $0 --no-wait cluster1            # Deploy without waiting for status
    $0 --list                        # List available clusters

Configuration:
    - Shared config: .env (AWS credentials, domain, etc.)
    - Cluster-specific: .env.<cluster_name> (network, name, etc.)

Status Monitoring:
    By default, the script monitors deployment status and alerts on errors.
    For ClusterImageSet errors, it automatically shows available images.
EOF
    exit 0
}

list_clusters() {
    echo -e "${GREEN}Available cluster configurations:${NC}"
    found_any=false
    for conf in "${SCRIPT_DIR}"/.env.cluster*; do
        if [ -f "$conf" ]; then
            found_any=true
            cluster_name=$(basename "$conf" | sed 's/^\.env\.//')
            echo "  - $cluster_name"
            if grep -q "POD_CIDR" "$conf"; then
                pod_cidr=$(grep "^POD_CIDR=" "$conf" | cut -d'"' -f2)
                svc_cidr=$(grep "^SVC_CIDR=" "$conf" | cut -d'"' -f2)
                echo -e "    ${YELLOW}POD: $pod_cidr, SVC: $svc_cidr${NC}"
            fi
        fi
    done
    if [ "$found_any" = false ]; then
        echo -e "${YELLOW}No cluster configurations found (.env.cluster* files)${NC}"
    fi
    exit 0
}

check_ocp_connection() {
    echo "Checking OpenShift connection..."

    if [ "$DRY_RUN" = true ]; then
        echo "⚠️  DRY RUN MODE: Skipping OCP connection check"
        return 0
    fi

    if ! command -v oc &> /dev/null; then
        echo -e "${RED}❌ ERROR: 'oc' CLI not found${NC}"
        echo "Please install the OpenShift CLI (oc) first."
        echo "Download from: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/"
        exit 1
    fi

    if ! oc whoami &> /dev/null; then
        echo -e "${RED}❌ ERROR: Not connected to an OpenShift cluster${NC}"
        echo ""
        echo "Please log in to your OpenShift cluster first using:"
        echo -e "${YELLOW}  oc login <cluster-url> --token=<your-token>${NC}"
        echo ""
        echo "Or with username/password:"
        echo -e "${YELLOW}  oc login <cluster-url> -u <username> -p <password>${NC}"
        echo ""
        echo "You can get your login command from the OpenShift web console:"
        echo "  Click your username → Copy login command"
        exit 1
    fi

    local current_user=$(oc whoami)
    local current_server=$(oc whoami --show-server)
    echo -e "${GREEN}✅ Connected to OpenShift as: ${current_user}${NC}"
    echo -e "${GREEN}   Server: ${current_server}${NC}"
    echo ""
}

report_imageset_error() {
    local cluster_name=$1
    local error_msg=$2

    echo -e "${RED}❌ Deployment failed: ClusterImageSet not found${NC}"
    echo ""
    echo -e "${YELLOW}Error Details:${NC}"
    echo "  $error_msg"
    echo ""
    echo -e "${YELLOW}Current IMAGE_SET configuration:${NC}"
    echo "  IMAGE_SET=\"$IMAGE_SET\""
    echo ""
    echo -e "${YELLOW}Available ClusterImageSets on hub cluster:${NC}"
    echo ""
    oc get clusterimageset -o custom-columns=NAME:.metadata.name,RELEASE:.spec.releaseImage --no-headers | sed 's/^/  /'
    echo ""
    echo -e "${GREEN}To fix this:${NC}"
    echo "  1. Choose a ClusterImageSet NAME from the list above"
    echo "  2. Update IMAGE_SET in .env file with the NAME (not the RELEASE URL)"
    echo "  3. Example: IMAGE_SET=\"img4.19.31-multi-appsub\""
    echo "  4. Retry the deployment"
    echo ""
}

monitor_deployment_status() {
    local cluster_name=$1
    local namespace=$cluster_name
    local timeout=${DEPLOYMENT_WAIT_TIMEOUT:-300}
    local check_interval=3
    local elapsed=0

    echo ""
    echo -e "${YELLOW}Monitoring deployment status... (timeout: ${timeout}s)${NC}"
    echo "Waiting 3 seconds for deployment to initialize..."
    sleep 3
    echo ""

    while [ $elapsed -lt $timeout ]; do
        # Get cluster deployment status
        local status_describe=$(oc describe clusterdeployment -n "$namespace" "$cluster_name" 2>/dev/null)

        if [ $? -ne 0 ]; then
            echo "  ⏳ Waiting for ClusterDeployment to be created... ($elapsed/$timeout seconds)"
            sleep $check_interval
            elapsed=$((elapsed + check_interval))
            continue
        fi

        # Check for ProvisionFailed condition
        local provision_failed=$(echo "$status_describe" | grep -o "ClusterImageSetNotFound" 2>/dev/null)

        if [ -n "$provision_failed" ]; then
            # Extract error message
            local error_msg=$(echo "$status_describe" | grep "Message:" | head -1 | sed 's/Message://' | sed -e 's/^[ \t]*//' 2>/dev/null)

            # Check if it's a ClusterImageSet error
            if [[ "$error_msg" == *"ClusterImageSet"* ]]; then
                report_imageset_error "$cluster_name" "$error_msg"
                return 1
            else
                echo -e "${RED}❌ Deployment failed${NC}"
                echo "  Error: $error_msg"
                return 1
            fi
        fi

        # Check for Provisioned condition (success)
        local provisioned=$(echo "$status_describe" | grep -o "Provisioned" 2>/dev/null)
        if [ -n "$provisioned" ]; then
            local prov_status=$(echo "$status_describe" | grep -A 3 "Message:" | head -1  2>/dev/null)
            if [ "$prov_status" = "True" ]; then
                echo -e "${GREEN}✅ Cluster provisioned successfully!${NC}"
                return 0
            fi
        fi

        echo "  ⏳ Deployment in progress... ($elapsed/$timeout seconds)"
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done

    echo -e "${YELLOW}⚠️  Deployment monitoring timeout reached${NC}"
    echo "  Your cluster is still deploying. Check status manually with:"
    echo -e "  ${YELLOW}oc get clusterdeployment -n $namespace $cluster_name${NC}"
    echo -e "  ${YELLOW}oc describe clusterdeployment -n $namespace $cluster_name${NC}"
    return 0
}

# Function: Smart Variable Check & Prompt
check_var() {
    local var_name=$1
    local prompt_msg=$2
    local is_secret=$3
    local current_val="${!var_name}"

    if [[ -z "$current_val" ]]; then
        if [[ "$is_secret" == "true" ]]; then
            read -sp "$prompt_msg: " input_val
            echo ""
        else
            read -p "$prompt_msg: " input_val
        fi

        export "$var_name"="$input_val"
        echo "$var_name=\"$input_val\"" >> "$ENV_FILE"
    fi
}

validate_prereqs() {
    if [ ! -f "$PULL_SECRET_FILE" ] || [ ! -f "$SSH_PRIV_FILE" ] || [ ! -f "$SSH_PUB_FILE" ]; then
        if [[ -f "./config-pull-secret-ssh-keys.sh" ]]; then
            echo "Generating secret files..."
            chmod +x ./config-pull-secret-ssh-keys.sh
            ./config-pull-secret-ssh-keys.sh
        else
            echo "⚠️ Warning: config-pull-secret-ssh-keys.sh not found."
        fi
    fi

    if [[ ! -f "$PULL_SECRET_FILE" || ! -f "$SSH_PRIV_FILE" || ! -f "$SSH_PUB_FILE" ]]; then
        echo "❌ ERROR: One or more secret files are missing in $SECRET_DIR"
        exit 1
    fi
}

create_credentials() {
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Creating Credentials${NC}"
    echo -e "${GREEN}========================================${NC}"

    # Load base environment variables
    if [ -f "$BASE_ENV" ]; then
        echo "Loading configuration from $BASE_ENV..."
        set -a
        source "$BASE_ENV"
        set +a
    fi

    # Prepare secrets with proper YAML indentation
    export PULL_SECRET_CONTENT=$(cat "$PULL_SECRET_FILE" | sed 's/^/    /')
    export SSH_PRIV_KEY=$(cat "$SSH_PRIV_FILE" | sed '2,$s/^/    /')
    export SSH_PUB_KEY=$(cat "$SSH_PUB_FILE")

    check_var "SECRET_NAME" "Enter Credential SECRET_NAME" "false"
    check_var "SECRET_NAMESPACE" "Enter Credential SECRET_NAMESPACE" "false"

    if [ "$DRY_RUN" = true ]; then
        echo "🔍 DRY RUN MODE: Generating secret file..."
        envsubst < $SCRIPT_DIR/templates/secret-acm-credential.yaml.txt > test-secret.yaml
        echo "Secret output saved to: test-secret.yaml"
    else
        if oc get secret "$SECRET_NAME" -n "$SECRET_NAMESPACE" &>/dev/null 2>&1; then
            echo "✅ Secret '$SECRET_NAME' already exists in namespace '$SECRET_NAMESPACE'."
        else
            echo "🚀 Creating new Secret..."
            envsubst < $SCRIPT_DIR/templates/secret-acm-credential.yaml.txt | oc apply -f -
            echo -e "${GREEN}✅ Secret created successfully!${NC}"
        fi
    fi

    echo ""
}

deploy_cluster() {
    local cluster_name=$1
    local cluster_env="${SCRIPT_DIR}/.env.${cluster_name}"

    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}Deploying: $cluster_name${NC}"
    echo -e "${GREEN}========================================${NC}"

    # Validate cluster config exists
    if [ ! -f "$cluster_env" ]; then
        echo -e "${RED}ERROR: Configuration file not found: $cluster_env${NC}"
        echo -e "${YELLOW}Create .env.$cluster_name with cluster-specific settings${NC}"
        exit 1
    fi

    # Create temporary merged .env file
    TEMP_ENV=$(mktemp)
    trap "rm -f $TEMP_ENV; [ -f '${BASE_ENV}.backup' ] && mv '${BASE_ENV}.backup' '$BASE_ENV'" EXIT
    
    # Backup and replace .env
    if [ -f "$BASE_ENV" ]; then
        cp "$BASE_ENV" "${BASE_ENV}.backup"
    fi
    
    # Merge shared and cluster-specific configs
    if [ -f "$BASE_ENV" ]; then
        cat "$BASE_ENV" > "$TEMP_ENV"
        echo "" >> "$TEMP_ENV"
    fi

    echo "# Cluster-specific overrides from .env.$cluster_name" >> "$TEMP_ENV"
    cat "$cluster_env" >> "$TEMP_ENV"

 
    cp "$TEMP_ENV" "$BASE_ENV"

    # Export all variables from merged config
    set -a
    source "$BASE_ENV"
    set +a

    echo -e "${YELLOW}Configuration loaded:${NC}"
    echo "  Cluster Name: $CLUSTER_NAME"
    echo "  POD CIDR: $POD_CIDR"
    echo "  SVC CIDR: $SVC_CIDR"
    echo "  Host Prefix: $HOST_PREFIX"
    echo "  Region: ${REGION:-<will be prompted>}"
    echo ""

    # Prepare secrets with proper YAML indentation
    export PULL_SECRET_CONTENT=$(cat "$PULL_SECRET_FILE" | sed 's/^/    /')
    export SSH_PRIV_KEY=$(cat "$SSH_PRIV_FILE" | sed '2,$s/^/    /')
    export SSH_PUB_KEY=$(cat "$SSH_PUB_FILE")

    echo "✅ Secret contents loaded and formatted."

    # Check if cluster already exists
    CLUSTER_EXISTS=false
    if [ "$DRY_RUN" = false ]; then
        if oc get managedcluster "$CLUSTER_NAME" &>/dev/null; then
            echo "Cluster '$CLUSTER_NAME' already exists."
            read -p "Do you want to create another? Use the (y/n) option: " EXISTS
            if [[ "$EXISTS" =~ ^[Yy]$ ]]; then
                read -p "Enter a NEW Cluster Name: " CLUSTER_NAME
                CLUSTER_EXISTS=false
            else
                CLUSTER_EXISTS=true
            fi
        fi
    fi

    export CLUSTER_NAME=${CLUSTER_NAME:-"cluster1"}

    # Use check_var for missing data
    check_var "REGION" "Enter AWS Region EMEA = [ eu-west-2 or eu-west-3 ]" "false"
    check_var "BASE_DOMAIN" "Enter Base DNS Domain" "false"

    # Only check AWS Keys for new clusters
    if [ "$CLUSTER_EXISTS" != "true" ]; then
        check_var "AWS_ID" "Enter AWS Access Key ID" "false"
        check_var "AWS_KEY" "Enter AWS Secret Access Key" "true"
    fi

    # ACM Deployment Logic
    echo "-------------------------------------------------------"

    if [ "$DRY_RUN" = false ]; then
        if ! oc get namespace "$CLUSTER_NAME" &>/dev/null; then
            echo "Creating Namespace: $CLUSTER_NAME..."
            oc create namespace "$CLUSTER_NAME"
        fi
    fi

    if ! command -v envsubst &> /dev/null; then
        echo "❌ ERROR: 'envsubst' not found. Please install the gettext package."
        exit 1
    fi

    if [ "$DRY_RUN" = true ]; then
        check_var "SECRET_NAME" "Enter Credential SECRET_NAME" "false"
        check_var "SECRET_NAMESPACE" "Enter Credential SECRET_NAMESPACE" "false"
        envsubst < $SCRIPT_DIR/templates/secret-acm-credential.yaml.txt > test-secret.yaml
        envsubst < $SCRIPT_DIR/templates/cluster-deployment.yaml.txt > test-cluster-deployment.yaml
    else
        if [ "$CLUSTER_EXISTS" = "true" ]; then
            echo "🔄 Updating existing ClusterDeployment..."
            echo "-------------------------------------------------------"
            echo "🎉 ClusterDeployment '$CLUSTER_NAME' already deployed."
        else
            echo "Checking for existing Credential AWS in ACM ..."
            check_var "SECRET_NAME" "Enter Credential SECRET_NAME" "false"
            check_var "SECRET_NAMESPACE" "Enter Credential SECRET_NAMESPACE" "false"
            if oc get secret "$SECRET_NAME" -n "$SECRET_NAMESPACE" &>/dev/null; then
                echo "✅ Secret '$SECRET_NAME' already exists."
            else
                echo "🚀 Creating new Secret and ManagedCluster..."
                envsubst < $SCRIPT_DIR/templates/secret-acm-credential.yaml.txt | oc apply -f -
            fi
            echo "Waiting 3s for resources to settle..."
            sleep 3
            echo "🏗️ Applying main ClusterDeployment..."
            envsubst < $SCRIPT_DIR/templates/cluster-deployment.yaml.txt | oc apply -f -
        fi
    fi

    echo -e "${GREEN}Deployment Launched for $cluster_name${NC}"

    if [ "$WAIT_FOR_DEPLOYMENT" = true ] && [ "$DRY_RUN" = false ] && [ "$CLUSTER_EXISTS" != "true" ]; then
        monitor_deployment_status "$cluster_name"
    fi

    echo ""
}

# Main logic
echo "-------------------------------------------------------"
echo "  ACM Multi-Cluster Deployment"
echo "-------------------------------------------------------"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            echo "🔍 DRY RUN MODE: No 'oc' commands will be executed. Files will be saved to test-*.yaml"
            shift
            ;;
        --all)
            DEPLOY_ALL=true
            shift
            ;;
        --no-wait)
            WAIT_FOR_DEPLOYMENT=false
            shift
            ;;
        --set-config)
            validate_prereqs
            exit 1
            ;;
        --create-creds)
            CREATE_CREDS_ONLY=true
            shift
            ;;
        --timeout)
            if [ -z "$2" ] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}ERROR: --timeout requires a numeric value (seconds)${NC}"
                exit 1
            fi
            DEPLOYMENT_WAIT_TIMEOUT=$2
            shift 2
            ;;
        --list)
            list_clusters
            ;;
        -h|--help)
            usage
            ;;
        -*)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
        *)
            CLUSTER_NAME=$1
            shift
            ;;
    esac
done

# Validate prerequisites
validate_prereqs

# Load base environment
if [ -f "$BASE_ENV" ]; then
    echo "Loading shared configuration from $BASE_ENV..."
    set -a
    source "$BASE_ENV"
    set +a
else
    touch "$BASE_ENV"
fi

# Check OCP connection before proceeding
check_ocp_connection

# Deploy logic
if [ "$CREATE_CREDS_ONLY" = true ]; then
    create_credentials
elif [ "$DEPLOY_ALL" = true ]; then
    echo -e "${GREEN}Deploying all configured clusters...${NC}"
    for conf in "${SCRIPT_DIR}"/.env.cluster*; do
        if [ -f "$conf" ]; then
            cluster=$(basename "$conf" | sed 's/^\.env\.//')
            deploy_cluster "$cluster"
        fi
    done
elif [ -n "$CLUSTER_NAME" ]; then
    deploy_cluster "$CLUSTER_NAME"
else
    echo -e "${RED}ERROR: No cluster specified${NC}"
    usage
fi

echo -e "${GREEN}All deployments Launched!${NC}"
