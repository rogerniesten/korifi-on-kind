#! /bin/bash
#
# This script is supposed to install a service (instance) from a korifi marketplace
#

## Includes
scriptpath="$(dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/utils.sh"


strongly_advice_root



##
## Config
##
SERVICE_NAME=myservice




##
## Check prerequisits
##

# Is KIND kluster running?
assert "kubectl cluster-info --context kind-korifi | grep 'Kubernetes control plane is running'"

# Is Korifi up and running?
kubectl get pods -n korifi
#verify TODO: not working correctly
#assert "kubectl get pods -n korifi | grep 'Running'"

# get name and ip of korifi controller plane
CTRLPLANE_NAME='korifi-control-plane'
echo "Korifi-Control-Plane"
echo "- name : $CTRLPLANE_NAME"
CTRLPLANE_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CTRLPLANE_NAME")
echo "- IP   : $CTRLPLANE_IP"

assert "test '$CTRLPLANE_IP' != ''"

# Is helm installed?
assert helm version


##
## Cleanup
##
echo "Cleanup..."
echo " - remove service from marketplace"
if cf marketplace | grep -q "$SERVICE_NAME"; then
  cf disable-service-access myservice
fi
echo " - purge lingering service offering"
if cf marketplace | grep -q "$SERVICE_NAME"; then
  cf purge-service-offering "$SERVICE_NAME" -f
fi
echo " - remove servicebroker"
cf delete-service-broker mybroker -f
echo " - remove broker-service"
kubectl delete -f "$scriptpath/broker-service.yaml" --ignore-not-found=true
echo " - remove broker-deployment"
kubectl delete -f "$scriptpath/broker-deployment.yaml" --ignore-not-found=true
echo ""

## WORKAROUND
# For some reason the service brokers corresponding to the services are not correctly removed during cleanup!
# The following command searches for all services (name, guid, guid of related broker)
SVCS=$(cf curl /v3/service_offerings | jq '[.resources[] | {name: .name, guid: .guid, broker_guid: .relationships.service_broker.data.guid}]')
# Then get the gui of the service brokers
BROKER_GUIDS=$(cf curl /v3/service_brokers | jq '[ .resources[].guid ]')
# Now filter services for the ones that have related valid broker guid 
ORPHAN_SVCS=$(echo "$SVCS" | jq --argjson broker_guids "$BROKER_GUIDS" '.[] | select(.broker_guid as $b | $broker_guids | index($b) | not)')
echo " - remove orphaned service offerings (workaround)"
echo -n "   DEBUG:"
echo "$ORPHAN_SVCS" | jq -c
# Now loop over all orphans and remove them
echo "$ORPHAN_SVCS" | jq -c | while read -r svc; do
  #echo "Processing: $svc"
  ORPHAN_NAME=$(echo "$svc" | jq -r '.name')
  BROKER_GUID=$(echo "$svc" | jq -r '.broker_guid')
  BROKER_NAME=$(echo "$BROKER_GUIDS" | jq -r --arg guid "$BROKER_GUID" '.[] | select(.guid == $guid) | .name')
  echo "   -> Purging orphaned service offering: $ORPHAN_NAME (broker guid: $BROKER_GUID, broker name: $BROKER_NAME)"
  cf purge-service-offering "$ORPHAN_NAME" -b "$BROKER_NAME" -f
done

echo " - waiting for completion"
sleep 5 # just try 5 seconds
echo "...done"
echo ""





##
## Info about Korifi Marketplace
##


# Korifi is Cloud Foundry for Kubernetes, essentially a PaaS on top of Kubernetes. The "Korifi Marketplace" refers to services available for Korifi apps, similar to CF marketplace.
#
#🔧 Architecture:
#	- Also uses the Open Service Broker API, but operates within a Kubernetes-native environment.
#	- Devs still use cf CLI, but under the hood it's all Kubernetes.
#	- Services can be standard Kubernetes services or OSB-compatible ones.
#
#🧩 Use Cases:
#	- Teams moving from Cloud Foundry to Kubernetes without losing the CF dev experience.
#	- Running CF-style apps on Kubernetes clusters.
#	- Gradual transition to Kubernetes while retaining CF workflows.


# Where to Find OSB-Compatible MySQL for Korifi?

# Use a Public OSB-Compatible MySQL Broker
# You can deploy an OSB-compliant service broker in your Kubernetes cluster alongside Korifi. For MySQL, a few options include:
#
#	- Service Broker for MySQL				The classic CF MySQL broker. Might need tweaking to run on K8s.	https://github.com/cloudfoundry/cf-mysql-release
#	- Open Service Broker for Azure / GCP			Includes MySQL support, works with Kubernetes.	         	https://github.com/Azure/open-service-broker-azure
#	- OSB-Brokerpak from Terraform 				More advanced — supports MySQL via Terraform infrastructure.	https://github.com/cloudfoundry-incubator/terraform-provider-servicebroker

