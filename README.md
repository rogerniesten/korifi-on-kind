# korifi-on-kind
This repo is made during the investigation of Korifi as a replacement for Cloud Foundry for one of my clients. It contains the installation for Korifi on several platforms:
- KIND (Kubernetes in Docker) as described on https://github.com/cloudfoundry/korifi/blob/main/INSTALL.kind.md
- KIND (Kubernetes in Docker), but now as it it would be a "normal" K8s cluster
- AKS (Azure Kuberetes Services)

It also contains some scripts to demo some of the functionalities and featurs of Korifi as a PoC:
- Create some orgs, spaces and users in Korifi with different access rights
- Push some applications to Korifi
- 

## Table of contents
- [General information](#general-information)
- [Some usefull sources](#some-useful-sources)
- [Prerequisits](#prerequisits)
- Install Korifi (and Kubernetes)
   - [Install Korifi #1: Setup a korifi cluster in kind](#install-Korifi-1-setup-a-korifi-cluster-in-kind)
   - [Install Korifi #2: Setup a korifi cluster on AKS](#install-korifi-2-setup-a-korifi-cluster-on-aks)
   - [Install Korifi #3: Setup a korifi cluster on KIND the "standard" way](#install-korifi-3-setup-a-korifi-cluster-on-kind-the-standard-way)
- Demos
   - [Demo: How to add users that are limited to a specific org](#demo-how-to-add-users-that-are-limited-to-a-specific-org)
   - [Demo: Create a custom service using buildbacks (kpack)](#demo-create-a-custom-service-using-buildbacks-kpack)
   - [Demo: Combine apps (generated with buildpacks) in different organizations in Korifi with restricted userrights](#demo-combine-apps-generated-with-buildpacks-in-different-organizations-in-korifi-with-restricted-userrights)
   - [Demo: Install a 3rd party functionality as service via the korifi marketplace](#demo-install-a-3rd-party-functionality-as-service-via-the-korifi-marketplace)
   - [Demo: Setup network firewall within the korifi cluster](#setup-network-firewall-within-the-korifi-cluster)


## General information
To run the examples below, clone the repo and follow the instructions as described in the separate chapters.

The scripts ask for all required information that is not provided yet. Some of the information is cached when provided the first time (e.g. Azure credentials, Docker Registry credentials), so they don't have to be provided each time again. Other information can be provided as envirment variables to prevent the script from asking:
```
export K8S_TYPE=<type>             # which K8S type is used. Valid types are: KIND, AKS
export K8S_KORIFI_CLUSTER=<name>   # the name of the Korifi cluster
```

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

## Install Korifi #1: Setup a korifi cluster in kind
The steps to create a korifi cluster in kind (Kubernetes in Docker) are implemented in bash script install_korifi.sh.
```
$ ./install_korifi_on_kind.sh
```
First the script ensures all required and suitable tools are available (jq, golang, kind, docker, kubectl, helm, cf)
Then it creates a K8s cluster (in kind) with a specific config is described on https://github.com/cloudfoundry/korifi/blob/main/INSTALL.kind.md
Now all is ready to install korifi using a k8s yaml file
Finally it uses cf to set the api, logs in as the default user and creates an org and space

### sources / inspiration:
- https://docs.cloudfoundry.org/cf-cli/install-go-cli.html
- https://github.com/cloudfoundry/korifi/blob/main/INSTALL.kind.md

## Install Korifi #2: Setup a korifi cluster on AKS
As in a serious (read: production) situation, Korifi will be running on a "real" K8s cluster and not on a KIND cluster. This chapter shows an installation on a K8s cluster in Azure (AKS, Azure Kubernetes Service). After an initial script (install_korifi_on_aks.sh), the script was refactored and split in two scripts to separate the deployment of the K8s cluster and the installation of the actual Korifi cluster. Also all configuration is moved to environment file .env
```
$ ./deploy_aks.sh
```
Please note that access to Azure, a Service Principal is required with permissions to an Azure Subscription. An example how to create a Service Principal can be found [here](https://learn.microsoft.com/en-us/cli/azure/azure-cli-sp-tutorial-1?view=azure-cli-latest&tabs=bash). The script deploy_aks.sh will ask for the required information and credentials. All info (except password) will be cached for future runs to minimize the amount of data to provide.
After installing AzureCLI, the script tries to login to Azure with the given credential (when it fails, it ask for credentials and tries again). Then the script deploys a AKS cluster with the provided name (provided via env var K8S_CLUSTER_KORIFI or via commandline input asked by the script).
```
$ ./install_korifi.sh
```
This scripts (after checking required tools) installs Korifi in the following stages according the description on https://github.com/cloudfoundry/korifi/blob/main/INSTALL.md:
- Prerequisits (cert manager, kpack, metrics server)
- Pre-install (asking for Container Registry server and credentials, deploying Container Registry Credentials secret)
- Install (vai helm chart https://github.com/cloudfoundry/korifi/releases/download/v${KORIFI_VERSION}/korifi-${KORIFI_VERSION}.tgz)
- Post-install
   - DNS (for this PoC we don't actually setup DNS entries, but add entries in /etc/hosts to make Korifi accessible via the expected hostname)
   - routing (to make Korifi api accessible outside the K8s cluster, a HTTPRoute will be applied on host port 443)
   - Admin account cf-admin will be created, including required authorizations
   - In case KIND is used as K8s cluster, port-forwardings will be started to make api and apps accessible from outside the Docker container/network.
After the installation of Korifi, the scripts sets the api, logs in as cf-admin and creates org named "org" and space name "space".

### sources / inspiration:
- https://github.com/cloudfoundry/korifi/blob/main/INSTALL.md

### Lessons learned:
TODO: need to add

## Install Korifi #3: Setup a korifi cluster on KIND the "standard" way
Goal is to have a separation between K8S deployment and Korifi install, os Korifi can be installed on any K8s cluster, regardless of the type. Therefore the content of the script install_korifi_on_kind.sh will be stripped of the parts that installs Korifi and will be stored in the script "deploy_kind.sh". After deploy kind has finished, the script install_korifi.sh can be used to install Korifi on the KIND cluster. This turned out to be quite different than the original installation in script install_korifi_in_kind.sh.

```
$ ./deploy_kind.sh
```
After installing all required tools (if not present yet), the script deploys a KIND cluster with the provided name (provided via env var K8S_CLUSTER_KORIFI or via commandline input asked by the script).
```
$ ./install_korifi.sh
```
This scripts (after checking required tools) installs Korifi in the following stages according the description on https://github.com/cloudfoundry/korifi/blob/main/INSTALL.md:
- Prerequisits (cert manager, kpack, metrics server)
- Pre-install (asking for Container Registry server and credentials, deploying Container Registry Credentials secret)
- Install (vai helm chart https://github.com/cloudfoundry/korifi/releases/download/v${KORIFI_VERSION}/korifi-${KORIFI_VERSION}.tgz)
- Post-install
   - DNS (for this PoC we don't actually setup DNS entries, but add entries in /etc/hosts to make Korifi accessible via the expected hostname)
   - routing (to make Korifi api accessible outside the K8s cluster, a HTTPRoute will be applied on host port 443)
   - Admin account cf-admin will be created, including required authorizations
   - In case KIND is used as K8s cluster, port-forwardings will be started to make api and apps accessible from outside the Docker container/network.
After the installation of Korifi, the scripts sets the api, logs in as cf-admin and creates org named "org" and space name "space".

### sources / inspiration:
- https://github.com/cloudfoundry/korifi/blob/main/INSTALL.md

### Lessons learned:
#### Ports
Although most parts of the install_korifi.sh script are identical for both K8s clustertypes (KIND, AKS), the architectural nature of KIND forces some differences regarding ports.
Apperantly the api port is hardcoded to port 80/443, the gateway ports (for apps) are configured via helm parameters networking.gatewayPorts.http and networking.gatewayPorts.https, which default to 80/443 as well.
In a "normal" K8s cluster (like AKS), these ports can be the same because 
   1. Contour Gateway is exposed via a real LoadBalancer
      Both domains (api... and apps...) point to the same external IP of the LoadBalancer.
      The same service (e.g. envoy-korifi) is capable of routing requests based on hostname.
   2. Contour/Gateway API routes based on HTTP hostnames
      api.kc09.fake → routed to korifi-api (API service)
      my-python-app.apps.kc09.fake → routed to my-python-app Pod
   This works because Envoy or Contour sees the Host header, and routes accordingly — even though both requests hit the same LoadBalancer IP + Port 443.

Unfortunately KIND doesn’t support real LoadBalancers. So unless something like MetalLB is used, you need to:
- Manually port-forward the CF API (svc/korifi-api-svc)
- Separately port-forward the Envoy ingress (svc/envoy-korifi)
Since port-forwarding is per-service, you can’t combine both on one local port (unless you put a proxy in front of both).

#### Container registry
In the KIND installer, an internal Docker registry is used which is accessible without credential (or with dummy credentials). It took me some time to understand the function of the Container registry and why Korifi requires write access to a Container registry. When Korifi pushes an application to Korifi, it first builds the application as a container and then uploads the container image to a container registry. This is required, because Kubernetes can only deploy containers when it can download the container image from a registry. Therefore Korifi requires write access to the Container registry to uploaded them on top of the read permissions, so Kubernetes can pull them fom the registry. There are several providers where a Container registry can be used: 

##### 🏷️ Free/Low-Cost Container Registries
| Registry | Free Tier | Pricing | Domain | Notes |
|:--|:--|:--|:--|:--|
| **Docker Hub** | 1 private repo, rate limits | $5+/month | [hub.docker.com](https://hub.docker.com) | Popular, easy setup, rate-limits for unauthenticated users (100 pulls/6h) |
| **GitHub Container Registry (GHCR)** | Public free, limited private | Starts at $4/user | [ghcr.io](https://ghcr.io) | Integrated with GitHub, easy CI/CD |
| **GitLab Container Registry** | 5GB free | Starts at $19/user/month | [gitlab.com](https://gitlab.com) | Part of GitLab CI/CD |

##### 🌥️ Cloud Provider Registries
| Registry | Free Tier | Pricing | Domain | Notes |
|:--|:--|:--|:--|:--|
| **Amazon Elastic Container Registry (ECR)** | 500MB free/month | $0.10/GB-month | [aws.amazon.com/ecr](https://aws.amazon.com/ecr/) | AWS IAM integration, good for AWS users |
| **Google Artifact Registry** | 0.5GB free/month | $0.10/GB-month | [cloud.google.com/artifact-registry](https://cloud.google.com/artifact-registry) | Multi-region, GCP integrated |
| **Azure Container Registry (ACR)** | None | ~$0.167/day (Basic) | [azure.microsoft.com/container-registry](https://azure.microsoft.com/en-us/products/container-registry/) | Good for Azure users, private endpoints |

##### 🔒 Enterprise/Self-Hosted Registries
| Registry | Pricing | Domain | Notes |
|:--|:--|:--|:--|
| **JFrog Artifactory** | Starts at ~$98/month | [jfrog.com/container-registry](https://jfrog.com/container-registry/) | Enterprise-grade, multi-artifact support |
| **Sonatype Nexus** | Starts at ~$120/month | [sonatype.com/products/repository-oss](https://www.sonatype.com/products/repository-oss) | Docker, Maven, NPM, etc. |
| **Quay.io (by RedHat)** | Free public | $15/month private | [quay.io](https://quay.io) | Security scanning, RedHat support |



## Demo: How to add users that are limited to a specific org 
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
# Deploy a K8s cluster (choose one):
$ ./deploy_kind.sh
$ ./deploy_aks.sh

# install korifi:
$ ./install_korifi.sh

# create orgs and users and limit access to one (or more) orgs
$ ./demo_korifi_users_and_rbac.sh
```
After a check for prerequisits, the script creates some orgs (amsterdam, utrecht, rotterdam, nieuwegein, vijlen) and spaces (amsterdam-space, etc). Then it retrieves the CA from the K8s cluster the same way as in the K8s script.

Then some users (anton, roger) are created by generating a private key, corresponding certificate request and signed with the CA, the user certificated is created. Same way as in K8s script. Only for this demo, the certificates are stored in ./tmp instead of \~/.kube/certs (this is easier to cleanup).
The creation of the RBAC roles is slightly different. The Cloud Foundry roles OrgManager, OrgAuditor, OrgBillingManager, SpaceManager, SpaceDeveloper and Space Auditor are already availale in the K8s cluster for Korifi, so no need for ```kubectl create role```. Adding a rolebinding for a non-existing role (other than mentioned above) won't display any error and the rolebinding is created in Kubernetes. However, it doesn't do anything because no permissions nor resources are attached to that role in Kubernetes.
On Korifi level, cf set-org-role is a high level command which implicitly executed the appropriate K8s commands, including ```kubectl create rolebinding``` so no need for any kubectl command here.
Finally a yaml must be applied to create the rolebinding.
A quick check is done to verify the rolebinding.

User anton is granted for amsterdam and user roger is granted for vijlen and nieuwegein.

Now everything is setup, let's show what every user can see:
- User cf-cluster (cluster admin) is allowed to see all orgs
- User anton is only allowed to see org amsterdam
- User roger is allowed to see both orgs vijlen and nieuwegein

Open items:
- Demo more actions in restricted orgs (see script demo_apps_in_orgs.sh)

Sources:
- https://docs.cloudfoundry.org/adminguide/cli-user-management.html (not implemented for korifi!)
- https://docs.cloudfoundry.org/uaa/#:~:text=User%20Account%20and%20Authentication%20(UAA,standards%20for%20authentication%20and%20authorization.
- https://github.com/cloudfoundry/korifi/blob/main/docs/using-kubernetes-api-to-create-cf-resources.md
- https://www.youtube.com/watch?v=EUGfQS2Fu78
- https://github.com/cloudfoundry/korifi/blob/main/docs/user-authentication-overview.md

### Lessons learned
Please note that to switch to a different user, only ```cf login``` or ```cf auth``` is not always sufficient!!
If different Korifi clusters are used, ```cf login -a``` or ```cf api``` change the Korifi cluster for all cf command. However, in case you also use kubectl commands, they are still pointing to the cluster as used by the used context (set by ```kubectl config use-context <context>```). So in case you use both kubectl (or other tool to access the K8s API) and cf commands, you need to set both to avoid sending calls to the wrong cluster!



## Demo: Create a custom service using buildbacks (kpack)
This demo is based on the dzone tutorial where a java webapp will be deployed with just 1 command and a python webapp will be deployed after installing the required buildpack. After each webapp has been deployed, it's shown by cf apps command and called with a curl command to show the well known Hello World!

Prerequisits:
- First setup a korifi cluster (with name korifi) as described in chapter 'Setup a korifi cluster in kind'

Instructions:
```
# Deploy a K8s cluster (choose one):
$ ./deploy_kind.sh
$ ./deploy_aks.sh

# install korifi:
$ ./install_korifi.sh

# then push the apps to the korifi cluster and test them
$ demo_buildpacks.sh
```
This demo first pushes a java app to Korifi. Java is available in Korifi out-of-the-box, so only ```cf push my-java-app``` is sufficient to get the java app running. Python is not available out-of-the-box in Korifi. Before a python app can be pushed to Korifi, first the buildback for Python must be deployed to Korifi.

sources:
- https://tutorials.cloudfoundry.org/cf4devs/getting-started/first-push/ (not working in korifi without drastic adaptions)
- https://dzone.com/articles/deploying-python-and-java-applications-to-kubernet


## Demo: Combine apps (generated with buildpacks) in different organizations in Korifi with restricted userrights
This demo combines the two previous demos to get a better understanding of them. This also deepens the demo about restricted orgs regarding only seeing (or not seeing) a specific organization in Korifi.
For this deme we  use same the java webapp as the previous demo. To distinguish between the webapps in the different orgs, a slightly modified copy of the webapp is made for each org. The modified app will not output "Hello World!", but "Hello Amsterdam!" etc.

Prerequisits:
- First setup a korifi cluster (with name korifi) as described in chapter 'Setup a korifi cluster in kind'
- The organizations amsterdam, utrecht, nieuwegein and vijlen are required. They are created in chapter 'Demo 3: How to add users that are limited to a specific org'
- Users anton (with access to org amsterdam) and roger (with access to orgs vijlen en nieuwegein) are requred. They are created in chapter 'Demo 3: How to add users that are limited to a specific org'
- The git repository sylvainkalache/sample-web-apps needs o to be available on the server on the same level as git repository rogerniesten/korifi-on-kind (done is chapter 'Demo 4: Create a custom service using buildbacks (kpack)')

Instructions:
```
# Deploy a K8s cluster (choose one):
$ ./deploy_kind.sh
$ ./deploy_aks.sh

# Create required orgs, users and roles
$ ./demo_korifi_users_and_rbac.sh

# Clone repository sylvainkalache/sample-web-apps
$ cd ..
$ git clone https://github.com/sylvainkalache/sample-web-apps
$ cd -
# Alternatively run demo 4
$ ./demo_buildpacks.sh

# Now push the apps to several orgs in the korifi cluster and test them with several users
$ ./demo_apps_in_orgs.sh
```

After checking the prerequisits, the script demo_apps_in_orgs.sh creates an additional folder in sample-web-apps for HelloAmsterdam, HellowNieuwegein and HelloUtrecht based on the HelloWorld java webapp. I then pushes the HelloAmsterdam webapp as user anton to org amsterdam and the HelloNieuwegein webapp as user roger to nieuwegein. After each push the webapp is tested by the same user by showing the app by cf apps by the same user. 
Then user roger pushes the webapp HelloUtrecht to org Utrecht, where user roger has no access. This will fail due to the missing accessrights, as will the checks.
As a last demo all apps will be shown per user (admin (kind-korifi), anton, roger).


## Demo: Install a 3rd party functionality as service via the korifi marketplace
This example described how to install a dummy service via a OSBAPI compatible service-broker using the korifi marketplace. First attempt was to create a 'real' service (e.g. mysql), but there were too many issues (probably due to lack of understanding at that point) and deplicated repositories. Therefore the service broker https://github.com/cloudfoundry-community/worlds-simplest-service-broker was used with a dummy service.

Prerequisits:
- First setup a korifi cluster (with name korifi) as described in chapter 'Setup a korifi cluster in kind'

Instructions:
```
# Deploy a K8s cluster (choose one):
$ ./deploy_kind.sh
$ ./deploy_aks.sh

# install korifi:
$ ./install_korifi.sh

# then install a service broker and activate a service
$ demo_service_via_korifi_marketplace.sh
```

After a check for prerequisits, the world-simplest-service-broker is installed in kubernetes. Please note that there are some behaviour to be concidered when executing this demo on a Korifi cluster in KIND. As the docker network is not available by default in the underlying kubernetes cluster (kind), the instructions have been altered to install the service broker in kubernetes, so it is directly available from the kubernetes pods. For this purpose, the files broker-deployment.yaml and broker-service.yaml have been created.
Then name and IP of the pod of the service-broker will be retrieved (as they are dynamically created) to compose the URL for the service-broker 
The service-broker must be reachable from pods in korifi (so from kubernetes), hence an attempt to access the service-broker URL via curl from a temporary pod
When all is fine, cf create-service-broker is used to create the service broker
After the service is enabled (using cf enable-service-access) it is available via the korify marketplace (cf marketplace)
Finally instances of this service can be created using cf create-service)
By a final cf service command is shown that the service (instance) is available in korifi.
Due to the fact that it is a dummy service, no actions can be performed to show this service is actually working.

Sources:
- https://github.com/cloudfoundry-community/worlds-simplest-service-broker
- https://github.com/openservicebrokerapi/servicebroker
- https://github.com/kubernetes-retired/service-catalog
- https://www.youtube.com/watch?v=bm59dpmMhAk
- https://www.cloudfoundry.org/technology/open-service-broker-api/
- https://docs.cloudfoundry.org/services/examples.html
- https://github.com/openservicebrokerapi/servicebroker/blob/master/gettingStarted.md
- https://www.openservicebrokerapi.org/


## Setup network firewall within the korifi cluster

