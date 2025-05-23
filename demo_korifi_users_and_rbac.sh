#! /bin/bash

##
## Demo Users and RBAC in Korifi to separate permissions in orgs 
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
sync_k8s_user


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
assert "kubectl cluster-info | grep 'Kubernetes control plane is running'"

# Is Korifi up and running?
#kubectl config use-context kind-korifi
echo "cf api https://${CF_API_DOMAIN} --skip-ssl-validation"
cf api "https://${CF_API_DOMAIN}" --skip-ssl-validation
echo "cf login -u ${ADMIN_USERNAME} -a https://${CF_API_DOMAIN} --skip-ssl-validation"
cf login -u "${ADMIN_USERNAME}" -a "https://${CF_API_DOMAIN}" --skip-ssl-validation

cf target -o org -s space

kubectl get pods -n korifi
assert "kubectl get pods -n korifi | grep Running"
echo "...done"




##
## Starts orgs & users demo
##


## Create orgs and spaces
cf create-org amsterdam
cf create-space -o amsterdam amsterdam-space
cf create-org utrecht
cf create-space -o utrecht utrecht-space
cf create-org rotterdam
cf create-space -o rotterdam rotterdam-space
cf create-org nieuwegein
cf create-space -o nieuwegein nieuwegein-space
cf create-org vijlen
cf create-space -o vijlen vijlen-space
echo "Orgs and spaces created successfully."


## Create users for this demo
create_k8s_user_cert "anton@${K8S_CLUSTER_KORIFI}" 
create_k8s_user_cert "roger@${K8S_CLUSTER_KORIFI}"



function create_rbac() {
  local username=$1
  local userorg=$2
  local cf_org_role="OrgManager"        # currently hardcoded, should probably be a parameter
  local userspace="${userorg}-space"	# currently generated, should probably be a parameter (in all demos in this repo every org has a space called <org>-space)
  local cf_space_role="SpaceDeveloper"  # currently hardcoded, should probably be a parameter

  ## Valid ClusterRoles in Kubernetes:
  #	ClusterRole/korifi-controllers-admin
  #	ClusterRole/korifi-controllers-organization-manager
  #	ClusterRole/korifi-controllers-organization-user
  #	ClusterRole/korifi-controllers-root-namespace-user
  #	ClusterRole/korifi-controllers-space-developer
  #	ClusterRole/korifi-controllers-space-manager

  ## Valid Roles in Korifi / Cloud Foundry:
  #	OrgManager 	- Invite and manage users, select and change plans, and set spending limits
  #	BillingManager 	- Create and manage the billing account and payment info
  #	OrgAuditor 	- Read-only access to org info and reports
  #	SpaceManager - Invite and manage users, and enable features for a given space
  #	SpaceDeveloper - Create and manage apps and services, and see logs and reports
  #	SpaceAuditor - View logs, reports, and settings on this space
  #	SpaceSupporter [Beta role, subject to change] - Manage app lifecycle and service bindings

  ## Mapping
  #	CF/Korifi Role	Kubernetes ClusterRole			Notes
  #     OrgManager	korifi-controllers-organization-manager	Full admin access to specific org namespace
  #     OrgAuditor	korifi-controllers-organization-user	Read-only or scoped access to org
  #	BillingManager						Billing isn't handled at Kubernetes/Korifi level
  #     SpaceManager    korifi-controllers-space-manager        Manage users and feature flags in space
  #     SpaceDeveloper	korifi-controllers-space-developer	Full developer access (apps, routes, services)
  #	SpaceAuditor	?					Missing ClusterRole — you'd need to create one manually
  #     SpaceSupporter  (Not currently mapped (Beta/Planned))	No ClusterRole yet, maybe planned
  #     <none> *)	korifi-controllers-admin                Possibly used by controllers, not for users
  #     <none> *)	korifi-controllers-root-namespace-user  Access to root namespace for system components
  #
  #	*) Likely internal Korifi role in Kubernetes


  local org_guid space_guid
  cf target -o "${userorg}"
  org_guid=$(cf org --guid "${userorg}")
  space_guid=$(cf space --guid "${userspace}")

  echo "Create RBAC (for $username in $userorg as $cf_org_role)..."
  # Note:
  # The commands 'cf set-org-role ...', 'kubectl create rolebinding ...' and 'kubectl  apply -f rolebinding.yaml'
  # have a three the same result! (except for the auto-generated binding name for cf set-org-role)
  # After testing it turns out that there is no Result is 3 times the same rolebinding with different
  # binding names, but same user and clusterrole!
  # However, cf orgs only works when using cf set-org-role, so this command seems to be doing more than
  # only setting rolebindings.
  #
  # Conclusion:
  # The command 'cf set-org-role' must be used and the other two are completely superfluous and can
  # be removed.

  echo " - set role '${cf_org_role}' for user '${username}' for org '${userorg}'"
  #echo "   DBG: cf set-org-role \"${username}\" \"${userorg}\" \"${cf_org_role}\""
  cf set-org-role "${username}" "${userorg}" "${cf_org_role}"

  # Verify Kubernetes RoleBinding
  echo " - verifying the RoleBinding in Kubernetes"
  #echo "   DBG: kubectl get rolebindings -n \"${org_guid}\""
  kubectl get rolebindings -n "${org_guid}"

  echo " - set role '${cf_space_role}' for user '${username}' for space ${userspace} in org '${userorg}'"
  #echo "   DBG: cf set-space-role \"${username}\" \"${userorg}\" \"${userspace}\" \"${cf_space_role}\""
  cf set-space-role "${username}" "${userorg}" "${userspace}" "${cf_space_role}"

  # Verify Kubernetes RoleBinding for Space ${userorg}-space
  echo " - verifying the RoleBinding in Kubernetes for space '${userspace}' ($space_guid)"
  #echo "   DBG: kubectl get rolebindings -n \"${space_guid}\""
  kubectl get rolebindings -n "${space_guid}"
  echo "...Done"
}