## Includes
scriptpath="$(dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/utils.sh"



##
## Config
##



strongly_advice_root




# Prepare folder for git repositories
mkdir -p "/home/%scriptpath${SUDO_USER}/git" 2>/dev/null
cd "/home/${SUDO_USER}/git/korifi-on-kind" || exit 99



##
## Run world's Simplest Service Broker in your Docker environment
##

# source: https://github.com/cloudfoundry-community/worlds-simplest-service-broker
CONTAINER_NAME="my-service-broker"

# Because kubernetes runs IN a docker container, the docker network is not reachable (by default) from the korifi pods in kubernetes!
# Therefore the service-broker will NOT be deployed as a docker container, but as a kubernetes pod (see below).

# Start container with service-broker
#docker run -d --name ${CONTAINER_NAME} \
#    -e BASE_GUID=$(uuidgen) \
#    -e CREDENTIALS='{"port": "4000", "host": "1.2.3.4"}' \
#    -e SERVICE_NAME=$SERVICE_NAME \
#    -e SERVICE_PLAN_NAME=shared \
#    -e TAGS='simple,shared' \
#    -e AUTH_USER=broker -e AUTH_PASSWORD=broker \
#    -p 9090:3000 cfcommunity/worlds-simplest-service-broker

# Wait until my-service-broker container is up&running
#echo -n "Waiting for $CONTAINER_NAME to be running."
#until [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == "true" ]; do
#  echo -n "."
#  sleep 1
#done
#echo "$CONTAINER_NAME is now running!"

# Wait until my-service-broker container is up&running
#echo -n "Waiting for $CONTAINER_NAME to be running."
#until [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == "true" ]; do
#  echo -n "."
#  sleep 1
#done
#echo "$CONTAINER_NAME is now running!"


# deploy the service-broker to kubernetes
kubectl apply -f "$scriptpath/broker-deployment.yaml"
kubectl apply -f "$scriptpath/broker-service.yaml"

# wait until the pods are running
echo "Waiting for pod to be ready..."
# shellcheck disable=SC2090	# it's a command, so all escaping is on purpose here
$SUDOCMD kubectl wait --for=create pods -l app=my-service-broker --timeout=300s
echo "All pods are ready. Proceeding with next steps..."


# check output of container when requesting service catalog
# Expected: something like this:
#	{
#	  "services": [
#	    {
#	      "id": "9e52543f-3974-4659-ba4f-f8db7abf32de-service-myservice",
#	      "name": "myservice",
#	      "description": "Shared service for myservice",
#	      "bindable": true,
#	      "instances_retrievable": false,
#	      "bindings_retrievable": false,
#	      "plan_updateable": false,
#	      "plans": [
#	        {
#	          "id": "9e52543f-3974-4659-ba4f-f8db7abf32de-plan-shared",
#	          "name": "shared",
#	          "description": "Shared service for myservice",
#	          "free": true
#	        }
#	      ],
#	      "metadata": {
#	        "displayName": "myservice"
#	      }
#	    }
#	  ]
#	}



## Test from within the K8s cluster

# Get the Name and IP of the broker pod
BROKER_NAME=$(kubectl get pods --no-headers -o custom-columns=":metadata.name" | grep "^${CONTAINER_NAME}")
echo "Broker-name : $BROKER_NAME"
BROKER_IP=$(kubectl get pod "${BROKER_NAME}" -o jsonpath='{.status.podIP}')

# WORKAROUND:
# Apparently the pod is NOT given an IP immediately after the pod is created.
# Therefore the .status.podIP is not immediately available after the previous kubectl wait command is finished
# So if the podID is empty, we'll have to retry (potentially a few times)
x=1
while [[ "$BROKER_IP" == "" ]];do
  #echo ""
  #echo "pod info:"
  #echo "========"
  #kubectl get pod ${BROKER_NAME} -o jsonpath='{}'
  #echo ""
  echo -n "Broker-IP not set yet! Waiting $x seconds before retrying ["
  for (( i=0; i<x; i++ )); do
    echo -n "."
    sleep 1
  done
  echo "]"
  BROKER_IP=$(kubectl get pod "${BROKER_NAME}" -o jsonpath='{.status.podIP}')
  x=$((x*2))
done
echo "Broker-IP   : $BROKER_IP"
echo ""


