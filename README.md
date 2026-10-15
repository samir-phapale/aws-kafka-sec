# aws-kafka-sec

Terraform-based AWS security automation for Kafka infrastructure, featuring AWS Config compliance checks, automated remediation, Conformance Packs, and security controls.

This repository takes an Apache Kafka broker on EC2 (KRaft mode) and adds security and compliance controls on top of it:

| Area | What it provides |
|---|---|
| **Kafka infrastructure** | VPC across two AZs, EC2 broker with IMDSv2 and encrypted EBS, SSM Session Manager access (no SSH, no public Kafka port) |
| **Secrets Manager + Kafka auth** | Terraform generates the Kafka credential into Secrets Manager; the broker reads it at boot and enforces SASL/SCRAM, so every client must authenticate with it |
| **Detective control** | Custom AWS Config rule (Lambda) that reports S3 buckets without versioning |
| **Reactive control** | Custom AWS Config rule (Lambda) that finds S3 buckets without full Public Access Block, with automatic remediation by a custom SSM Automation document |
| **Conformance pack** | Both rules and the remediation deployed as one unit |
| **Policy as code (OPA)** | Rego policies checked with `conftest` against every Terraform plan; a violation fails the PR and blocks the deploy |
| **CI/CD** | GitHub Actions with AWS OIDC (no long-lived keys): plan + policy check on PR, policy check + apply + tests on `main` |

## How it works

```text
                       Terraform
                           │
     ┌─────────────────────┼──────────────────────────┐
     ▼                     ▼                          ▼
 VPC + EC2 Kafka     Secrets Manager          Rule Lambdas + IAM roles
     │                     │                          │
     └─ SASL/SCRAM login ──┘                          ▼
                                            Conformance pack
                                       ┌──────────────┴──────────────┐
                                       ▼                             ▼
                              Detective rule                   Reactive rule
                              (every 24h)                      (on bucket change)
                                       │                             │
                                       ▼                             ▼
                              versioning on?                 all 4 Public Access
                              → report only                  Block settings on?
                                                                     │ no
                                                                     ▼
                                                     SSM Automation remediation
                                                     → re-evaluated → COMPLIANT
```

### Detective: S3 versioning (detect → report)

1. Every 24 hours AWS Config invokes the detective Lambda.
2. The Lambda finds buckets carrying the scope tag (one Resource Groups Tagging API call) in its own region.
3. For each one it reads the versioning status: `Enabled` → `COMPLIANT`, otherwise `NON_COMPLIANT`.
4. Results are sent back to Config (`PutEvaluations`). Nothing is changed.

### Reactive: S3 Public Access Block (detect → remediate → verify)

1. A tagged bucket's configuration changes; the AWS Config recorder records it.
2. Config invokes the reactive Lambda with the configuration item.
3. If any of `BlockPublicAcls`, `IgnorePublicAcls`, `BlockPublicPolicy`, `RestrictPublicBuckets` is off → `NON_COMPLIANT`.
4. Config automatically runs our SSM Automation document `<project>-<env>-s3-public-access-remediation` under a dedicated least-privilege role. Its three steps (Python in `modules/config_controls/remediation/`, unit-tested):
   - **VerifyScopeTag:** refuses to touch a bucket without the scope tag
   - **EnablePublicAccessBlock:** turns on all four settings, recording the prior state
   - **VerifyPublicAccessBlock:** confirms all four settings are on, or fails the run
5. The fix is itself a change, so the rule re-evaluates → `COMPLIANT`.

The Lambda only decides; it never modifies the bucket. Remediation is done by SSM Automation, with retries and an audit trail.

### Kafka authentication: Secrets Manager → SASL/SCRAM

```text
terraform apply ─► random_password ─► Secrets Manager {username, password}
                                             │ (IAM: broker role may read this secret only)
EC2 first boot ──────────────────────────────┘
  1. read the secret with the instance role (user data holds only the ARN)
  2. kafka-storage.sh format --add-scram  → credential stored as a salted hash in cluster metadata
  3. port 9092 = SASL_PLAINTEXT, mechanism SCRAM-SHA-512 → no credential, no access
Clients ─► kafka-client-config fetches the secret at run time → temporary config → connect
```

- **No secret in code, user data or logs.** User data carries only the secret's ARN; command tracing is turned off while the credential is handled, and the e2e tests check that the value appears in neither user data nor the provisioning logs.
- **On disk only where Kafka needs it.** The broker's own login (for inter-broker authentication) lives in `server.properties`, readable only by the `kafka` user (`600`).
- **New credential, new broker.** The secret's version is part of user data, so a changed password replaces the broker and it is formatted with the new credential.

