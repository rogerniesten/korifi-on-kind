#! /bin/bash

##
## Demo Pushing buildbacks to Korifi
##

## Includes
scriptpath="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
. "$scriptpath/../env/.env"
. "$LIB_PATH/cf_utils.sh"


##
## Config
##

# logging
export log_level="$LOG_TRC"
export show_timestamp=false
export log_commands_always=true

# korifi
prompt_if_missing K8S_TYPE "var" "Which K8S type to use? (KIND, AKS)"
prompt_if_missing K8S_CLUSTER_KORIFI "var" "Name of K8S Cluster for Korifi"
. "$ENV_PATH/.env_korifi" || { echo "Config ERROR! Script aborted"; exit 1; }      # read config from environment file

# Script should be executed as root (just sudo fails for some commands)
strongly_advice_root


##
## Check prerequisits
##
log "$LOG_INF" "Check prerequisits..."
# Are all required tools available?
assert jq --version
assert go version
assert kubectl version
assert helm version
assert cf --version

# Make sure kubenetes user and cf account are in sync
sync_k8s_user "$ADMIN_USERNAME"


# Is KIND kluster running?
assert "kubectl cluster-info | grep 'Kubernetes control plane is running'"

# Is Korifi up and running?
cf api "https://${CF_API_DOMAIN}" --skip-ssl-validation
cf login -u "${ADMIN_USERNAME}" -o org -s space
cf target -o org -s space

kubectl get pods -n korifi
assert "kubectl get pods -n korifi | grep Running"

ensure_korifi_ready

echo "...done"




##
## Starts buildpacks demo
##

# Based on: https://tutorials.cloudfoundry.org/cf4devs/getting-started/first-push/

# Note:
#	This tutorial is based on Cloud Foundry, not on Korifi!
#	Expectation is that there will be some tweaks required to get it working.

#First attempt:
#$cf push

# Result:
#root@korifi-dev2:/home/rniesten/git/korifi-on-kind/applications/first-push# cf push
#Pushing app first-push to org org / space space as kubernetes-admin...
#Applying manifest file /home/rniesten/git/korifi-on-kind/applications/first-push/manifest.yml...
#
#Updating with these attributes...
#  ---
#  applications:
#  - name: first-push
#    disk-quota: 64M
#    instances: 1
#    memory: 32M
#    random-route: true
#    buildpacks:
#    - staticfile_buildpack
#Manifest applied
#Packaging files to upload...
#Uploading files...
# 63.22 KiB / 63.22 KiB [==============================================================] 100.00% 1s
#
#Waiting for API to complete processing files...
#
#Staging app and tracing logs...
#Failed to retrieve logs from Log Cache: unexpected status code 404
#InvalidBuildpacks: buildpack "staticfile_buildpack" not present in default ClusterStore. See `cf buildpacks`
#FAILED
#root@korifi-dev2:/home/rniesten/git/korifi-on-kind/applications/first-push# cf buildpacks
#Getting buildpacks as kubernetes-admin...
#
#position   name                         stack                        enabled   locked   state   filename
#1          paketo-buildpacks/java       io.buildpacks.stacks.jammy   true      false            paketo-buildpacks/java@18.6.0
#2          paketo-buildpacks/go         io.buildpacks.stacks.jammy   true      false            paketo-buildpacks/go@4.15.4
#3          paketo-buildpacks/nodejs     io.buildpacks.stacks.jammy   true      false            paketo-buildpacks/nodejs@7.7.0
#4          paketo-buildpacks/ruby       io.buildpacks.stacks.jammy   true      false            paketo-buildpacks/ruby@0.47.6
#5          paketo-buildpacks/procfile   io.buildpacks.stacks.jammy   true      false            paketo-buildpacks/procfile@5.11.0


# So it turns out this is not working as is. 
# Removing the buildpacks item (which apparently causes the error) as a completely empty buildpack.
# The folder is copied to first-push-v2 and manifest is altered.

