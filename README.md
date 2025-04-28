# korifi-on-kind
Investigation on korifi on kind, including marketplace, etc.

## Some useful sources:
- https://tutorials.cloudfoundry.org/korifi/overview/
- https://docs.cloudfoundry.org/adminguide/index.html
- https://bosh.io/docs/
- https://tutorials.cloudfoundry.org/korifi/cf/
- https://v3-apidocs.cloudfoundry.org/version/3.191.0/index.html
- 

## Prerequisits
The examples below are all based on a ubuntu server, so you need an ubuntu server to run these scripts on.

Following ubuntu servers have been used / tested:
- Ubuntu Server 20.04 VM (2 CPU cores, 3GB) on a Synology DS918+ (4 CPU, 8GB) [not all tests worked on this VM due to CPU/RAM limitations]
- Ubuntu Server 24.04 Azure VM (Standard_B2s: 2 vCPU, 4GB) [not all tests worked on this VM due to CPU/RAM limitations]
- Ubuntu Server 24.04 Azure VM (Stardard_D4s_v3: 4 vCPU, 16GB) [so far all tests worked fine on this VM]

To run the examples below, clone the repo and follow the instructions as described in the separate chapters.

```
$ git clone https://github.com/rogerniesten/korifi-on-kind.git
```

Note: 
When running the scripts as an ordinary user, there are some issues (not investigated in detail). Therefore it is recommended to run these scripts as root or switch to root and run the scripts as such.
WARNING: be careful when switching to root! This is in general not recommended!
```
$ sudo env "PATH=$PATH" bash -i
```

All scripts are attempted to be idempotent, so multiple runs will give the same result in the end. However, in some cases this might not be achieved entirely. So in case you run into issues it is recommended to start again from scratch (in most cases re-run the script install_korifi.sh is sufficient as it does a complete cleanup before it starts installing).

## Setup a korifi cluster in kind
The steps to create a korifi cluster in kind (Kubernetes in Docker) are implemented in bash script install_korifi.sh.
```
$ ./install_korifi.sh
```
First the script ensures all required and suitable tools are available (jq, golang, kind, docker, kubectl, helm, cf)
Then it creates a K8s cluster (in kind) with a specific config
Now all is ready to install korifi using a k8s yaml file
Finally it uses cf to set the api, logs in as the default user and creates an org and space

sources / inspiration:
- https://docs.cloudfoundry.org/cf-cli/install-go-cli.html
- https://github.com/cloudfoundry/korifi/blob/main/INSTALL.kind.md


## Install a 3rd party functionality as service via the korifi marketplace
This example described how to install a dummy service via a OSBAPI compatible service-broker using the korifi marketplace. First attempt was to create a 'real' service (e.g. mysql), but there were too many issues (probably due to lack of understanding at that point) and deplicated repositories. Therefore the service broker https://github.com/cloudfoundry-community/worlds-simplest-service-broker was used with a dummy service.

Prerequisits:
- First setup a korifi cluster (with name korifi) as described in chapter 'Setup a korifi cluster in kind'

Instructions:
```
# install korifi, if not done yet:
$ ./install_korifi.sh

# then install a service broker and activate a service
$ install_service_via_korifi_marketplace.sh
```

After a check for prerequisits, the world-simplest-service-broker is installed in kubernetes. Please note that the instructions in the repository are to install it in docker. As the docker network is not available by default in the underlying kubernetes cluster (kind), the instructions have been altered to install the service broker in kubernetes, so it is directly available from the kubernetes pods. For this purpose, the files broker-deployment.yaml and broker-service.yaml have been created.
Then name and IP of the pod of the service-broker will be retrieved (as they are dynamically created) to compose the URL for the service-broker 
The service-broker must be reachable from pods in korifi (so from kubernetes), hence an attempt to access the service-broker URL via curl from a temporary pod
When all is fine, cf create-service-broker is used to create the service broker
After the service is enabled (using cf enable-service-access) it is available via the korify marketplace (cf marketplace)
Finally instances of this service can be created using cf create-service)
By a final cf service command is shown that the service (instance) is available in korifi.
Due to the fact that it is a dummy service, no actions can be performed to show it is working.

Sources:
- https://github.com/cloudfoundry-community/worlds-simplest-service-broker
- https://github.com/openservicebrokerapi/servicebroker
- https://github.com/kubernetes-retired/service-catalog
- https://www.youtube.com/watch?v=bm59dpmMhAk
- https://www.cloudfoundry.org/technology/open-service-broker-api/
- https://docs.cloudfoundry.org/services/examples.html
- https://github.com/openservicebrokerapi/servicebroker/blob/master/gettingStarted.md
- https://www.openservicebrokerapi.org/


