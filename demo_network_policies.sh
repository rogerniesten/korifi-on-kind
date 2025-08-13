#! /bin/bash

##
## Demo Firewalls in Korifi - K8s Network Policies
##

## Includes
scriptpath="$(pwd dirname "${BASH_SOURCE[0]}")"
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

declare -a ALL_ORGS=("amsterdam" "utrecht" ) #>"rotterdam") #> "nieuwegein" "vijlen")
declare -A ORG_SPACES
ORG_SPACES[amsterdam]="amsterdam-space bijlmer" #> de-pijp centrum"
ORG_SPACES[utrecht]="utrecht-space"
#>ORG_SPACES[rotterdam]="rotterdam-space haven"	# disabled voor mininale test-setup
#>ORG_SPACES[nieuwegein]="nieuwegein-space"
#>ORG_SPACES[vijlen]="vijlen-space"
export curl_app_image="$DOCKER_REGISTRY_SERVER/curl-task-app"
export curl_app_name="curl-tester"


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

# Make sure kubenetes user and cf account are in sync
sync_k8s_user "$ADMIN_USERNAME"


# Is K8s cluster running?
assert "kubectl cluster-info | grep 'Kubernetes control plane is running'"

# Is Korifi up and running?
cf api "https://${CF_API_DOMAIN}" --skip-ssl-validation
cf login -u "${ADMIN_USERNAME}" -o org -s space
cf target -o org -s space

#kubectl get pods -n korifi
assert "kubectl get pods -n korifi | grep Running >/dev/null"

# Does K8s cluster support Network Policies by Calico?
assert "kubectl get pods -A -l k8s-app=calico-node"

echo "...done (check prerequisits)"


##
## LOCAL HELPER FUNCTIONS
## ======================
##


##
## Create some namespaces etc to setup demo environment
##

function create_org_with_spaces() {
  local org=$1

  cf create-org "$org"
  for src_space in ${ORG_SPACES[$org]}; do
    cf create-space -o "$org" "$src_space"
  done
}


function get_guid() {
  local org="$1"
  local space="${2:-}"

  local prev_org prev_space guid
  prev_org=$(cf target | grep '^org:' | awk '{print $2}')
  prev_space=$(cf target | grep '^space:' | awk '{print $2}')

  # target the org to get access to org or space
  cf target -o "$org" >/dev/null

  # retrieve the guid of the requested object (org or space)
  if [[ -n "$space" ]];then
    guid=$(cf space "$space" --guid)
  else
    guid=$(cf org "$org" --guid)
  fi

  # switch back to the previous org and space
  cf target -o "$prev_org" -s "$prev_space" >/dev/null

  # return value
  echo "$guid"
}


function get_curl_tester_pod() {
  local namespace="$1"
  local found=false

  if [[ -z "$namespace" ]]; then
    echo "Error: namespace is required." >&2
    return 1
  fi

  kubectl get pod -n "$namespace" | grep Running | awk '{print $1}' | while read -r pod; do
    if kubectl describe pod -n "$namespace" "$pod" | grep -q 'Image:.*curl'; then
      echo "$pod"
      found=true
    fi
  done

  # If nothing found, print error and return non-zero
  if [[ "$found" -ne "true" ]]; then
    echo "Error: No Running pod in namespace '$namespace' has an Image containing 'curl'." >&2
    return 1
  fi
}


