#! /bin/bash
# shellcheck disable=SC2086,SC2090	# all $SUDOCMD aliasses cause an ignorable error, hence disabling this check for all here
##
## Installation of a basic Korifi Cluster on AKS (Azure Kubernetes Service)

##

## Includes
scriptpath="$(dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/cf_utils.sh"
tmp="$scriptpath/tmp"
mkdir -p "$tmp"


##
## Config
##
prompt_if_missing K8S_TYPE "var" "Which K8S type to use? (KIND, AKS)"
prompt_if_missing K8S_CLUSTER_KORIFI "var" "Name of K8S Cluster for Korifi"
. .env || { echo "Config ERROR! Script aborted"; exit 1; }      # read config from environment file

# Script should be executed as root (just sudo fails for some commands)
strongly_advice_root


##
## Installing required tools
##

echo ""
echo ""
echo "---------------------------------------"
echo "Installing required tools"
echo "---------------------------------------"
echo ""

## GPG keys and repo sources are added in .env

install_if_missing apt jq jq "jq --version"
install_if_missing apt curl 
install_if_missing apt helm helm "helm version"
install_if_missing apt cf cf8-cli

install_if_missing apt snap snapd
install_if_missing snap yq yq "yq --version"
install_if_missing snap kubectl snap 

install_go_if_missing "${GO_VERSION}"

# Make sure kubenetes user and cf account are in sync
sync_k8s_user "$ADMIN_USERNAME"

## TODO: DO SOME CHECKS FOR PREREQUISITS !!!

# Is the specified K8S cluster available?
assert "kubectl config get-clusters | grep ${K8S_CLUSTER_KORIFI}"



##
## Install Korifi cluster
##



# Namespace creation (TODO: namespaces seem already to be existing, so these command seem to be superfluous and can be removed)
echo "Namespace creation"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $ROOT_NAMESPACE
  labels:
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/enforce: restricted
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $KORIFI_NAMESPACE
  labels:
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/enforce: restricted
EOF
echo ""


# based on: https://github.com/cloudfoundry/korifi/blob/main/INSTALL.md

#
# First install the prerequisits
#
echo ""
echo ""
echo "---------------------------------------"
echo "Installing prerequisits for Korifi"
echo "---------------------------------------"
echo ""


## Install Cert Manager
echo "Installing cert-manager..."
echo "TRC: kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.yaml"
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/v${CERT_MANAGER_VERSION}/cert-manager.yaml"
result=$?
# Wait until all cert-manager pods are ready
echo "Waiting for cert-manager pods to become ready..."
while true; do
  # shellcheck disable=SC2126   # grep -c not possible here as param -v is not combineable with -c
  NOT_READY=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -v 'Running' | grep -v 'Completed' | wc -l)
  TOTAL=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | wc -l)
  if [[ "$TOTAL" -gt 0 && "$NOT_READY" -eq 0 ]]; then
    echo "✅ All cert-manager pods are ready."
    break
  fi
  echo "⏳ Still waiting... ($((TOTAL - NOT_READY))/$TOTAL ready)"
  sleep 3
done
echo "...done"
echo ""


## Install kpack
install_kpack "$KPACK_VERSION"


## Install Contour Gateway
echo "Installing contour gateway..."
echo "- Contour Gateway Provisioner"
echo "TRC: kubectl apply -f https://raw.githubusercontent.com/projectcontour/contour/release-${CONTOUR_VERSION}/examples/render/contour-gateway-provisioner.yaml"
kubectl apply -f "https://raw.githubusercontent.com/projectcontour/contour/release-${CONTOUR_VERSION}/examples/render/contour-gateway-provisioner.yaml"
echo "- Contour Gateway Class"
echo "TRC: kubectl apply -f - <<EOF
kind: GatewayClass
apiVersion: gateway.networking.k8s.io/v1beta1
metadata:
  name: $GATEWAY_CLASS_NAME
spec:
  controllerName: projectcontour.io/gateway-controller
EOF"
kubectl apply -f - <<EOF
kind: GatewayClass
apiVersion: gateway.networking.k8s.io/v1beta1
metadata:
  name: $GATEWAY_CLASS_NAME
spec:
  controllerName: projectcontour.io/gateway-controller
EOF
#echo "Verify:"
# TODO: How?
echo "...done"
echo ""


