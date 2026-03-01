
require "yaml"
vagrant_root = File.dirname(File.expand_path(__FILE__))
settings = YAML.load_file "#{vagrant_root}/settings.yaml"

IP_SECTIONS = settings["network"]["control_ip"].match(/^([0-9.]+\.)([^.]+)$/)
# First 3 octets including the trailing dot:
IP_NW = IP_SECTIONS.captures[0]
# Last octet excluding all dots:
IP_START = Integer(IP_SECTIONS.captures[1])
NUM_WORKER_NODES = settings["nodes"]["workers"]["count"]

# All settings.yaml values passed to every ansible_local run as extra_vars.
# This keeps settings.yaml as the single source of truth for versions and network config.
ANSIBLE_EXTRA_VARS = {
  "dns_servers"              => settings["network"]["dns_servers"],
  "control_ip"               => settings["network"]["control_ip"],
  "pod_cidr"                 => settings["network"]["pod_cidr"],
  "service_cidr"             => settings["network"]["service_cidr"],
  "kubernetes_version"       => settings["software"]["kubernetes"],
  "kubernetes_version_short" => settings["software"]["kubernetes"][0..3],
  "calico_version"           => settings["software"]["calico"],
  "dashboard_version"        => settings["software"]["dashboard"] || "",
  "argocd_version"           => settings["software"]["argocd"] || "",
  "headlamp_version"         => settings["software"]["headlamp"] || "",
  "os"                       => settings["software"]["os"],
  "num_worker_nodes"         => NUM_WORKER_NODES,
  "ip_nw"                    => IP_NW,
  "ip_start"                 => IP_START,
  "environment"              => settings["environment"] || ""
}

Vagrant.configure("2") do |config|
  config.vm.boot_timeout = 600

  if `uname -m`.strip == "aarch64"
    config.vm.box = settings["software"]["box"] + "-arm64"
  else
    config.vm.box = settings["software"]["box"]
  end
  config.vm.box_check_update = false


  ## Stage : Provision & Setup Node-Master
  config.vm.define "devnodemaster01" do |controlplane|
    controlplane.vm.hostname = "devnodemaster01"

    ## Assign IP From Settings YAML
    controlplane.vm.network "private_network", ip: settings["network"]["control_ip"]

    ## Open forwarded ports toward host machine so host can access services
    ## Port 30001 : Kubernetes UI Dashboard
    ## Port 30002 : Kubernetes UI ArgoCD
    ## Port 30003 : Kubernetes UI Headlamp
    ## Port 31000 : OpenTelemetry Demo (frontend-proxy)
    ## Port 32000 : Sample NGINX Deployment
    controlplane.vm.network "forwarded_port", guest: 30001, host: 30001
    controlplane.vm.network "forwarded_port", guest: 30002, host: 30002
    controlplane.vm.network "forwarded_port", guest: 30003, host: 30003
    controlplane.vm.network "forwarded_port", guest: 31000, host: 31000
    controlplane.vm.network "forwarded_port", guest: 32000, host: 32000

    ## Mount additional shared folders (optional, configured in settings.yaml)
    if settings["shared_folders"]
      settings["shared_folders"].each do |shared_folder|
        controlplane.vm.synced_folder shared_folder["host_path"], shared_folder["vm_path"]
      end
    end

    controlplane.vm.provider "virtualbox" do |vb|
      vb.name = "DEVNODEMASTER01-ANSIBLE"
      vb.cpus = settings["nodes"]["control"]["cpu"]
      vb.memory = settings["nodes"]["control"]["memory"]
      vb.gui = true
      if settings["cluster_name"] and settings["cluster_name"] != ""
        vb.customize ["modifyvm", :id, "--groups", ("/" + settings["cluster_name"])]
      end
    end

    ## Run Ansible playbook for control plane (common + control_plane roles)
    controlplane.vm.provision "ansible_local" do |ansible|
      ansible.playbook       = "ansible/playbooks/pb_control_plane.yaml"
      ansible.config_file    = "ansible/ansible.cfg"
      ansible.extra_vars     = ANSIBLE_EXTRA_VARS
      ansible.install        = true
      ansible.install_mode   = :pip
    end
  end


  ## Stage : Provision & Setup Node-Worker
  (1..NUM_WORKER_NODES).each do |i|
    config.vm.boot_timeout = 600
    config.vm.define "devnodeworker0#{i}" do |node|
      node.vm.hostname = "devnodeworker0#{i}"
      node.vm.network "private_network", ip: IP_NW + "#{IP_START + i}"

      if settings["shared_folders"]
        settings["shared_folders"].each do |shared_folder|
          node.vm.synced_folder shared_folder["host_path"], shared_folder["vm_path"]
        end
      end

      node.vm.provider "virtualbox" do |vb|
        vb.name = "DEVNODEWORKER0#{i}-ANSIBLE"
        vb.cpus = settings["nodes"]["workers"]["cpu"]
        vb.memory = settings["nodes"]["workers"]["memory"]
        vb.gui = true
        if settings["cluster_name"] and settings["cluster_name"] != ""
          vb.customize ["modifyvm", :id, "--groups", ("/" + settings["cluster_name"])]
        end
      end

      ## Run Ansible playbook for workers (common + worker roles)
      node.vm.provision "ansible_local" do |ansible|
        ansible.playbook       = "ansible/playbooks/pb_workers.yaml"
        ansible.config_file    = "ansible/ansible.cfg"
        ansible.extra_vars     = ANSIBLE_EXTRA_VARS
        ansible.install        = true
        ansible.install_mode   = :pip
      end

      ## Stage : Deploy addons after the last worker is provisioned.
      ## BUG FIX: dashboard and argocd now each check their own version string independently.
      if i == NUM_WORKER_NODES
        should_run_addons = (settings["software"]["dashboard"] && settings["software"]["dashboard"] != "") ||
                            (settings["software"]["argocd"]    && settings["software"]["argocd"]    != "") ||
                            (settings["software"]["headlamp"]  && settings["software"]["headlamp"]  != "")

        if should_run_addons
          node.vm.provision "ansible_local" do |ansible|
            ansible.playbook       = "ansible/playbooks/pb_addons.yaml"
            ansible.config_file    = "ansible/ansible.cfg"
            ansible.extra_vars     = ANSIBLE_EXTRA_VARS
            ansible.install        = true
            ansible.install_mode   = :pip
          end
        end
      end

    end
  end
end
