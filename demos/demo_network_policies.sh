#! /bin/bash

##
## Demo Firewalls in Korifi - K8s Network Policies
##

## Includes
scriptpath="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
. "$scriptpath/../env/.env"
. "$LIB_PATH/cf_utils.sh"


##
## Script argument parsing and syntax message
##

function syntax(){
  local msg="${1:-}"
  local rv=0

  if [[ -n "$msg" ]]; then
    echo -e "\n$msg"
    rv=1
  fi
  echo "
Run a demo to show how firewall rules (network policies) in Korifi can be configured to separate orgs and spaces.

Syntax:

  $0 [-T|--cluster-type <AKS|KIND>] [-C|--cluster-name <name>] $(logging__get_args) [-h|--help]

Parameters:
  -T|--cluster-type; AKS or KIND
  -C|--cluster-name; Name of the K8s cluster to be used/created for Korifi. This arg overrules
                     environment variable K8S_CLUSTER_KORIFI
  -h|--help;         Show this syntax info
$(logging__show_args_desc)
"
  exit "$rv"
}

log "$LOG_TR5" "*** Parsing args in $0 ($*)"
while [[ $# -gt 0 ]]; do

  # Pas current arg to logging library if it wants to process it
  if logging__parse_arg "$@"; then
    shift $__LOGGING__ARGS_CONSUMED     # logging__parse_args tells us how many args to consume
    continue
  fi

  # Parse script specific args
  case "$1" in
    -h|--help)          syntax ;;
    -T|--cluster-type)  K8S_TYPE="$2";                  log "$LOG_TR5" "handled -T $2"; shift 2 ;;
    -C|--cluster-name)  K8S_CLUSTER_KORIFI="$2";        log "$LOG_TR5" "handled -C $2"; shift 2 ;;
    --)                 break;                          log "$LOG_TR5" "stop parsing";  shift ;;
    *)  syntax "ERROR: Invalid arg $1" ;;
  esac
done



##
## Config
##
prompt_if_missing K8S_TYPE "var" "Which K8S type to use? (KIND, AKS)"
prompt_if_missing K8S_CLUSTER_KORIFI "var" "Name of K8S Cluster for Korifi"
. "$ENV_PATH/.env_korifi" || die 1 "Config ERROR! Script aborted"      # read config from environment file

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
log "$LOG_INF" "Check prerequisits..."
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

log "$LOG_INF" "...done (check prerequisits)"


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
  local namespace="${1?Parameter 'namespace' is missing in call to function 'get_curl_tester_pod'}"

  while read -r pod; do
    if kubectl describe pod -n "$namespace" "$pod" | grep -q 'Image:.*curl'; then
      echo "$pod"
      return 0
    fi
  done < <(kubectl get pod -n "$namespace" | grep Running | awk '{print $1}')

  # If nothing found, print error and return non-zero
  die 1 "Error: No Running pod in namespace '$namespace' has an Image containing 'curl'."
}


function curl_in_k8s_pod_and_get_result() {
  local url="${1?Parameter 'url' is missing in call to function 'curl_in_k8s_pod_and_get_result'}"
  local info="${2:-}"
  local src_namespace="$3"
  local timeout="${4:-3}"

  local curl_pod

  # cf target must already be set to required org and space
  # Let op: de test-app moet al gepusht zijn met cf push

  log "$LOG_INF" "$info"

  # find the curl-tester pod in the current namespace
  curl_pod=$(get_curl_tester_pod "$src_namespace")

  # exeute curl command in pod
  log "$LOG_CMD" "kubectl exec -n $src_namespace $curl_pod -- curl --max-time $timeout -s -o /dev/null -w '%{http_code}' $url\""	>/dev/tty
  if RAW_OUTPUT=$(kubectl exec -n "$src_namespace" "$curl_pod" -- curl --max-time "$timeout" -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null); then
    retval=$?
    echo "SUCCESS ($RAW_OUTPUT)"
  else
    retval=0
    echo "FAILED  ($RAW_OUTPUT)"
  fi

  return $retval
}