# Result:
#
#root@korifi-dev2:/home/rniesten/git/korifi-on-kind/applications/first-push-v2# cf push
#Pushing app first-push to org org / space space as kubernetes-admin...
#Applying manifest file /home/rniesten/git/korifi-on-kind/applications/first-push-v2/manifest.yml...
#
#Updating with these attributes...
#  ---
#  applications:
#  - name: first-push
#    disk-quota: 64M
#    instances: 1
#    memory: 32M
#    random-route: true
#Manifest applied
#Packaging files to upload...
#Uploading files...
# 63.22 KiB / 63.22 KiB [==========================================================================] 100.00% 1s
#
#Waiting for API to complete processing files...
#
#Staging app and tracing logs...
#   Build reason(s): CONFIG
#   CONFIG:
#        + env:
#        + - name: VCAP_APPLICATION
#        +   valueFrom:
#        +     secretKeyRef:
#        +       key: VCAP_APPLICATION
#        +       name: fc36a3bb-a55f-4167-9864-0f1a8ee17fb0-vcap-application
#        + - name: VCAP_SERVICES
#        +   valueFrom:
#        +     secretKeyRef:
#        +       key: VCAP_SERVICES
#        +       name: fc36a3bb-a55f-4167-9864-0f1a8ee17fb0-vcap-services
#        resources: {}
#        - source: {}
#        + source:
#        +   registry:
#        +     image: localregistry-docker-registry.default.svc.cluster.local:30050/fc36a3bb-a55f-4167-9864-0f1a8ee17fb0-packages@sha256:1e71848c808df4836eeb4d48df6738d68a61cab95ff91b901a49e1452feada25
#        +     imagePullSecrets:
#        +     - name: image-registry-credentials
#   Loading registry credentials from service account secrets
#   Loading secret for "localregistry-docker-registry.default.svc.cluster.local:30050" from secret "image-registry-credentials" at location "/var/build-secrets/image-registry-credentials"
#   Loading cluster credential helpers
#   Pulling localregistry-docker-registry.default.svc.cluster.local:30050/fc36a3bb-a55f-4167-9864-0f1a8ee17fb0-packages@sha256:1e71848c808df4836eeb4d48df6738d68a61cab95ff91b901a49e1452feada25...
#   Successfully pulled localregistry-docker-registry.default.svc.cluster.local:30050/fc36a3bb-a55f-4167-9864-0f1a8ee17fb0-packages@sha256:1e71848c808df4836eeb4d48df6738d68a61cab95ff91b901a49e1452feada25 in path "/workspace"
#   Image with name "localregistry-docker-registry.default.svc.cluster.local:30050/fc36a3bb-a55f-4167-9864-0f1a8ee17fb0-droplets" not found
#   target distro name/version labels not found, reading /etc/os-release file
#   ======== Output: paketo-buildpacks/leiningen@4.12.0 ========
#   SKIPPED: project.clj could not be found in /workspace/project.clj
#   ======== Output: paketo-buildpacks/clojure-tools@2.15.0 ========
#   SKIPPED: no 'deps.edn' file found in the application path
#   ======== Output: paketo-buildpacks/gradle@7.18.0 ========
#     Build Configuration:
#       $BP_EXCLUDE_FILES                                                                       colon separated list of glob patterns, matched source files are removed
#       $BP_GRADLE_ADDITIONAL_BUILD_ARGUMENTS                                                   the additionnal arguments (appended to BP_GRADLE_BUILD_ARGUMENTS) to pass to Gradle
#       $BP_GRADLE_BUILD_ARGUMENTS             --no-daemon -Dorg.gradle.welcome=never assemble  the arguments to pass to Gradle
#       $BP_GRADLE_BUILD_FILE                                                                   the location of the main build config file, relative to the application root
#       $BP_GRADLE_BUILT_ARTIFACT              build/libs/*.[jw]ar                              the built application artifact explicitly.  Supersedes $BP_GRADLE_BUILT_MODULE
#       $BP_GRADLE_BUILT_MODULE                                                                 the module to find application artifact in
#       $BP_GRADLE_INIT_SCRIPT_PATH                                                             the path to a Gradle init script file
#       $BP_INCLUDE_FILES                                                                       colon separated list of glob patterns, matched source files are included
#       $BP_JAVA_INSTALL_NODE                  false                                            whether to install Yarn/Node binaries based on the presence of a package.json or yarn.lock file
#       $BP_NODE_PROJECT_PATH                                                                   configure a project subdirectory to look for `package.json` and `yarn.lock` files
#   SKIPPED: No plans could be resolved
#   ======== Output: paketo-buildpacks/sbt@6.18.1 ========
#   SKIPPED: build.sbt could not be found in /workspace/build.sbt
#   ======== Output: paketo-buildpacks/executable-jar@6.13.0 ========
#     Build Configuration:
#       $BP_EXECUTABLE_JAR_LOCATION         a glob specifying which jar files should be used
#       $BP_LIVE_RELOAD_ENABLED      false  enable live process reload in the image