# Run a temporary Pod with crul on board to call the catalog api of the catalog
# Note that IP and port are different! Internal K8s network
BROKER_CATALOG_URL="http://${BROKER_IP}:3000/v2/catalog"
echo "Try to reach the broker URL ($BROKER_CATALOG_URL) from witin a k8s pod"
kubectl run curlpod --image=curlimages/curl -it --rm --restart=Never -- curl -s -u broker:broker "$BROKER_CATALOG_URL" -H 'X-Broker-API-Version: 2.3' | sed -n '1p' | jq
# Expected: same result as mentioned above
echo ""


#
# Create the service broker
#
echo "Create service broker 'mybroker'..."
cf -v create-service-broker mybroker broker broker "http://${BROKER_IP}:3000"
# Note that the IP and Port must be K8s (Korifi) Internal!!!
echo "...done"
echo ""

# Service broker can be removed by:
#	cf -v delete-service-broker mybroker -f


## Add the service to the marketplace
echo "Add service '$SERVICE_NAME' to the cf marketplace..."
cf enable-service-access "$SERVICE_NAME"
## NOTE:
#	First it didn't work:
#	Enabling access to all plans of service offering myservice for all orgs as kubernetes-admin...
#	Service 'myservice' is provided by multiple service brokers: ,
#	Specify a broker by using the '-b' flag.
#	FAILED
#	This was because there were still service-offerings although the corresponding broker was removed.
#	This has been fixed in a workaround immediately after the cleanup. Now it works fine :-)

# Verify
echo "Show service in Korifi marketplace:"
cf marketplace
# Expected: the service is listed by this command
echo ""
echo "Show details of $SERVICE_NAME"
cf marketplace -e "$SERVICE_NAME"


#
# Creating an instance of myservice
#

echo ""
echo "Creating a service instance of myservice..."
cf create-service "$SERVICE_NAME" shared "${SERVICE_NAME}-instance"
echo "...done"
echo ""


echo "Show list of service instances:"
cf services
echo ""

#echo "Show info of myservice-instance"
#cf service ${SERVICE_NAME}-instance
#echo ""


echo "Reaching this point without errors means that we have proofed that creating service instances via a service broker works in korifi"
echo ""
echo "End of script."
echo
exit
###############################################################################


##
## Remaining code are attempts that didn't work or ran into too many issues to continue
## These are left here for reference and archive
##





##
## MySQL via classic CF MySQL broker 
##

# Add bitnami helm chart repository for MySQL
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
# verify TODO:
assert "helm repo list | grep '^bitnami '"


#
# Following service brokers as suggested by ChatGPT are NOT existing (anymore):
#

#git clone https://github.com/cloudfoundry-community/mysql-broker
#git clone https://github.com/cloudfoundry/service-fabrik-broker


#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/service-catalog/master/charts/helm-broker/templates/deployment.yaml


#
# Following repos suggested by ChatGPT have been depricated (mostly in 2022, no following mentioned):
#

# https://github.com/kubernetes-retired/service-catalog (since 2022-05-06)
# https://github.com/Azure/open-service-broker-azure (since 2022-07-06)
# https://github.com/GoogleCloudPlatform/gcp-service-broker (since 2022-07-07)
# https://github.com/cloudfoundry/service-fabrik-broker (since 2025-01-29)




#
# Potential useful service brokers for korifi
#

# https://github.com/cloudfoundry/cloud-service-broker (OSBAPI-compliant service broker that uses OpenTofu (?) to create service instances. 
#	Used with Cloud Foundry and Kubernetes. 
#	Fork of gcp-service-broker

# NOPE, these are Kubernetes Service Brokers:
# https://github.com/AdeAttwood/service-broker
# https://github.com/dfilppi/service-broker 




# Install the MySQL Service Broker
helm install mysql-broker bitnami/mysql --namespace korifi
# to customize config set specify values, e.g.
# helm install my-mysql bitnami/mysql --set mysqlRootPassword=my-secret-pw
# verify
kubectl get pods -l app.kubernetes.io/name=mysql
kubectl get svc -l app.kubernetes.io/name=mysql

# Create a Service Instance
cf create-service mysql database-standard my-mysql-instance






exit 0


##
## MySQL via OSB for Azure
##

# Clone the repository
#git clone https://github.com/Azure/open-service-broker-azure.git
#cd open-service-broker-azure



## Corrections:

