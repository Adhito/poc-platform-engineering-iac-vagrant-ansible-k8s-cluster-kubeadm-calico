# Project Platform Engineering IaC Vagrant Ansbile K8s Cluster
Provision Kubernetes Cluster (K8S) systematically using Infrastructure as Code — Vagrant manages VM lifecycle and Ansible (running inside each guest via `ansible_local`) handles all provisioning, with no manual steps required on the host. This POC is inspired by Kelsey Hightower ["Kubernetes The Hard Way"](https://github.com/kelseyhightower/kubernetes-the-hard-way) and meant as a sandbox ground to learn K8S



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
- **Dashboard Alternative**: Headlamp v0.26.0 lightweight Kubernetes UI
- **Load Balancing**: MetalLB for bare-metal `LoadBalancer` services on the hostonly network
- **Ingress**: ingress-nginx, exposing ArgoCD at a `nip.io` hostname alongside its NodePort

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
- **30003**: Headlamp UI (http://localhost:30003)
- **31000**: OpenTelemetry Demo frontend proxy (http://localhost:31000)
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

MetalLB hands out IPs from `network.metallb_ip_range` in `settings.yaml` (default `192.168.56.200-192.168.56.230`) on this same subnet. Before provisioning, confirm this range doesn't overlap your VirtualBox hostonly adapter's own DHCP server, or any `IPAddressPool` from another MetalLB install already sharing this cluster:
```shell
VBoxManage list dhcpservers
kubectl get ipaddresspool -A
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
  metallb_ip_range: 192.168.56.200-192.168.56.230  # MetalLB LoadBalancer IP pool

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
  metallb: 0.14.9                  # MetalLB version
  ingress_nginx: 1.11.3            # ingress-nginx controller version
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

Re-run Ansible provisioning without destroying VMs:

```shell
# Reprovision all nodes
vagrant provision

# Reprovision specific node
vagrant provision devnodemaster01
vagrant provision devnodeworker01
vagrant provision devnodeworker02
```

> **Note**: `kubeadm init` and `kubeadm join` are one-shot operations guarded by file checks. Reprovisioning the control plane on an already-initialized cluster requires a full `vagrant destroy -f && vagrant up`.

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

**Access URL (NodePort)**: https://localhost:30002

**Access URL (Ingress)**: `https://infra-utility-argocd.<lb-ip>.nip.io`, where `<lb-ip>` is the ingress-nginx controller's LoadBalancer IP. (Utility tools follow an `infra-utility-<tool>` hostname convention; the label comes from the `argocd_ingress_host` default in `ansible/roles/addon_argocd/defaults/main.yaml`.)

```shell
# Fresh standalone cluster (this repo installed ingress-nginx):
cat configs/credential_ingress_nginx_lb_ip
# Shared cluster (reusing an existing controller): the value of
# network.existing_ingress_nginx_lb_ip in settings.yaml
# e.g. 192.168.56.240 -> https://infra-utility-argocd.192.168.56.240.nip.io
```

The Ingress uses the `nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"` annotation, so ingress-nginx forwards over HTTPS to `argocd-server`'s own self-signed TLS backend — no controller-level SSL-passthrough flag is required, which is what lets the Ingress reuse an ingress-nginx controller this repo doesn't own. Your browser shows a self-signed certificate warning on either URL; this is expected, click through it. The NodePort URL keeps working unchanged.

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

**Node VM unresponsive or won't boot** (e.g. `VERR_VD_VMDK_INVALID_HEADER` from a storage
interruption): see [documents/DOCUMENTS-runbook-node-recovery.md](documents/DOCUMENTS-runbook-node-recovery.md)
for the full diagnose → safe reboot → rebuild → cross-project fixup sequence.

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
poc-platform-engineering-iac-vagrant-ansible-k8s-cluster-kubeadm-calico/
├── Vagrantfile                              # VM definitions; reads settings.yaml, drives ansible_local
├── settings.yaml                            # Single source of truth for all versions, IPs, resources
├── README.md                                # This file
├── configs/                                 # Generated during provisioning (do not edit manually)
│   ├── config                              # Kubernetes kubeconfig for host kubectl access
│   ├── setup-join.sh                       # kubeadm join command relayed from control plane to workers
│   ├── credential_token                    # Dashboard bearer token
│   ├── credentials_argocd_admin_password   # ArgoCD admin password
│   ├── credential_headlamp_token           # Headlamp service account token
│   └── credential_ingress_nginx_lb_ip      # MetalLB-assigned LoadBalancer IP for ingress-nginx
├── ansible/                                 # All provisioning logic
│   ├── ansible.cfg
│   ├── inventory/hosts.ini
│   ├── playbooks/
│   │   ├── pb_control_plane.yaml           # Runs on devnodemaster01
│   │   ├── pb_workers.yaml                 # Runs on each worker
│   │   └── pb_addons.yaml                  # Runs on last worker (MetalLB, ingress-nginx, Dashboard, ArgoCD, Headlamp)
│   └── roles/
│       ├── common/                         # All nodes: CRI-O, kubeadm packages, DNS, swap
│       ├── control_plane/                  # kubeadm init, Calico, Metrics Server, join relay
│       ├── worker/                         # kubeadm join, node labeling
│       ├── addon_metallb/                  # LoadBalancer IP pool for the hostonly network
│       ├── addon_ingress_nginx/            # Ingress controller (LoadBalancer Service via MetalLB)
│       ├── addon_dashboard/                # Kubernetes Dashboard + RBAC
│       ├── addon_argocd/                   # ArgoCD deployment + NodePort + nip.io Ingress (backend-protocol HTTPS)
│       └── addon_headlamp/                 # Headlamp deployment
├── script-manifest/                         # Kubernetes manifests applied outside Ansible
│   ├── utility-dashboard/                  # Dashboard component YAMLs
│   ├── utility-argocd/                     # ArgoCD Ingress Jinja2 template + unused legacy TLS certs
│   ├── utility-metallb/                    # MetalLB IPAddressPool/L2Advertisement Jinja2 template
│   ├── utility-headlamp/                   # Headlamp Jinja2 template
│   ├── utility-hashicorp-vault/            # Vault platform (Stage A) — ArgoCD-delivered, not Ansible
│   └── application-otel-demo/              # OpenTelemetry Demo manifests (manual apply)
├── scripts-setup/                           # Utility shell scripts (post-provision helpers)
│   └── setup-refresh-token.sh              # Refresh expired Dashboard/Headlamp tokens
└── documents/                                # Operational runbooks
    └── DOCUMENTS-runbook-node-recovery.md  # Recovering an unresponsive/unbootable node VM
```

### Generated Files

After running `vagrant up`, the following files are generated in the `configs/` directory:

- **config**: Kubernetes admin kubeconfig file
- **setup-join.sh**: Command to join worker nodes to the cluster
- **credential_token**: Bearer token for Kubernetes Dashboard authentication
- **credentials_argocd_admin_password**: ArgoCD admin password
- **credential_headlamp_token**: Headlamp service account token
- **credential_ingress_nginx_lb_ip**: MetalLB-assigned LoadBalancer IP for ingress-nginx (used to build the ArgoCD `nip.io` URL)

**Important**: The `configs/` directory is regenerated on each `vagrant up` run.

## Task Backlog

### Completed ✓

- [x] Create service for ArgoCD WebUI with NodePort type
- [x] Automated cluster provisioning with Vagrant
- [x] Calico CNI integration
- [x] Kubernetes Dashboard with admin access
- [x] ArgoCD GitOps deployment
- [x] Metrics Server installation
- [x] MetalLB for bare-metal LoadBalancer services
- [x] Add Ingress controller (ingress-nginx) with ArgoCD exposed via `nip.io`

### In Progress

- [ ] Load testing and performance optimization
- [ ] Documentation for common deployment patterns

### Planned

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