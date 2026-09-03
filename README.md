# CloudOps — Intelligent Field Operations & Incident Management Platform

**Live demo:** https://d12crl947z8m7p.cloudfront.net
*(Note: demo uses seeded test accounts — see [Demo access](#demo-access) below)*

A cloud-based platform for logging, assigning, and tracking IT incidents from creation to resolution — built entirely hands-on on AWS.

## Why this exists

In a previous role, I saw the same problem come up again and again: when something went wrong, keeping everyone informed took nearly as much effort as fixing the actual issue. The same update explained repeatedly, to different people, because there was no single place showing what was actually happening in the moment.

CloudOps solves that directly. The moment an incident is logged, updated, or resolved, that information is instantly visible to everyone who needs it — especially managers, who can make decisions based on live, accurate information instead of waiting for someone to explain it to them again.

I'm building this alongside studying for the **AWS Certified Solutions Architect** certification, as a way to put the concepts into practice on a real, deployed system rather than just exam scenarios.

## What it does today

- **Full incident lifecycle** — create, view, list, update, and close incidents, each with severity (P1–P4), status (OPEN / IN_PROGRESS / CLOSED), location, and device tracking
- **Real authentication** — Amazon Cognito user pools, JWT-based sign-in, no hardcoded credentials
- **Role-based authorization** — only Managers/Admins can close an incident; enforced both in the UI and independently in the backend (never trust the client alone)
- **File attachments** — attach photos, PDFs, or logs to an incident, uploaded directly to S3 via presigned URLs (the file never passes through the API layer)
- **Event-driven P1 alerting** — every incident creation publishes an event; a filtered EventBridge rule routes P1s through SQS (with a dead-letter queue for failed processing) to trigger automatic escalation
- **Automated critical incident escalation** — a Step Functions state machine waits 5 minutes for a P1 to be acknowledged; if it isn't, it automatically emails an escalation notice via SNS — verified end to end in both directions (acknowledged → no escalation, unacknowledged → real email sent)
- **A real, deployed web dashboard** — hosted on Amazon S3, served through Amazon CloudFront over HTTPS, with the origin bucket kept fully private via Origin Access Control

## Architecture

```
Browser (CloudFront + S3, HTTPS)
        │
        ├── Cognito (sign-in, JWT issuance)
        │
        ▼
API Gateway (HTTP API, JWT authorizer on every route)
        │
        ▼
Lambda functions (Python, arm64/Graviton)
   ├── CreateIncident      → DynamoDB PutItem + publishes IncidentCreated event
   ├── GetIncident         → DynamoDB GetItem
   ├── ListIncidents       → DynamoDB Scan
   ├── UpdateIncident      → DynamoDB UpdateItem (partial updates)
   ├── CloseIncident       → DynamoDB UpdateItem (conditional, role-gated)
   ├── AcknowledgeIncident → DynamoDB UpdateItem (marks a P1 as seen)
   ├── GetUploadUrl        → S3 presigned URL + DynamoDB metadata update
   └── ProcessP1Alert      → triggered by SQS, starts the escalation workflow
        │
        ▼
DynamoDB (incidents table)      S3 (attachments bucket)

Event pipeline (P1s only):
CreateIncident ──▶ EventBridge (filtered: severity=P1) ──▶ SQS ──▶ ProcessP1Alert
                                                              │
                                                              ▼ (on repeated failure)
                                                             DLQ

Escalation workflow (Step Functions — no Lambda glue code, direct service integrations):
ProcessP1Alert ──▶ Wait 5 min ──▶ DynamoDB: GetItem ──▶ Choice: acknowledged?
                                                            ├── Yes → Succeed
                                                            └── No  → SNS: Publish (email escalation)
```

Every Lambda has its own dedicated IAM role, scoped to exactly the single action it needs on exactly the single resource it needs — no shared roles, no wildcard permissions.

## Tech stack

| Layer | Service |
|---|---|
| Compute | AWS Lambda (Python 3.x, arm64) |
| API | Amazon API Gateway (HTTP API) |
| Database | Amazon DynamoDB |
| Auth | Amazon Cognito (User Pools, JWT authorizers) |
| Storage | Amazon S3 (static hosting + file attachments) |
| CDN / Delivery | Amazon CloudFront (HTTPS, Origin Access Control, WAF) |
| Events | Amazon EventBridge, Amazon SQS (+ dead-letter queue) |
| Orchestration | AWS Step Functions (direct DynamoDB/SNS service integrations) |
| Notifications | Amazon SNS |
| Frontend | Plain HTML / CSS / JavaScript (no framework, no build step) |
| IAM | Per-function least-privilege policies |

## Repository structure

```
backend/
  lambdas/                 One folder per Lambda function
    create-incident/
    get-incident/
    list-incidents/
    update-incident/
    close-incident/
    acknowledge-incident/
    get-upload-url/
    process-p1-alert/
  step-functions/
    p1-escalation-workflow.asl.json   The P1 escalation state machine definition
frontend/
  login.html               Cognito sign-in page
  dashboard.html            Main incident console
docs/
  PROGRESS.md               Full build log: every sprint, every decision, every bug fixed
```

## Demo access

The live demo uses seeded test accounts for evaluation purposes:
- A `Managers` group account (can close incidents)
- A no-group account (cannot close incidents — demonstrates the 403 permission boundary)

*(Credentials available on request — not published here since this is a live AWS account.)*

## What's next

This is an active, in-progress project. Done so far: core incident API, authentication and role-based authorization, a live dashboard, file attachments, event-driven P1 alerting, and automated critical-incident escalation (Sprints 1–7).

Planned next: a live operations map with real-time field engineer tracking (Amazon Location Service), smart dispatch, geofencing, a full observability stack (CloudWatch, X-Ray, WAF dashboards, CloudTrail), infrastructure-as-code via Terraform, and a CI/CD pipeline via GitHub Actions.

See [`docs/PROGRESS.md`](docs/PROGRESS.md) for the complete build log — including the real bugs hit and fixed along the way (a region mismatch, a misconfigured OAuth client, a CORS/origin issue, an EventBridge JSON-parsing gotcha, and a Step Functions Choice-state edge case), which were honestly the most valuable part of building this.

## Author

Paulo Martinho — [LinkedIn](https://www.linkedin.com/in/paulo-martinho-5957ab69/)
