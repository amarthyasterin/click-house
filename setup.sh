#!/bin/bash
set -e  # Exit on error

# Log everything for debugging
exec > /var/log/userdata.log 2>&1

# Update and install required packages
sudo apt update -y
sudo apt install -y curl unzip

# Install AWS CLI (if not already installed)
if ! command -v aws &> /dev/null; then
    echo "Installing AWS CLI..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
    rm -rf awscliv2.zip aws
fi

# Install ClickHouse and ZooKeeper
sudo apt install -y clickhouse-server clickhouse-client zookeeperd

# Wait for services to be installed
sleep 10

# Fetch all node IPs dynamically
NODES=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=clickhouse-zookeeper-node" "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].PrivateIpAddress" --output text | sort)

if [[ -z "$NODES" ]]; then
  echo "ERROR: No nodes found. Exiting."
  exit 1
fi

# Get current node's private IP
MY_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

# Assign a unique ID for ZooKeeper
MY_ID=1
for IP in $NODES; do
    if [[ "$IP" == "$MY_IP" ]]; then
        break
    fi
    ((MY_ID++))
done

# Validate MY_ID
if [[ $MY_ID -lt 1 || $MY_ID -gt $(echo "$NODES" | wc -w) ]]; then
  echo "ERROR: Invalid ZooKeeper ID. Exiting."
  exit 1
fi

# Create ZooKeeper ID file
echo "$MY_ID" | sudo tee /etc/zookeeper/conf/myid

# Configure ZooKeeper
cat <<EOL | sudo tee /etc/zookeeper/conf/zoo.cfg
tickTime=2000
dataDir=/var/lib/zookeeper
clientPort=2181
initLimit=5
syncLimit=2
EOL

# Add ZooKeeper nodes
ID=1
for IP in $NODES; do
    echo "server.$ID=$IP:2888:3888" | sudo tee -a /etc/zookeeper/conf/zoo.cfg
    ((ID++))
done

# Ensure dataDir exists and has correct permissions
sudo mkdir -p /var/lib/zookeeper
sudo chown -R zookeeper:zookeeper /var/lib/zookeeper

# Restart ZooKeeper and enable on boot
sudo systemctl enable zookeeper
sudo systemctl restart zookeeper

# Wait for ZooKeeper to start
echo "Waiting for ZooKeeper to start..."
sleep 20

# Add custom user 'sterin' to ClickHouse
CUSTOM_USER_CONFIG=$(cat <<EOF
<yandex>
    <!-- Custom user 'sterin'. -->
    <users>
        <sterin>
            <password>password</password>
            <networks>
                <ip>::/0</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
        </sterin>
    </users>
</yandex>
EOF
)

# Write the custom user configuration to ClickHouse
echo "$CUSTOM_USER_CONFIG" | sudo tee /etc/clickhouse-server/users.d/custom_user.xml

# Restart ClickHouse
sudo systemctl restart clickhouse-server

echo "User data script completed successfully."