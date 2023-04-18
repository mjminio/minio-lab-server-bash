#!/bin/bash

set -e

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Prompt user for config file location
read -p "Please enter the path to the config.env file (or press Enter for default './config.env'): " CONFIG_FILE
CONFIG_FILE=${CONFIG_FILE:-./config.env}

# Read variables from config file
source "$CONFIG_FILE"

# Check if script is being run as root
if [[ $EUID -ne 0 ]]; then
echo "This script must be run as root" 
exit 1
fi

# Check if system is Ubuntu or RHEL-based
echo -e "${GREEN}Checking OS version...${NC}"
if [[ $(grep -oP '(?<=^ID=).+' /etc/os-release) == "ubuntu" ]]; then
    PM="apt-get"
    INSTALL="install -y"
    UPDATE_OPTION="update -yq"
    UPGRADE_OPTION="upgrade -yq"
elif [[ $(grep -oP '(?<=^ID=).+' /etc/os-release) == "rhel" ]]; then
    PM="dnf"
    INSTALL="install -y"
    UPDATE_OPTION="update -y"
    UPGRADE_OPTION="upgrade -y"
else
    echo "Unsupported operating system. This script only works on Ubuntu and RHEL-based systems."
    exit 1
fi

# Update the system to the latest packages and security updates
echo -e "${GREEN}Installing Updates...${NC}"
$PM $UPDATE_OPTION
$PM $UPGRADE_OPTION

# Install required packages and applications
echo -e "${GREEN}Installing Required packages...${NC}"
$PM $INSTALL curl git unzip wget tree nano vim htop net-tools haveged fzf zsh

# Set Cert variables
CN="$HOSTIP.sslip.io"
DNS_NAMES="*.$HOSTIP.sslip.io, *.$DOMAIN_NAME, $HOSTIP.sslip.io, $DOMAIN_NAME"
IP_ADDRESS="$HOSTIP"
CERT_DIR="/certs"
CERT_NAME="server"

# Generate private key and CSR
mkdir -p $CERT_DIR
openssl req -newkey rsa:2048 -nodes -keyout $CERT_DIR/$CERT_NAME.key -out $CERT_DIR/$CERT_NAME.csr -subj "/CN=$CN" \
-reqexts SAN -config <(cat /etc/ssl/openssl.cnf <(printf "[SAN]\nsubjectAltName="; printf "DNS:%s," $(echo $DNS_NAMES | sed 's/,/ DNS:/g'); printf "IP:%s" $IP_ADDRESS))

# Generate self-signed certificate
openssl x509 -req -in $CERT_DIR/$CERT_NAME.csr -signkey $CERT_DIR/$CERT_NAME.key -out $CERT_DIR/$CERT_NAME.crt \
-days 3650 -extensions SAN -extfile <(cat /etc/ssl/openssl.cnf <(printf "[SAN]\nsubjectAltName="; printf "DNS:%s," $(echo $DNS_NAMES | sed 's/,/ DNS:/g'); printf "IP:%s" $IP_ADDRESS))

# Concatenate certs into a bundle
cat $CERT_DIR/$CERT_NAME.crt $CERT_DIR/$CERT_NAME.key > $CERT_DIR/$CERT_NAME-bundle.crt

# Download and install Helm 3
echo -e "${GREEN}Installing Helm 3...${NC}"
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# Install K3d
echo -e "${GREEN}Installing K3d...${NC}"
wget -q -O - https://raw.githubusercontent.com/rancher/k3d/main/install.sh | TAG=$K3D_VERSION bash

# Create a directory to store MinIO and Code data
echo -e "${GREEN}Creating directory to store MinIO and Code data...${NC}"
sudo mkdir -p $BASE_STORAGE_PATH/data
sudo chmod -R 777 $BASE_STORAGE_PATH/data

# Install Code Server
echo -e "${GREEN}Installing Code-Server...${NC}"
curl -fsSL https://code-server.dev/install.sh | sh -s -- --version=$CODE_SERVER_VERSION

