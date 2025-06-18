#! /bin/bash
# shellcheck disable=SC2086,SC2090	# all $SUDOCMD aliasses cause an ignorable error, hence disabling this check for all here
##
## Install a local Docker Registry that contains all required images for Korifi and demo's

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
K8S_TYPE=${K8S_TYPE:-AKS}			# env requires this var, but this script doesn't, so any value is fine
K8S_CLUSTER_KORIFI=${K8S_CLUSTER_KORIFI:-dummy}	# env requires this var, but this script doesn't, so any value is fine
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

install_if_missing apt curl 
install_if_missing apt snap snapd
install_if_missing snap kubectl
install_if_missing apt nginx
install_if_missing apt certbot


# Ensure required env vars are populated
prompt_if_missing LOCAL_IMAGE_REGISTRY "var" "Name of local Image Registry in Azure (e.g. my-local-registry)"	"$AZ_ENV_FILE"



##
## Expose the registry port to the outside world and set the domain as LOCAL_IMAGE_REGISTRY_FQDN
##

function publish_image_registry() {
  # get name of resource group
  az_resource_group=$(az vm list --query "[?name=='$(hostname)'].resourceGroup" -o tsv)
  # get the name of the network interface
  az_network_interface_id=$(az vm show --resource-group $az_resource_group --name $(hostname) --query "networkProfile.networkInterfaces[0].id" -o tsv)
  # get the public IP resource ID
  az_public_ip_resource_id=$(az network nic show --ids $az_network_interface_id --query "ipConfigurations[0].publicIPAddress.id" -o tsv)
  # set a domain name
  az network public-ip update --ids $az_public_ip_resource_id --dns-name "$LOCAL_IMAGE_REGISTRY"
  # verify
  registry_fqdn=$(az network public-ip show --ids $az_public_ip_resource_id --query "dnsSettings.fqdn" -o tsv)
  echo "Image registry accessible as: $registry_fqdn:5000"
  echo ""

  export LOCAL_IMAGE_REGISTRY_FQDN="$registry_fqdn"
  save_env_var "LOCAL_IMAGE_REGISTRY_FQDN" "$registry_fqdn" "$AZ_ENV_FILE"
}

