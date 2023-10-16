#!/bin/sh

curl -L https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash
helm repo add nfs-subdir-external-provisioner https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/
kubectl create ns nfs-provisioner
helm -n  nfs-provisioner install nfs-provisioner-01 nfs-subdir-external-provisioner/nfs-subdir-external-provisioner \
    --set nfs.server=$1 \
    --set nfs.path=$2 \
    --set storageClass.defaultClass=true \
    --set replicaCount=1 \
    --set storageClass.name=nfs-01 \
   --set storageClass.provisionerName=nfs-provisioner-01