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

prompt_if_missing K8S_TYPE "var" "Which K8S type to use? (KIND, AKS)"
prompt_if_missing K8S_CLUSTER_KORIFI "var" "Name of K8S Cluster for Korifi"
. "$ENV_PATH/.env.korifi" || die 1 "Config ERROR! Script aborted"     # read config from environment file

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
switch_user "$ADMIN_USERNAME"
sync_k8s_user "$ADMIN_USERNAME"

# Is KIND kluster running?
assert "kubectl cluster-info | grep 'Kubernetes control plane is running'"

# Is Korifi up and running?
cf api "https://${CF_API_DOMAIN}" --skip-ssl-validation
cf login -u "${ADMIN_USERNAME}" -o org -s space
cf target -o org -s space

kubectl get pods -n korifi
assert "kubectl get pods -n korifi | grep Running"
log "$LOG_INF" "...done"


# Are users anton and roger present?
#kubectl get rolebindings -A | grep "roger@${K8S_CLUSTER_KORIFI}" && echo 'User roger is configured' || USERS_FOUND=0
#kubectl get rolebindings -A | grep "anton@${K8S_CLUSTER_KORIFI}" && echo 'User anton is configured' || USERS_FOUND=0
#if [[ "$USERS_FOUND" == "0" ]]; then
#  echo "Expected users not configured. Please run script ./demo_korifi_users_and_rbac.sh and try again"
#  exit 1
#fi

# is repo sample-web-apps already cloned?
[[ -d "$REPO_PATH/../sample-web-apps" ]] || die 1 "Repo sample-web-apps not cloned yet. Please run script ./demo_buildpacks.sh and try again"


##
## Prepare java apps javaA (Hello Amsterdam) and javaN (Hello Nieuwegein)
##
appsroot="${REPO_PATH}/../sample-web-apps"

function create_app() {
  local appname=$1
  local city=$2

  if [[ -d "${appsroot}/${appname}" ]];then
    log "$LOG_DBG" "Application '$appname' already present. No action required"
    return
  fi

  log "$LOG_DBG" "Creating folder and filestructure for $appname in $appsroot/$appname"
  cp -r "$appsroot/java" "$appsroot/$appname"

  log "$LOG_INF" "Adjusting World to '$city' for this app"
  (
    cd "$appsroot/$appname" || exit 99
    sed -i "s/World/${city}/g" README.md pom.xml src/main/java/sampleapp/HelloWorld.java
    sed -i "s/world/${city}/g" README.md pom.xml src/main/java/sampleapp/HelloWorld.java

    log "$LOG_INF" "Renaming main java file (HelloWorld.java -> Hello${city}.java)."
    mv "src/main/java/sampleapp/HelloWorld.java" "src/main/java/sampleapp/Hello${city}.java"
  )
}

create_app javaA Amsterdam
create_app javaN Nieuwegein
create_app javaU Utrecht



##
## Starts apps in orgs demo
##

# In this demo:
#	1) User anton will install a 'Hello, Amsterdam!' Java app in org 'amsterdam'
#       2) User roger will install a 'Hello, Nieuwegein!' Java app in org 'nieuwegein'
#	3) User roger will showcase that installing an app in org 'amsterdam' is not allowed
#

function push_app_by_user_in_org() {
  local username=$1
  local org=$2
  local app_fldr=$3

  local app_name="${org}-java-app"

  switch_user "$username"
  cf target -o "${org}" -s "${org}-space"
  echo ""

  # Now push the sample java app to korifi
  log "$LOG_INF" "switching to folder '$appsroot/$app_fldr'"
  cd "$appsroot/$app_fldr" || exit 99
  log "$LOG_INF" "push application '${app_name}'"
  cf push "${app_name}"

  # Workaround for demo situation: As the route is (most likely) not yet in any DNS or in the /etc/hosts, let's add it
  app_url=$(cf curl "/v3/apps/$(cf app "$app_name" --guid)/routes" | jq -r '.resources[0].url')
  add_to_etc_hosts "$app_url" "$CF_APPS_DOMAIN"
}


