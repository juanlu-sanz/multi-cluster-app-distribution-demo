#!/usr/bin/env bash
# post-install.sh
# Installs operators and imports managed clusters into ACM.
# Run this after 'terraform apply' completes successfully.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# -----------------------------------------------------------------------------
# Read Terraform outputs
# -----------------------------------------------------------------------------

echo "==> Reading Terraform outputs..."
DEMO_NAME=$(terraform output -raw demo_name)
RESOURCE_GROUP=$(terraform output -raw azure_resource_group)
HUB_NAME=$(terraform output -raw hub_cluster_name)
ROSA_CLUSTER_NAME=$(terraform output -raw rosa_cluster_name)
CLUSTER_B_NAME=$(terraform output -raw cluster_b_cluster_name)
HUB_API_URL=$(terraform output -raw hub_api_url)
CLUSTER_A_API_URL=$(terraform output -raw cluster_a_api_url)
CLUSTER_B_API_URL=$(terraform output -raw cluster_b_api_url)

# -----------------------------------------------------------------------------
# Get credentials
# -----------------------------------------------------------------------------

echo "==> Retrieving ARO credentials..."
HUB_PASSWORD=$(az aro list-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$HUB_NAME" \
  --query kubeadminPassword -o tsv)

CLUSTER_B_PASSWORD=$(az aro list-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name "$CLUSTER_B_NAME" \
  --query kubeadminPassword -o tsv)

echo "==> Creating ROSA admin user..."
ROSA_ADMIN_OUTPUT=$(rosa create admin --cluster="$ROSA_CLUSTER_NAME" --yes 2>&1 || true)

if echo "$ROSA_ADMIN_OUTPUT" | grep -q "already has an admin"; then
  echo "    Admin user already exists. Retrieve password from previous creation."
  echo "    If lost, run: rosa delete admin --cluster=$ROSA_CLUSTER_NAME && rosa create admin --cluster=$ROSA_CLUSTER_NAME"
  read -rp "    Enter Cluster A cluster-admin password: " CLUSTER_A_PASSWORD
else
  CLUSTER_A_PASSWORD=$(echo "$ROSA_ADMIN_OUTPUT" | grep -oP '(?<=--password )\S+' || echo "")
  if [[ -z "$CLUSTER_A_PASSWORD" ]]; then
    echo "    Could not parse ROSA admin password from output:"
    echo "$ROSA_ADMIN_OUTPUT"
    read -rp "    Enter Cluster A cluster-admin password manually: " CLUSTER_A_PASSWORD
  fi
fi

# -----------------------------------------------------------------------------
# Login and rename contexts
# -----------------------------------------------------------------------------

echo "==> Logging in to all clusters..."
oc login "$HUB_API_URL" --username cluster-admin --password "$HUB_PASSWORD" --insecure-skip-tls-verify=true
HUB_CTX=$(oc config current-context)
oc config rename-context "$HUB_CTX" hub 2>/dev/null || true

oc login "$CLUSTER_A_API_URL" --username cluster-admin --password "$CLUSTER_A_PASSWORD" --insecure-skip-tls-verify=true
CA_CTX=$(oc config current-context)
oc config rename-context "$CA_CTX" cluster-a 2>/dev/null || true

oc login "$CLUSTER_B_API_URL" --username kubeadmin --password "$CLUSTER_B_PASSWORD" --insecure-skip-tls-verify=true
CB_CTX=$(oc config current-context)
oc config rename-context "$CB_CTX" cluster-b 2>/dev/null || true

echo "==> Contexts configured:"
oc config get-contexts

# -----------------------------------------------------------------------------
# Install ACM on Hub
# -----------------------------------------------------------------------------

echo "==> Installing Red Hat Advanced Cluster Management on Hub..."

oc create namespace open-cluster-management --context hub 2>/dev/null || true

cat <<'EOF' | oc apply --context hub -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: open-cluster-management
  namespace: open-cluster-management
spec:
  targetNamespaces:
    - open-cluster-management
EOF

cat <<'EOF' | oc apply --context hub -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: advanced-cluster-management
  namespace: open-cluster-management
spec:
  channel: release-2.11
  name: advanced-cluster-management
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

echo "    Waiting for MultiClusterHub CRD (this may take 2-3 minutes)..."
until oc get crd multiclusterhubs.operator.open-cluster-management.io --context hub &>/dev/null; do
  sleep 10
done

cat <<'EOF' | oc apply --context hub -f -
apiVersion: operator.open-cluster-management.io/v1
kind: MultiClusterHub
metadata:
  name: multiclusterhub
  namespace: open-cluster-management
spec: {}
EOF

echo "    Waiting for MultiClusterHub to be ready (5-10 minutes)..."
oc wait multiclusterhub multiclusterhub \
  -n open-cluster-management \
  --for=condition=Complete \
  --timeout=900s \
  --context hub

echo "    ACM is ready."

# -----------------------------------------------------------------------------
# Install OpenShift GitOps on Hub
# -----------------------------------------------------------------------------

echo "==> Installing OpenShift GitOps on Hub..."

cat <<'EOF' | oc apply --context hub -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

echo "    Waiting for GitOps operator rollout..."
until oc get deployment openshift-gitops-server -n openshift-gitops --context hub &>/dev/null; do
  sleep 10
done
oc rollout status deployment/openshift-gitops-server -n openshift-gitops --context hub --timeout=300s

echo "    GitOps is ready."

# -----------------------------------------------------------------------------
# Import managed clusters into ACM
# -----------------------------------------------------------------------------

import_cluster() {
  local name=$1
  local context=$2

  echo "==> Importing $name into ACM..."

  # Create the ManagedCluster on the Hub
  cat <<EOF | oc apply --context hub -f -
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: $name
spec:
  hubAcceptsClient: true
EOF

  # Create KlusterletAddonConfig
  cat <<EOF | oc apply --context hub -f -
apiVersion: agent.open-cluster-management.io/v1
kind: KlusterletAddonConfig
metadata:
  name: $name
  namespace: $name
spec:
  clusterName: $name
  clusterNamespace: $name
  applicationManager:
    enabled: false
  certPolicyController:
    enabled: true
  policyController:
    enabled: true
  searchCollector:
    enabled: true
EOF

  # Wait for the import secret to be generated
  echo "    Waiting for import secret..."
  until oc get secret "${name}-import" -n "$name" --context hub &>/dev/null; do
    sleep 5
  done

  # Apply import CRDs and manifests on the managed cluster
  oc get secret "${name}-import" -n "$name" --context hub \
    -o jsonpath='{.data.crds\.yaml}' | base64 -d | oc apply --context "$context" -f -

  oc get secret "${name}-import" -n "$name" --context hub \
    -o jsonpath='{.data.import\.yaml}' | base64 -d | oc apply --context "$context" -f -

  echo "    Waiting for $name to join ACM..."
  oc wait managedcluster "$name" \
    --for=condition=ManagedClusterConditionAvailable \
    --timeout=300s \
    --context hub

  echo "    $name imported successfully."
}

import_cluster "cluster-a" "cluster-a"
import_cluster "cluster-b" "cluster-b"

# -----------------------------------------------------------------------------
# Configure ACM + GitOps integration (GitOpsCluster push model)
# -----------------------------------------------------------------------------

echo "==> Configuring ACM GitOps integration on Hub..."

cat <<'EOF' | oc apply --context hub -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: global
  namespace: openshift-gitops
spec:
  clusterSet: global
EOF

cat <<'EOF' | oc apply --context hub -f -
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: all-openshift-clusters
  namespace: openshift-gitops
spec:
  predicates:
    - requiredClusterSelector:
        labelSelector:
          matchLabels:
            vendor: OpenShift
EOF

cat <<'EOF' | oc apply --context hub -f -
apiVersion: apps.open-cluster-management.io/v1beta1
kind: GitOpsCluster
metadata:
  name: gitops-clusters
  namespace: openshift-gitops
spec:
  argoServer:
    cluster: local-cluster
    argoNamespace: openshift-gitops
  placementRef:
    kind: Placement
    apiVersion: cluster.open-cluster-management.io/v1beta1
    name: all-openshift-clusters
    namespace: openshift-gitops
EOF

echo "    Waiting for ArgoCD cluster secrets..."
until oc get secrets -n openshift-gitops -l argocd.argoproj.io/secret-type=cluster --context hub 2>/dev/null | grep -q cluster; do
  sleep 5
done

echo "    GitOps integration configured."

# -----------------------------------------------------------------------------
# Install OpenShift Service Mesh 3.0 on managed clusters
# -----------------------------------------------------------------------------

install_service_mesh() {
  local context=$1

  echo "==> Installing OpenShift Service Mesh 3.0 on $context..."

  cat <<'EOF' | oc apply --context "$context" -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator3
  namespace: openshift-operators
spec:
  channel: stable
  name: servicemeshoperator3
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

  echo "    Waiting for Service Mesh operator CSV..."
  until oc get csv -n openshift-operators --context "$context" 2>/dev/null | grep -q servicemesh; do
    sleep 10
  done
  echo "    Service Mesh operator installed on $context."
}

install_service_mesh "cluster-a"
install_service_mesh "cluster-b"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

echo ""
echo "============================================================================="
echo " Setup complete!"
echo "============================================================================="
echo ""
echo "Clusters:"
echo "  Hub (Azure):       $HUB_API_URL"
echo "  Cluster A (AWS):   $CLUSTER_A_API_URL"
echo "  Cluster B (Azure): $CLUSTER_B_API_URL"
echo ""
echo "Contexts are configured as: hub, cluster-a, cluster-b"
echo ""
echo "Workshop variables (paste into your terminal):"
echo ""
echo "  export HUB_API_URL=\"$HUB_API_URL\""
echo "  export CLUSTER_A_API_URL=\"$CLUSTER_A_API_URL\""
echo "  export CLUSTER_B_API_URL=\"$CLUSTER_B_API_URL\""
echo "  export GIT_REPO_URL=\"https://github.com/juanlu-sanz/multi-cluster-app-distribution-demo.git\""
echo "  export REMOTE_INGRESS_IP=\"<set after Submariner - see Step 2, sub-step 6>\""
echo ""
echo "Installed operators:"
echo "  Hub:       ACM 2.11, OpenShift GitOps"
echo "  Cluster A: Service Mesh 3.0"
echo "  Cluster B: Service Mesh 3.0"
echo ""
echo "Next: start the demo from 00-current-state/"
echo "============================================================================="