Connect from the broker (`ssm_connect_command`):

```bash
CFG=$(kafka-client-config)          # temporary client config with the credential
/opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --command-config "$CFG" --list
rm -f "$CFG"
```

### Safety in a shared account: tagged buckets only

Because the reactive control changes buckets automatically, both rules only act on buckets tagged:

```text
Phase3Scope = <project_name>-<environment>      (default: kafka-on-ec2-dev)
```

- **Reactive:** the Config rule scope is the tag, and the Lambda re-checks the tag before reporting `NON_COMPLIANT`, so remediation can never reach an untagged bucket.
- **Detective:** periodic rules have no change scope, so the Lambda itself queries only tagged buckets.

### AWS Config recorder

This repository does **not** create an AWS Config recorder or delivery channel. AWS allows one recorder per account and region; in a Control Tower account it already exists (`aws-controltower-BaselineConfigRecorder`) and is owned by Control Tower. The rules use that recorder. In an account without AWS Config, enable the recorder first.

## Policy as code (OPA)

Every Terraform plan is converted to JSON and checked against the Rego policies in `policy/` with [conftest](https://www.conftest.dev/). The policies see everything that will exist after the change, including unchanged resources, so the whole stack is checked on every run.

```text
terraform plan -out=tfplan ─► terraform show -json ─► plan.json ─► conftest test (policy/*.rego)
                                                                     │
                                         any deny ─► job fails ─► PR blocked / apply never runs
```

| ID | Rule | Why |
|---|---|---|
| EC2-001 | EC2 must require IMDSv2 | Stops credential theft via the metadata service (SSRF) |
| EC2-002 | Root/data volumes encrypted; root volume declared explicitly | Data at rest, independent of account defaults |
| EC2-003 | Instance types only from `t3`, `t3a` | Cost guardrail |
| NET-001 | No inbound from `0.0.0.0/0` or `::/0` | Kafka and SSH never public; access is via SSM |
| TAG-001 | `Project`, `Environment`, `ManagedBy` on every taggable resource | Ownership and cost allocation |
| SEC-001 | Secrets Manager values must not be literals in code | Checks how the value is written, never the value itself |
| IAM-001 / IAM-002 | No `Action "*"` on `Resource "*"`; no `AdministratorAccess` attachments | Least privilege |
| LOG-001 / LOG-002 | Log groups have retention; every Lambda's log group is managed in code | No orphaned, never-expiring logs |

Where it runs:

| Workflow | Check |
|---|---|
| `phase3-validation.yml` (PR) | `conftest verify`: policy unit tests (passing and violating inputs for every rule) |
| `terraform-plan.yml` (PR) | `conftest test` on the PR's plan |
| `terraform-apply.yml` (`main`) | `conftest test` on the plan that is then applied (`terraform apply tfplan`) |

The policies only read the plan, so they are independent of the CI tool; moving to CodePipeline/CodeBuild would reuse them unchanged.

## Repository structure

```text
aws-kafka-sec/
├── .github/workflows/
│   ├── terraform-plan.yml          PR: fmt, validate, plan (needs AWS)
│   ├── phase3-validation.yml       PR: fmt, validate, unit tests (no AWS needed)
│   ├── terraform-apply.yml         push to main: apply + Kafka end-to-end tests
│   └── terraform-destroy.yml       manual: destroy (type "destroy-dev" to confirm)
├── modules/
│   ├── vpc/                        VPC, public/private subnets, routing
│   ├── security_group/             broker SG (Kafka ports only from itself)
│   ├── iam/                        broker role: SSM + read the secret
│   ├── ec2_kafka/                  broker instance + Kafka install with SASL/SCRAM (user data)
│   ├── secrets_manager/            generated Kafka credential
│   └── config_controls/
│       ├── main.tf                 Lambdas, IAM roles, log groups, conformance pack
│       ├── templates/conformance_pack.yaml
│       ├── templates/remediation_document.yaml   custom SSM Automation runbook
│       ├── remediation/s3_public_access_block.py  its three remediation steps
│       └── lambda/
│           ├── detective/handler.py
│           └── reactive/handler.py
├── policy/                         OPA policies (Rego) + their unit tests (*_test.rego)
│   ├── lib/                        plan helpers and test builders
│   ├── ec2.rego  network.rego  tagging.rego  secrets.rego  iam.rego  logging.rego
├── .github/actions/setup-conftest/ pinned, checksum-verified conftest install
├── tests/
│   ├── test_phase3_logic.py        unit tests for both rule Lambdas (mocked AWS)
│   ├── test_remediation.py         unit tests for the remediation steps (mocked AWS)
│   └── test_kafka_e2e.py           on the broker via SSM: authenticated produce/consume,
│                                   auth rejection, credential-leak checks
├── scripts/
│   ├── create_test_resources.sh    creates two tagged, non-compliant test buckets
│   └── cleanup.sh                  deletes those test buckets
├── main.tf  variables.tf  outputs.tf  providers.tf
├── terraform.tfvars
└── backend.hcl.example
```

## Prerequisites

- Terraform >= 1.11, AWS CLI, Python 3.12
- AWS credentials (SSO) for local runs
- An existing S3 bucket for Terraform state
- AWS Config recording in the target region (see above)

## Deploy

```bash
cp backend.hcl.example backend.hcl     # set your state bucket
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Key outputs:

| Output | Use |
|---|---|
| `ssm_connect_command` | Open a shell on the broker |
| `phase3_secret_arn` | The Secrets Manager secret holding the Kafka credential |
| `phase3_conformance_pack_name` | The conformance pack |
| `compliance_scope_tag_key` / `compliance_scope_tag_value` | Tag a bucket with these to bring it under the rules |

## Test

**Unit tests** (no AWS needed):

```bash
pip install -r tests/requirements.txt
pytest tests/test_phase3_logic.py tests/test_remediation.py -v
```

**OPA policies** (install [conftest](https://www.conftest.dev/install/)):

```bash
conftest verify --policy policy                       # policy unit tests, no AWS needed

terraform plan -out=tfplan                            # needs AWS credentials
terraform show -json tfplan > plan.json
conftest test plan.json --policy policy --all-namespaces
rm -f plan.json                                       # contains planned values, incl. sensitive ones
```

**Controls in AWS:** create two deliberately non-compliant, tagged buckets:

```bash
export AWS_REGION=us-east-1
bash scripts/create_test_resources.sh
```

Then check results. AWS Config adds a suffix to rule names inside a conformance pack, so list them first:

```bash
PACK="$(terraform output -raw phase3_conformance_pack_name)"

aws configservice describe-conformance-pack-compliance --conformance-pack-name "$PACK"
aws configservice get-conformance-pack-compliance-details --conformance-pack-name "$PACK"

# Run the periodic detective rule now instead of waiting 24h
aws configservice start-config-rules-evaluation --config-rule-names <detective rule name>

# Remediation history for the reactive rule
aws configservice describe-remediation-execution-status --config-rule-name <reactive rule name>

# Step-by-step runs of the custom remediation document
aws ssm describe-automation-executions \
  --filters Key=DocumentNamePrefix,Values="$(terraform output -raw phase3_remediation_document_name)"
```

Expected: the versioning bucket is `NON_COMPLIANT` (reported only); the Public Access Block bucket goes `NON_COMPLIANT` → remediated → `COMPLIANT` within a few minutes.

**Kafka end-to-end** (run by the apply workflow; locally after a deploy):

```bash
export KAFKA_INSTANCE_ID="$(terraform output -raw instance_id)"
export KAFKA_TOPIC_NAME="$(terraform output -raw kafka_topic_name)"
export KAFKA_SECRET_ARN="$(terraform output -raw phase3_secret_arn)"
pytest tests/test_kafka_e2e.py -v
```

Covers: authenticated produce/consume; a client with no credential and one with a wrong password are both rejected; `server.properties` is `600 kafka`; the credential is in neither EC2 user data nor the provisioning logs.

## CI/CD

GitHub Actions authenticate to AWS with OIDC; no access keys are stored. Configure in **Settings → Secrets and variables → Actions**:

| Type | Name | Value |
|---|---|---|
| Secret | `AWS_ROLE_ARN` | IAM role trusted for this repo via GitHub OIDC |
| Variable | `AWS_REGION` | e.g. `us-east-1` |
| Variable | `TF_STATE_BUCKET` | Terraform state bucket |

> `terraform-apply.yml` does not destroy the stack after testing; run `terraform-destroy.yml` when finished to avoid ongoing EC2 cost.

## Cleanup

```bash
export PHASE3_VERSIONING_BUCKET=<bucket>
export PHASE3_REACTIVE_BUCKET=<bucket>
bash scripts/cleanup.sh

terraform destroy
```

## Roadmap

- Three-broker Kafka cluster across three AZs
- TLS (`SASL_SSL`): SCRAM already keeps the password off the wire, but message data is not yet encrypted in transit
- Credential rotation (rotation Lambda that also updates the Kafka SCRAM credential)
