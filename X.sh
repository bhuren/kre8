#!/bin/bash

# Prompt for Azure Credentials
subscription_id=8f50f42f-3ef8-4aa5-8379-5c48f89bbefc
client_id=a530e812-4ce3-4b39-8005-6f4802b92b16
client_secret=IOm8Q~HUuQIQwoz1VC2a3AyFHzJfd55VzgbTDdw0
tenant_id=82d919c0-736c-416b-b827-595e94597471
read -p "Enter Resource Group Name: " resource_group
read -p "Enter Location (e.g., eastus): " location

nfs_share=/nfsX

# Check if Azure CLI is installed, if not, install it
if ! command -v az &> /dev/null; then
    echo "Azure CLI not found. Installing..."
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
else
    echo "Azure CLI is already installed."
fi

# Login to Azure
az login --service-principal -u "$client_id" -p "$client_secret" --tenant "$tenant_id"

# Set the subscription to work with
az account set --subscription "$subscription_id"

# Create Resource Group
az group create --name "$resource_group" --location "$location"

# Provision VM1
az vm create \
  --resource-group "$resource_group" \
  --name "master" \
  --image "Canonical:0001-com-ubuntu-server-focal:20_04-lts:latest" \
  --size "Standard_DS2_v2" \
  --admin-username "azureuser" \
  --generate-ssh-keys

# Provision VM2
az vm create \
  --resource-group "$resource_group" \
  --name "worker" \
  --image "Canonical:0001-com-ubuntu-server-focal:20_04-lts:latest" \
  --size "Standard_DS2_v2" \
  --admin-username "azureuser" \
  --generate-ssh-keys

# Fetch IP Addresses of VMs
master_pub_ip=$(az vm list-ip-addresses -g "$resource_group" -n "master" --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)
worker_pub_ip=$(az vm list-ip-addresses -g "$resource_group" -n "worker" --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -o tsv)

master_pvt_ip=$(az vm list-ip-addresses -g "$resource_group" -n "master" --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv)
worker_pvt_ip=$(az vm list-ip-addresses -g "$resource_group" -n "worker" --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv)

# Print IP Addresses
echo "Public IP of VM1: $master_pub_ip"
echo "Public IP of VM2: $worker_pub_ip"
echo "Private IP of VM1: $master_pvt_ip"
echo "Private IP of VM2: $worker_pvt_ip"


## KUEBADM
# Copy master.sh to the Master VM
scp -o StrictHostKeyChecking=no master.sh azureuser@$master_pub_ip:~

# Copy worker.sh to the Worker VM
scp -o StrictHostKeyChecking=no worker.sh azureuser@$worker_pub_ip:~

# SSH into Master VM and run master.sh as sudo to install kubeadm
# Pass the public IP of the master as an argument
echo "Running master.sh on Master VM..."
ssh -o StrictHostKeyChecking=no azureuser@$master_pub_ip "sudo ./master.sh $master_pub_ip $nfs_share"

# SSH into Worker VM and run worker.sh as sudo to install kubeadm
echo "Running worker.sh on Worker VM..."
ssh -o StrictHostKeyChecking=no azureuser@$worker_pub_ip "sudo ./worker.sh"

# Generate kubeadm join token on the master node
echo "Generating kubeadm join token on Master VM..."
join_command=$(ssh -o StrictHostKeyChecking=no azureuser@$master_pub_ip 'sudo kubeadm token create --print-join-command --ttl 0')

# Print the join command (Optional)
echo "Kubeadm Join Command: $join_command"

# Use the join command to join the worker node to the cluster
echo "Joining Worker VM to the cluster..."
ssh -o StrictHostKeyChecking=no azureuser@$worker_pub_ip "echo '$join_command' | sudo sh"

# Copy nfs.sh to the Master VM and install NFS provisioner on the cluster
scp -o StrictHostKeyChecking=no nfs.sh azureuser@$master_pub_ip:~
echo "Running nfs.sh on Master VM..."
ssh -o StrictHostKeyChecking=no azureuser@$master_pub_ip "sudo ./nfs.sh $master_pvt_ip $nfs_share"


# Copy monitoring.sh to the Master VM
scp -o StrictHostKeyChecking=no monitoring.sh azureuser@$master_pub_ip:~
echo "Installing monitoring stack on cluster..."
ssh -o StrictHostKeyChecking=no azureuser@$master_pub_ip "sudo ./monitoring.sh"

# Copy awx.sh to the Master VM amd execute the script to install AWX
scp -o StrictHostKeyChecking=no awx.sh azureuser@$master_pub_ip:~
echo "Running awx.sh on Master VM..."
ssh -o StrictHostKeyChecking=no azureuser@$master_pub_ip "sudo ./awx.sh"

#copying kube-config file to local system
echo "Copying kubeconfig from Master VM to local machine..."
ssh -o StrictHostKeyChecking=no azureuser@$master_pub_ip "sudo cat /etc/kubernetes/admin.conf" > ~/.kube/config
# Replace the internal IP with the public IP in the kubeconfig file
echo "Updating kubeconfig with Public IP..."
sed -i "s/https:\/\/[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+\:6443/https:\/\/$master_pub_ip:6443/g" ~/.kube/config


echo "Opening port 6443 on Master VM..."
# Extract NSG name from the VM's network interface
vmnicname=$(az vm show --resource-group $resource_group --name master --query 'networkProfile.networkInterfaces[0].id' -o tsv | cut -d '/' -f9 | sed -e 's/\"//g' -e 's/\,//g')
# Fetch NSG name based on the NIC
nsg_name=$(az network nic show --resource-group $resource_group --name $vmnicname --query 'networkSecurityGroup.id' -o tsv | cut -d '/' -f9)
# Open port 6443 on Master VM for kubectl
az network nsg rule create \
  --resource-group $resource_group \
  --nsg-name $nsg_name \
  --name kubernetesApiPort \
  --protocol Tcp \
  --priority 500 \
  --destination-port-range 6443 \
  --access Allow
