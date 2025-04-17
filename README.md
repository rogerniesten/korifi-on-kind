# korifi-on-kind
Investigation on korifi on kind, including marketplace, etc.

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
First the script ensures all required and suitable tools are available (jq, golang, kind, docker, kubectl, helm, cf)
Then it creates a K8s cluster (in kind) with a specific config
Now all is ready to install korifi using a k8s yaml file
Finally it uses cf to set the api, logs in as the default user and creates an org and space

sources:
- https://docs.cloudfoundry.org/cf-cli/install-go-cli.html
- https://github.com/cloudfoundry/korifi/blob/main/INSTALL.kind.md


## Install a 3rd party functionality as service via the korifi marketplace
This example described how to install a dummy service via a OSBAPI compatible service-broker using the korifi marketplace. First attempt was to create a 'real' service (e.g. mysql), but there were too many issues (probably due to lack of understanding at that point) and deplicated repositories. Therefore the service broker https://github.com/cloudfoundry-community/worlds-simplest-service-broker was used with a dummy service.

Prerequisits:
- First setup a korifi cluster (with name korifi) as described in chapter 'Setup a korifi cluster in kind'

After a check for prerequisits and a cleanup (for idempotency), the world-simplest-service-broker is installed in kubernetes. Please note that the instructions in the repository are to install it in docker. As the docker network is not available by default in the underlying kubernetes cluster (kind), the instructions have been altered to install the service broker in kubernetes, so it is directly available from the kubernetes pods. For this purpose, the files broker-deployment.yaml and broker-service.yaml have been created.
Then name and IP of the pod of the service-broker will be retrieved (as they are dynamically created) to compose the URL for the service-broker 
The service-broker must be reachable from pods in korifi (so from kubernetes), hence an attempt to access the service-broker URL via curl from a temporary pod
When all is fine, cf create-service-broker is used to create the service broker
After the service is enabled (using cf enable-service-access) it is available via the korify marketplace (cf marketplace)
Finally instances of this service can be created using cf create-service)
By a final cf service command is shown that the service (instance) is available in korifi.
Due to the fact that it is a dummy service, no actions can be performed to show it is working.

Sources:
- https://github.com/cloudfoundry-community/worlds-simplest-service-broker
- 

## How to add users that are limited to a specific org 


## Setup network firewall within the korifi cluster


## Create a custom service using buildbacks (kpack)



