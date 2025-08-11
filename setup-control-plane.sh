#!/bin/bash

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo." >&2
  exit 1
fi

echo "### [PHASE 1] Starting Kubernetes Control-Plane Setup ###"

# --- [PREREQUISITES] ---
echo "--> [1/4] Running prerequisite steps..."
# Disable swap
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Enable kernel modules
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# Set sysctl params
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# Set SELinux to permissive
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

# Configure firewall
firewall-cmd --permanent --add-port={6443,2379-2380,10250,10251,10252,10257,10259}/tcp > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1

# --- [CONTAINER RUNTIME] ---
echo "--> [2/4] Installing and configuring containerd..."
# Install containerd
dnf install -y containerd.io > /dev/null 2>&1

# Configure containerd and restart
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd > /dev/null 2>&1

# --- [KUBERNETES PACKAGES] ---
echo "--> [3/4] Installing kubeadm, kubelet, and kubectl..."

# Define the latest Kubernetes version
K8S_VERSION="v1.30" # <-- CHANGE: Updated to the latest stable version

# Add Kubernetes repo using the new community-owned repository
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
# <-- CHANGE: Updated repository URL to point to the latest stable version channel
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
# <-- CHANGE: Updated GPG key URL to match the new repository
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

# Install packages
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes > /dev/null 2>&1
systemctl enable --now kubelet > /dev/null 2>&1

# --- [INITIALIZE CLUSTER] ---
echo "--> [4/4] Initializing Kubernetes cluster with kubeadm..."
# Initialize control plane
kubeadm init --pod-network-cidr=192.168.0.0/16

# Configure kubectl for the current user
echo "--> Configuring kubectl for user: $(logname)"
mkdir -p "/home/$(logname)/.kube"
cp -i /etc/kubernetes/admin.conf "/home/$(logname)/.kube/config"
chown "$(id -u $(logname)):$(id -g $(logname))" "/home/$(logname)/.kube/config"

# --- [NETWORK CNI] ---
echo "--> Installing Calico network CNI..."
# <-- CHANGE: Updated Calico manifest URL to the latest version recommended by Project Calico
kubectl --kubeconfig=/etc/kubernetes/admin.conf create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/calico.yaml

echo ""
echo "### [SUCCESS] Your Kubernetes control-plane has been initialized! ###"
echo ""
echo "To add worker nodes to the cluster, run the following command on each worker:"
echo "-------------------------------------------------------------------------"
kubeadm token create --print-join-command
echo "-------------------------------------------------------------------------"