## How to add users that are limited to a specific org 
In order to give each department its own little corner in the Korifi cluster, users can be limited to access only one organisation in Korifi. Cloud Foundry has implemented User Account and Authentication (UAA) which acts as an OAuth2 provider. Korifi uses a different approach and delegates this responsibility to the Kubernetes API server and Kubernetes native RBAC. See [here](https://github.com/cloudfoundry/korifi/blob/main/docs/user-authentication-overview.md) for more details.
Therefore user management in Korif is slightly different from user management in Cloud Foundry. Commands like cf create-user or cf delete user as described [here](https://docs.cloudfoundry.org/adminguide/cli-user-management.html) are not available in Korifi. Kubernetes tool kubectl is need for creating, modifying, deleting and granting users. It is also required to change the kubernetes context when switching to a different user, besides logging in using cf login or cf auth. 
Please note that Kubernetes by itself doesn't store user account! The example script mentioned below creates a user by creating a certificate for that user, which is signed by the CA of that cluster (KIND creates a self signed CA). By creating RBAC bindings, the access is defined for a user (certificate).

To get a better understanding of RBAC in Kubernetes, the following script has been developed:
```
$ ./demo_k8s_rbac.sh
```
This script creates a Kubernetes cluster (KIND) called city-cluster with 3 namespaces (amsterdam, utrecht, rotterdam). (Note that orgs and spaces in Korifi are implemented as namespaces in Kubernetes).
The Kubernetes CA (cert and key) are retrieved respectively from the kubernetes config and the control-plane node of the cluster. These are required to sign the user certificates.
Then users are created by generating a private key, corresponding certificate request and signed with the CA, the user certificated is created. For this script, all certificates are stored in \~/.kube/certs. In a production environment, each user would have its own \~/.kube/config which would dictate the user to be used. In this demo script the current user (root) can switch to different users.
Then ```kubectl config set-credentials``` is used to bind the certificate and private key to the user. This adds a user item to the users array in the kubernetes configuration yaml file (\~/.kube/config or the file specified by environment variable KUBECONFIG). With ```kubectl config set-context``` the user is bound to a kubernetes cluster and a specific namespace. This adds a context item the the contexts array in the kubernetes configuration yaml file.
Finally a RBAC role is created and bound to the users, using respectively kubectl create role and kubectl create rolebinding.
To have some pods visible in the namespaces, a (dummy) nginx is started in each namespace.
By changing the context with ```kubectl config use-context <user>-context``` (and logically change to another user), only resources in the granted namespace will be visible. Only the admin (kind-city-cluster) will be able to see resources in all namespaces.

After understanding users and RBAC in kubernetes, it's time to develop a demo script for users and rbac in Korifi.
```
# install korifi, if not done yet:
$ ./install_korifi.sh

# create orgs and users and limit access to one (or more) orgs
$ ./demo_korifi_users_and_rbac.sh
```
After a check for prerequisits, the script creates some orgs (amsterdam, utrecht, rotterdam, nieuwegein, vijlen) and spaces (amsterdam-space, etc). Then it retrieves the CA from the K8s cluster the same way as in the K8s script.

Then some users (anton, roger) are created by generating a private key, corresponding certificate request and signed with the CA, the user certificated is created. Same way as in K8s script. Only for this demo, the certificates are stored in ./tmp instead of \~/.kube/certs (this is easier to cleanup).
The creation of the RBAC roles is slightly different. The Cloud Foundry roles OrgManager, OrgAuditor, OrgBillingManager, SpaceManager, SpaceDeveloper and Space Auditor are already availale in the K8s cluster for Korifi, so no need for ```kubectl create role```.
On Korifi level, cf set-org-role is a high level command which implicitly executed the appropriate K8s commands, including ```kubectl create rolebinding```.
Finally a yaml must be applied to create the rolebinding.
A quick check is dome to verify the rolebinding.

User anton is granted for amsterdam and user roger is granted for vijlen and nieuwegein.

Please note that to switch to a different user, only ```cf login``` or ```cf auth``` is not sufficient!!
To switch, you first need to change the context in K8s (```kubectl config user-context <user>```) and then login with ```cf auth <user>``` or ```cf login```.

Now everything is setup, let's show what every user can see:
- User kind-korifi (cluster admin) is allowed to see all orgs
- User anton is only allowed to see org amsterdam
- User roger is allowed to see both orgs vijlen and nieuwegein

Open items:
- Not sure whether other roles than the predefined roles are required, nor how to create them
- kubectl create rolebinding must be removed from function create_rbac as it seems to be superfluous. Test before commit as it is proposed by ChatGPT!!
- Demo more actions in restricted orgs

Sources:
- https://docs.cloudfoundry.org/adminguide/cli-user-management.html (not implemented for korifi!)
- https://docs.cloudfoundry.org/uaa/#:~:text=User%20Account%20and%20Authentication%20(UAA,standards%20for%20authentication%20and%20authorization.
- https://github.com/cloudfoundry/korifi/blob/main/docs/using-kubernetes-api-to-create-cf-resources.md
- https://www.youtube.com/watch?v=EUGfQS2Fu78
- https://github.com/cloudfoundry/korifi/blob/main/docs/user-authentication-overview.md


## Setup network firewall within the korifi cluster


## Create a custom service using buildbacks (kpack)



sources:
- https://tutorials.cloudfoundry.org/cf4devs/getting-started/first-push/


