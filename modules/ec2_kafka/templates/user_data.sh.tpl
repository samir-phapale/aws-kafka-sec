#!/bin/bash
set -euxo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

KAFKA_VERSION="${kafka_version}"
SCALA_VERSION="${scala_version}"
TOPIC_NAME="${topic_name}"
TOPIC_PARTITIONS="${topic_partitions}"
TOPIC_REPLICATION_FACTOR="${topic_replication_factor}"

echo "=== Installing Java and prerequisites ==="
dnf install -y java-17-amazon-corretto-headless wget tar nc

echo "=== Creating kafka service account ==="
id -u kafka &>/dev/null || useradd -m -s /sbin/nologin kafka

echo "=== Downloading Kafka $${KAFKA_VERSION} (Scala $${SCALA_VERSION}) ==="
KAFKA_DIST="kafka_$${SCALA_VERSION}-$${KAFKA_VERSION}"
cd /opt
wget -q "https://dlcdn.apache.org/kafka/$${KAFKA_VERSION}/$${KAFKA_DIST}.tgz" -O /opt/kafka.tgz
tar -xzf /opt/kafka.tgz -C /opt
rm -f /opt/kafka.tgz
ln -sfn "/opt/$${KAFKA_DIST}" /opt/kafka

mkdir -p /var/lib/kafka/data
chown -R kafka:kafka "/opt/$${KAFKA_DIST}" /var/lib/kafka

echo "=== Configuring Kafka (KRaft mode, single node) ==="
# IMDSv2 is enforced (http_tokens = "required"), so fetch a session token first.
IMDS_TOKEN=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
PRIVATE_IP=$(curl -sf -H "X-aws-ec2-metadata-token: $${IMDS_TOKEN}" http://169.254.169.254/latest/meta-data/local-ipv4)
# Run as kafka so the /opt/kafka/logs dir that kafka-run-class.sh creates is owned by kafka, not root.
CLUSTER_ID=$(sudo -u kafka /opt/kafka/bin/kafka-storage.sh random-uuid)

cat > /opt/kafka/config/server.properties <<EOF
process.roles=broker,controller
node.id=1
controller.quorum.bootstrap.servers=$${PRIVATE_IP}:9093
listeners=PLAINTEXT://0.0.0.0:9092,CONTROLLER://0.0.0.0:9093
inter.broker.listener.name=PLAINTEXT
advertised.listeners=PLAINTEXT://$${PRIVATE_IP}:9092
controller.listener.names=CONTROLLER
listener.security.protocol.map=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
log.dirs=/var/lib/kafka/data
num.partitions=$${TOPIC_PARTITIONS}
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
share.coordinator.state.topic.replication.factor=1
share.coordinator.state.topic.min.isr=1
group.initial.rebalance.delay.ms=0
EOF
chown kafka:kafka /opt/kafka/config/server.properties

sudo -u kafka /opt/kafka/bin/kafka-storage.sh format --standalone -t "$${CLUSTER_ID}" -c /opt/kafka/config/server.properties

echo "=== Installing systemd unit ==="
cat > /etc/systemd/system/kafka.service <<EOF
[Unit]
Description=Apache Kafka (KRaft mode)
After=network.target

[Service]
Type=simple
User=kafka
Environment=JAVA_HOME=/usr/lib/jvm/java-17-amazon-corretto
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
ExecStop=/opt/kafka/bin/kafka-server-stop.sh
Restart=on-failure
RestartSec=5
LimitNOFILE=100000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kafka
systemctl start kafka

echo "=== Waiting for Kafka to become ready ==="
READY=0
for i in $(seq 1 30); do
  if /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 5
done

if [ "$${READY}" -ne 1 ]; then
  echo "ERROR: Kafka did not become ready in time"
  exit 1
fi

echo "=== Creating topic '$${TOPIC_NAME}' ==="
sudo -u kafka /opt/kafka/bin/kafka-topics.sh --create --if-not-exists \
  --topic "$${TOPIC_NAME}" \
  --bootstrap-server localhost:9092 \
  --partitions "$${TOPIC_PARTITIONS}" \
  --replication-factor "$${TOPIC_REPLICATION_FACTOR}"

echo "USER_DATA_COMPLETE" > /opt/kafka-ready
echo "=== Provisioning complete ==="