## Install Metrics Server
kubectl get pods -A | grep metrics-server 1>/dev/null
metrics_server_installed=$?
if [[ $metrics_server_installed -eq 0 ]]; then
  # Metrics server is already installed implicitly on AKS
  echo "Metrics Server already installed, no action required"
else
  echo "Installing Metrics Server..."
  echo "TRC: kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  # verify
  echo "Verify:"
  # TODO: How?
  echo "...done"
fi




echo ""
echo ""
echo "---------------------------------------"
echo "Pre-install configuration"
echo "---------------------------------------"
echo ""

## Container registry credentials Secret
echo "Container registry credentials Secret"

# First ensure all required vars are populated
# Values will be stored in .env_docker_registry
# For localhost (kind), dummy values are sufficient
prompt_if_missing DOCKER_REGISTRY_SERVER		"var" "Docker Registry Server (e.g. ghcr.io)"					"$DOCKER_REGISTRY_ENV_FILE" 
prompt_if_missing DOCKER_REGISTRY_USERNAME              "var" "Username"								"$DOCKER_REGISTRY_ENV_FILE"
prompt_if_missing DOCKER_REGISTRY_PASSWORD              "var" "Password (for ghcr.io use PAT)"						"$DOCKER_REGISTRY_ENV_FILE"
prompt_if_missing DOCKER_REGISTRY_CONTAINER_REPOSITORY	"var" "Docker Container Registry (e.g. ghcr.io/rogerniesten/korifi)"		"$DOCKER_REGISTRY_ENV_FILE"
prompt_if_missing DOCKER_REGISTRY_BUILDER_REPOSITORY	"var" "Docker Builder Registry (e.g. ghcr.io/rogerniesten/korifi-kpack-builder"	"$DOCKER_REGISTRY_ENV_FILE"

# dummies are sufficient for pulling images from only public registries and they are required.
# So ALWAYS create this secret!
echo "DBG: kubectl create secret docker-registry image-registry-credentials \\
  --docker-username=\"$DOCKER_REGISTRY_USERNAME\" \\
  --docker-password=\"${DOCKER_REGISTRY_PASSWORD:1:4}**********\" \\
  --docker-server=\"$DOCKER_REGISTRY_SERVER\" \\
  -n \"$ROOT_NAMESPACE\""
kubectl delete secret image-registry-credentials -n "$ROOT_NAMESPACE" --ignore-not-found	# for idempotency
kubectl create secret docker-registry image-registry-credentials \
  --docker-username="$DOCKER_REGISTRY_USERNAME" \
  --docker-password="$DOCKER_REGISTRY_PASSWORD" \
  --docker-server="$DOCKER_REGISTRY_SERVER" \
  -n "$ROOT_NAMESPACE"
echo ""


## TLS certificates
#TODO: Currently SelfSigned certificates are generated via cert-manager, so no further action need at this moment





echo ""
echo ""
echo "---------------------------------------"
echo "Install Korifi"
echo "---------------------------------------"
echo ""

echo "helm upgrade --install korifi https://github.com/cloudfoundry/korifi/releases/download/v${KORIFI_VERSION}/korifi-${KORIFI_VERSION}.tgz \\
    --namespace=$KORIFI_NAMESPACE  \\
    --set=generateIngressCertificates=true \\
    --set=rootNamespace=$ROOT_NAMESPACE \\
    --set=adminUserName=$ADMIN_USERNAME \\
    --set=api.apiServer.url=$CF_API_DOMAIN \\
    --set=defaultAppDomainName=$CF_APPS_DOMAIN \\
    --set=containerRepositoryPrefix=$DOCKER_REGISTRY_CONTAINER_REPOSITORY \\
    --set=kpackImageBuilder.builderRepository=$DOCKER_REGISTRY_BUILDER_REPOSITORY \\
    --set=networking.gatewayClass=$GATEWAY_CLASS_NAME \\
    --set=networking.gatewayPorts.http=${CF_HTTP_PORT} \\
    --set=networking.gatewayPorts.https=${CF_HTTPS_PORT} \\
    --set experimental.managedServices.enabled=true \\
    --set=experimental.managedServices.trustInsecureBrokers=true \\
    --wait"

