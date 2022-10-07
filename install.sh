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
    if [ "$1" = "-o" ]; then
        ofile=$2
        shift 2
        echo "$@" ">" $ofile | indent '>'
        { "$@" >$ofile 2>&3; } 3>&1 | indent ':'
    elif [ "$1" = "-a" ]; then
        local ofile=$2
        shift 2
        echo "$@" ">>" $ofile | indent '>'
        { "$@" >>$ofile 2>&3; } 3>&1 | indent ':'
    else
        echo "$@" | indent '>'
        { { "$@" 2>&3 | indent '|'; } 3>&1 1>&4 | indent '!'; } 4>&1
    fi
}

echo "##########################"
echo "# Minikube Installerator #"
echo "##########################"

if [ $UID != 0 ]; then
    echo "ERROR: This script must be run as root" 1>&2
    exit -1
elif [ $SUDO_UID = 0 ]; then
    echo "ERROR: This script must be run through sudo" 1>&2
    exit -1
elif [ ! -f /etc/debian_version ]; then
    echo "ERROR: This script is intended to be run on debian" 1>&2
    exit -1
elif [ "$(cat /etc/debian_version | cut -d '.' -f 1)" != 11 ]; then
    echo "WARNING: This script has only been tested on Debian 11 (Bullseye)" 1>&2
fi
rel=$(lsb_release -cs)
arch=$(dpkg --print-architecture)
if [ "$arch" != "amd64" ]; then
    echo "WARNING: This script has only been tested on AMD64 architectures" 1>&2
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
https://download.docker.com/linux/debian/gpg
"""

echo """
Downloading assets
------------------"""
for url in $URLS; do
    echo $url | indent '>'
    result=$(curl -OLs --write-out "%{http_code}" "$url")
    echo "return code: $result" | indent
    if [ $result != 200 ]; then
        echo "ERROR: download failed"
        # exit -1
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
Permissions fix
---------------"""
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
runcmd apt-get install -yq iptables-persistent arptables ebtables conntrack nfs-kernel-server dnsutils jq
runcmd update-alternatives --set iptables /usr/sbin/iptables-legacy
runcmd update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
runcmd update-alternatives --set arptables /usr/sbin/arptables-legacy
runcmd update-alternatives --set ebtables /usr/sbin/ebtables-legacy

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
runcmd gpg --dearmor --verbose -o $ring < gpg
runcmd -o /etc/apt/sources.list.d/docker.list echo "deb [arch=$arch signed-by=$ring] $url $rel stable"
runcmd apt-get update -yq
runcmd apt-get install -yq docker-ce docker-ce-cli containerd.io
iptables -I DOCKER-USER -j ACCEPT
runcmd -o /etc/iptables/rules.v4 iptables-save
runcmd docker pull cryptexlabs/minikube-ingress-dns:0.3.0

# Minikube requirements:
# - legacy iptables
# - conntrack (installed above)
# - cni plugins (only need bridge, actually)
# - crictrl
# - cri-dockerd

echo """
Installing additional components
--------------------------------"""
runcmd dpkg -i cri-dockerd*
runcmd mkdir -p /opt/cni/bin
runcmd tar xvfz cni-plugins-*.tgz -C /opt/cni/bin
runcmd tar xvfz crictl-*.tar.gz -C /usr/bin
runcmd install -v minikube-linux-* /usr/bin/minikube
runcmd install -v kubectl generate-certs docker-startup minikube-startup /usr/bin/

echo """
Enable TLS access for docker
----------------------------"""
runcmd mkdir -p /etc/systemd/system/docker.service.d/
runcmd cp docker-override.conf /etc/systemd/system/docker.service.d/
runcmd systemctl daemon-reload
runcmd ln -s /etc/docker/client /root/.docker

# We are running minikube twice here, deliberately. The first
# time downloads the resources and creates the cluster profile.
# The second time exercises our startup script
echo """
Initialize minikube
-------------------"""
runcmd mkdir -p /root/.kube /root/.minikube/extra
runcmd cp ingress-dns.tmpl coredns.tmpl /root/.minikube/extra/
runcmd chgrp docker /root/.kube
runcmd chmod g+rxs /root/.kube
runcmd minikube start --driver=none --cni=bridge \
    --kubernetes-version=${kubernetes_version} \
    --addons=ingress --download-only
runcmd cp minikube.service /lib/systemd/system/
runcmd systemctl daemon-reload
export='export KUBECONFIG=$HOME/.kube/config.internal'
runcmd -o /etc/profile.d/kubeconfig.sh echo "$export"
runcmd -a /root/.bashrc echo "$export"
runcmd systemctl enable minikube

uuid=$SUDO_UID
user=$(id -un $SUDO_UID)
echo """
Enable access for $user($uuid)
------------------------------"""
runcmd usermod -a -G docker $user
runcmd chmod +x /root
runcmd ln -s /root/.kube /home/$user/
runcmd ln -s /root/.docker /home/$user/
runcmd rm -rf /root/.kube/cache
runcmd rm *

echo """
Installation is complete, but certificates have not been
generated, and Minikube has not been fully configured.
- If you wish to turn this VM into an AMI, shut it
  down now without making further changes.
- If you wish to use this VM, reboot it or run the
  following commands:
     sudo systemctl restart docker
     sudo minikube-startup"""