# Create systemd unit file for Code Server
cat <<EOF > /etc/systemd/system/code-server.service
[Unit]
Description=Code Server
After=network.target

[Service]
User=$USERNAME
Group=$USERNAME
Type=simple
Environment=PASSWORD=$GLOBAL_PASSWORD
ExecStart=/usr/bin/code-server --auth=password --port=10000 --host=0.0.0.0 --user-data-dir $CODE_SERVER_USER_PATH /minio
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and start Code Server service
systemctl daemon-reload
systemctl start code-server

# Enable Code Server service on boot
systemctl enable code-server

# Install Docker and Docker Compose
echo -e "${GREEN}Installing Docker and Docker Compose...${NC}"
if [[ $(grep -oP '(?<=^ID=).+' /etc/os-release) == "ubuntu" ]]; then
    sudo apt-get remove docker docker-engine docker.io containerd runc || true
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y
elif [[ $(grep -oP '(?<=^ID=).+' /etc/os-release) == "rhel" ]]; then
    $PM install -y yum-utils device-mapper-persistent-data lvm2
    sudo dnf check-update
    sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin
    sudo systemctl --now enable docker
fi

# Add user to docker group
usermod -aG docker $USERNAME

# Installing MinIO Server
echo -e "${GREEN}Installing MinIO Server...${NC}"
if ! which minio > /dev/null; then
  wget https://dl.min.io/server/minio/release/linux-amd64/minio
  chmod +x minio
  mv minio /usr/local/bin/
else
  echo "MinIO Server is already installed"
fi

# Installing MinIO Client
echo -e "${GREEN}Installing MinIO Client...${NC}"
if ! command -v mc &> /dev/null; then
    echo -e "${GREEN}Installing MinIO Client...${NC}"
    wget https://dl.min.io/client/mc/release/linux-amd64/mc
    chmod +x mc
    mv mc /usr/local/bin/
else
    echo -e "${YELLOW}MinIO Client is already installed. Skipping installation...${NC}"
fi

# Download and install kubectl
echo -e "${GREEN}Installing Kubectl...${NC}"
if ! command -v kubectl &> /dev/null; then
    curl -LO "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/
else
    echo "Kubectl is already installed"
fi


# Download and install k9s
echo -e "${GREEN}Installing K9s...${NC}"
if ! command -v k9s &> /dev/null
then
    echo -e "${GREEN}Installing K9s...${NC}"
    curl -LO "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz"
    tar -xf k9s_Linux_amd64.tar.gz
    chmod +x k9s
    mv k9s /usr/local/bin/
    rm k9s_Linux_amd64.tar.gz
else
    echo -e "${YELLOW}K9s is already installed.${NC}"
fi

# Download and install kubectx and kubens
echo -e "${GREEN}Checking if kubectx and kubens are already installed...${NC}"
if ! which kubectx >/dev/null 2>&1 || ! which kubens >/dev/null 2>&1; then
    echo -e "${GREEN}Installing kubectx and kubens...${NC}"
    sudo git clone https://github.com/ahmetb/kubectx /opt/kubectx
    sudo ln -s /opt/kubectx/kubectx /usr/local/bin/kubectx
    sudo ln -s /opt/kubectx/kubens /usr/local/bin/kubens
    chmod +x /usr/local/bin/kubectx
    chmod +x /usr/local/bin/kubens
else
    echo -e "${GREEN}kubectx and kubens are already installed. Skipping installation...${NC}"
fi

# Run Portainer, with specified passwords
# Check if the portainer container is already running
if [ "$(docker ps -q -f name=portainer)" ]; then
    echo "Portainer container already exists. Skipping Portainer installation..."
else
    # Run Portainer, with specified passwords
    echo -e "${GREEN}Installing Portainer...${NC}"
    echo -n $GLOBAL_PASSWORD > /tmp/portainer-password.txt
    docker run -d -p 10001:8000 -p 10002:9443 --name portainer --restart=always -v /tmp/portainer-password.txt:/tmp/portainer-password.txt -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:latest --admin-password-file /tmp/portainer-password.txt