function configure_nginx() {

  # increase bucket size to support long urls
  sudo sed -i 's/server_names_hash_bucket_size .*/server_names_hash_bucket_size 128;/g'		/etc/nginx/nginx.conf
  sudo sed -i 's/\# server_names_hash_bucket_size .*/server_names_hash_bucket_size 128;/g'	/etc/nginx/nginx.conf
  # server_names_hash_bucket_size

  # optain the required SSL certificate
  echo -e "sudo certbot certonly \\ \n
          --standalone \\ \n
          --non-interactive \\ \n
          --agree-tos \\ \n
          --email dummy@example.com \\ \n
          -d ${LOCAL_IMAGE_REGISTRY_FQDN}"
  sudo certbot certonly \
          --standalone \
          --non-interactive \
          --agree-tos \
          --email dummy@example.com \
          -d "${LOCAL_IMAGE_REGISTRY_FQDN}"

  # add nginx configfile for image registry in docker
  sudo tee /etc/nginx/sites-available/docker-registry > /dev/null <<EOF
server {
    listen 443 ssl;
    server_name ${LOCAL_IMAGE_REGISTRY_FQDN};

    ssl_certificate /etc/letsencrypt/live/${LOCAL_IMAGE_REGISTRY_FQDN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${LOCAL_IMAGE_REGISTRY_FQDN}/privkey.pem;

    location / {
        proxy_pass http://localhost:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}

server {
    listen 80;
    server_name ${LOCAL_IMAGE_REGISTRY_FQDN};

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

  # Enable the config
  if [[ ! -d /etc/nginx/sites-enabled/ ]]; then
    sudo ln -s /etc/nginx/sites-available/docker-registry /etc/nginx/sites-enabled/
  fi
  sudo nginx -t
  sudo systemctl start nginx
}


##
## Install a local Docker Registry (and give it a name)
##
local_registry_container=$($SUDOCMD docker ps -a --filter name=registry | grep registry)
echo "Found following registry container in docker:"
echo $local_registry_container

if [[ -n "$local_registry_container" ]]; then
  if [[ "$local_registry_container" != *"Up "* ]]; then
    # remove container if not running
    echo "Cleaning up non-running container."
    echo $local_registry_container
    # now remove it
    $SUDOCMD docker rm registry
  fi

  # start local registry container in Docker
  $SUDOCMD docker run -d -p 5000:5000 --name registry registry:2

  # Show result
  $SUDOCMD docker ps -a
fi

publish_image_registry
configure_nginx



##
## Populate local registry with required images
##
function copy_image_to_local_registry() {
  local registry=$1
  local image=$2
  local target_registry=${3:-$LOCAL_IMAGE_REGISTRY_FQDN}
  
  echo "$SUDOCMD docker pull $image"
  $SUDOCMD docker pull "$image"			# pull the image from docker hub
  echo "$SUDOCMD docker tag $image ${target_registry}/${image}"
  $SUDOCMD docker tag "$image" "${target_registry}/${image}"	# tag the image
  echo "$SUDOCMD docker push ${target_registry}/${image}"
  $SUDOCMD docker push "${target_registry}/${image}"		# push the image to the local hub

  # remove the images (from remote and from local)
  echo "$SUDOCMD docker image rm $image"
  $SUDOCMD docker image rm "$image"
  $SUDOCMD docker image rm "${target_registry}/${image}"
  echo "---------------------"
}



# Copy Korifi images from docker.io
copy_image_to_local_registry "$DOCKER_IMAGE_REGISTRY" "$KORIFI_HELM_HOOKSIMAGE"
copy_image_to_local_registry "$DOCKER_IMAGE_REGISTRY" "$KORIFI_API_IMAGE"
copy_image_to_local_registry "$DOCKER_IMAGE_REGISTRY" "$KORIFI_CONTROLLERS_IMAGE"
copy_image_to_local_registry "$DOCKER_IMAGE_REGISTRY" "$KORIFI_KPACKBUILDER_IMAGE"
copy_image_to_local_registry "$DOCKER_IMAGE_REGISTRY" "$KORIFI_STATEFULSETRUNNER_IMAGE"
copy_image_to_local_registry "$DOCKER_IMAGE_REGISTRY" "$KORIFI_JOBSTASKRUNNER_IMAGE"

# Copy contour envoy images from docker.io
copy_image_to_local_registry "$DOCKER_IMAGE_REGISTRY" "$CONTOUR_ENVOY_IMAGE"

# Copy contour images from ghcr.io
copy_image_to_local_registry "$GHCR_IMAGE_REGISTRY" "$CONTOUR_CONTOUR_IMAGE"

# Copy kpack images from ghcr.io
copy_image_to_local_registry "$GHCR_IMAGE_REGISTRY" "$KPACK_CONTROLLER_IMAGE"
copy_image_to_local_registry "$GHCR_IMAGE_REGISTRY" "$KPACK_WEBHOOK_IMAGE"
copy_image_to_local_registry "$GHCR_IMAGE_REGISTRY" "$KPACK_BUILD_INIT"
copy_image_to_local_registry "$GHCR_IMAGE_REGISTRY" "$KPACK_BUILD_WAITER"
copy_image_to_local_registry "$GHCR_IMAGE_REGISTRY" "$KPACK_REBASE"
copy_image_to_local_registry "$GHCR_IMAGE_REGISTRY" "$KPACK_COMPLETION"
copy_image_to_local_registry "$GHCR_IMAGE_REGISTRY" "$KPACK_LIVECYCLE"


# Copy cert manager images from quay.io
copy_image_to_local_registry "$QUAY_IMAGE_REGISTRY" "$CERT_MGR_CONTROLLER_IMAGE"
copy_image_to_local_registry "$QUAY_IMAGE_REGISTRY" "$CERT_MGR_WEBHOOK_IMAGE"
copy_image_to_local_registry "$QUAY_IMAGE_REGISTRY" "$CERT_MGR_CAINJECTOR_IMAGE"
copy_image_to_local_registry "$QUAY_IMAGE_REGISTRY" "$CERT_MGR_ACMESOLVER_IMAGE"



#
# End message
#
echo ""
echo "======== End of Script ========"
echo ""
echo ""

