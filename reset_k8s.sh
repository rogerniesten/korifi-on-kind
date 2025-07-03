#!/bin/bash

export BASELINE_CLUSTERROLES_FILE=tmp/default-clusterroles.txt
export BASELINE_CLUSTERROLEBINDINGS_FILE=tmp/default-clusterrolebindings.txt

if [[ ! -f "$BASELINE_CLUSTERROLES_FILE" ]];then echo "No baseline file for clusterroles found! Can't reset cluster!"; exit 99; fi
if [[ ! -f "$BASELINE_CLUSTERROLEBINDINGS_FILE" ]];then echo "No baseline file for clusterrolebindings found! Can't reset cluster!"; exit 99; fi


echo "Resetting K8s cluster to original state ($(date))"

# List of namespaces to preserve (AKS defaults + Calico)
PRESERVE_NS="^(kube-system|kube-public|kube-node-lease|default|azure-arc|calico-system|tigera-operator)$"

# Delete all other namespaces (i.e., from Korifi and anything user-installed)
for ns in $(kubectl get ns --no-headers | awk '{print $1}' | grep -vE "$PRESERVE_NS"); do
  echo "Deleting namespace: $ns"
  kubectl delete ns "$ns" --wait
done

# Delete all CustomResourceDefinitions (CRDs)
kubectl delete crd $(kubectl get crd -o name)

# Delete non-system ClusterRoles and ClusterRoleBindings
#while read cr; do
#  if ! grep -Fxq "$cr" "$BASELINE_CLUSTERROLES_FILE"; then
#    echo "Deleting ClusterRole: $cr"
#    kubectl delete clusterrole "$cr"
#  fi
#done < <(kubectl get clusterrole -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
#
#while read crb; do
#  if ! grep -Fxq "$crb" "$BASELINE_CLUSTERROLES_FILE"; then
#    echo "Deleting ClusterRoleBinding: $crb"
#    kubectl delete clusterrolebinding "$crb"
#  fi
#done < <(kubectl get clusterrolebinding -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')


# Delete all Mutating and Validating Webhooks
#kubectl delete mutatingwebhookconfiguration --all
#kubectl delete validatingwebhookconfiguration --all

# Delete non-core API services
#kubectl get apiservice -o name | grep -v 'v1.' | xargs kubectl delete

# Delete all StorageClasses (optional)
kubectl delete sc $(kubectl get sc -o name)

# Delete all Persistent Volume Claims in the 'default' namespace (or others if needed)
kubectl delete pvc --all -n default

echo "K8s cluster in clean state now"
