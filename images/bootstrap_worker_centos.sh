#!/bin/bash

# wait for permanent hostname
HOSTNAME_PRE="ip-172"
while [ "$HOSTNAME_PRE" != "ip-10" ]; do
    echo "permanent hostname not yet available"
    sleep 10
    HOSTNAME_PRE=$(hostname | cut -c1-5)
done
HOSTNAME=$(hostname)

PRIVATE_IP=""
while [ "$PRIVATE_IP" == "" ]; do
    echo "private IP not yet available"
    sleep 10
    PRIVATE_IP=$(ip addr show eth0 | grep -Po 'inet \K[\d.]+')
done

# shut up broken DNS warnings
if ! grep -q $host /etc/hosts; then
  echo "fixing broken /etc/hosts"
  cat <<EOF | sudo dd oflag=append conv=notrunc of=/etc/hosts >/dev/null 2>&1
# added by bootstrap_etcd0.sh `date`
$PRIVATE_IP $HOSTNAME
EOF
fi

JOINED=0
PROXY_EP=0
MASTER_IPS=0
VPC_CIDR=0
IMAGE_REPO=0
API_LB_EP=0

# ensure iptables are used correctly
cat <<EOF >  /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
sysctl --system

# reset any existing iptables rules
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT
sudo iptables -t nat -F
sudo iptables -t mangle -F
sudo iptables -F
sudo iptables -X

# proxy vars for docker
while [ $PROXY_EP -eq 0 ]; do
    if [ -f /tmp/proxy_ep ]; then
        PROXY_EP=$(cat /tmp/proxy_ep)
    else
        echo "proxy endpoint not yet available"
        sleep 10
    fi
done

# master node IP addresses
while [ $MASTER_IPS -eq 0 ]; do
    if [ -f /tmp/master_ips ]; then
        MASTER_IPS=$(cat /tmp/master_ips)
    else
        echo "master ips not yet available"
        sleep 10
    fi
done

# VPC CIDR
while [ $VPC_CIDR -eq 0 ]; do
    if [ -f /tmp/vpc_cidr ]; then
        VPC_CIDR=$(cat /tmp/vpc_cidr)
    else
        echo "vpc cidr not yet available"
        sleep 10
    fi
done

sudo mkdir -p /etc/systemd/system/docker.service.d
sudo cat > /etc/systemd/system/docker.service.d/http-proxy.conf <<EOF
[Service]
Environment="HTTP_PROXY=http://$PROXY_EP:3128/" "HTTPS_PROXY=http://$PROXY_EP:3128/" "NO_PROXY=docker-pek.cnqr-cn.com,$HOSTNAME,localhost,$MASTER_IPS,127.0.0.1,169.254.169.254,192.168.0.0/16,$VPC_CIDR"
EOF

sudo systemctl daemon-reload
sudo systemctl restart docker

# image repo to pull images from
while [ $IMAGE_REPO -eq 0 ]; do
    if [ -f /tmp/image_repo ]; then
        IMAGE_REPO=$(cat /tmp/image_repo)
    else
        echo "image repo not yet available"
        sleep 10
    fi
done

# get the ELB domain name for the API server
while [ $API_LB_EP -eq 0 ]; do
    if [ -f /tmp/api_lb_ep ]; then
        API_LB_EP=$(cat /tmp/api_lb_ep)
    else
        echo "API load balancer endpoint not yet available"
        sleep 10
    fi
done

# change pause image repo
cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<EOF
[Service]
Environment="HTTP_PROXY=http://$PROXY_EP:3128/" "HTTPS_PROXY=http://$PROXY_EP:3128/" "NO_PROXY=docker-pek.cnqr-cn.com,$HOSTNAME,localhost,.default.svc.cluster.local,.svc.cluster.local,.cluster.local,.us-east-2.compute.internal,$API_LB_EP,127.0.0.1,169.254.169.254,192.168.0.0/16,10.96.0.0/12,$VPC_CIDR"
Environment="KUBELET_INFRA_IMAGE=--pod-infra-container-image=${IMAGE_REPO}/pause-amd64:3.0"
Environment="KUBELET_CGROUPS=--cgroup-driver=systemd --runtime-cgroups=/systemd/system.slice --kubelet-cgroups=/systemd/system.slice"
Environment="KUBELET_CLOUD_PROVIDER=--cloud-provider=aws"
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_SYSTEM_PODS_ARGS=--pod-manifest-path=/etc/kubernetes/manifests --allow-privileged=true"
Environment="KUBELET_NETWORK_ARGS=--network-plugin=cni --cni-conf-dir=/etc/cni/net.d --cni-bin-dir=/opt/cni/bin"
Environment="KUBELET_DNS_ARGS=--cluster-dns=10.96.0.10 --cluster-domain=cluster.local"
Environment="KUBELET_AUTHZ_ARGS=--authorization-mode=Webhook --client-ca-file=/etc/kubernetes/pki/ca.crt"
Environment="KUBELET_CADVISOR_ARGS=--cadvisor-port=0"
Environment="KUBELET_CERTIFICATE_ARGS=--rotate-certificates=true --cert-dir=/var/lib/kubelet/pki"
ExecStart=
ExecStart=/usr/bin/kubelet \$KUBELET_INFRA_IMAGE \$KUBELET_CGROUPS \$KUBELET_CLOUD_PROVIDER \$KUBELET_KUBECONFIG_ARGS \$KUBELET_SYSTEM_PODS_ARGS \$KUBELET_NETWORK_ARGS \$KUBELET_DNS_ARGS \$KUBELET_AUTHZ_ARGS \$KUBELET_CADVISOR_ARGS \$KUBELET_CERTIFICATE_ARGS \$KUBELET_EXTRA_ARGS
EOF

sudo systemctl daemon-reload
sudo systemctl restart kubelet

# run kubeadm join
while [ $JOINED -eq 0 ]; do
    if [ -f /tmp/join ]; then
        echo "Joining node to cluster..."
        sudo $(cat /tmp/join)
        JOINED=1
    else
        echo "Join command not yet available - sleeping..."
        sleep 10
    fi
done

# clean
sudo rm -rf /tmp/image_repo \
    /tmp/join \
    /tmp/proxy_ep

echo "bootstrap complete"
exit 0