# Evaluation / Conclusion:
# Several parts have been skipped due to missing files. Although no explicit error has been reported, I'm 
# not convinced this run can be concluded to be succesfull (for the parts that have been executed...
# The logs of the build show a lot of skips and fails, so doesn't seem to be ok....


############


# Instead of continuing the approach to "fix" the cloudfoundry tutorial, I've searched for a korifi tutorial 
# for buildpacks. So let's continue with one of those.
# Based on: https://dzone.com/articles/deploying-python-and-java-applications-to-kubernet

# Some additional requirements

# kbld installation
# https://carvel.dev/kbld/docs/v0.32.0/install/
function kbld_install() {
  if [[ -f "/usr/local/bin/kbld" ]];then
    log "$LOG_DBG" "already availabe on machine, no need to install"
  else
    log "$LOG_INF" "Installing kbld and dependencies"
    wget -O- https://carvel.dev/install.sh > install.sh
    sudo bash install.sh
  fi
}

log "$LOG_INF" "Install kbld"
kbld_install


# To align with the tutorial, lets use the mentioned org and namespace
echo "Prepare org and space for this tutorial"
cf create-org tutorial-org
cf create-space -o tutorial-org tutorial-space
cf target -o tutorial-org -s tutorial-space


# Now clone the repository of a simple java application
log "$LOG_INF" "Clone the git repo with all sample web apps"
cd "$REPO_PATH/.." || die 99 "Cannot change to folder '$REPO_PATH/..'"	#switch to the parent folder, where all git repos are located
[[ -d "sample-web-apps" ]] || git clone https://github.com/sylvainkalache/sample-web-apps
cd sample-web-apps || die 99 "Cannot change to folder 'sample-web-apps'"
APPS_DIR=$(pwd)
log "$LOG_INF" "List of current folder (${APPS_DIR}):"
ls -la

# Now push the sample java app to korifi
log "$LOG_INF" "

============================================
Demo 1: Push a sample JAVA web app to korifi
        (${APPS_DIR}/java)
============================================
"
APP_NAME="my-java-app"
cd "${APPS_DIR}/java" || exit 99
log "$LOG_CMD" "cf push $APP_NAME"
cf push "$APP_NAME"
log "$LOG_INF"  ""

# Workaround for demo situation: As the route is (most likely) not yet in any DNS or in the /etc/hosts, let's add it
app_url=$(cf curl "/v3/apps/$(cf app "$APP_NAME" --guid)/routes" | jq -r '.resources[0].url')
add_to_etc_hosts "$app_url" "$CF_APPS_DOMAIN"

# let's check the result of the app
log "$LOG_INF" "
Let's check the app
-------------------
"

log "$LOG_CMD" "cf app $APP_NAME"
cf app "$APP_NAME"
log "$LOG_INF" ""

log "$LOG_INF" "Call the URL of the app: curl --insecure https://$app_url:$CF_HTTPS_PORT"
curl --insecure "https://$app_url:$CF_HTTPS_PORT"
# Expected:
#	Hello, World!
#	Java Version: 21.0.7
log "$LOG_INF" ""

