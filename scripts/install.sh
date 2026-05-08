#!/bin/bash
set -e

ARGO_NS="argocd"
DEV_NS="dev"
CLUSTER_NAME="iot-cluster"
ARGO_VERSION="v2.10.5"

echo "==> [1/6] Installing dependencies ..."
apt-get update -qq
apt-get install -y -qq curl wget git apt-transport-https ca-certificates gnupg lsb-release

# Docker
if ! command -v docker &>/dev/null; then
  echo "==> Installing Docker ..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io
  usermod -aG docker $(logname)
fi

# kubectl
if ! command -v kubectl &>/dev/null; then
  echo "==> Installing kubectl ..."
  curl -fsSLo /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x /usr/local/bin/kubectl
fi

# K3d
if ! command -v k3d &>/dev/null; then
  echo "==> Installing K3d ..."
  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

echo "==> [2/6] Creating K3d cluster ..."
k3d cluster delete ${CLUSTER_NAME} 2>/dev/null || true
k3d cluster create ${CLUSTER_NAME} \
  --agents 2 \
  --port "8888:30080@loadbalancer" \
  --port "8443:30443@loadbalancer" \
  --wait

CURRENT_USER=$(logname)
mkdir -p /home/${CURRENT_USER}/.kube
cp /root/.kube/config /home/${CURRENT_USER}/.kube/config
chown ${CURRENT_USER}:${CURRENT_USER} /home/${CURRENT_USER}/.kube/config
export KUBECONFIG=/home/${CURRENT_USER}/.kube/config

echo "==> [3/6] Creating namespaces ..."
kubectl create namespace ${ARGO_NS}  --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace ${DEV_NS}   --dry-run=client -o yaml | kubectl apply -f -

echo "==> [4/6] Installing Argo CD ..."
kubectl apply -n ${ARGO_NS} -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml

echo "==> Waiting for Argo CD pods to be ready ..."
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n ${ARGO_NS} --timeout=300s

echo "==> [5/6] Applying Argo CD Application manifest ..."
kubectl apply -f "$(dirname "$0")/../confs/argocd-app.yaml"

echo "==> [6/6] Patching argocd-server service to NodePort ..."
kubectl patch svc argocd-server -n ${ARGO_NS} \
  -p '{"spec":{"type":"NodePort","ports":[{"port":443,"targetPort":8080,"nodePort":30443}]}}'

ARGO_PASS=$(kubectl -n ${ARGO_NS} get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "======================================"
echo " Argo CD is ready!"
echo " URL  : https://localhost:8443"
echo " User : admin"
echo " Pass : ${ARGO_PASS}"
echo "======================================"