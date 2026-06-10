# ACM Multi-Cluster Deployment Automation

Automated deployment of OpenShift clusters on AWS using Red Hat Advanced Cluster Management (ACM).
This project provides scripts and configuration templates to streamline the provisioning and management of multiple clusters with different network configurations.

This is for people using Red Hat Demo Platform with the service:
Advanced Cluster Management for Kubernetes Demo

The Red Hat Demo Platform will provide you:

- URL link User and Password to openshift ACM
- AWS ID,KEY and BASE_DOMAIN

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
  - [Shared Configuration](#shared-configuration)
  - [Cluster-Specific Configuration](#cluster-specific-configuration)
- [Deployment](#deployment)
  - [Single Cluster Deployment](#single-cluster-deployment)
  - [Multi-Cluster Deployment](#multi-cluster-deployment)
- [Usage Examples](#usage-examples)
- [Troubleshooting](#troubleshooting)
- [Project Structure](#project-structure)

## Prerequisites

### Required Tools

- **OpenShift CLI (oc)**: Download from [OpenShift Mirror](https://mirror.openshift.com/pub/openshift-v4/clients/ocp/)
- **OpenShift Cluster Manager CLI (OCM)**: Download from [OpenShift Dedicated QuickStart](https://cloud.redhat.com/experts/osd/quickstart/)
- **envsubst**: Part of the `gettext` package (usually pre-installed on Linux)
- **bash**: Version 4.0 or higher

### AWS Requirements

Red Hat Demo Platform provides:

- AWS Access Key ID and Secret Access Key
- Base DNS domain (provided by RHDP system)
  (Valid AWS account with appropriate permissions)

### ACM Hub Cluster

- An existing ACM Hub cluster must be running and accessible
- You must be logged in to the hub cluster with `oc login` for the first time

### Credentials (optional)

This script will generate for you:

- Red Hat OpenShift pull secret (from your Red Hat account)
- SSH key pair in PEM format (can be generated or provided)

## Quick Start

### 1. Set Up Credentials

First, configure your pull secret and SSH keys:

```bash
./deploy-cluster.sh --set-config
```

It will open a webpage you need to approve to get the pull secret

This will prompt you to provide:

- Red Hat OpenShift pull secret
- SSH private and public keys (or generate new ones)

The credentials will be stored in `tmp-secrets/` directory.

### 2. Create Shared Configuration

Create a `.env` file with your AWS credentials and shared settings:

```bash
cat > .env << 'EOF'
# AWS Credentials (from RHDP email)
BASE_DOMAIN="your-domain.opentlc.com"
AWS_ID="your-aws-access-key-id"
AWS_KEY="your-aws-secret-access-key"

# Deployment Settings
SECRET_NAME="aws"
SECRET_NAMESPACE="open-cluster-management"
IMAGE_SET="img4.19.31-multi-appsub"   # Check available images with: oc get clusterimageset
EOF
```

### 3. Deploy Your First Cluster

Create a cluster-specific configuration:

```bash
cat > .env.cluster1 << 'EOF'
CLUSTER_NAME="cluster1"
POD_CIDR="10.128.0.0/14"
SVC_CIDR="172.30.0.0/16"
MNET_CIDR="10.0.0.0/16"
HOST_PREFIX="23"
REGION="eu-west-2"
EOF
```

Deploy the cluster:

```bash
./deploy-cluster.sh cluster1
```

## Configuration

### Shared Configuration

The `.env` file contains settings shared across all clusters:

| Variable           | Description                                | Example                    |
| ------------------ | ------------------------------------------ | -------------------------- |
| `BASE_DOMAIN`      | Base DNS domain from RHDP                  | `sandbox2462.opentlc.com`  |
| `AWS_ID`           | AWS Access Key ID                          | From RHDP email            |
| `AWS_KEY`          | AWS Secret Access Key                      | From RHDP email            |
| `REGION`           | AWS region                                 | `eu-west-2` or `eu-west-3` |
| `SECRET_NAME`      | Kubernetes secret name for AWS credentials | `aws`                      |
| `SECRET_NAMESPACE` | Namespace for the secret                   | `open-cluster-management`  |
| `IMAGE_SET`        | ClusterImageSet name for OpenShift version | `img4.20.22-multi-appsub`  |

**Finding Available ClusterImageSets:**

```bash
oc get clusterimageset -o custom-columns=NAME:.metadata.name,RELEASE:.spec.releaseImage
```

### Cluster-Specific Configuration

Each cluster needs a `.env.cluster<NUMBER>` file with network settings:

| Variable       | Description                 | Example         |
| -------------- | --------------------------- | --------------- |
| `CLUSTER_NAME` | Unique cluster name         | `cluster1`      |
| `POD_CIDR`     | Pod network CIDR            | `10.128.0.0/14` |
| `SVC_CIDR`     | Service network CIDR        | `172.30.0.0/16` |
| `MNET_CIDR`    | Machine network CIDR        | `10.0.0.0/16`   |
| `HOST_PREFIX`  | Host prefix for pod subnets | `23`            |

**Network Planning Tips:**

- Each cluster needs unique CIDR ranges
- Pod CIDR: Typically `/14` (provides ~1000 subnets with `/23` host prefix)
- Service CIDR: Typically `/16` (provides ~65k services)
- Machine CIDR: Should match your VPC network
- Host Prefix: `/23` is standard (provides 510 IPs per node)

Example for multiple clusters:

```bash
# Cluster 1
cat > .env.cluster1 << 'EOF'
CLUSTER_NAME="cluster1"
POD_CIDR="10.128.0.0/14"
SVC_CIDR="172.30.0.0/16"
MNET_CIDR="10.0.0.0/16"
HOST_PREFIX="23"
REGION="eu-west-2"
EOF

# Cluster 2
cat > .env.cluster2 << 'EOF'
CLUSTER_NAME="cluster2"
POD_CIDR="10.132.0.0/14"
SVC_CIDR="172.31.0.0/16"
MNET_CIDR="10.0.0.0/16"
HOST_PREFIX="23"
REGION="eu-west-3"
EOF
```

## Deployment

### Single Cluster Deployment

Deploy a single cluster and monitor its status:

```bash
./deploy-cluster.sh cluster1
```

The script will:

1. Load shared configuration from `.env`
2. Load cluster-specific configuration from `.env.cluster1`
3. Create AWS credentials secret (if not exists)
4. Create ClusterDeployment resource
5. Monitor deployment progress (default timeout: 300 seconds)

### Multi-Cluster Deployment

Deploy all configured clusters in sequence:

```bash
./deploy-cluster.sh --all
```

This will deploy all clusters found in `.env.cluster*` files.
It will also generate ssh_key and pull-secret if they are not already in tmp-secrets

## Usage Examples

### List Available Clusters

```bash
./deploy-cluster.sh --list
```

Output:

```
Available cluster configurations:
  - cluster1
    POD: 10.128.0.0/14, SVC: 172.30.0.0/16
  - cluster2
    POD: 10.132.0.0/14, SVC: 172.31.0.0/16
```

### Dry-Run Mode

Test deployment without making actual changes:

```bash
./deploy-cluster.sh --dry-run cluster1
```

This generates test YAML files (`test-secret.yaml`, `test-cluster-deployment.yaml`) without applying them to the cluster.

### Create Credentials Only

Create AWS credentials secret without deploying a cluster:

```bash
./deploy-cluster.sh --create-creds
```

### Deploy Without Waiting

Deploy a cluster and return immediately (don't monitor status):

```bash
./deploy-cluster.sh --no-wait cluster1
```

### Custom Timeout

Deploy with a custom monitoring timeout (in seconds):

```bash
./deploy-cluster.sh --timeout 600 cluster1
```

### Set Pull Secret and SSH Keys

Configure credentials interactively:

```bash
./deploy-cluster.sh --set-config
```

### Simplify your navigation between clusters with ACM:

This script will overwrite your kubeconfig and get all new clusters created in ACM

```bash
./init-local-clusters.sh
```

Your ACM cluster will be renamed to acm-hub and all other clusters will get the same name as your ACM cluster

You can check with:

```bash
oc config get-contexts
```

You can switch to another cluster with:

```bash
oc config use-context <cluster-name>
```

## Troubleshooting

### ClusterImageSet Not Found Error

**Error Message:**

```
Deployment failed: ClusterImageSet not found
```

**Solution:**

1. Check available ClusterImageSets:

   ```bash
   oc get clusterimageset -o custom-columns=NAME:.metadata.name,RELEASE:.spec.releaseImage
   ```

2. Update `IMAGE_SET` in `.env` with the correct name:

   ```bash
   IMAGE_SET="img4.20.22-multi-appsub"
   ```

3. Retry the deployment

### Not Connected to OpenShift Cluster

**Error Message:**

```
ERROR: Not connected to an OpenShift cluster
```

**Solution:**

Log in to your ACM Hub cluster:

```bash
# Get login command from OpenShift web console
# Click your username → Copy login command

oc login <cluster-url> --token=<your-token>

# Or with username/password
oc login <cluster-url> -u <username> -p <password>
```

### Missing Secret Files

**Error Message:**

```
ERROR: One or more secret files are missing in ./tmp-secrets
```

**Solution:**

Generate the required secret files:

```bash
./deploy-cluster.sh --set-config
```

Or manually create them:

```bash
mkdir -p tmp-secrets

# Add your pull secret
cat > tmp-secrets/pull-secret.txt << 'EOF'
<your-pull-secret-json>
EOF

# Add your SSH keys
cp ~/.ssh/id_rsa tmp-secrets/
cp ~/.ssh/id_rsa.pub tmp-secrets/
```

### YAML Validation Errors

**Error Message:**

```
error converting YAML to JSON: yaml: line X: mapping values are not allowed in this context
```

**Solution:**

This typically indicates indentation issues in embedded YAML. Ensure:

- No leading spaces before root-level YAML keys
- Consistent use of spaces (not tabs)
- Proper indentation within nested structures

### Deployment Stuck or Timeout

**Solution:**

Check deployment status manually:

```bash
# List all cluster deployments
oc get clusterdeployment -n <cluster-name>

# Get detailed status
oc describe clusterdeployment -n <cluster-name> <cluster-name>

# Check for errors
oc logs -n <cluster-name> -l app=hive --tail=100
```

## Project Structure

```
.
├── README.md                              # This file
├── deploy-cluster.sh                      # Main deployment script
├── config-pull-secret-ssh-keys.sh         # Credential setup helper
├── export-acm-cluster.sh                  # Export cluster configuration
├── .env                                   # Shared configuration (AWS, domain, etc.)
├── .env.cluster1                          # Cluster 1 specific config
├── .env.cluster2                          # Cluster 2 specific config
├── .env.clusterN                          # Additional cluster configs
├── templates/
│   ├── cluster-deployment.yaml.txt        # ClusterDeployment template
│   └── secret-acm-credential.yaml.txt     # AWS credentials secret template
├── tmp-secrets/
│   ├── pull-secret.txt                    # Red Hat pull secret
│   ├── id_rsa                             # SSH private key
│   └── id_rsa.pub                         # SSH public key
├── test-manuel/                           # Manual test files
└── CLAUDE.md                              # Development notes
```

## Key Features

- **Multi-Cluster Support**: Deploy multiple clusters with different network configurations
- **Configuration Management**: Separate shared and cluster-specific settings
- **Dry-Run Mode**: Test deployments without making changes
- **Status Monitoring**: Automatic deployment progress tracking
- **Error Handling**: Detailed error messages and troubleshooting guidance
- **Credential Management**: Secure handling of AWS credentials and SSH keys

## Next Steps

1. **Monitor Cluster Deployment**: After deployment, monitor the cluster status in the ACM console
2. **Verify Addons**: Check that all required addons are installed and running
3. **Import Cluster**: Once provisioned, the cluster will be automatically imported into ACM
4. **Configure Policies**: Set up cluster policies and governance rules as needed

## Additional Resources

- [Red Hat Advanced Cluster Management Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/)
- [OpenShift Installation Guide](https://docs.openshift.com/container-platform/latest/installing/index.html)
- [AWS EC2 Instance Types](https://aws.amazon.com/ec2/instance-types/)

## Support

For issues or questions:

1. Check the [Troubleshooting](#troubleshooting) section
2. Review deployment logs: `oc logs -n <cluster-name> -l app=hive`
3. Consult the ACM documentation for cluster management topics
