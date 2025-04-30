#!/bin/bash

set -euo pipefail

# First do a cleanup (idempotency)

rm -rf ~/.kube/certs
kind delete clusters city-cluster


# Step 1: Create KIND cluster
echo "Creating KIND cluster..."
kind create cluster --name city-cluster

# Step 2: Create namespaces
echo "Creating namespaces..."
kubectl create namespace amsterdam
kubectl create namespace utrecht
kubectl create namespace rotterdam


# Step 3: Create users and credentials
# These are just demo users using client certs for auth
echo "Setting up users..."

create_user_cert() {
  USER=$1
  NAMESPACE=$2

  openssl genrsa -out "${USER}.key" 2048
  openssl req -new -key "${USER}.key" -out "${USER}.csr" -subj "/CN=${USER}"
  openssl x509 -req -in "${USER}.csr" -CA ~/.kube/certs/ca.crt -CAkey ~/.kube/certs/ca.key \
    -CAcreateserial -out "${USER}.crt" -days 365

  kubectl config set-credentials "${USER}" \
    --client-certificate="${USER}.crt" \
    --client-key="${USER}.key"

  kubectl config set-context "${USER}-context" \
    --cluster=kind-city-cluster \
    --namespace="${NAMESPACE}" \
    --user="${USER}"
}

# Simulate user certs (in a real case you'd use Kubernetes CSR API or proper CA)
mkdir -p ~/.kube/certs
# Get CA from cluster
kubectl config view --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > /root/.kube/certs/ca.crt
docker cp city-cluster-control-plane:/etc/kubernetes/pki/ca.key /root/.kube/certs/ca.key

# KIND now automatically merges kubeconfig to ~/.kube/config
# Backing up current kubeconfig
cp ~/.kube/config ~/.kube/kubeconfig-kind

# Create users
create_user_cert anton amsterdam
create_user_cert ursula utrecht
create_user_cert ron rotterdam

# Step 4: Create RBAC roles and bindings

create_rbac() {
  USER=$1
  NAMESPACE=$2

  kubectl create role "${USER}-viewer" \
    --verb=get,list,watch \
    --resource=pods \
    --namespace="${NAMESPACE}"

  kubectl create rolebinding "${USER}-binding" \
    --role="${USER}-viewer" \
    --user="${USER}" \
    --namespace="${NAMESPACE}"
}

create_rbac anton amsterdam
create_rbac ursula utrecht
create_rbac ron rotterdam

# Step 5: Create admin user with full cluster access
kubectl create clusterrolebinding admin-binding \
  --clusterrole=cluster-admin \
  --user=admin

# Step 6: Create dummy pods in each namespace
echo "Creating dummy pods..."
kubectl run nginx-amsterdam --image=nginx --restart=Never --namespace=amsterdam
kubectl run nginx-utrecht --image=nginx --restart=Never --namespace=utrecht
kubectl run nginx-rotterdam --image=nginx --restart=Never --namespace=rotterdam

echo "KIND cluster with RBAC demo is ready."
echo "Use 'kubectl config use-context anton-context' to switch to Anton, etc."