## Grant access to users for orgs
create_rbac "anton@${K8S_CLUSTER_KORIFI}" "amsterdam" 
create_rbac "roger@${K8S_CLUSTER_KORIFI}" "vijlen"
create_rbac "roger@${K8S_CLUSTER_KORIFI}" "nieuwegein"



function switch_user() {
  local username=$1

  echo "Switch to user '$username'..."
  # Validate name in k8s
  #echo " - validate username '$username' against k8s"
  assert kubectl config get-contexts | grep "$username" >/dev/null

  # This is not required, but ensures that cf and k8s are in sync regarding environment (in case of multiple envs)
  #echo " - switch to k8s context ${username}"
  kubectl config use-context "${username}"

  #echo " - setting cf api"
  cf api "https://${CF_API_DOMAIN}" --skip-ssl-validation
  #echo " - executing cf auth"
  cf auth "${username}"

  #echo "...done"
}



##
## Now show the results of the demo
##
echo ""
echo ""
echo "Show orgs for different users based on their access"
echo "==================================================="
echo ""

# 1. Show all orgs as admin
echo "Show all orgs as admin"
switch_user "${ADMIN_USERNAME}"

echo "exec: cf orgs"
cf orgs #2>/dev/null

echo "--------------"


# 2. Show all accessible orgs as anton
echo "Show all accessible orgs as anton"
switch_user "anton@${K8S_CLUSTER_KORIFI}"

echo "exec: cf orgs"
cf orgs #2>/dev/null

echo "--------------"


# 3. Show all accessible orgs as roger
echo "Show all accessible orgs as roger"
switch_user "roger@${K8S_CLUSTER_KORIFI}"

echo "exec: cf orgs"
cf orgs #2>/dev/null

echo "--------------"


# 9. switch back to admin
switch_user "${ADMIN_USERNAME}"

echo "==== END OF SCRIPT ===="
echo ""