helm upgrade --install korifi "https://github.com/cloudfoundry/korifi/releases/download/v${KORIFI_VERSION}/korifi-${KORIFI_VERSION}.tgz" \
    --namespace="$KORIFI_NAMESPACE" \
    --set=generateIngressCertificates=true \
    --set=rootNamespace="$ROOT_NAMESPACE" \
    --set=adminUserName="$ADMIN_USERNAME" \
    --set=api.apiServer.url="$CF_API_DOMAIN" \
    --set=defaultAppDomainName="$CF_APPS_DOMAIN" \
    --set=containerRepositoryPrefix="$DOCKER_REGISTRY_CONTAINER_REPOSITORY" \
    --set=kpackImageBuilder.builderRepository="$DOCKER_REGISTRY_BUILDER_REPOSITORY" \
    --set=networking.gatewayClass="$GATEWAY_CLASS_NAME" \
    --set=networking.gatewayPorts.http="${CF_HTTP_PORT}" \
    --set=networking.gatewayPorts.https="${CF_HTTPS_PORT}" \
    --set experimental.managedServices.enabled=true \
    --set=experimental.managedServices.trustInsecureBrokers=true \
    --wait
    # In KIND following params are set different (https://github.com/cloudfoundry/korifi/releases/latest/download/install-korifi-kind.yaml)
    # TODO: In case of issues in KIND with this install script, concider changing the values of these params
#    --set=api.apiServer.url="localhost" \
#    --set=defaultAppDomainName="apps-127-0-0-1.nip.io" \
#    --set=containerRepositoryPrefix=europe-docker.pkg.dev/my-project/korifi/ \\
#    --set=kpackImageBuilder.builderRepository=europe-docker.pkg.dev/my-project/korifi/kpack-builder \\
    # In KIND following params are set additionally (https://github.com/cloudfoundry/korifi/releases/latest/download/install-korifi-kind.yaml)
    # TODO: In case of issues in KIND with this install script, concider adding
#    --set=logLevel="debug" \
#    --set=debug="false" \
#    --set=stagingRequirements.buildCacheMB="1024" \
#    --set=controllers.taskTTL="5s" \
#    --set=jobTaskRunner.jobTTL="5s" \
#+    --set=networking.gatewayPorts.http="32080" \
#+    --set=networking.gatewayPorts.https="32443" \

result=$?
if [[ "$result" -ne "0" ]]; then echo "Helm deployment of Korifi cluster failed! Script aborted!"; exit 1; fi


# Wait for all pods in the korifi namespace to be ready
kubectl wait --for=condition=Ready pods --all --namespace korifi --timeout=450s
# Verify
assert cf version





echo ""
echo ""
echo "---------------------------------------"
echo "Post Install Configuration"
echo "---------------------------------------"
echo ""


# DNS
echo "Apply DNS and gateway configuration"
# For static gateway
# kubectl get service envoy -n projectcontour -ojsonpath='{.status.loadBalancer.ingress[0]}'
# For dynamic gateway
echo "kubectl get service envoy-korifi -n korifi-gateway -ojsonpath='{.status.loadBalancer.ingress[0]}'"
kubectl get service envoy-korifi -n korifi-gateway -ojsonpath='{.status.loadBalancer.ingress[0]}'
KORIFI_IP=$(kubectl get service envoy-korifi -n korifi-gateway -ojsonpath='{.status.loadBalancer.ingress[0].ip}')
KORIFI_IP=${KORIFI_IP:-::1}	# hose localhost address as backup (for KIND cluster) (Note: IPv6 is used as IPv4 port 443 fails cq. is in use)
assert test -n "$KORIFI_IP"

# Add domain to /etc/hosts in case it is not handled at a DNS server
# For Korifi on a KIND cluster the api is on localhosts, which is already configured in /etc/hosts
echo ""
echo "Add following to /etc/hosts for every machine you want to access the K8S cluster from:"
echo "${KORIFI_IP}	$CF_API_DOMAIN  $CF_APPS_DOMAIN # for korifi cluster $K8S_CLUSTER_KORIFI"
if grep "${CF_API_DOMAIN}" /etc/hosts;then
  # replace existing entry
  $SUDOCMD sed -i "s/.*	${CF_API_DOMAIN}/${KORIFI_IP}	${CF_API_DOMAIN}/" /etc/hosts
else
  # add new entry
  add_to_etc_hosts "${KORIFI_IP}	$CF_API_DOMAIN	$CF_APPS_DOMAIN	# for korifi cluster $K8S_CLUSTER_KORIFI"
  echo "(already done for this machine)"
fi
echo ""

# Add a HTTPRoute to Kubernetes to use korifi-api
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: HTTPRoute
metadata:
  name: korifi-api
  namespace: korifi-gateway
