#! /bin/bash

##
## Demo Pushing buildbacks to Korifi
##

## Includes
scriptpath="$(pwd dirname "${BASH_SOURCE[0]}")"
. "$scriptpath/utils.sh"
. "$scriptpath/cf_utils.sh"

tmp="$scriptpath/tmp"
mkdir -p "$tmp"

##
## Config
##


##
## Check prerequisits
##
echo ""
echo "Check prerequisits..."
# Are all required tools available?
assert jq --version
assert go version
assert kubectl version
assert helm version
assert cf --version

# Is KIND kluster running?
assert "kubectl cluster-info --context kind-korifi | grep 'Kubernetes control plane is running'"

# Is Korifi up and running?
kubectl config use-context kind-korifi
cf api https://localhost --skip-ssl-validation
cf login -u kind-korifi -o org -s space
cf target -o org -s space

kubectl get pods -n korifi
assert "kubectl get pods -n korifi | grep Running"
echo "...done"

# Are users anton and roger present?
#kubectl get rolebindings -A | grep roger && echo 'User roger is configured' || USERS_FOUND=0
#kubectl get rolebindings -A | grep anton && echo 'User anton is configured' || USERS_FOUND=0
#if [[ "$USERS_FOUND" == "0" ]]; then
#  echo "Expected users not configured. Please run script ./demo_korifi_users_and_rbac.sh and try again"
#  exit 1
#fi

# is repo sample-web-apps already cloned?
if [[ ! -d "$scriptpath/../sample-web-apps" ]]; then
  echo "Repo sample-web-apps not cloned yet. Please run script ./demo_buildpacks.sh and try again"
fi



##
## Prepare java apps javaA (Hello Amsterdam) and javaN (Hello Nieuwegein)
##
appsroot="${scriptpath}/../sample-web-apps"

function create_app() {
  local appname=$1
  local city=$2

  if [[ -d "${appsroot}/${appname}" ]];then
    echo "Application '$appname' already present. No action required"
    return
  fi

  echo "Creating folder and filestructure for $appname in $appsroot/$appname"
  cp -r "$appsroot/java" "$appsroot/$appname"

  echo "Adjusting World to '$city' for this app"
  cd "$appsroot/$appname" || exit 99
  sed -i "s/World/${city}/g" README.md pom.xml src/main/java/sampleapp/HelloWorld.java
  sed -i "s/world/${city}/g" README.md pom.xml src/main/java/sampleapp/HelloWorld.java

  echo "Renaming main java file (HelloWorld.java -> Hello${city}.java)."
  mv "src/main/java/sampleapp/HelloWorld.java" "src/main/java/sampleapp/Hello${city}.java"

  cd - || exit 99
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

push_app_by_user_in_org() {
  local username=$1
  local org=$2
  local app_fldr=$3

  local app_name="${org}-java-app"

  switch_user "$username"
  cf target -o "${org}" -s "${org}-space"
  echo ""

  # Now push the sample java app to korifi
  echo "switching to folder '$appsroot/$app_fldr'"
  cd "$appsroot/$app_fldr" || exit 99
  echo "push application '${app_name}'"
  cf push "${app_name}"
  echo ""
}

check_app_by_user() {
  local username=$1
  local org=$2
  
  local app_name="${org}-java-app"
  local app_url="https://${app_name}.apps-127-0-0-1.nip.io"

  switch_user "$username"
  cf target -o "${org}" -s "${org}-space"
  echo ""

  # let's check the result of the app
  echo ""
  echo "Let's check the app"
  echo "-------------------"
  echo ""
  cf app "${app_name}"
  echo ""

  echo "Call the URL of the app: curl --insecure ${app_url}"
  curl --insecure "${app_url}"
  # Expected:
  #	Hello, <city>!
  #	Java Version: 21.0.7
  echo ""

  echo "Show the headers of the call: curl -I --insecure ${app_url}"
  curl -I --insecure "${app_url}"
  # Expected:
  #	HTTP/2 200
  #	date: Tue, 29 Apr 2025 09:08:16 GMT
  #	x-envoy-upstream-service-time: 2
  #	vary: Accept-Encoding
  #	server: envoy
  echo ""
}


##
## Creating Hello Amsterdam App by Anton
##
echo ""
echo "============================================="
echo "Demo 1: Creating Hello Amsterdam App by Anton"
echo "============================================="
echo ""
push_app_by_user_in_org anton amsterdam javaA
check_app_by_user anton amsterdam


# Creating Hello Nieuwegein App by Roger
echo ""
echo ""
echo "=============================================="
echo "Demo 2: Creating Hello Nieuwegein App by Roger"
echo "=============================================="
echo ""
push_app_by_user_in_org roger nieuwegein javaN
check_app_by_user roger nieuwegein

# Creating Hello Utrecht App by Roger
A
echo ""
echo ""
echo "===================================================="
echo "Demo 3: Atttempt to create app in non-accessible org"
echo "===================================================="
echo ""
push_app_by_user_in_org roger utrecht javaU
check_app_by_user roger nieuwegein


# Show apps per user
echo ""
echo ""
echo "=========================="
echo "Demo 4: Show apps per user"
echo "=========================="
echo ""


function show_all_apps() {
  # Get list of orgs
  orgs=$(cf orgs 2>/dev/null | tail -n +4)
  
  for org in $orgs; do
    echo ""
    echo "🔹 Org: $org"
    cf target -o "$org" >/dev/null 2>&1
 
    # Get list of spaces in this org
    spaces=$(cf spaces 2>/dev/null | tail -n +4)
 
    for space in $spaces; do
      echo "  🔸 Space: $space"
      cf target -o "$org" -s "$space" >/dev/null 2>&1
 
      # List apps in this space
      apps=$(cf apps 2>/dev/null | tail -n +4)

     if [ -z "$apps" ]; then
       echo "    (No apps found)"
     else
       echo "$apps" | while read -r app; do
         app_name=$(echo "$app" | awk '{print $1}')
         echo "    ✅ App: $app_name"
      done
      fi
    done
  done
}


echo "Admin:"
switch_user kind-korifi
cf target -o org 2>/dev/null
show_all_apps
echo ""

echo "Anton:"
switch_user anton 2>/dev/null
cf target -o amsterdam
show_all_apps
echo ""

echo "Roger:"
switch_user roger 2>/dev/null
cf target -o vijlen
show_all_apps


# TODO:
# - roger access app in nieuwegein when target is set to vijlen (result unknown yet)


























echo ""
echo "======== END OF SCRIPT ========"
echo ""

