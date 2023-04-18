#!/bin/bash


# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Prompt user to continue
echo -e "${GREEN}Are you sure you want to continue? This will remove ALL components installed by the install script including data. Type YES to proceed: ${NC}"
read confirmation

# Check if user typed YES
if [[ "$confirmation" != "YES" ]]; then
  echo "Exiting script"
  exit 1
fi

# Continue with script
echo "Continuing with script..."

# Prompt user for config file location
read -p "Please enter the path to the config.env file (or press Enter for default './config.env'): " CONFIG_FILE
CONFIG_FILE=${CONFIG_FILE:-./config.env}

# Read variables from config file
source "$CONFIG_FILE"

# Stop and remove all running Docker containers
docker stop $(docker ps -a -q) && docker rm $(docker ps -a -q)
docker volume prune -f

# Remove Docker
systemctl stop docker
systemctl disable docker
sudo apt-get remove docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo dnf remove -y yum-utils device-mapper-persistent-data lvm2 docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo rm -rf /etc/docker

# Removing MinIO Components
sudo rm /usr/local/bin/minio
sudo rm /usr/local/bin/mc
sudo rm -rf $BASE_STORAGE_PATH

# Remove Kubernetes components
sudo rm /usr/local/bin/kubectl
sudo rm /usr/local/bin/k9s
sudo rm /usr/local/bin/helm
sudo rm -rf /opt/kubectx

# Remove code-server
systemctl stop code-server
systemctl disable code-server
rm /etc/systemd/system/code-server.service
rm -rf /opt/code-server

# Remove HAProxy
systemctl stop haproxy
systemctl disable haproxy
rm /etc/haproxy/haproxy.cfg

# Remove Certs
sudo rm -rf $CERT_DIR

# Remove INSTALL-LOG
rm INSTALL-LOG.txt
