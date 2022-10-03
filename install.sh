#!/bin/bash

kubernetes_version=1.24.6
minkube_version=1.27.0
cri_dockerd_version=0.2.6
crictl_version=1.25.0
cni_version=1.1.1

set -eo pipefail

function indent {
    sed "s@^@ ${1:-|} @"
}

function runcmd {
    echo "$@" | indent '>'
    "$@" 2>&1 | indent
}

function mycurl {
    echo $1 | indent '>'
    result=$(curl -OLs --write-out "%{http_code}" "$1")
    echo "return code: $result" | indent
    [ $result = 200 ]
}

echo "##########################"
echo "# Minikube Installerator #"
echo "##########################"

if [ $UID != 0 ]; then
    echo "ERROR: This script must be run as root" 1>2
    exit -1
elif [ $SUDO_UID = 0 ]; then
    echo "ERROR: This script must be run through sudo" 1>2
    exit -1
elif [ ! -f /etc/debian_version ]; then
    echo "ERROR: This script is intended to be run on debian" 1>2
    exit -1
elif [ "$(cat /etc/debian_version | cut -d '.' -f 1)" != 11 ]; then
    echo "WARNING: This script has only been tested on Debian 11 (Bullseye)" 1>2
fi
rel=$(lsb_release -cs)
arch=$(dpkg --print-architecture)
if [ "$arch" != "amd64" ]; then
    echo "WARNING: This script has only been tested on AMD64 architectures" 1>2
fi

public_ip=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
private_ip=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
echo """
IP addresses
------------
 Public: ${public_ip}
 Private: ${private_ip}"""

echo """
Versions
--------
 Minikube: ${minkube_version}
 Kubernetes: ${kubernetes_version}
 CNI plugins: ${cni_version}
 cri-dockerd: ${cri_dockerd_version}
 crictl: ${crictl_version}"""

URLS="""
https://dl.k8s.io/release/v${kubernetes_version}/bin/linux/${arch}/kubectl
https://github.com/kubernetes/minikube/releases/download/v${minkube_version}/minikube-linux-${arch}
https://github.com/Mirantis/cri-dockerd/releases/download/v${cri_dockerd_version}/cri-dockerd_${cri_dockerd_version}.3-0.debian-${rel}_${arch}.deb
https://github.com/kubernetes-sigs/cri-tools/releases/download/v${crictl_version}/crictl-v${crictl_version}-linux-${arch}.tar.gz
https://github.com/containernetworking/plugins/releases/download/v${cni_version}/cni-plugins-linux-${arch}-v${cni_version}.tgz
"""

echo """
Downloading assets
------------------"""
for url in $URLS; do
    if ! mycurl $url; then
        echo "ERROR: download failed"
        exit -1
    fi
done

#
# Workaround for permission denied issues
# https://unix.stackexchange.com/questions/503111/group-permissions-for-root-not-working-in-tmp
# https://groups.google.com/g/linux.debian.bugs.dist/c/k-lbkGMPe3Y
#

protec=$(sysctl fs.protected_regular | cut -d ' ' -f 3)
if [[ "$protec" != "" && "$protec" != 0 ]]; then
    echo """
Modifying system setting
------------------------"""
    runcmd sysctl -w fs.protected_regular=0
    runcmd sed -i -E 's@^(fs.protected_regular =).*@\1 0@' /lib/sysctl.d/protect-links.conf
fi

#
# Update base operating system
#

echo """
Initial OS updates
------------------"""
export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical
runcmd apt-get update -yq
runcmd apt-get upgrade -yq

#
# Install docker and containerd.io
#

echo """
Installing docker
-----------------"""
ring=/etc/apt/keyrings/docker.gpg
url=https://download.docker.com/linux/debian
runcmd apt-get install -y gnupg 
runcmd mkdir -p $(dirname $ring)
mycurl https://download.docker.com/linux/debian/gpg
runcmd gpg --dearmor -o $ring < gpg
echo echo "deb [arch=$arch signed-by=$ring] $url $rel stable" '>' /etc/apt/sources.list.d/docker.list | indent '>'
echo "deb [arch=$arch signed-by=$ring] $url $rel stable" > /etc/apt/sources.list.d/docker.list
runcmd apt-get update -yq
runcmd apt-get install -yq docker-ce docker-ce-cli containerd.io

# Minikube requirements:
# - conntrack
# - cni plugins (only need bridge, actually)
# - crictrl
# - cri-dockerd

echo """
Installing additional components
--------------------------------"""
runcmd apt-get install -yq conntrack
runcmd dpkg -i cri-dockerd*
runcmd mkdir -p /opt/cni/bin
runcmd tar xvfz cni-plugins-*.tgz -C /opt/cni/bin
runcmd tar xvfz crictl-*.tar.gz -C /usr/bin
runcmd install -v minikube-linux-* /usr/bin/minikubes
runcmd install -v kubectl generate-certs docker-startup minikube-startup /usr/bin/
runcmd cp override.conf /etc/systemd/system/docker.service.d/

echo """
Enable TLS access for docker
----------------------------"""
runcmd generate-certs --no-private --no-public
fname=/etc/systemd/system/docker.service.d/override.conf
runcmd mkdir -p $(dirname $fname)
runcmd cp docker.override $fname
runcmd systemctl daemon-reload
runcmd systemctl restart docker.service

echo """
Initialize minikube
-------------------"""
runcmd minikube start --driver=none --cni=bridge --wait=all \
    --kubernetes-version=${kubernetes_version} \
    --embed-certs --apiserver-ips=${public_ip}
runcmd cp minikube.service /lib/systemd/system/
runcmd systemctl daemon-reload
runcmd enable minikube.service

uuid=$SUDO_UID
user=$(id -un $SUDO_UID)
echo """
Enable access for $user($uuid)
------------------------------"""
runcmd usermod -a -G docker $user
runcmd chmod +x /root
runcmd chgrp -R docker /root/.kube
runcmd chmod -R g=u,g+s /root/.kube
runcmd rm -rf ~$user/.kube
runcmd ln -s /root/.kube ~$user/