# Issue: 
#	helm dependency build causes:
# 	no repository definition for https://kubernetes-charts.storage.googleapis.com/
#
# Explanation:
#	This URL is deprecated — it was the default Helm stable chart repo used in Helm v2, but it’s been shut down.
#
# Fix/Workaround:
#	Add the stable repo from the new location
#helm repo add stable https://charts.helm.sh/stable
#helm repo update
#	Replace the deprecated URL with the new location
#sed -i 's/https:\/\/kubernetes-charts.storage.googleapis.com\//https:\/\/charts.bitnami.com\/bitnami' ./contrib/k8s/charts/open-service-broker-azure/requirements.lock
#sed -i 's/version: .*/version: 20.10.0' ./contrib/k8s/charts/open-service-broker-azure/requirements.lock
#
#sed -i 's/https:\/\/kubernetes-charts.storage.googleapis.com\//https:\/\/charts.bitnami.com\/bitnami' ./contrib/k8s/charts/open-service-broker-azure/requirements.yaml
#sed -i 's/version: .*/version: 20.10.0' ./contrib/k8s/charts/open-service-broker-azure/requirements.yaml
#
#helm dependency update ./contrib/k8s/charts/open-service-broker-azure

# Alternative workaround:
#	Download the dependencies manually
#helm fetch bitnami/redis --version 20.10.0
#	.. and install it in the same namespace
#helm install redis bitnami/redis --namespace osba



## Install required CRDs
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/service-catalog/master/deploy/crds/broker.crd.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/service-catalog/master/deploy/crds/serviceinstance.crd.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/service-catalog/master/deploy/crds/servicebinding.crd.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/service-catalog/master/deploy/crds/clusterservicebroker.crd.#yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/service-catalog/master/deploy/crds/clusterserviceinstance.crd.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/service-catalog/master/deploy/crds/clusterservicebinding.crd.yaml

#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/service-catalog/v0.3.0/deploy/crds/broker.crd.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/service-catalog/v0.3.0/deploy/crds/serviceinstance.crd.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/service-catalog/v0.3.0/deploy/crds/servicebinding.crd.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/service-catalog/v0.3.0/deploy/crds/clusterservicebroker.crd.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/service-catalog/v0.3.0/deploy/crds/clusterserviceinstance.crd.yaml
#kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/service-catalog/v0.3.0/deploy/crds/clusterservicebinding.crd.yaml






#
# Store the Azure Service Principle 'sp_korifi_osba' credentials in a korifi secret
# SP: https://portal.azure.com/#view/Microsoft_AAD_IAM/ManagedAppMenuBlade/~/Overview/objectId/bd0713ac-a153-463f-ac2d-e0cb24b642fa/appId/9160d903-8202-49bb-ae95-f9bd46986ae4
# epxires on 09-07-2025
#
#export AZURE_SUBSCRIPTION_ID=<enter value here>
#export AZURE_TENANT_ID=<enter value here>
#export AZURE_CLIENT_ID=<enter value here>
#export AZURE_CLIENT_SECRET=<enter value here>
#export AZURE_LOCATION=westeurope





# Install OSBA on Kubernetes (OSBA will act as a service broker)
#helm install osba ./contrib/k8s/charts/open-service-broker-azure   \
#	--namespace osba --create-namespace \
#	--set azure.subscriptionId=$AZURE_SUBSCRIPTION_ID \
#      	--set azure.tenantId=$AZURE_TENANT_ID   \
#	--set azure.clientId=$AZURE_CLIENT_ID   \
#	--set azure.clientSecret=$AZURE_CLIENT_SECRET   \
#	--set azure.location=$AZURE_LOCATION


# Create a values.yaml with the Azure credentials
#cat <<EOF >values.yaml
#azure:
#  tenantId: "$AZURE_TENANT_ID"
#  subscriptionId: "$AZURE_SUBSCRIPTION_ID"
#  clientId: "$AZURE_CLIENT_ID$"
#  clientSecret: "$AZURE_CLIENT_SECRET$"
#  location: "$AZURE_LOCATION"
#EOF


# Install OSBA in the korifi cluster
#? helm install osba osba/open-service-broker-azure -f values.yaml --namespace osba --create-namespace






exit 0


##
## Install the MySQL Database from the ernetes Marketplace
##

# Add bitnami helm chart repository for MySQL
#helm repo add bitnami https://charts.bitnami.com/bitnami
#helm repo update
# verify TODO: how?

# Install the MySQL chart
#helm install my-mysql bitnami/mysql
# to customize config set specify values, e.g.
# helm install my-mysql bitnami/mysql --set mysqlRootPassword=my-secret-pw
# verify
#kubectl get pods -l app.kubernetes.io/name=mysql
#kubectl get svc -l app.kubernetes.io/name=mysql

# Get credentials
#MYSQL_ROOT_PASSWORD=$(kubectl get secret --namespace default my-mysql -o jsonpath="{.data.mysql-root-password}" | base64 --decode)

# Get MySQL URL (TODO: make scriptable)
#kubectl get svc my-mysql

# Show required info
#echo "MySQL has been installed and can be tested from within the cluster with the following command:"
#echo ""
#echo "	kubectl run -i --tty --rm debug --image=mysql:5.7 --env MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD} -- mysql -h my-mysql -u root -p"
#echo ""
