#!/bin/bash
git clone https://github.com/ansible/awx-operator.git
cd awx-operator/
RELEASE_TAG=`curl -s https://api.github.com/repos/ansible/awx-operator/releases/latest | grep tag_name | cut -d '"' -f 4`
echo $RELEASE_TAG
git checkout $RELEASE_TAG

#make is needed for subsequent commands
apt install make -y

#create an AWX namespace and set it as default context
NAMESPACE=awx
kubectl create ns ${NAMESPACE}
kubectl config set-context --current --namespace=$NAMESPACE

make deploy

#create the PV
cat <<EOF | kubectl create -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: awx-static-data-pvc
  namespace: awx
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: nfs-01
  resources:
    requests:
      storage: 10Gi
EOF

# Wait for the AWX operator pod to be ready
kubectl wait --for=condition=Ready pod -l app=awx-operator --timeout=300s

# apply AWX config and install
cat <<EOF | kubectl apply -f -
---
apiVersion: awx.ansible.com/v1beta1
kind: AWX
metadata:
  name: awx
spec:
  service_type: nodeport
  projects_persistence: true
  projects_storage_access_mode: ReadWriteOnce
  web_extra_volume_mounts: |
    - name: static-data
      mountPath: /var/lib/projects
  extra_volumes: |
    - name: static-data
      persistentVolumeClaim:
        claimName:  awx-static-data-pvc
EOF