function curl_in_k8s_pod_and_get_result() {
  local url="$1"
  local info="${2:-}"
  local src_namespace="$3"
  local timeout="${4:-3}"

  local curl_pod
  # cf target must already be set to required org and space

  # Let op: de test-app moet al gepusht zijn met cf push
  echo "[DEBUG] $info" 					>/dev/tty

  # find the curl-tester pod in the current namespace
  curl_pod=$(get_curl_tester_pod "$src_namespace")

  # exeute curl command in pod
  echo "[TRACE] kubectl exec -n $src_namespace $curl_pod -- curl --max-time $timeout -s -o /dev/null -w \\\"%{http_code}\\\" $url\""	>/dev/tty
  RAW_OUTPUT=$(kubectl exec -n $src_namespace $curl_pod -- curl --max-time "$timeout" -s -o /dev/null -w \"%{http_code}\" "$url" 2>/dev/null)
  retval=$?
  echo "[DEBUG] $RAW_OUTPUT"				>/dev/tty
  if [[ "$retval" -eq "0" ]]; then
    echo "SUCCESS ($RAW_OUTPUT)"
  else
    echo "FAILED  ($RAW_OUTPUT)"
  fi

  return $retval
}


function test_connectivity_in_k8s() {
  echo "[DEBUG] function test_connectivity_in_k8s() - STARTED"

  local space_guid report src_namespace TARGET_URL result report_line app_alias

  report=()
  report+=("Source-Org Source-Space Target-Org Target-Space Result Reason")
  report+=("---------- ------------ ---------- ------------ ------ ------")

  for SRC_ORG in "${!ORG_SPACES[@]}"; do
    for SRC_SPACE in ${ORG_SPACES[$SRC_ORG]}; do

      echo ""
      echo ""
      echo "🎯 Test vanaf $SRC_SPACE (org: $SRC_ORG)"

      cf target -o "$SRC_ORG" -s "$SRC_SPACE" >/dev/null
      src_namespace=$(cf space "$SRC_SPACE" --guid)

      TARGET_URL="https://google.com"
      result=$(curl_in_k8s_pod_and_get_result "https://google.com" "Testing connectifity from org '$SRC_ORG', space '$SRC_SPACE' to the internet" "$src_namespace")
      report_line="$SRC_ORG $SRC_SPACE INTERNET google.com $result"
      echo "task result: $report_line"
      report+=("$report_line")


      for TGT_ORG in "${!ORG_SPACES[@]}"; do
        echo "[DEBUG] Processing target org '$TGT_ORG'"
        for TGT_SPACE in ${ORG_SPACES[$TGT_ORG]}; do
          echo "[DEBUG] Processing target space '$TGT_SPACE'"
          space_guid=$(get_guid "$TGT_ORG" "$TGT_SPACE")
          app_alias="nginx-$TGT_ORG-$TGT_SPACE"

          TARGET_URL="http://${app_alias}.${space_guid}.svc.cluster.local"
	  echo "[DEBUG] Tesing if direct route can be used: '$SRC_ORG' == '$TGT_ORG' and '$SRC_SPACE' == '$TGT_SPACE'"
	  if [[ "$SRC_ORG" == "$TGT_ORG" && "$SRC_SPACE" == "$TGT_SPACE" ]]; then
	    echo "[DEBUG] changing URL to direct route"
            TARGET_URL="http://${app_alias}"
	  fi

          echo "🔍 $SRC_SPACE → $TGT_SPACE: "
	  result=$(curl_in_k8s_pod_and_get_result "$TARGET_URL" "Testing connectifity from org '$SRC_ORG', space '$SRC_SPACE' to $TARGET_URL" "$src_namespace")
          report_line="$SRC_ORG $SRC_SPACE $TGT_ORG $TGT_SPACE $result"
          echo "task result: $report_line"
          report+=("$report_line")
        done
      done
    done
  done

  echo ""
  echo ""
  echo "Test result of connectivity test"
  echo "================================"
  printf "%s\n" "${report[@]}" | column -t
  echo ""
  echo ""
  echo "[DEBUG] function test_connectivity_in_k8s finished"
}




function curl_in_runtask() {
  local url="$1"
  local info="${2:-}"
  local timeout="${3:-3}"
  local waittime="${4:-2}"

  # cf target must already be set to required org and space
  # Let op: de test-app moet al gepusht zijn met cf push

  # Start de task
  echo "[DEBUG] $info"
  echo "[TRACE] cf run-task $curl_app_name --command \"curl --max-time $timeout -s -o /dev/null -w \\\"%{http_code}\\\" $url\""
  # parameter --name is apparently not valid! So remove it from the commands below!
  RAW_OUTPUT=$(cf run-task "$curl_app_name" --command "curl --max-time $timeout -s -o /dev/null -w \"%{http_code}\" $url" 2>/dev/null)
  echo "$RAW_OUTPUT"
  TASK_ID=$(echo "$RAW_OUTPUT" | grep -i 'task id:' | awk '{print $3}')
  echo "[DEBUG] TASK_ID='$TASK_ID'"

  if [[ -z "$TASK_ID" ]]; then
    echo "-> ⚠️ kon task niet starten"
    return 1
  fi

  # Get task info
  echo "[TRACE] cf task $curl_app_name $TASK_ID"
  cf task "$curl_app_name" "$TASK_ID"

  # Wacht en haal resultaat op
  sleep "$waittime"
}


function get_task_result() {
  local src_org=$1
  local src_space=$2
  local tgt_org=$3
  local tgt_space=$4
  local url=${5:-://}

  if [ "$BASH_SUBSHELL" -eq 0 ]; then
    echo "******** Running in same shell, so test run"		>/dev/tty
  else
	  echo "******** Running in subshell, so real execution (logging directly to tty)" >/dev/tty
  fi

  while true; do
    echo "cf tasks $curl_app_name | grep $url | head -n 1"	>/dev/tty
    result_line=$(cf tasks "$curl_app_name" | grep "$url" | head -n 1)
    task_id=$(echo "$result_line" | awk '{ print $1 }')
    echo "$result_line"						>/dev/tty
  
    # Check if task_id is a valid number (only digits)
    if [[ "$task_id" =~ ^[0-9]+$ ]]; then
       break
   fi
  
    sleep 1
  done

  # Wait until the task is visible (cf task doesn't fail)
  #echo -n "[DEBUG] Waiting for task to be visible"		>/dev/tty
  echo "[DEBUG] Waiting for task to be visible" >/dev/tty
  while true; do
    echo "cf task $curl_app_name $task_id"			>/dev/tty
    task_info=$(cf task "$curl_app_name" "$task_id" 2>/dev/null)
    echo "$task_info"						>/dev/tty
  
    if echo "$task_info" | grep -q '^id:'; then
      echo "✓"							>/dev/tty
      break
    fi
  
    echo -n "."							>/dev/tty
    sleep 1
  done

  # Wait for task to finish (SUCCEEDED or FAILED)
  echo -n "[DEBUG] Waiting for task to be finished"		>/dev/tty
  while true; do
    task_state=$(echo "$task_info" | awk -F': *' '/^state:/ {print $2}')

    if [[ "$task_state" == "SUCCEEDED" || "$task_state" == "FAILED" ]]; then
      break
    fi

    echo -n "."							>/dev/tty
    sleep 1
    task_info=$(cf task "$curl_app_name" "$task_id")
  done
  echo "✓"							>/dev/tty

  task_fail_reason=$(echo "$task_info" | grep 'failure reason:' | awk '{for (i=3; i<=NF; i++) printf $i (i<NF ? " " : "\n")}' || echo "OK")
  task_fail_reason="${task_fail_reason:0:60}"
  report_line="$src_org $src_space $tgt_org $tgt_space $task_state $task_fail_reason"

  echo "$report_line"
}



function test_connectivity_in_korifi() {

  local space_guid

  report=()
  report+=("Source-Org Source-Space Target-Org Target-Space Result Reason")
  report+=("---------- ------------ ---------- ------------ ------ ------")

  for SRC_ORG in "${!ORG_SPACES[@]}"; do
    for SRC_SPACE in ${ORG_SPACES[$SRC_ORG]}; do

      echo ""
      echo ""
      echo "🎯 Test vanaf $SRC_SPACE (org: $SRC_ORG)"
      cf target -o "$SRC_ORG" -s "$SRC_SPACE" >/dev/null

      TARGET_URL="https://google.com"
      curl_in_runtask "https://google.com" "Testing connectifity from org '$SRC_ORG', space '$SRC_SPACE' to the internet"
      if [[ "$?" -ne 0 ]]; then
        report_line="$SRC_ORG $SRC_SPACE $TGT_ORG $TGT_SPACE NOT_STARTED Could not start runtask for curl-tester"
	continue
      fi
      #echo "[DEBUG] ======== TEST RUN FOR get_task_result ======================="
      #get_task_result "$SRC_ORG" "$SRC_SPACE" "Internet" "x" "google.com"
      #echo "[DEBUG] ======== SUBSHELL RUN FOR get_task_result ==================="
      report_line=$(get_task_result "$SRC_ORG" "$SRC_SPACE" "Internet" "google.com" "$TARGET_URL")
      #echo "[DEBUG] ======== RUNS FOR get_task_result DONE ======================"
      echo "task result: $report_line"
      report+=("$report_line")


      for TGT_ORG in "${!ORG_SPACES[@]}"; do
	echo "[DEBUG] Processing target org '$TGT_ORG'"
        for TGT_SPACE in ${ORG_SPACES[$TGT_ORG]}; do
          echo "[DEBUG] Processing target space '$TGT_SPACE'"
          space_guid=$(get_guid "$TGT_ORG" "$TGT_SPACE")
	  app_alias="nginx-$TGT_ORG-$TGT_SPACE"

          TARGET_URL="http://${app_alias}.${space_guid}.svc.cluster.local"

          echo "🔍 $SRC_SPACE → $TGT_SPACE: "
	  curl_in_runtask "$TARGET_URL" "Testing connectifity from org '$SRC_ORG', space '$SRC_SPACE' to $TARGET_URL"
          if [[ "$?" -ne 0 ]]; then
            report_line="$SRC_ORG $SRC_SPACE $TGT_ORG $TGT_SPACE NOT_STARTED Could not start runtask for curl-tester"
            continue
          fi
	  report_line=$(get_task_result "$SRC_ORG" "$SRC_SPACE" "$TGT_ORG" "$TGT_SPACE" "$TARGET_URL")
	  echo "task result: $report_line"
	  report+=("$report_line")

        done
      done
    done
  done

  echo ""
  echo ""
  echo "Test result of connectivity test"
  echo "================================"
  printf "%s\n" "${report[@]}" | column -t
  echo ""
  echo ""
  #echo "[DEBUG] function test_connectivit finished"
}



echo ""
echo "============================================================"
echo "Setup environment for this network policy demo"
echo "============================================================"
echo ""

## Create a container image with curl that is compatible with korifi
build_folder="$tmp/$curl_app_name"
echo "[INFO ] Create korifi compatible container image for curl"
mkdir -p "$build_folder"
cd "$build_folder" || exit

cat <<'EOF' > "$build_folder/launcher"
#!/bin/sh
# This launcher expects the first argument to be the URL
# It implicitly calls curl with that URL

if [ $# -eq 0 ]; then
  echo "Usage: <launcher> <command>"
  exit 1
fi

echo "[INFO ] Executing: $@"
exec /bin/bash -c "$@"
retval=$?
echo "[INFO ] Exit code: $retval"
case "$retval" in
  0) echo "[INFO ] Task succesfully executed";;
  *) echo "[ERROR] Task FAILED!"
esac
exit "$retval"
EOF

cat <<EOF > "$build_folder/Dockerfile"
FROM alpine:latest

# Install curl and a tiny HTTP server
RUN apk add --no-cache curl busybox-extras bash

## Properly create the fake lifecycle launcher
COPY launcher /cnb/lifecycle/launcher
RUN chmod +x /cnb/lifecycle/launcher

# Create a non-root user
RUN adduser -D -u 10001 nonrootuser
USER 10001
WORKDIR /home/nonrootuser

# Default command (satisfies cf push --no-start)
CMD ["sleep", "3600"]
EOF

echo "[TRACE] docker build -t $curl_app_image $build_folder"
docker build -t "$curl_app_image" "$build_folder"
echo "[TRACE] docker push $curl_app_image"
docker push "$curl_app_image"


## Create namespaces (orgs and spaces)
echo "[INFO ] Create namespaces (orgs and spaces)"
for src_org in "${ALL_ORGS[@]}"; do
  create_org_with_spaces "$src_org"
done


function create_dns_friendly_alias() {
  echo "[DEBUG] create_dns_friendly_alias( '$1') - START"
  local app_name=$1

  local org space space_guid app_guid
  org=$(cf target | grep '^org:' | awk '{print $2}')
  space=$(cf target | grep '^space:' | awk '{print $2}')
  space_guid=$(get_guid "$org" "$space")
  app_guid=$(cf app "$app_name" --guid)

  echo "[DEBUG] Applying clusterIP (for $app_guid)"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: $app_name
  namespace: $space_guid
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
  selector:
    korifi.cloudfoundry.org/app-guid: $app_guid
    korifi.cloudfoundry.org/process-type: web
EOF
  echo "[DEBUG] ClusterIP applied"
}



## Create an nginx in each org
echo "[INFO ] pushing nginx to each org"
nginx_image="index.docker.io/nginxinc/nginx-unprivileged"
if [[ -n "$LOCAL_IMAGE_REGISTRY_FQDN" ]];then
  nginx_image="${LOCAL_IMAGE_REGISTRY_FQDN}/${nginx_image}"
fi

## Create an nginx and a curl tester app in each space
echo "[INFO ] pushing curl test-app to each space"
for src_org in "${ALL_ORGS[@]}"; do
  for src_space in ${ORG_SPACES[$src_org]}; do
    # switch to this org and space
    echo "[TRACE] cf target -o $src_org -s $src_space"
    cf target -o "$src_org" -s "$src_space"

    # push nginx to this space
    app_name="nginx-$src_org-$src_space"
    echo "[TRACE] cf push $app_name --docker-image $nginx_image"
    cf push "$app_name" --docker-image "$nginx_image"
    echo "[DEBUG] creating dns alias for $app_name"
    create_dns_friendly_alias "$app_name"

    # push curl-tester app to this space
    echo "[TRACE] cf push $curl_app_name --docker-image $curl_app_image --no-route --no-start" 
    cf push "$curl_app_name" --docker-image "$curl_app_image" --no-route --no-start
    echo "[TRACE] cf set-health-check $curl_app_name  process"
    cf set-health-check "$curl_app_name"  process
    echo "[TRACE] cf start $curl_app_name"
    cf start "$curl_app_name"
  done
done





echo ""
echo "============================================================"
echo "Baseline - What is allowed by default and what isn't"
echo "============================================================"
echo ""

test_connectivity_in_k8s
test_connectivity_in_korifi


#exit 0


##
## Demo 1 - Isolation per space
## 

echo ""
echo "============================================================"
echo "Demo 1 - Isolate spaces with Network Policies"
echo "============================================================"
echo ""

function isolate_space() {
  local space=$1

  echo "[INFO ]   Create network policies to isolate space '$space'"
  echo "[DEBUG]   Apply network policy 'allow-same-namespace' for space '$space'"
  kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: $space
spec:
  podSelector: {}  # Select all pods in the namespace
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}  # Allow ingress from all pods in the same namespace
EOF

  echo "[DEBUG]   Apply network policy 'deny-other-namespaces' for space '$space'"
  kubectl apply -f - <<EOF
# network-policy-deny-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-other-namespaces
  namespace: $space
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress: []  # No sources allowed besides those allowed by other policies
EOF
}

echo "[INFO ] Isolation all spaces"
for src_org in "${ALL_ORGS[@]}"; do
  for src_space in ${ORG_SPACES[$src_org]}; do

    # isolate this space
    echo "[INFO]  Isolate org '$src_org', space '$src_space'"
    isolate_space "$(get_guid "$src_org" "$src_space")"
  done
done

# Test isoloation (in kubernetes)
#kubectl run tester -n 


test_connectivity_in_k8s
test_connectivity_in_korifi





echo ""
echo "============================================================"
echo "Cleanup"
echo "============================================================"
echo ""

## Switching back to admin 
switch_user "${ADMIN_USERNAME}" >>/dev/null

## Remove all network policies
echo "[INFO ] Remove all network policies"
for src_org in "${ALL_ORGS[@]}"; do
  for src_space in ${ORG_SPACES[$src_org]}; do

    # isolate this space
    guid=$(get_guid "$src_org" "$src_space")
    echo "[DEBUG] Remove network policies for org '$src_org', space '$src_space' ($guid)"
    kubectl delete networkpolicy -n "$guid" deny-other-namespaces
    kubectl delete networkpolicy -n "$guid" allow-same-namespace
  done
done


echo ""
echo "======== END OF SCRIPT ========"
echo ""

