# aws-kafka-sec

Terraform-based AWS security automation for Kafka infrastructure, featuring AWS Config compliance checks, automated remediation, Conformance Packs, and security controls.

This repository takes an Apache Kafka broker on EC2 (KRaft mode) and adds security and compliance controls on top of it:

| Area | What it provides |
|---|---|
| **Kafka infrastructure** | VPC across two AZs, EC2 broker with IMDSv2 and encrypted EBS, SSM Session Manager access (no SSH, no public Kafka port) |
| **Secrets Manager** | A generated credential stored in Secrets Manager; the broker's IAM role may read only that secret |
| **Detective control** | Custom AWS Config rule (Lambda) that reports S3 buckets without versioning |
| **Reactive control** | Custom AWS Config rule (Lambda) that finds S3 buckets without full Public Access Block, with automatic remediation via SSM Automation |
| **Conformance pack** | Both rules and the remediation deployed as one unit |
| **CI/CD** | GitHub Actions with AWS OIDC (no long-lived keys): plan on PR, apply + tests on `main` |

## How it works

```text
                       Terraform
                           │
     ┌─────────────────────┼──────────────────────────┐
     ▼                     ▼                          ▼
 VPC + EC2 Kafka     Secrets Manager          Rule Lambdas + IAM roles
     │                     │                          │
     └── IAM role may read ┘                          ▼
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
4. Config automatically runs the SSM Automation runbook `AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock` under a dedicated least-privilege role.
5. The fix is itself a change, so the rule re-evaluates → `COMPLIANT`.

The Lambda only decides; it never modifies the bucket. Remediation is done by SSM Automation, with retries and an audit trail.

### Safety in a shared account: tagged buckets only

Because the reactive control changes buckets automatically, both rules only act on buckets tagged:

```text
Phase3Scope = <project_name>-<environment>      (default: kafka-on-ec2-dev)
```

- **Reactive:** the Config rule scope is the tag, and the Lambda re-checks the tag before reporting `NON_COMPLIANT`, so remediation can never reach an untagged bucket.
- **Detective:** periodic rules have no change scope, so the Lambda itself queries only tagged buckets.

### AWS Config recorder

This repository does **not** create an AWS Config recorder or delivery channel. AWS allows one recorder per account and region; in a Control Tower account it already exists (`aws-controltower-BaselineConfigRecorder`) and is owned by Control Tower. The rules use that recorder. In an account without AWS Config, enable the recorder first.

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
│   ├── ec2_kafka/                  broker instance + Kafka install (user data)
│   ├── secrets_manager/            generated credential
│   └── config_controls/
│       ├── main.tf                 Lambdas, IAM roles, log groups, conformance pack
│       ├── templates/conformance_pack.yaml
│       └── lambda/
│           ├── detective/handler.py
│           └── reactive/handler.py
├── tests/
│   ├── test_phase3_logic.py        unit tests for both rule Lambdas (mocked AWS)
│   └── test_kafka_e2e.py           produce/consume test on the broker via SSM
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
| `phase3_secret_arn` | The Secrets Manager secret |
| `phase3_conformance_pack_name` | The conformance pack |
| `compliance_scope_tag_key` / `compliance_scope_tag_value` | Tag a bucket with these to bring it under the rules |

## Test

**Unit tests** (no AWS needed):

```bash
pip install -r tests/requirements.txt
pytest tests/test_phase3_logic.py -v
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
aws configservice describe-remediation-executions --config-rule-name <reactive rule name>
```

Expected: the versioning bucket is `NON_COMPLIANT` (reported only); the Public Access Block bucket goes `NON_COMPLIANT` → remediated → `COMPLIANT` within a few minutes.

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

- Kafka authentication (SASL/SCRAM) using the Secrets Manager credential; today the secret is created and readable by the broker role but not yet used by Kafka
- Three-broker Kafka cluster across three AZs
- Custom SSM remediation document in place of the AWS-managed runbook