fi

# Run Rancher in Docker, with specified passwords
echo -e "${GREEN}Installing Rancher...${NC}"
if [ "$(docker ps -q -f name=rancher)" ]; then
    RANCHERPW=$(docker logs rancher 2>&1 | grep "Bootstrap Password:" | cut -d ' ' -f6)
    echo "Rancher container already exists. Skipping Rancher installation..."
else
    docker run -d --restart=unless-stopped -p 10003:80 -p 10004:443 --name rancher --privileged rancher/rancher:$RANCHER_VERSION
    echo -e "${GREEN}Waiting 30 seconds for Rancher to start...${NC}"
    sleep 30
    RANCHERPW=$(docker logs rancher 2>&1 | grep "Bootstrap Password:" | cut -d ' ' -f6)
fi

# Install HAProxy and configure it to route traffic to specified services
echo -e "${GREEN}Installing HAProxy...${NC}"
$PM $INSTALL haproxy

# Write HAProxy config file
cat <<EOF > /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

defaults
    log global
    mode http
    option httplog
    option dontlognull
    timeout connect 5000
    timeout client 50000
    timeout server 50000

    stats enable
    stats hide-version
    stats refresh 30s
    stats show-node
    stats auth admin:$GLOBAL_PASSWORD
    stats uri  /stats

frontend http
    bind *:80
    bind *:443 ssl crt $CERT_DIR/server-bundle.crt
    mode http
    option httplog
    acl code_acl hdr(host) -i code.$DOMAIN_NAME code.$HOSTIP.sslip.io
    acl portainer_acl hdr(host) -i portainer.$DOMAIN_NAME portainer.$HOSTIP.sslip.io
    acl rancher_acl hdr(host) -i rancher.$DOMAIN_NAME rancher.$HOSTIP.sslip.io
    acl minio_acl hdr(host) -i minio.$DOMAIN_NAME minio.$HOSTIP.sslip.io
    acl minio_api_acl hdr(host) -i minio-api.$DOMAIN_NAME minio-api.$HOSTIP.sslip.io
    acl minio1_acl hdr(host) -i minio1.$DOMAIN_NAME minio1.$HOSTIP.sslip.io
    acl minio1_api_acl hdr(host) -i minio1-api.$DOMAIN_NAME minio1-api.$HOSTIP.sslip.io
    acl minio2_acl hdr(host) -i minio2.$DOMAIN_NAME minio2.$HOSTIP.sslip.io
    acl minio2_api_acl hdr(host) -i minio2-api.$DOMAIN_NAME minio2-api.$HOSTIP.sslip.io
    acl minio3_acl hdr(host) -i minio3.$DOMAIN_NAME minio3.$HOSTIP.sslip.io
    acl minio3_api_acl hdr(host) -i minio3-api.$DOMAIN_NAME minio3-api.$HOSTIP.sslip.io
    acl minio4_acl hdr(host) -i minio4.$DOMAIN_NAME minio4.$HOSTIP.sslip.io
    acl minio4_api_acl hdr(host) -i minio4-api.$DOMAIN_NAME minio4-api.$HOSTIP.sslip.io

    use_backend code_backend if code_acl
    use_backend portainer_backend if portainer_acl
    use_backend rancher_backend if rancher_acl
    use_backend minio_backend if minio_acl
    use_backend minio_api_backend if minio_api_acl
    use_backend minio1_backend if minio1_acl
    use_backend minio1_api_backend if minio1_api_acl
    use_backend minio2_backend if minio2_acl
    use_backend minio2_api_backend if minio2_api_acl
    use_backend minio3_backend if minio3_acl
    use_backend minio3_api_backend if minio3_api_acl
    use_backend minio4_backend if minio4_acl
    use_backend minio4_api_backend if minio4_api_acl

backend code_backend
    mode http
    balance roundrobin
    server code 127.0.0.1:10000 check

backend portainer_backend
    mode http
    balance roundrobin
    server portainer 127.0.0.1:10002 check ssl verify none