function check_app_by_user() {
  local username=$1
  local org=$2
  local apps_port="${3:-$CF_HTTPS_PORT}"

  local app_name app_url 
  app_name="${org}-java-app"
  app_url=$(cf curl "/v3/apps/$(cf app "$app_name" --guid)/routes" | jq -r '.resources[0].url')
  if [[ -z "${app_url:-}" || "$app_url" == "null" ]]; then
    log "$LOG_WRN" "FAILURE: no valid url ($app_url) can be found for app '$app_name'"
    return
  fi

  switch_user "$username"
  # OR -> cf login -u "$username" -a "https://${CF_API_DOMAIN}" --skip-ssl-validation
  cf target -o "${org}" -s "${org}-space"

  # let's check the result of the app
  log "$LOG_INF" "
  Let's check the app
  -------------------
  "
  log "$LOG_CMD" "cf app $app_name"
  cf app "$app_name"
  
  log "$LOG_INF" "Call the URL of the app"
  log "$LOG_CMD" "curl --insecure https://$app_url:$apps_port"
  curl --insecure "https://$app_url:$apps_port"
  # Expected:
  #       Hello, World!
  #       Java Version: 21.0.7
  
  log "$LOG_INF" "Call the URL of the app"
  log "$LOG_CMD" "curl -I --insecure https://$app_url:$apps_port"
  curl -I --insecure "https://$app_url:$apps_port"
  #       HTTP/2 200
  #       date: Tue, 29 Apr 2025 09:08:16 GMT
  #       x-envoy-upstream-service-time: 2
  #       vary: Accept-Encoding
  #       server: envoy
}


##
## Creating Hello Amsterdam App by Anton
##
log "$LOG_INF" "
=============================================
Demo 1: Creating Hello Amsterdam App by Anton
=============================================
"
push_app_by_user_in_org "anton@${K8S_CLUSTER_KORIFI}" amsterdam javaA
check_app_by_user "anton@${K8S_CLUSTER_KORIFI}" amsterdam


# Creating Hello Nieuwegein App by Roger
log "$LOG_INF" "
==============================================
Demo 2: Creating Hello Nieuwegein App by Roger
==============================================
"
push_app_by_user_in_org "roger@${K8S_CLUSTER_KORIFI}" nieuwegein javaN
check_app_by_user "roger@${K8S_CLUSTER_KORIFI}" nieuwegein

# Creating Hello Utrecht App by Roger
log "$LOG_INF" "
====================================================
Demo 3: Atttempt to create app in non-accessible org
====================================================

This demo is supposed to fail!
"
set +e
push_app_by_user_in_org "roger@${K8S_CLUSTER_KORIFI}" utrecht javaU
check_app_by_user "roger@${K8S_CLUSTER_KORIFI}" utrecht
set -e

# Show apps per user
log "$LOG_INF" "
==========================
Demo 4: Show apps per user
==========================
"


function show_all_apps() {

  local orgs

  # Get list of orgs
  orgs=$(cf orgs 2>/dev/null | tail -n +4 || true)
  
  for org in $orgs; do
    log "$LOG_INF" ""
    log "$LOG_INF" "🔹 Org: $org"
    if ! cf target -o "$org" >/dev/null 2>&1; then
      continue
    fi
 
    # Get list of spaces in this org
    spaces=$(cf spaces 2>/dev/null | tail -n +4 || true)
 
    for space in $spaces; do
      log "$LOG_INF" "  🔸 Space: $space"
      if ! cf target -o "$org" -s "$space" >/dev/null 2>&1; then
        continue
      fi
 
      # List apps in this space
      apps=$(cf apps 2>/dev/null | tail -n +4i || true)

     if [ -z "${apps:-}" ]; then
       log "$LOG_INF" "    (No apps found)"
     else
       echo "$apps" | while read -r app; do
         app_name=$(echo "$app" | awk '{print $1}')
         log "$LOG_INF" "    ✅ App: $app_name"
      done
      fi
    done
  done
}


log "$LOG_INF" "Admin:"
switch_user "${ADMIN_USERNAME}"
cf target -o org 2>/dev/null
show_all_apps

log "$LOG_INF" "Anton:"
switch_user "anton@${K8S_CLUSTER_KORIFI}"  2>/dev/null
cf target -o amsterdam
show_all_apps

log "$LOG_INF" "Roger:"
switch_user "roger@${K8S_CLUSTER_KORIFI}" 2>/dev/null
cf target -o vijlen
show_all_apps


# TODO:
# - roger access app in nieuwegein when target is set to vijlen (result unknown yet)


## Switching back to admin 
switch_user "${ADMIN_USERNAME}"





log "$LOG_INF" "
======== END OF SCRIPT ========
"

