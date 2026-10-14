import os
import time
import uuid

import boto3
import pytest

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
TOPIC_NAME = os.environ.get("KAFKA_TOPIC_NAME", "demo-topic")
COMMAND_TIMEOUT_SECONDS = 120
KAFKA_BIN = "/opt/kafka/bin"


@pytest.fixture(scope="session")
def instance_id():
    value = os.environ.get("KAFKA_INSTANCE_ID")
    if not value:
        pytest.skip("KAFKA_INSTANCE_ID not set - deploy the environment first")
    return value


@pytest.fixture(scope="session")
def ec2_client():
    return boto3.client("ec2", region_name=AWS_REGION)


@pytest.fixture(scope="session")
def ssm_client():
    return boto3.client("ssm", region_name=AWS_REGION)


def run_remote_command(ssm_client, instance_id, commands, timeout=COMMAND_TIMEOUT_SECONDS):
    response = ssm_client.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": commands},
    )
    command_id = response["Command"]["CommandId"]

    deadline = time.time() + timeout
    invocation = None
    while time.time() < deadline:
        time.sleep(2)
        try:
            invocation = ssm_client.get_command_invocation(
                CommandId=command_id, InstanceId=instance_id
            )
        except ssm_client.exceptions.InvocationDoesNotExist:
            continue
        if invocation["Status"] not in ("Pending", "InProgress", "Delayed"):
            return invocation

    raise TimeoutError(f"SSM command {command_id} did not complete within {timeout}s")


def test_ec2_instance_is_running(ec2_client, instance_id):
    response = ec2_client.describe_instance_status(
        InstanceIds=[instance_id], IncludeAllInstances=True
    )
    state = response["InstanceStatuses"][0]["InstanceState"]["Name"]
    assert state == "running", f"expected instance to be running, got '{state}'"


def test_kafka_service_is_active(ssm_client, instance_id):
    result = run_remote_command(ssm_client, instance_id, ["systemctl is-active kafka"])
    assert result["Status"] == "Success", result["StandardErrorContent"]
    assert result["StandardOutputContent"].strip() == "active"


def test_kafka_is_reachable(ssm_client, instance_id):
    result = run_remote_command(
        ssm_client,
        instance_id,
        [f"{KAFKA_BIN}/kafka-broker-api-versions.sh --bootstrap-server localhost:9092"],
    )
    assert result["Status"] == "Success", result["StandardErrorContent"]


def test_kafka_topic_exists(ssm_client, instance_id):
    result = run_remote_command(
        ssm_client,
        instance_id,
        [f"{KAFKA_BIN}/kafka-topics.sh --list --bootstrap-server localhost:9092"],
    )
    assert result["Status"] == "Success", result["StandardErrorContent"]
    topics = result["StandardOutputContent"].split()
    assert TOPIC_NAME in topics, f"expected topic '{TOPIC_NAME}' in {topics}"


def test_producer_can_publish(ssm_client, instance_id):
    run_id = uuid.uuid4().hex[:8]
    count = 3
    command = (
        f"for i in $(seq 1 {count}); do echo \"produce-check-{run_id}-$i\"; done | "
        f"{KAFKA_BIN}/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic {TOPIC_NAME}"
    )
    result = run_remote_command(ssm_client, instance_id, [command])
    print(result["StandardOutputContent"])
    assert result["Status"] == "Success", result["StandardErrorContent"]


def test_end_to_end_produce_and_consume(ssm_client, instance_id):
    run_id = uuid.uuid4().hex[:8]
    count = 5
    tag = f"e2e-{run_id}"
    command = f"""
set -u
for i in $(seq 1 {count}); do echo "{tag}-$i"; done | {KAFKA_BIN}/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic {TOPIC_NAME}
RECEIVED=$({KAFKA_BIN}/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic {TOPIC_NAME} --from-beginning --timeout-ms 15000 2>/dev/null | grep -c "{tag}-")
echo "EXPECTED={count}"
echo "RECEIVED=$RECEIVED"
if [ "$RECEIVED" -eq "{count}" ]; then
  echo "SUCCESS: received $RECEIVED/{count} messages"
  exit 0
else
  echo "FAILURE: received $RECEIVED/{count} messages"
  exit 1
fi
""".strip()

    result = run_remote_command(ssm_client, instance_id, [command], timeout=90)
    print(result["StandardOutputContent"])
    assert result["Status"] == "Success", result["StandardErrorContent"]
    assert f"received {count}/{count} messages" in result["StandardOutputContent"]