backend rancher_backend
    mode http
    balance roundrobin
    server rancher 127.0.0.1:10004 check ssl verify none

backend minio_backend
    mode http
    balance roundrobin
    server minio 127.0.0.1:9000 check

backend minio_api_backend
    mode http
    balance roundrobin
    server minio-api 127.0.0.1:9090 check

backend minio1_backend
    mode http
    balance roundrobin
    server minio1 127.0.0.1:9001 check

backend minio1_api_backend
    mode http
    balance roundrobin
    server minio1-api 127.0.0.1:9091 check

backend minio2_backend
    mode http
    balance roundrobin
    server minio2 127.0.0.1:9002 check

backend minio2_api_backend
    mode http
    balance roundrobin
    server minio2-api 127.0.0.1:9092 check

backend minio3_backend
    mode http
    balance roundrobin
    server minio3 127.0.0.1:9003 check

backend minio3_api_backend
    mode http
    balance roundrobin
    server minio3-api 127.0.0.1:9093 check

backend minio4_backend
    mode http
    balance roundrobin
    server minio4 127.0.0.1:9004 check

backend minio4_api_backend
    mode http
    balance roundrobin
    server minio4-api 127.0.0.1:9094 check
EOF

# Restart HAProxy service
systemctl restart haproxy

# Write required information to README.md file
echo -e "${GREEN}Outputing INSTALL-LOG.txt...${NC}"
cat <<EOF > INSTALL-LOG.txt
# Services and Passwords

## Services
## If Using custom domain, see below.
- [Code Server](http://code.$DOMAIN_NAME)
- [Portainer](http://portainer.$DOMAIN_NAME)
- [Rancher](http://rancher.$DOMAIN_NAME)
- [MinIO Console](http://minio.$DOMAIN_NAME)
- [MinIO API](http://minio-api.$DOMAIN_NAME)
- [MinIO Console 1](http://minio1.$DOMAIN_NAME)
- [MinIO API 1](http://minio1-api.$DOMAIN_NAME)
- [MinIO Console 2](http://minio2.$DOMAIN_NAME)
- [MinIO API 2](http://minio2-api.$DOMAIN_NAME)
- [MinIO Console 3](http://minio3.$DOMAIN_NAME)
- [MinIO API 3](http://minio3-api.$DOMAIN_NAME)
- [MinIO Console 4](http://minio4.$DOMAIN_NAME)
- [MinIO API 4](http://minio4-api.$DOMAIN_NAME)

## If using sslip.io, see below.
- [Code Server](http://code.$HOSTIP.sslip.io)
- [Portainer](http://portainer.$HOSTIP.sslip.io)
- [Rancher](http://rancher.$HOSTIP.sslip.io)
- [MinIO Console](http://minio.$HOSTIP.sslip.io)
- [MinIO API](http://minio-api.$HOSTIP.sslip.io)
- [MinIO Console 1](http://minio1.$HOSTIP.sslip.io)
- [MinIO API 1](http://minio1-api.$HOSTIP.sslip.io)
- [MinIO Console 2](http://minio2.$HOSTIP.sslip.io)
- [MinIO API 2](http://minio2-api.$HOSTIP.sslip.io)
- [MinIO Console 3](http://minio3.$HOSTIP.sslip.io)
- [MinIO API 3](http://minio3-api.$HOSTIP.sslip.io)
- [MinIO Console 4](http://minio4.$HOSTIP.sslip.io)
- [MinIO API 4](http://minio4-api.$HOSTIP.sslip.io)

## Passwords

- GLOBAL_PASSWORD: $GLOBAL_PASSWORD

### Rancher

- Username: admin
- Password: $RANCHERPW

### Portainer

- Username: admin
- Password: $GLOBAL_PASSWORD

### Code Server

- Username: admin
- Password: $GLOBAL_PASSWORD
EOF

echo -e "${GREEN}Installation Complete. Please see INSTALL-LOG.txt for details.${NC}"