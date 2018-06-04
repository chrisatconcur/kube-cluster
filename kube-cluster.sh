#!/bin/bash

USAGE=$(cat << END
Usage: ./kube-cluster.sh [-h] /path/to/private/key

Provide the private key that will grant access to EC2 instances

This utility will deploy a test k8s cluster with 3 masters, etcd co-hosted on masters
Number of workers statically defined in terraform.tfvars
END
)

if [ "$1" = "-h" ]; then
    echo "$USAGE"
    exit 0
elif [ "$1" = "" ]; then
    echo "Error: missing argument"
    echo "$USAGE"
    exit 1
fi

KEY_PATH=$1

if [ ! -f $KEY_PATH ]; then
    echo "Error: no file found at $KEY_PATH"
    echo "$USAGE"
    exit 1
fi

trusted_fetch() {
    SOURCE=$1
    DEST=$2
    scp -i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $SOURCE $DEST
}

trusted_send() {
    LOCAL_FILE=$1
    REMOTE_HOST=$2
    REMOTE_PATH=$3
    scp -i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        $LOCAL_FILE ubuntu@$REMOTE_HOST:/tmp/tempfile
    ssh -i $KEY_PATH -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ubuntu@$REMOTE_HOST "mv /tmp/tempfile $REMOTE_PATH"
}

set -e

# provision that action
terraform init infra
terraform apply -auto-approve infra

# collect terraform output
MASTER0=$(terraform output master0_ep)
MASTER0_IP=$(terraform output master0_ip)
MASTER1=$(echo "$(terraform output master_ep)" | sed -n '1 p' | tr -d ,)
MASTER2=$(echo "$(terraform output master_ep)" | sed -n '2 p')
API_LB_EP=$(terraform output api_lb_ep)
WORKERS=$(terraform output worker_ep)

# wait for infrastructure to spin up
echo "pausing for 3 min to allow infrastructure to spin up..."
sleep 180

if [ ! -d /tmp/kube-cluster ]; then
    mkdir /tmp/kube-cluster
fi

# distribute K8s API endpoint
echo "$API_LB_EP" > /tmp/kube-cluster/api_lb_ep
trusted_send /tmp/kube-cluster/api_lb_ep $MASTER0 /tmp/api_lb_ep
trusted_send /tmp/kube-cluster/api_lb_ep $MASTER1 /tmp/api_lb_ep
trusted_send /tmp/kube-cluster/api_lb_ep $MASTER2 /tmp/api_lb_ep
echo "k8s api endpoint distributed to master nodes"

# retrieve etcd TLS
trusted_fetch ubuntu@$MASTER0:/tmp/etcd_tls.tar.gz /tmp/kube-cluster/
echo "etcd TLS assets retrieved"

# distribute etcd TLS
trusted_send /tmp/kube-cluster/etcd_tls.tar.gz $MASTER1 /tmp/etcd_tls.tar.gz
trusted_send /tmp/kube-cluster/etcd_tls.tar.gz $MASTER2 /tmp/etcd_tls.tar.gz
echo "etcd TLS assets distributed"

# collect etcd members
trusted_fetch ubuntu@$MASTER0:/tmp/etcd_member /tmp/kube-cluster/etcd0
trusted_fetch ubuntu@$MASTER1:/tmp/etcd_member /tmp/kube-cluster/etcd1
trusted_fetch ubuntu@$MASTER2:/tmp/etcd_member /tmp/kube-cluster/etcd2
echo "$(cat /tmp/kube-cluster/etcd0),$(cat /tmp/kube-cluster/etcd1),$(cat /tmp/kube-cluster/etcd2)" > \
    /tmp/kube-cluster/init_cluster
echo "etcd members collected"

# distribute etcd initial cluster
trusted_send /tmp/kube-cluster/init_cluster $MASTER0 /tmp/init_cluster
trusted_send /tmp/kube-cluster/init_cluster $MASTER1 /tmp/init_cluster
trusted_send /tmp/kube-cluster/init_cluster $MASTER2 /tmp/init_cluster
echo "initial etcd cluster distributed"

# collect private IPs for api server
trusted_fetch ubuntu@$MASTER0:/tmp/private_ip /tmp/kube-cluster/etcd0_ip
trusted_fetch ubuntu@$MASTER1:/tmp/private_ip /tmp/kube-cluster/etcd1_ip
trusted_fetch ubuntu@$MASTER2:/tmp/private_ip /tmp/kube-cluster/etcd2_ip
echo "addon master IPs collected"

# distribute private IPs
trusted_send /tmp/kube-cluster/etcd0_ip $MASTER0 /tmp/etcd0_ip
trusted_send /tmp/kube-cluster/etcd1_ip $MASTER0 /tmp/etcd1_ip
trusted_send /tmp/kube-cluster/etcd2_ip $MASTER0 /tmp/etcd2_ip
trusted_send /tmp/kube-cluster/etcd0_ip $MASTER1 /tmp/etcd0_ip
trusted_send /tmp/kube-cluster/etcd1_ip $MASTER1 /tmp/etcd1_ip
trusted_send /tmp/kube-cluster/etcd2_ip $MASTER1 /tmp/etcd2_ip
trusted_send /tmp/kube-cluster/etcd0_ip $MASTER2 /tmp/etcd0_ip
trusted_send /tmp/kube-cluster/etcd1_ip $MASTER2 /tmp/etcd1_ip
trusted_send /tmp/kube-cluster/etcd2_ip $MASTER2 /tmp/etcd2_ip

# wait for master0 to initialize cluster
echo "pausing for 8 min to allow master initialization..."
sleep 480

# retreive K8s TLS assets
trusted_fetch ubuntu@$MASTER0:/tmp/k8s_tls.tar.gz /tmp/kube-cluster/
echo "k8s TLS assets retrieved"

# distribute K8s TLS assets
trusted_send /tmp/kube-cluster/k8s_tls.tar.gz $MASTER1 /tmp/k8s_tls.tar.gz
trusted_send /tmp/kube-cluster/k8s_tls.tar.gz $MASTER2 /tmp/k8s_tls.tar.gz
echo "k8s TLS assets distributed"

# retreive kubeadm join command
trusted_fetch ubuntu@$MASTER0:/tmp/join /tmp/kube-cluster/join
echo "join command retreived"

# distribute join command to worker/s
for WORKER in $WORKERS; do
    trusted_send /tmp/kube-cluster/join $(echo $WORKER | tr -d ,) /tmp/join
done
echo "join command sent to worker/s"

rm -rf /tmp/kube-cluster

# grab the kubeconfig to use locally
trusted_fetch ubuntu@$MASTER0:~/.kube/config ./kubeconfig
sed -i -e "s/$MASTER0_IP/$API_LB_EP/g" ./kubeconfig

exit 0

