# Project Platform Engineering IaC Vagrant K8s Cluster
Provision Kubernetes Cluster (K8S) systematically using Infrastructure as a Code (Vagrant) + some bash script instead provisioning it manually. This POC is inspired by Kelsey Hightower ["Kubernetes The Hard Way"](https://github.com/kelseyhightower/kubernetes-the-hard-way) and meant as a sandbox ground to learn K8S



## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Cluster Management](#cluster-management)
- [Accessing Services](#accessing-services)
- [Troubleshooting](#troubleshooting)
- [Project Structure](#project-structure)
- [Task Backlog](#task-backlog)

## Overview

This project provides a fully automated Kubernetes cluster deployment that includes:

- **Multi-node cluster**: 1 control plane node + 2 worker nodes (configurable)
- **Container Runtime**: CRI-O for OCI-compliant container management
- **Network Plugin**: Calico v3.28.0 for pod networking and network policies
- **Kubernetes Version**: 1.29.0
- **Monitoring**: Kubernetes Dashboard v2.7.0 with admin access
- **GitOps**: ArgoCD v2.14.8 for continuous deployment
- **Metrics**: Metrics Server for resource monitoring

The cluster is configured with custom pod and service CIDRs, DNS servers, and port forwarding for easy access to web UIs from your host machine.

## Architecture

### Network Configuration

- **Control Plane IP**: 192.168.56.10
- **Worker Node IPs**: 192.168.56.11, 192.168.56.12 (incremental)
- **Pod CIDR**: 172.16.1.0/16
- **Service CIDR**: 172.17.1.0/18
- **DNS Servers**: 8.8.8.8, 1.1.1.1

### Resource Allocation

**Control Plane Node (devnodemaster01)**:
- CPU: 4 cores
- Memory: 8192 MB
- Role: Kubernetes control plane, etcd, API server

**Worker Nodes (devnodeworker01, devnodeworker02)**:
- CPU: 4 cores each
- Memory: 8192 MB each
- Role: Application workload execution

### Exposed Ports

The following ports are forwarded from guest VMs to your host machine:

- **30001**: Kubernetes Dashboard UI (https://localhost:30001)
- **30002**: ArgoCD UI (https://localhost:30002)
- **32000**: Sample NGINX deployment (if deployed)

## Prerequisites

Ensure you have the following software installed on your host machine:

### Required Software

1. **Oracle VirtualBox** (6.1 or higher)
   - Download: https://www.virtualbox.org/wiki/Downloads
   - Required for VM provisioning

2. **Hashicorp Vagrant** (2.2 or higher)
   - Download: https://www.vagrantup.com/downloads
   - Automates VM lifecycle management

3. **kubectl** (1.29 or compatible)
   - Download: https://kubernetes.io/docs/tasks/tools/
   - Kubernetes command-line tool

4. **Helm** (3.x)
   - Download: https://helm.sh/docs/intro/install/
   - Kubernetes package manager (optional but recommended)


### System Requirements

- **CPU**: Multi-core processor (8+ cores recommended)
- **RAM**: 16 GB minimum (24 GB recommended for smooth operation)
- **Disk**: 50 GB free space
- **OS**: Windows, macOS, or Linux

### Network Requirements

Ensure VirtualBox is configured to allow the private network range 192.168.56.0/24:

**For VirtualBox 6.1.28+**, edit `/etc/vbox/networks.conf` (create if it doesn't exist):
```
* 192.168.56.0/24
```

## Quick Start

### 1. Clone the Repository

```shell
git clone https://github.com/Adhito/poc-platform-engineering-iac-vagrant-k8s-cluster-kubeadm-calico
cd project-platform-engineering-iac-vagrant-k8s-cluster
```

### 2. Review Configuration (Optional)

Edit `settings.yaml` to customize:
- Node count and resources
- Network configuration
- Software versions
- Cluster name

### 3. Provision the Cluster

```shell
vagrant up
```

This command will:
1. Download the Ubuntu 22.04 base box (first run only)
2. Create and configure 3 VMs (1 control plane + 2 workers)
3. Install and configure CRI-O container runtime
4. Initialize the Kubernetes cluster with kubeadm
5. Deploy Calico CNI plugin
6. Install Kubernetes Dashboard
7. Deploy ArgoCD for GitOps
8. Generate and save access credentials

**Estimated time**: 15-25 minutes (depending on internet speed and hardware)

### 4. Verify the Installation

After provisioning completes, verify the cluster status:

```shell
# Copy kubeconfig from the generated configs directory
cp configs/config ~/.kube/config

# Check cluster nodes
kubectl get nodes

# Expected output:
# NAME               STATUS   ROLE           AGE   VERSION
# devnodemaster01    Ready    control-plane  5m    v1.29.0
# devnodeworker01    Ready    worker         4m    v1.29.0
# devnodeworker02    Ready    worker         3m    v1.29.0

# Check all pods
kubectl get pods -A
```

## Configuration

### Customizing settings.yaml

The `settings.yaml` file controls all aspects of your cluster:

```yaml
cluster_name: Development Kubernetes Cluster Kubeadm Calico Vagrant

network:
  control_ip: 192.168.56.10       # Control plane IP
  dns_servers:
    - 8.8.8.8
    - 1.1.1.1
  pod_cidr: 172.16.1.0/16          # Pod network CIDR
  service_cidr: 172.17.1.0/18      # Service network CIDR

nodes:
  control:
    cpu: 4                          # Control plane CPU cores
    memory: 8192                    # Control plane RAM in MB
  workers:
    count: 2                        # Number of worker nodes
    cpu: 4                          # Worker CPU cores per node
    memory: 8192                    # Worker RAM in MB per node

software:
  box: bento/ubuntu-22.04          # Base OS image
  calico: 3.28.0                   # Calico CNI version
  dashboard: 2.7.0                 # K8s Dashboard version
  kubernetes: 1.29.0-*             # Kubernetes version
  argocd: 2.14.8                   # ArgoCD version
```

### Environment Variables

You can set environment variables for container runtime and kubelet by uncommenting the `environment` section in `settings.yaml`:

```yaml
environment: |
  HTTP_PROXY=http://my-proxy:8000
  HTTPS_PROXY=http://my-proxy:8000
  NO_PROXY=127.0.0.1,localhost,master-node,node01,node02
```

### Shared Folders

Mount additional directories from your host to VMs:

```yaml
shared_folders:
  - host_path: ../script-manifest
    vm_path: /vagrant/script-manifest
  - host_path: ../scripts
    vm_path: /vagrant/scripts
```

## Cluster Management

### Starting the Cluster

Start all nodes (after initial provisioning or halt):

```shell
vagrant up
```

Start specific nodes:

```shell
vagrant up devnodemaster01
vagrant up devnodeworker01
```

### Stopping the Cluster

Gracefully stop all nodes:

```shell
vagrant halt
```

Stop specific nodes:

```shell
vagrant halt devnodeworker02
```

### Restarting the Cluster

```shell
# Stop the cluster
vagrant halt

# Start the cluster
vagrant up
```

### Destroying the Cluster

**Warning**: This permanently deletes all VMs and data.

```shell
vagrant destroy -f
```

### Checking Cluster Status

```shell
# Check Vagrant VM status
vagrant status

# SSH into control plane
vagrant ssh devnodemaster01

# SSH into worker node
vagrant ssh devnodeworker01

# Check Kubernetes cluster health
kubectl get nodes
kubectl get pods -A
kubectl cluster-info
```

### Reprovisioning

Re-run provisioning scripts without destroying VMs:

```shell
# Reprovision all nodes
vagrant provision

# Reprovision specific node
vagrant provision devnodemaster01

# Reprovision specific provisioner
vagrant provision --provision-with setup-dashboard
```

## Accessing Services

### Kubernetes Dashboard

The Kubernetes Dashboard provides a web-based UI for cluster management.

**Access URL**: https://localhost:30001

**Authentication**:
1. Select "Token" authentication method
2. Use the token from `configs/credential_token` file:

```shell
cat configs/credential_token
```

3. Copy and paste the token into the dashboard login

**Features**:
- View cluster resources (pods, services, deployments)
- Monitor resource utilization
- View logs and exec into containers
- Deploy applications via UI

### ArgoCD

ArgoCD provides GitOps continuous delivery for Kubernetes.

**Access URL**: https://localhost:30002

**Credentials**:
- **Username**: `admin`
- **Password**: Located in `configs/credentials_argocd_admin_password`

```shell
cat configs/credentials_argocd_admin_password
```

**Getting Started with ArgoCD**:
1. Login with admin credentials
2. Connect your Git repository
3. Create an application pointing to your manifests
4. ArgoCD will automatically sync and deploy

### Using kubectl

The kubeconfig file is automatically generated at `configs/config`:

```shell
# Set KUBECONFIG environment variable
export KUBECONFIG=$(pwd)/configs/config

# Or copy to default location
cp configs/config ~/.kube/config

# Verify access
kubectl get nodes
kubectl get pods -A
```

## Troubleshooting

### Common Issues

**Issue**: VMs fail to start with network errors

**Solution**: Ensure the network range is allowed in VirtualBox:
```shell
# Create/edit /etc/vbox/networks.conf
echo "* 192.168.56.0/24" | sudo tee -a /etc/vbox/networks.conf
```

---

**Issue**: Nodes show "NotReady" status

**Solution**: Check Calico pod status:
```shell
kubectl get pods -n kube-system | grep calico
kubectl logs -n kube-system <calico-node-pod>
```

---

**Issue**: Dashboard or ArgoCD not accessible

**Solution**: Verify port forwarding and service status:
```shell
# Check services
kubectl get svc -n kubernetes-dashboard
kubectl get svc -n argocd

# Verify VirtualBox port forwarding
vagrant ssh devnodemaster01 -c "netstat -tuln | grep -E '30001|30002'"
```

---

**Issue**: Insufficient resources

**Solution**: Reduce resource allocation in `settings.yaml`:
```yaml
nodes:
  control:
    cpu: 2
    memory: 4096
  workers:
    count: 1
    cpu: 2
    memory: 4096
```

### Logs and Debugging

```shell
# View Vagrant provisioning logs
vagrant up --debug

# SSH into node for debugging
vagrant ssh devnodemaster01

# Check kubelet logs
sudo journalctl -u kubelet -f

# Check CRI-O logs
sudo journalctl -u crio -f

# View kubeadm logs
sudo cat /var/log/kubeadm-init.log
```

### Reset and Recovery

To reset a node without destroying it:

```shell
# SSH into the node
vagrant ssh devnodemaster01

# Reset kubeadm
sudo kubeadm reset -f

# Exit and reprovision
exit
vagrant provision devnodemaster01
```

## Project Structure

```
project-platform-engineering-iac-vagrant-k8s-cluster/
├── Vagrantfile                              # Main Vagrant configuration
├── settings.yaml                            # Cluster configuration
├── README.md                                # This file
├── configs/                                 # Generated configuration files
│   ├── config                              # Kubernetes kubeconfig
│   ├── setup-join.sh                       # Worker join command
│   ├── credential_token                    # Dashboard token
│   └── credentials_argocd_admin_password   # ArgoCD password
└── scripts-setup/                          # Provisioning scripts
    ├── setup-node-all.sh                   # Common setup for all nodes
    ├── setup-node-control-plane.sh         # Control plane initialization
    ├── setup-node-worker.sh                # Worker node setup
    ├── setup-infra-utility-dashboard.sh    # Dashboard deployment
    └── setup-infra-utility-argocd.sh       # ArgoCD deployment
```

### Generated Files

After running `vagrant up`, the following files are generated in the `configs/` directory:

- **config**: Kubernetes admin kubeconfig file
- **setup-join.sh**: Command to join worker nodes to the cluster
- **credential_token**: Bearer token for Kubernetes Dashboard authentication
- **credentials_argocd_admin_password**: ArgoCD admin password

**Important**: The `configs/` directory is regenerated on each `vagrant up` run.

## Task Backlog

### Completed ✓

- [x] Create service for ArgoCD WebUI with NodePort type
- [x] Automated cluster provisioning with Vagrant
- [x] Calico CNI integration
- [x] Kubernetes Dashboard with admin access
- [x] ArgoCD GitOps deployment
- [x] Metrics Server installation

### In Progress

- [ ] Load testing and performance optimization
- [ ] Documentation for common deployment patterns

### Planned

- [ ] Create service for ArgoCD WebUI with LoadBalancer type (requires MetalLB)
- [ ] Add Ingress controller (NGINX or Traefik)
- [ ] Implement persistent storage with Longhorn or Rook
- [ ] Add monitoring stack (Prometheus + Grafana)
- [ ] Configure backup solution (Velero)
- [ ] Add cert-manager for automatic TLS certificates
- [ ] Implement network policies and security hardening
- [ ] Create example application deployments
- [ ] Add automated testing pipeline
- [ ] Multi-cluster federation setup

## Additional Resources

- **Kubernetes Documentation**: https://kubernetes.io/docs/
- **Vagrant Documentation**: https://developer.hashicorp.com/vagrant/docs
- **Calico Documentation**: https://docs.tigera.io/calico/latest/about
- **ArgoCD Documentation**: https://argo-cd.readthedocs.io/
- **kubeadm Reference**: https://kubernetes.io/docs/reference/setup-tools/kubeadm/

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests to the repository.

## License

This project is open-source and available under the MIT License.

---

**Repository**: https://github.com/Adhito/poc-platform-engineering-iac-vagrant-k8s-cluster-kubeadm-calico

**Maintainer**: Adhito

**Last Updated**: 2025