spec:
  parentRefs:
    - name: korifi
      namespace: korifi-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: korifi-api-svc
          namespace: korifi
          port: 443
EOF



## Create certificates for cf-admin
echo "Create certificates for '$ADMIN_USERNAME'"
create_k8s_user_cert "$ADMIN_USERNAME"

# It seems that cf-admin has not the clusterrole cluster-admin in KIND, which is required for several 
# actions.
# Therefore it will be configure here explicitly
  echo "Apply admin authorization for ${ADMIN_USERNAME}"
  ## apply korifi-admin role to cf-admin
  kubectl apply -f - <<EOF
  apiVersion: rbac.authorization.k8s.io/v1
  kind: ClusterRoleBinding
  metadata:
    name: ${ADMIN_USERNAME}-binding
  subjects:
  - kind: User
    name: ${ADMIN_USERNAME}  # <-- must match CN in certificate!
    apiGroup: rbac.authorization.k8s.io
  roleRef:
    kind: ClusterRole
    name: cluster-admin
    apiGroup: rbac.authorization.k8s.io
EOF



# TODO: Workaround for KIND!!!
# The cf api nor k8s load balancer (for apps) is reachable from the host
# As a workaround, let's run a background process to handle the port forwarding. 
if [[ "${K8S_TYPE^^}" == "KIND" ]];then
  forwarding_logfile=forwarding_$(date +"%y%m%d-%H%M").log
  touch "$forwarding_logfile"
  echo ""
  echo "As a workaround, K8s port-fording is started:"
  echo ""
  echo "- for api traffic (port 443):"
  echo ""
  echo "    nohup $SUDOCMD kubectl port-forward -n korifi --address ::1 svc/korifi-api-svc 443:443 >> ${forwarding_logfile} 2>&1 &"
  echo ""
  echo "- for apps traffic (port $CF_HTTP_SPORT):"
  echo ""
  echo "    nohup $SUDOCMD kubectl port-forward -n korifi-gateway --address ::1 svc/envoy-korifi $CF_HTTPS_PORT:$CF_HTTPS_PORT >> ${forwarding_logfile} 2>&1 &"
  echo ""
  echo "$(date): Starting background job for CF API port-forwarding port 443" >> "${forwarding_logfile}"
  echo "$(date): Starting background job for CF APPS port-forwarding port $CF_HTTPS_PORT" >> "${forwarding_logfile}"
  nohup $SUDOCMD kubectl port-forward --kubeconfig ~/.kube/config -n korifi --address ::1 svc/korifi-api-svc 443:443 >> "${forwarding_logfile}" 2>&1 &
  nohup $SUDOCMD kubectl port-forward --kubeconfig ~/.kube/config -n korifi-gateway --address ::1 svc/envoy-korifi "$CF_HTTPS_PORT:$CF_HTTPS_PORT" >> "${forwarding_logfile}" 2>&1 &
  reset	# reset the terminal as it might be scrambled after the nohup & commands
  echo ""
  echo "Background processes regarding port forwarding:"
  pgrep -f -a 'kubectl port-forward'
  echo "Find logs in $(pwd)/forwarding.log"
  echo ""
fi





echo ""
echo "---------------------------------------"
echo "Korifi installation complete."
echo "---------------------------------------"
echo "Info:"
echo " - K8S Cluster:	$K8S_CLUSTER_KORIFI"
#echo " - K8S Domain:	$(az aks list | jq -r ".[] | select(.name == \"$K8S_CLUSTER_KORIFI\") | .azurePortalFqdn")"
echo " - API endpoint:  $CF_API_DOMAIN"
echo " - CF Admin:      $ADMIN_USERNAME"
echo " - CS IP:		$KORIFI_IP"
echo "---------------------------------------"
echo ""

##
## Login to Korifi as admin and show some demoe results
##

echo "cf api https://${CF_API_DOMAIN} --skip-ssl-validation"
cf api "https://${CF_API_DOMAIN}" --skip-ssl-validation
echo "cf login -u ${ADMIN_USERNAME} -a https://${CF_API_DOMAIN} --skip-ssl-validation"
cf login -u "${ADMIN_USERNAME}" -a "https://${CF_API_DOMAIN}" --skip-ssl-validation

# create a default org and default space
cf create-org org
cf create-space -o org space
cf target -o org -s space


#
# End message
#
echo ""
echo "======== Korifi install finished ========"
echo ""
echo ""

