#!/bin/bash

# Ensure the script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo." >&2
  exit 1
fi

echo "### [PHASE 1] Starting Kubernetes Worker Node Setup ###"

# --- [PREREQUISITES] ---
echo "--> [1/3] Running prerequisite steps..."
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
firewall-cmd --permanent --add-port={10250,30000-32767}/tcp > /dev/null 2>&1
firewall-cmd --reload > /dev/null 2>&1

# --- [CONTAINER RUNTIME] ---
echo "--> [2/3] Installing and configuring containerd..."
# Install containerd
dnf install -y containerd.io > /dev/null 2>&1

# Configure containerd and restart
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd
systemctl enable containerd > /dev/null 2>&1

# --- [KUBERNETES PACKAGES] ---
echo "--> [3/3] Installing kubeadm, kubelet, and kubectl..."
# Add Kubernetes repo
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.28/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

# Install packages
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes > /dev/null 2>&1
systemctl enable --now kubelet > /dev/null 2>&1

echo ""
echo "### [SUCCESS] Worker node has been prepared! ###"
echo ""
echo "NOW, run the 'kubeadm join' command that you got from your control-plane node to add this node to the cluster."