function test_connectivity_in_k8s() {
  log "$LOG_INF" "function test_connectivity_in_k8s() - STARTED"

  local space_guid report src_namespace TARGET_URL result report_line app_alias

  report=()
  report+=("Source-Org Source-Space Target-Org Target-Space Result Reason")
  report+=("---------- ------------ ---------- ------------ ------ ------")

  for SRC_ORG in "${!ORG_SPACES[@]}"; do
    for SRC_SPACE in ${ORG_SPACES[$SRC_ORG]}; do

      log "$LOG_INF" ""
      log "$LOG_INF" ""
      log "$LOG_DBG" "🎯 Test (Kubernetes) vanaf $SRC_SPACE (org: $SRC_ORG)"

      cf target -o "$SRC_ORG" -s "$SRC_SPACE" >/dev/null
      src_namespace=$(cf space "$SRC_SPACE" --guid)

      TARGET_URL="https://google.com"
      result=$(curl_in_k8s_pod_and_get_result "https://google.com" "Testing connectifity from org '$SRC_ORG', space '$SRC_SPACE' to the internet" "$src_namespace")
      report_line="$SRC_ORG $SRC_SPACE INTERNET google.com $result"
      log "$LOG_INF" "Task result: $report_line"
      report+=("$report_line")


      for TGT_ORG in "${!ORG_SPACES[@]}"; do
        log "$LOG_DBG" "Processing target org '$TGT_ORG'"
        for TGT_SPACE in ${ORG_SPACES[$TGT_ORG]}; do
          log "$LOG_DBG" "Processing target space '$TGT_SPACE'"
          space_guid=$(get_guid "$TGT_ORG" "$TGT_SPACE")
          app_alias="nginx-$TGT_ORG-$TGT_SPACE"

          TARGET_URL="http://${app_alias}.${space_guid}.svc.cluster.local"
	  log "$LOG_DBG" "Tesing if direct route can be used: '$SRC_ORG' == '$TGT_ORG' and '$SRC_SPACE' == '$TGT_SPACE'"
	  if [[ "$SRC_ORG" == "$TGT_ORG" && "$SRC_SPACE" == "$TGT_SPACE" ]]; then
	    log "$LOG_DBG" "changing URL to direct route"
            TARGET_URL="http://${app_alias}"
	  fi

          log "$LOG_DBG" echo "🔍 $SRC_SPACE → $TGT_SPACE: "
	  result=$(curl_in_k8s_pod_and_get_result "$TARGET_URL" "Testing connectifity from org '$SRC_ORG', space '$SRC_SPACE' to $TARGET_URL" "$src_namespace")
          report_line="$SRC_ORG $SRC_SPACE $TGT_ORG $TGT_SPACE $result"
          log "$LOG_TRC" "task result: $report_line"
          report+=("$report_line")
        done
      done
    done
  done

  log "$LOG_INF" "
  Test result of connectivity test
  ================================
  $(printf "%s\n" "${report[@]}" | column -t)
  
 "
  log "$LOG_INF" "function test_connectivity_in_k8s finished"
}




function curl_in_runtask() {
  local url="${1?Parameter 'url' is missing in call to function 'curl_in_runtask'}"
  local info="${2:-}"
  local timeout="${3:-3}"
  local waittime="${4:-2}"

  # cf target must already be set to required org and space
  # Let op: de test-app moet al gepusht zijn met cf push

  # Start de task
  log "$LOG_INF" "$info"
  log "$LOG_CMD" "cf run-task $curl_app_name --command \"curl --max-time $timeout -s -o /dev/null -w \\\"%{http_code}\\\" $url\""
  # parameter --name is apparently not valid! So remove it from the commands below!
  RAW_OUTPUT=$(cf run-task "$curl_app_name" --command "curl --max-time $timeout -s -o /dev/null -w \"%{http_code}\" $url" 2>/dev/null)
  log "$LOG_TRC" "$RAW_OUTPUT"
  TASK_ID=$(echo "$RAW_OUTPUT" | grep -i 'task id:' | awk '{print $3}')
  log "$LOG_DBG"  "TASK_ID='$TASK_ID'"

  if [[ -z "${TASK_ID:-}" ]]; then
    die 1 "-> ⚠️ kon task niet starten"
  fi

  # Get task info
  log "$LOG_CMD" "cf task $curl_app_name $TASK_ID"
  cf task "$curl_app_name" "$TASK_ID"

  # Wacht en haal resultaat op
  sleep "$waittime"
}


