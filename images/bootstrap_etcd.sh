#!/bin/bash

PRIVATE_IP=$(ip addr show eth0 | grep -Po 'inet \K[\d.]+')
PEER_NAME=$(hostname)
ETCD_TLS=0
INIT_CLUSTER=0

echo "${PEER_NAME}=https://${PRIVATE_IP}:2380" > /tmp/etcd_member
echo "${PRIVATE_IP}" > /tmp/private_ip

sudo mkdir -p /etc/kubernetes/pki/etcd

while [ $ETCD_TLS -eq 0 ]; do
    if [ -f /tmp/etcd_tls.tar.gz ]; then
        (cd /tmp; tar xvf /tmp/etcd_tls.tar.gz)
        sudo mv /tmp/etc/kubernetes/pki/etcd/ca.pem /etc/kubernetes/pki/etcd/
        sudo mv /tmp/etc/kubernetes/pki/etcd/ca-key.pem /etc/kubernetes/pki/etcd/
        sudo mv /tmp/etc/kubernetes/pki/etcd/client.pem /etc/kubernetes/pki/etcd/
        sudo mv /tmp/etc/kubernetes/pki/etcd/client-key.pem /etc/kubernetes/pki/etcd/
        sudo mv /tmp/etc/kubernetes/pki/etcd/ca-config.json /etc/kubernetes/pki/etcd/
        ETCD_TLS=1
    else
        echo "etcd tls assets not yet available"
        sleep 10
    fi
done

cfssl print-defaults csr | sudo tee /etc/kubernetes/pki/etcd/config.json
sudo sed -i '0,/CN/{s/example\.net/'"$PEER_NAME"'/}' /etc/kubernetes/pki/etcd/config.json
sudo sed -i 's/www\.example\.net/'"$PRIVATE_IP"'/' /etc/kubernetes/pki/etcd/config.json
sudo sed -i 's/example\.net/'"$PEER_NAME"'/' /etc/kubernetes/pki/etcd/config.json

(cd /etc/kubernetes/pki/etcd; sudo cfssl gencert \
    -ca=/etc/kubernetes/pki/etcd/ca.pem \
    -ca-key=/etc/kubernetes/pki/etcd/ca-key.pem \
    -config=/etc/kubernetes/pki/etcd/ca-config.json \
    -profile=server \
    /etc/kubernetes/pki/etcd/config.json | cfssljson -bare server)

(cd /etc/kubernetes/pki/etcd; sudo cfssl gencert \
    -ca=/etc/kubernetes/pki/etcd/ca.pem \
    -ca-key=/etc/kubernetes/pki/etcd/ca-key.pem \
    -config=/etc/kubernetes/pki/etcd/ca-config.json \
    -profile=peer \
    /etc/kubernetes/pki/etcd/config.json | cfssljson -bare peer)

sudo tee /etc/etcd.env << END
PEER_NAME=$PEER_NAME
PRIVATE_IP=$PRIVATE_IP
END

while [ $INIT_CLUSTER -eq 0 ]; do
    if [ -f /tmp/init_cluster ]; then
        INIT_CLUSTER=$(cat /tmp/init_cluster)
    else
        echo "initial cluster values not yet available"
        sleep 10
    fi
done

sudo tee /etc/systemd/system/etcd.service << END
[Unit]
Description=etcd
Documentation=https://github.com/coreos/etcd
Conflicts=etcd.service
Conflicts=etcd2.service

[Service]
EnvironmentFile=/etc/etcd.env
Type=notify
Restart=always
RestartSec=5s
LimitNOFILE=40000
TimeoutStartSec=0

ExecStart=/usr/local/bin/etcd --name ${PEER_NAME} \
    --data-dir /var/lib/etcd \
    --listen-client-urls https://${PRIVATE_IP}:2379 \
    --advertise-client-urls https://${PRIVATE_IP}:2379 \
    --listen-peer-urls https://${PRIVATE_IP}:2380 \
    --initial-advertise-peer-urls https://${PRIVATE_IP}:2380 \
    --cert-file=/etc/kubernetes/pki/etcd/server.pem \
    --key-file=/etc/kubernetes/pki/etcd/server-key.pem \
    --client-cert-auth \
    --trusted-ca-file=/etc/kubernetes/pki/etcd/ca.pem \
    --peer-cert-file=/etc/kubernetes/pki/etcd/peer.pem \
    --peer-key-file=/etc/kubernetes/pki/etcd/peer-key.pem \
    --peer-client-cert-auth \
    --peer-trusted-ca-file=/etc/kubernetes/pki/etcd/ca.pem \
    --initial-cluster ${INIT_CLUSTER} \
    --initial-cluster-token my-etcd-token \
    --initial-cluster-state new

[Install]
WantedBy=multi-user.target
END

sudo systemctl daemon-reload
sudo systemctl enable etcd
sudo systemctl start etcd

