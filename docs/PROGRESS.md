# Build Log

A sprint-by-sprint record of what's been built, including the real bugs hit and fixed along the way — kept honest and unpolished on purpose, since that's the part that actually shows problem-solving.

Region: `eu-west-2` (London) · Naming convention: `cloudops-dev-<resource>`

---

## Sprint 1 — Incident Core API ✅

DynamoDB table, two Lambda functions (Create, Get), API Gateway (HTTP API) — the first working, tested endpoint.

**What got built:**
- DynamoDB table `cloudops-dev-incidents`, on-demand capacity, `incidentId` as partition key
- `CreateIncident` and `GetIncident` Lambdas (Python, arm64/Graviton), each with a dedicated IAM role scoped to exactly one DynamoDB action on exactly one table
- HTTP API in API Gateway wiring both together
- Full input validation (required fields, severity enum), proper HTTP status codes (201/400/404/500)

**Bugs hit and fixed:**
- API Gateway got created in `us-east-1` by mistake instead of `eu-west-2` — Lambda integrations must be in the same region as the function. Recreated in the correct region.
- A route existed in API Gateway but had no integration attached — looked like a routing bug, was actually a missing "Attach integration" step.
- A trailing slash on `/incidents/` caused a 404 that had nothing to do with the code — HTTP APIs match paths literally, `/incidents` and `/incidents/` are different routes.

---

## Sprint 2 — Full CRUD + Data Model ✅

Extended the API with List, Update, and Close, plus the state-transition thinking that comes with a Close action.

**What got built:**
- `ListIncidents` (DynamoDB Scan — deliberately skipped pagination for now, noted as a "add when actual data volume needs it" decision)
- `UpdateIncident` — partial updates via a dynamic `UpdateExpression`, an allowlist of updatable fields (never trust the client to say which fields it can touch), a `ConditionExpression` so updating a non-existent ID fails cleanly instead of silently creating a new item
- `CloseIncident` as its own dedicated endpoint (not folded into Update) — deliberately chosen to set up the "state transition as its own action" pattern needed later. Uses a double condition (`attribute_exists AND status <> CLOSED`) to make double-closing return `409 Conflict`, not `404` — an intentional HTTP semantics choice: 404 means "nothing here," 409 means "something's here, but it conflicts with your request."

---

## Sprint 3 — Authentication & Authorization (Cognito) ✅

Replaced "anyone can call any endpoint" with real identity: Cognito user pools, JWT-based auth, and role-based permissions enforced in application code.

**What got built:**
- Cognito User Pool with three groups: `Managers`, `FieldEngineers`, `Admins`
- A JWT authorizer in API Gateway attached to every route — rejects unauthenticated requests before they ever reach a Lambda
- Role-based logic inside `CloseIncident` — reads the `cognito:groups` claim from the decoded JWT (passed through by API Gateway), returns `403 Forbidden` if the caller isn't a Manager or Admin

**Bugs hit and fixed (this was the big one):**
- The first Cognito app client silently generated a client secret despite intending a public/secretless client — only discovered when sign-in failed with `SECRET_HASH was not received`.
- Learned the hard way that "Traditional web application" client type is treated as *confidential* (secret required) in the current Cognito console — the type that's actually public/secretless is **Single-page application (SPA)**.
- The SPA client type doesn't enable username/password sign-in (`ALLOW_USER_PASSWORD_AUTH`) by default — only SRP and choice-based sign-in. Had to manually enable it.
- Along the way: a placeholder string accidentally left in a request body instead of the real session token, and a session token that expired mid-debugging (they're short-lived, a few minutes) — both good reminders that auth challenge flows are time-sensitive.

---

## Sprint 4 — Frontend Dashboard ✅

A real, deployed web app: login page + incident console, hosted on S3, served through CloudFront over HTTPS, with the storage bucket kept fully private.

**What got built:**
- `login.html` — calls Cognito's sign-in API directly from the browser, handles the "new password required" first-login challenge inline
- `dashboard.html` — live incident list with stats, a "create incident" modal, status actions, and a role-gated Close button (disabled client-side for non-Managers, and independently rejected server-side too — the frontend check is a UX nicety, the backend check is the actual security boundary)
- CloudFront distribution in front of S3, using **Origin Access Control** so the S3 bucket itself stays fully private — CloudFront is the only thing allowed to read from it
- CORS on API Gateway, tightened from a wildcard down to the exact CloudFront domain once it existed

**Bugs hit and fixed:**
- Testing the dashboard by opening the HTML files directly from disk (`file://...`) caused CORS errors even with a correct wildcard CORS policy — turns out `file://` produces a `null` origin, which browsers handle inconsistently for CORS purposes. Fixed by actually deploying to S3 rather than fighting local file testing.
- CloudFront's console suggested pointing at the S3 *website* endpoint instead of the *REST* endpoint — but Origin Access Control only works with the REST endpoint. Declining that suggestion was the right call.
- After creating the CloudFront distribution, the root URL (`/`) returned `AccessDenied` — the "Default root object" setting had been left blank. Setting it to `login.html` fixed it.

---

## Sprint 5 — Incident File Attachments ✅

Let users attach files to an incident using **presigned URLs** — the browser uploads the file directly to S3, never routing the actual bytes through a Lambda function.

**What got built:**
- `GetUploadUrl` Lambda — validates the requested file type against an allowlist, generates a short-lived (5 minute) presigned PUT URL scoped to one exact S3 object key, and appends the attachment's metadata onto the incident's DynamoDB record using `list_append`/`if_not_exists` (safely appends to a list that might not exist yet)
- Dashboard UI: an expandable "Attach" panel per incident, doing the two-step flow (ask the API for a URL, then PUT the file straight to S3)

**Design decisions made along the way (and deliberately left open):**
- Attaching files to an already-`CLOSED` incident is allowed — a conscious choice to support realistic post-incident documentation (e.g. attaching a root-cause report after the fact), not an oversight.
- No hard-delete for incidents exists (or is planned) — discussed adding a `CANCELLED` status instead, following how real ITSM tools avoid destructive deletes to preserve an audit trail. Parked for a future sprint.
- All authenticated users can currently see all incidents, with no role/assignment-based filtering — judged reasonable for this project's single-team scope, revisit if that scope changes.

---

## What's next

Sprints 6–16 (not yet started): event-driven architecture (EventBridge, SQS), a Step Functions-based critical incident escalation workflow, a live operations map and real-time field engineer tracking via Amazon Location Service, geofencing, a full observability stack (CloudWatch, X-Ray, WAF dashboards, CloudTrail), a complete rebuild of the infrastructure as Terraform, a CI/CD pipeline via GitHub Actions, deliberate failure/chaos testing, and a closing cost + AWS Well-Architected Framework review.