function get_task_result() {
  local src_org=${1?Parameter 'src_org' is missing in call to function 'get_task_result'}
  local src_space=${2?Parameter 'src_space' is missing in call to function 'get_task_result'}
  local tgt_org=${3?Parameter 'tgt_org' is missing in call to function 'get_task_result'}
  local tgt_space=${4?Parameter 'tgt_space' is missing in call to function 'get_task_result'}
  local url=${5:-://}

  if [ "$BASH_SUBSHELL" -eq 0 ]; then
    log "$LOG_TRC" "******** Running in same shell, so test run of function get_task_result()"
  else
    log "$LOG_TRC" "******** Running in subshell, so real execution of function get_task_result (logging directly to tty)"
  fi

  while true; do
    log "$LOG_CMD" "cf tasks $curl_app_name | grep $url | head -n 1"
    result_line=$(cf tasks "$curl_app_name" | grep "$url" | head -n 1)
    task_id=$(echo "$result_line" | awk '{ print $1 }')
    log "$LOG_TRC" "$result_line"
  
    # Check if task_id is a valid number (only digits)
    if [[ "$task_id" =~ ^[0-9]+$ ]]; then
       break
   fi
  
    sleep 1
  done

  # Wait until the task is visible (cf task doesn't fail)
  #echo -n "[DEBUG] Waiting for task to be visible"		>/dev/tty
  log "$LOG_INF" "Waiting for task to be visible"
  while true; do
    log "$LOG_CMD" "cf task $curl_app_name $task_id"
    task_info=$(cf task "$curl_app_name" "$task_id" 2>/dev/null)
    log "$LOG_INF" "$task_info"
  
    if echo "$task_info" | grep -q '^id:'; then
      echo "✓"							>/dev/tty
      break
    fi
  
    echo -n "."							>/dev/tty
    sleep 1
  done

  # Wait for task to finish (SUCCEEDED or FAILED)
  log "$LOG_DBG" "Waiting for task to be finished"		>/dev/tty
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

      log "$LOG_INF" ""
      log "$LOG_INF" ""
      log "$LOG_DBG" "🎯 Test (Korifi) vanaf $SRC_SPACE (org: $SRC_ORG)"
      cf target -o "$SRC_ORG" -s "$SRC_SPACE" >/dev/null

      TARGET_URL="https://google.com"
      if ! curl_in_runtask "https://google.com" "Testing connectifity from org '$SRC_ORG', space '$SRC_SPACE' to the internet"; then
        report_line="$SRC_ORG $SRC_SPACE $TGT_ORG $TGT_SPACE NOT_STARTED Could not start runtask for curl-tester"
	continue
      fi
      #echo "[DEBUG] ======== TEST RUN FOR get_task_result ======================="
      #get_task_result "$SRC_ORG" "$SRC_SPACE" "Internet" "x" "google.com"
      #echo "[DEBUG] ======== SUBSHELL RUN FOR get_task_result ==================="
      report_line=$(get_task_result "$SRC_ORG" "$SRC_SPACE" "Internet" "google.com" "$TARGET_URL")
      #echo "[DEBUG] ======== RUNS FOR get_task_result DONE ======================"
      log "$LOG_TRC" "task result: $report_line"
      report+=("$report_line")


      for TGT_ORG in "${!ORG_SPACES[@]}"; do
	log "$LOG_DBG" "Processing target org '$TGT_ORG'"
        for TGT_SPACE in ${ORG_SPACES[$TGT_ORG]}; do
          log "$LOG_DBG" "Processing target space '$TGT_SPACE'"
          space_guid=$(get_guid "$TGT_ORG" "$TGT_SPACE")
	  app_alias="nginx-$TGT_ORG-$TGT_SPACE"

          TARGET_URL="http://${app_alias}.${space_guid}.svc.cluster.local"

          log "$LOG_DBG" "🔍 $SRC_SPACE → $TGT_SPACE: "
	  if ! curl_in_runtask "$TARGET_URL" "Testing connectifity from org '$SRC_ORG', space '$SRC_SPACE' to $TARGET_URL"; then
            report_line="$SRC_ORG $SRC_SPACE $TGT_ORG $TGT_SPACE NOT_STARTED Could not start runtask for curl-tester"
            continue
          fi
	  report_line=$(get_task_result "$SRC_ORG" "$SRC_SPACE" "$TGT_ORG" "$TGT_SPACE" "$TARGET_URL")
	  log "$LOG_TRC" "task result: $report_line"
	  report+=("$report_line")

        done
      done
    done
  done

  log "$LOG_INF" "
  Test result of connectivity test
  ================================
  $(printf "%s\n" "${report[@]}" | column -t)

 "
  log "$LOG_INF" "function test_connectivity_in_k8s finished"
}


log "$LOG_INF" "
============================================================
Setup environment for this network policy demo
============================================================
"

## Create a container image with curl that is compatible with korifi
build_folder="$tmp/$curl_app_name"
log "$LOG_INF" "Create korifi compatible container image for curl"
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

log "$LOG_CMD" "docker build -t $curl_app_image $build_folder"
docker build -t "$curl_app_image" "$build_folder"
log "$LOG_CMD" "docker push $curl_app_image"
docker push "$curl_app_image"


## Create namespaces (orgs and spaces)
log "$LOG_INF" "Create namespaces (orgs and spaces)"
for src_org in "${ALL_ORGS[@]}"; do
  create_org_with_spaces "$src_org"
done


function create_dns_friendly_alias() {
  log "$LOG_DBG" "create_dns_friendly_alias( '$1') - START"
  local app_name=$1

  local org space space_guid app_guid
  org=$(cf target | grep '^org:' | awk '{print $2}')
  space=$(cf target | grep '^space:' | awk '{print $2}')
  space_guid=$(get_guid "$org" "$space")
  app_guid=$(cf app "$app_name" --guid)

  log "$LOG_DBG" "Applying clusterIP (for $app_guid)"
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
  log "$LOG_DBG" "ClusterIP applied"
}



## Create an nginx in each org
log "$LOG_INF" "pushing nginx to each org"
nginx_image="index.docker.io/nginxinc/nginx-unprivileged"
if [[ -n "$LOCAL_IMAGE_REGISTRY_FQDN" ]];then
  nginx_image="${LOCAL_IMAGE_REGISTRY_FQDN}/${nginx_image}"
fi

## Create an nginx and a curl tester app in each space
log "$LOG_INF" "pushing curl test-app to each space"
for src_org in "${ALL_ORGS[@]}"; do
  for src_space in ${ORG_SPACES[$src_org]}; do
    # switch to this org and space
    log "$LOG_CMD" "cf target -o $src_org -s $src_space"
    cf target -o "$src_org" -s "$src_space"

    # push nginx to this space
    app_name="nginx-$src_org-$src_space"
    log "$LOG_CMD" "cf push $app_name --docker-image $nginx_image"
    cf push "$app_name" --docker-image "$nginx_image"
    log "$LOG_DBG" "creating dns alias for $app_name"
    create_dns_friendly_alias "$app_name"

    # push curl-tester app to this space
    log "$LOG_CMD" "cf push $curl_app_name --docker-image $curl_app_image --no-route --no-start" 
    cf push "$curl_app_name" --docker-image "$curl_app_image" --no-route --no-start
    log "$LOG_CMD" "cf set-health-check $curl_app_name  process"
    cf set-health-check "$curl_app_name"  process
    log "$LOG_CMD" "cf start $curl_app_name"
    cf start "$curl_app_name"
  done
done





log "$LOG_INF" "
============================================================
Baseline - What is allowed by default and what isn't
============================================================
"

test_connectivity_in_k8s
test_connectivity_in_korifi



##
## Demo 1 - Isolation per space
## 
log "$LOG_INF" "
============================================================
Demo 1 - Isolate spaces with Network Policies
============================================================
"

function isolate_space() {
  local space=$1

  log "$LOG_INF" "Create network policies to isolate space '$space'"
  log "$LOG_DBG" "Apply network policy 'allow-same-namespace' for space '$space'"
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

  log "$LOG_DBG" "Apply network policy 'deny-other-namespaces' for space '$space'"
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

log "$LOG_INF" "Isolation all spaces by name (guid)"
for src_org in "${ALL_ORGS[@]}"; do
  for src_space in ${ORG_SPACES[$src_org]}; do

    # isolate this space
    log "$LOG_INF" "Isolate org '$src_org', space '$src_space'"
    isolate_space "$(get_guid "$src_org" "$src_space")"
  done
done

# Test isoloation (in kubernetes)
#kubectl run tester -n 

test_connectivity_in_k8s
test_connectivity_in_korifi



log "$LOG_INF" "
============================================================
Cleanup
============================================================
"

## Switching back to admin 
switch_user "${ADMIN_USERNAME}" >>/dev/null

## Remove all network policies
log "$LOG_INF" "Remove all network policies"
for src_org in "${ALL_ORGS[@]}"; do
  for src_space in ${ORG_SPACES[$src_org]}; do

    # isolate this space
    guid=$(get_guid "$src_org" "$src_space")
    log "$LOG_DBG" "Remove network policies for org '$src_org', space '$src_space' ($guid)"
    kubectl delete networkpolicy -n "$guid" deny-other-namespaces
    kubectl delete networkpolicy -n "$guid" allow-same-namespace
  done
done


log "$LOG_INF" "
======== END OF SCRIPT ========
"