log "$LOG_INF" "Show the headers of the call: curl -I --insecure https://$app_url:$CF_HTTPS_PORT"
curl -I --insecure "https://$app_url:$CF_HTTPS_PORT"
#	HTTP/2 200
#	date: Tue, 29 Apr 2025 09:08:16 GMT
#	x-envoy-upstream-service-time: 2
#	vary: Accept-Encoding
#	server: envoy
log "$LOG_INF" ""



# Now push the sample Python app to korifi
log "$LOG_INF" "

=============================================
Demo 2: Push a sample Python web app to korifi
        for a non-pre-installed buildpack
        (${APPS_DIR}/python)
==============================================
"
APP_NAME="my-python-app"
cd "${APPS_DIR}/python" || exit 99
log "$LOG_INF" ""
ls -la
log "$LOG_INF" ""

function show_buildpacks() {
  local clusterbuilder=$1
  local clusterstore=$2

  log "$LOG_DBG" "---------------------------------------------------------------"
  log "$LOG_DBG" "snipped from clusterstore '$clusterstore' (.spec.sources):"
  kubectl get clusterstore "$clusterstore" -o yaml | yq eval ".spec.sources"

  log "$LOG_DBG" "snipped from clusterbuilder '$clusterstore' (.specs.order):"
  kubectl get clusterbuilder "$clusterbuilder" -o yaml | yq eval ".spec.order"

  log "$LOG_TR5" "cf buildpacks"
  cf buildpacks
  echo "----------------------------------------------------------------"
  echo ""
}

