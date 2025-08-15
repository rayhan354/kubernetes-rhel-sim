#!/bin/bash

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo." >&2
  exit 1
fi

echo "### [PHASE 1] Starting Kubernetes Control-Plane Setup ###"

# --- [PREREQUISITES] ---
echo "--> [1/4] Running prerequisite steps..."

# --- Source OS information ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
else
    echo "Cannot determine OS version. /etc/os-release not found."
    exit 1
fi

# Check for RHEL
if [[ $ID == "rhel" ]]; then
    if [[ $VERSION_ID == 9* ]]; then
        echo "Enabling CodeReady Builder for RHEL 9..."
        subscription-manager repos --enable codeready-builder-for-rhel-9-x86_64-rpms
    elif [[ $VERSION_ID == 8* ]]; then
        echo "Enabling CodeReady Builder for RHEL 8..."
        subscription-manager repos --enable codeready-builder-for-rhel-8-x86_64-rpms
    else
        echo "Unsupported RHEL version: $VERSION_ID"
        exit 1
    fi
    
# Check for CentOS
elif [[ $ID == "centos" ]]; then
    if [[ $VERSION_ID == 9* ]]; then
        echo "Enabling CRB repository for CentOS Stream 9..."
        dnf config-manager --set-enabled crb
    elif [[ $VERSION_ID == 8* ]]; then
        # For CentOS 8, the repo was called "PowerTools"
        echo "Enabling PowerTools repository for CentOS Stream 8..."
        dnf config-manager --set-enabled powertools
    else
        echo "Unsupported CentOS version: $VERSION_ID"
        exit 1
    fi
# Handle other operating systems
else
    echo "This script is intended for RHEL or CentOS only. Aborting."
    exit 1
fi

# Install the docker
dnf install –y dnf-plugins-core 
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli docker-buildx-plugin docker-compose-plugin containerd.io
dnf config-manager --set-enabled crb || 
systemctl enable --now docker

docker version

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
echo "--> [2/4] Configuring containerd..."

# Configure containerd and restart
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable --now containerd > /dev/null 2>&1

# --- [KUBERNETES PACKAGES] ---
echo "--> [3/4] Installing kubeadm, kubelet, and kubectl..."

# Define the latest Kubernetes version

# Add Kubernetes repo using the new community-owned repository
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
# <-- CHANGE: Updated repository URL to point to version 1.30
baseurl=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/
enabled=1
gpgcheck=1
# <-- CHANGE: Updated GPG key URL to match the repository
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.30/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni kubernetes # To prevent auto-updates
EOF

# Install packages
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes > /dev/null 2>&1
systemctl enable --now kubelet > /dev/null 2>&1

# --- [INITIALIZE CLUSTER] ---
echo "--> [4/4] Initializing Kubernetes cluster with kubeadm..."

# Initialize control plane
kubeadm init --pod-network-cidr=10.244.0.0/16 # Exclusive pod IP address for Flannel

sleep 5

# Configure kubectl for the current user
echo "--> Configuring kubectl for user: $(logname)"
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

export KUBECONFIG=/etc/kubernetes/admin.conf

sleep 5

# --- [NETWORK CNI] ---
echo "--> Installing Flannel network CNI..."
# <-- CHANGE: Updated Flannel manifest URL to the latest version recommended by Project Calico
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml

echo ""
echo "### [SUCCESS] Your Kubernetes control-plane has been initialized! ###"
echo ""
echo "To add worker nodes to the cluster, run the 'kubeadm join ...' command. Or, generate another token using this command."
echo "-------------------------------------------------------------------------"
echo "kubeadm token create --print-join-command"
echo "-------------------------------------------------------------------------"
