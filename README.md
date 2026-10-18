# CloudOps — Field Operations & Incident Management Platform

**Live demo:** https://d35plopv18aik3.cloudfront.net
*(Sign-in is by invitation: accounts are created by an administrator. See [Demo access](#demo-access).)*

A serverless platform for logging, working and closing IT / data-centre incidents, built hands-on on AWS and **deployed entirely from Terraform code**.

## Why this exists

In a previous role I saw the same problem again and again: when something went wrong, keeping everyone informed took nearly as much effort as fixing the issue. The same update explained repeatedly, to different people, because there was no single place showing what was happening right now.

CloudOps solves that directly. The moment an incident is logged, worked or resolved, everyone who needs to know can see it, and a critical (P1) incident that nobody picks up escalates by itself.

I'm building it alongside studying for the **AWS Certified Solutions Architect – Associate**, to put the concepts into practice on a real, deployed system.

## What it does

- **Incident lifecycle (ITIL style):** OPEN → IN PROGRESS → RESOLVED (engineer says it's fixed) → CLOSED (manager signs off), with Reopen and a full timeline of who did what.
- **Authentication and roles:** Amazon Cognito, JWT on every API route. Field engineers work incidents, managers sign off, view-only users can look and report. Every rule is enforced in the backend, never only in the UI.
- **Photo / file attachments** straight from a phone camera to S3 with presigned URLs (files never pass through the API).
- **Automatic P1 escalation:** every new incident publishes an event; EventBridge picks out P1s and starts a Step Functions workflow that waits 5 minutes, checks whether anyone acknowledged it, and emails an escalation if not. No Lambda glue code.
- **Monitoring:** CloudWatch alarms email on Lambda errors, API 5xx errors, undeliverable P1 events and failed escalations.

## Architecture

```
Browser ──HTTPS──▶ CloudFront (WAF, security headers) ──OAC──▶ S3 (dashboard, private)
   │
   ├──▶ Cognito (sign-in, JWT)
   │
   └──▶ API Gateway HTTP API (JWT authorizer on every route, throttling, access logs)
            │
            ▼
        9 Lambda functions (Python 3.14, arm64), each with its OWN least-privilege role
            │
            ├──▶ DynamoDB (incidents, GSI on status, point-in-time recovery)
            ├──▶ S3 (attachments: presigned PUT/GET, lifecycle to IA / Glacier IR)
            └──▶ EventBridge (IncidentCreated events)
                     │  rule: severity = P1
                     ▼
                 Step Functions: wait 5 min → DynamoDB GetItem → acknowledged?
                     │                                   ├── yes → done
                     │                                   └── no  → SNS email
                     └── undeliverable events → SQS dead-letter queue

CloudWatch: 30-day logs everywhere + 4 alarms → SNS email
```

## Infrastructure as code

Everything above is defined in [`terraform/`](terraform/) — **111 resources**, one file per service:

| File | What it builds |
|---|---|
| `dynamodb.tf` | Incidents table, status index, PITR, deletion protection |
| `s3.tf` | Attachments + dashboard buckets (private, encrypted, HTTPS-only) |
| `cognito.tf` | User pool (admin-only sign-up), app client, role groups |
| `events.tf` | EventBridge bus + P1 rule, Step Functions workflow, SNS, DLQ |
| `lambda.tf` | 9 functions, each with its own IAM role and log group (code in `lambda_src/`) |
| `cloudfront.tf` | CloudFront, WAF, Origin Access Control, attachments CORS |
| `api.tf` | HTTP API, JWT authorizer, 10 routes, one invoke permission per route |
| `dashboard.tf` | Uploads the dashboard (`dashboard_src/`) with the live API / Cognito values filled in |
| `monitoring.tf` | Alarms and the ops-alerts topic |

State is kept in S3 with native locking. The system was first built by hand in the console, then **inventoried with a read-only script, rebuilt as code alongside the original, tested end to end, and switched over** — the console version was deleted afterwards. Rebuilding as code exposed problems the console had hidden (a shared IAM role across five functions, open self sign-up, stale permissions), all fixed in the Terraform version.

## Tech stack

| Layer | Service |
|---|---|
| IaC | Terraform (AWS provider 6.x), remote state in S3 |
| Compute | AWS Lambda (Python 3.14, arm64 / Graviton) |
| API | Amazon API Gateway (HTTP API, JWT authorizer) |
| Database | Amazon DynamoDB |
| Auth | Amazon Cognito |
| Storage / CDN | Amazon S3, Amazon CloudFront, AWS WAF |
| Events | Amazon EventBridge, AWS Step Functions, Amazon SNS, Amazon SQS |
| Location | Amazon Location Service (geocoding) |
| Observability | Amazon CloudWatch (logs, alarms) |
| Frontend | Plain HTML / CSS / JavaScript (no framework, no build step) |

## Demo access

The live demo uses test accounts (a manager, a field engineer and a view-only user). Credentials are available on request — not published here because this is a live AWS account.

## What's next

1. **CI/CD** with GitHub Actions (OIDC, no stored AWS keys): `terraform plan` on every pull request, `apply` on merge.
2. **AI triage** with Amazon Bedrock: suggest severity and a summary for new incidents — AI suggests, a human confirms.
3. **Portfolio write-up**: architecture diagram, design decisions, costs, the real bugs found and fixed, and a short demo video.

See [`docs/PROGRESS.md`](docs/PROGRESS.md) for the earlier build log (Sprints 1–7).

## Author

Paulo Martinho — [LinkedIn](https://www.linkedin.com/in/paulo-martinho-5957ab69/)