# Wait for the ClusterBuilder to be ready
function wait_for_clusterbuilder_ready() {
  local clusterbuilder=${1:-custom-cluster-builder}
  log "$LOG_DBG" "Waiting for ClusterBuilder '$clusterbuilder' to become Ready..."
  while true; do
    ready=$(kubectl get clusterbuilder "$clusterbuilder" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    if [[ "$ready" == "True" ]]; then
      log "$LOG_DBG" "ClusterBuilder '$clusterbuilder' is ready."
      break
    fi
    sleep 1
  done
}

function add_buildpack() {
  local buildpack_name="$1"
  local buildpack_reg="${2:-index.docker.io}"
  local buildpack_path="${3:-paketobuildpacks}"
  local clusterbuilder="${4:-$CLUSTERBUILDER_NAME}"
  local local_registry="${5:-$LOCAL_IMAGE_REGISTRY_FQDN}"

  local clusterstore buildpack buildpack_id
  buildpack="$buildpack_reg/$buildpack_path/$buildpack_name"

  if [[ -n "$local_registry" ]];then
    buildpack="$local_registry/$buildpack"
  fi

  buildpack_id=$(pack inspect-buildpack "$buildpack" | awk '/Detection Order:/ {getline; getline; print $2}' | sed 's/@.*//')

  # retrieve the name of the clusterstore used by Korifi
  clusterstore=$(kubectl get clusterbuilder "$clusterbuilder" -o jsonpath='{.spec.store.name}')
  assert test -n "$clusterstore"

  log "$LOG_DBG" "Situation before:"
  show_buildpacks "$clusterbuilder" "$clusterstore"

  log "$LOG_INF" "Adding '$buildpack' to clusterstore '$clusterstore' (as python is not included by default in Korifi)"
  if ! kubectl get clusterstore "$clusterstore" -o json | jq -e ".spec.sources[]?.image == \"$buildpack\"" > /dev/null; then
    local existing_sources merged_sources full_patch
    log "$LOG_DBG" "🔧 Adding buildpack to ClusterStore: $buildpack"
    existing_sources=$(kubectl get clusterstore "$clusterstore" -o json | jq '.spec.sources')		# get existin sources
    merged_sources=$(echo "$existing_sources" | jq --arg image "$buildpack" '. + [{image: $image}]')	# merge new source into the existing array
    full_patch=$(jq -n --argjson sources "$merged_sources" '{"spec": {"sources": $sources}}')		# create full patch to payload with merged sources
    kubectl patch clusterstore "$clusterstore" --type merge -p "$full_patch"				# apply patch
  else
    log "$LOG_DBG" "✅ Buildpack already present in ClusterStore: $buildpack"
  fi

  log "$LOG_INF" "Adding '$buildpack_name' on top of the spec.order group list of clusterbuilder '$clusterbuilder'"
  # The tutorial doesn't mention why it has to be on top. I assume this is done in the tutorial to prevent other buildpacks to do an attempt (performance and reliability)
  if ! kubectl get clusterbuilder "$clusterbuilder" -o json | jq -e ".spec.order[].group[]?.id == \"$buildpack_id\"" > /dev/null; then
    local existing_order new_group merged_order full_patch
    log "$LOG_DBG" "🔧 Adding buildpack to ClusterBuilder: $buildpack_id"
    new_group="{\"group\": [{\"id\": \"$buildpack_id\"}]}"                                      	# create json patch that appends to the array
    existing_order=$(kubectl get clusterbuilder "$clusterbuilder" -o json | jq '.spec.order')		# Get existing .spec.order
    merged_order=$(echo "$existing_order" | jq ". + [ $new_group ]")					# Append new group with buildpack id
    full_patch=$(jq -n --argjson order "$merged_order" '{"spec": {"order": $order}}')			# Construct full patch with new order
    kubectl patch clusterbuilder "$clusterbuilder" --type merge -p "$full_patch"			# Apply patch
  else
    log "$LOG_DBG" "✅ Buildpack already present in ClusterBuilder: $buildpack_id"
  fi

  # avoid race condition (wait for python to be available)
  wait_for_clusterbuilder_ready "$clusterbuilder"

  log "$LOG_DBG" "Situation after:"
  show_buildpacks "$clusterbuilder" "$clusterstore"
}

## Add paketo-buildpacks/python to the clusterstore
log "$LOG_INF" "Adding paketo-buildpacks/python to clusterstore (as python is not included by default in Korifi)"
add_buildpack "python"


log "$LOG_INF" "Now push the python app to korifi"
#cf push "$APP_NAME"
# For some reason Korifi doesn't recognize that we want to push a Python application, so can't determin
# which buildpack to use (at least not the first time).
# By explicitly telling the command to use the python buildback, all works fine.
python_buildpack="paketo-buildpacks/python"
#? if [[ -n "$LOCAL_IMAGE_REGISTRY_FQDN}" ]];then
#?   echo "[DEBUG] using local registry '$LOCAL_IMAGE_REGISTRY_FQDN'"
#?   python_buildpack="$LOCAL_IMAGE_REGISTRY_FQDN/$python_buildpack"
#? fi

log "$LOG_CMD" "[TRACE] cf push $APP_NAME -b $python_buildpack"
cf push "$APP_NAME" -b "$python_buildpack"
log "$LOG_INF" ""

# Workaround for demo situation: As the route is (most likely) not yet in any DNS or in the /etc/hosts, let's add it
app_url=$(cf curl "/v3/apps/$(cf app "$APP_NAME" --guid)/routes" | jq -r '.resources[0].url')
add_to_etc_hosts "$app_url" "$CF_APPS_DOMAIN"

# let's check the result of the app
log "$LOG_INF" "
Let's check the app
-------------------
"

log "$LOG_CMD" "cf app $APP_NAME"
cf app "$APP_NAME"
log "$LOG_INF" ""

log "$LOG_INF" "Call the URL of the app: curl --insecure https://$app_url:$CF_HTTPS_PORT"
curl --insecure "https://$app_url:$CF_HTTPS_PORT"

# Expected:
#       Hello, World!
#       Python version: 3.10.17
log "$LOG_INF" ""

log "$LOG_INF" "Show the headers of the call: curl -I --insecure https://$app_url:$CF_HTTPS_PORT"
curl -I --insecure "https://$app_url:$CF_HTTPS_PORT"
# Expected:
#	HTTP/2 200
#	server: envoy
#	date: Tue, 29 Apr 2025 15:41:16 GMT
#	content-type: text/html; charset=utf-8
#	content-length: 38
#	x-envoy-upstream-service-time: 1
#	vary: Accept-Encoding
log "$LOG_INF" ""




log "$LOG_INF" "
======== END OF SCRIPT ========
"

