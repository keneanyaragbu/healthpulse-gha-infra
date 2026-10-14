#!/bin/bash
# Phase 2 full bootstrap — ESO, OTel→Splunk, ARC, Kyverno, monitoring, ArgoCD.
set -euo pipefail

CLUSTER_NAME="healthpulse-dev"
REGION="us-east-1"
CONFIG_REPO="https://github.com/keneanyaragbu/healthpulse-gha-config.git"
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
SPLUNK_REALM="us1"

echo "==> [1] kubeconfig"
aws eks update-kubeconfig --region "${REGION}" --name "${CLUSTER_NAME}"
kubectl get nodes

echo "==> [2] clone config repo"
CONFIG_DIR=$(mktemp -d)
git clone "${CONFIG_REPO}" "${CONFIG_DIR}"

echo "==> [3] metrics-server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl rollout status deployment metrics-server -n kube-system --timeout=120s

echo "==> [4] Kyverno + verify-signature policy"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace --wait --timeout 5m
kubectl apply -f "${CONFIG_DIR}/kyverno/verify-image-signature.yaml"

echo "==> [5] AWS Load Balancer Controller"
LBC_ROLE_ARN=$(cd "${TF_DIR}" && terraform output -raw lbc_role_arn)
VPC_ID=$(cd "${TF_DIR}" && terraform output -raw vpc_id)
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set serviceAccount.create=true --set serviceAccount.name=aws-load-balancer-controller \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${LBC_ROLE_ARN}" \
  --set region="${REGION}" --set vpcId="${VPC_ID}" --wait --timeout 5m

echo "==> [6] External Secrets Operator + IRSA"
ESO_ROLE_ARN=$(cd "${TF_DIR}" && terraform output -raw eso_role_arn)
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --set installCRDs=true \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${ESO_ROLE_ARN}" \
  --wait --timeout 5m
# create namespaces the secrets land in BEFORE applying ExternalSecrets:
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace arc-systems --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${CONFIG_DIR}/external-secrets/secretstore.yaml"
kubectl apply -f "${CONFIG_DIR}/external-secrets/splunk-secret.yaml"
kubectl apply -f "${CONFIG_DIR}/external-secrets/arc-secret.yaml"
echo "    waiting for ESO to sync secrets..."
sleep 20
kubectl get secret splunk-token -n observability && kubectl get secret github-pat -n arc-systems

echo "==> [7] kube-prometheus-stack (Prometheus + Grafana)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring -f "${CONFIG_DIR}/k8s/monitoring-values.yaml" --wait --timeout 10m

echo "==> [8] OpenTelemetry Collector (traces + logs -> Splunk ${SPLUNK_REALM})"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  -n observability \
  --set mode=deployment \
  --set image.repository="otel/opentelemetry-collector-contrib" \
  --set presets.logsCollection.enabled=true \
  --set presets.kubernetesAttributes.enabled=true \
  -f "${CONFIG_DIR}/k8s/otel-collector-values.yaml" \
  --wait --timeout 5m

echo "==> [9] ARC (Actions Runner Controller) + runner scale set"
helm upgrade --install arc \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller \
  -n arc-systems --wait --timeout 5m
helm upgrade --install healthpulse-runners \
  oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set \
  -n arc-systems \
  --set githubConfigUrl="https://github.com/keneanyaragbu/healthpulse-gha" \
  --set githubConfigSecret="github-pat" \
  --set runnerScaleSetName="healthpulse-runners" \
  --wait --timeout 5m

echo "==> [10] ArgoCD + apps"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl rollout status deployment argocd-server -n argocd --timeout=300s
kubectl apply -f "${CONFIG_DIR}/argocd/healthpulse-dev.yaml"
kubectl apply -f "${CONFIG_DIR}/argocd/healthpulse-uat.yaml"
kubectl apply -f "${CONFIG_DIR}/argocd/healthpulse-prod.yaml"

rm -rf "${CONFIG_DIR}"
echo "==> DONE. ESO synced secrets, OTel->Splunk, ARC runners, Kyverno enforcing, ArgoCD deploying signed image."