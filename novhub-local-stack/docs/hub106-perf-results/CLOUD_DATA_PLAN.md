# HUB-106: local NovApi and NovApp on the dev cloud data (plan)

Goal: run NovApi and NovApp locally, connected to dev's OpenSearch and PostgreSQL, so BEFORE and AFTER can be measured on real dev data without merging to `main`. Scripts only; no product code changes.

## Facts read from the code (NovApi, `~/dev/NovApi`)

| Topic | Fact | Source |
|---|---|---|
| PostgreSQL | Settings are `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USERNAME`, `DB_PASSWORD`. With `NODE_ENV=development` they come from `.env`; otherwise from AWS Secrets Manager. | `utils/secrets.js`, `.env.sample` |
| OpenSearch | Settings are `OPENSEARCH_HOST` (a full URL) and `OPENSEARCH_INDEX`. The client signs every request with AWS SigV4 (service `es`) using the default AWS credential chain, so the account behind the credentials must be allowed by the domain's access policy. `ssl.rejectUnauthorized` is false. | `osRepo/queries.js` 49-80 |
| Migrations | Not run at start. Only the admin route `routes/api/v1/admin.js` applies them. A local NovApi on dev data must never have that route called. | `routes/api/v1/admin.js` 102-128; `bin/www` |
| Network | The bastion is a bare jump host. It reaches the dev database on 5432 and OpenSearch on 443. Both endpoints are VPC-only. | owner's read-only exploration |
| Existing tooling | `connect_server`, `cp_server`, `exec_server` in `~/dev/scripts/bashrc/.functions` (target `cat-dev`). Tooling launchers strip `AWS_*` from NovApi's environment (to protect the MinIO setup). | SCRIPT report |

## Design

1. Two SSH local forwards through the bastion: local port to the RDS host on 5432, local port to the OpenSearch host on 443. NovApi's `.env` for this mode points `DB_HOST`/`DB_PORT` at the local end.
2. OpenSearch through a tunnel: the SigV4 signature covers the `Host` header, so NovApi must send the real VPC hostname. Two ways, to be tested (unverified): the OpenSearch URL keeps the real hostname with the forwarded port in the URL and a `/etc/hosts` line mapping the hostname to 127.0.0.1, or the same on port 443 (needs root for the forward). A `/etc/hosts` line is a system change: the owner's decision.
3. Read-only by construction: a read-only PostgreSQL role and read-only AWS credentials for the OpenSearch domain. The Analytics pages only read. The launcher refuses to start in cloud mode if the database role can write.
4. One git-ignored config file for cloud mode (ports, hostnames, index, robot name, URLs); secrets only in 0600 files; nothing hardcoded, nothing printed.
5. A/B on the same data without a merge: BEFORE = the `main` commit of both repos, AFTER = branch `jaguar/HUB-4.2.0-release-prep`, both run locally through the same tunnels, same robot, same window. Both pay the same tunnel round trip, so the comparison is fair; absolute server times are inflated and are not production times.

## Roles

| Who | Work | Code changes |
|---|---|---|
| SCRIPT | Idempotent tunnel script (open, status, close; uses the `.functions` helpers; refuses a key with loose mode). Cloud-mode config and launchers for NovApi and NovApp. Read-only connectivity checks (`SELECT 1`, OpenSearch cluster health). Remote capture already exists (`--remote`). | scripts repo only |
| NOVAPI | Read-only audit, then the exact environment list: does anything write at start or on sign-in; how the database client sets TLS and pool size; how OpenSearch host and port behave behind a tunnel with SigV4; whether the S3 client reuses the same AWS credentials. | none |
| NOVAPP | Confirm which `.env` values point the NovApp build at a local NovApi, for the BEFORE (`main`) and AFTER (branch) builds. | none |
| Owner | Ask the lead for a read-only PostgreSQL role, read-only AWS credentials for the OpenSearch domain, the index name, and which dev robot holds the most data. Put values in the git-ignored files, never in chat. Approve the `/etc/hosts` decision. | none |

## Phases

0. Owner asks for the credentials and the robot (nothing else can start without them).
1. NOVAPI and NOVAPP audits (read-only, no dev contact).
2. SCRIPT builds the tunnel script and checks; the owner runs it. Expected result: the status command shows both forwards open, `SELECT 1` answers, cluster health answers.
3. SCRIPT builds the cloud-mode launchers; the owner runs NovApi and NovApp locally on `main`, signs in with their own dev login.
4. BEFORE capture on `main`, then AFTER on the branch: same robot, same date range, same tools (Playwright capture and the owner's DevTools HAR and trace).
5. Report: before-vs-after tables on dev data.

## Risks

| Risk | Handling |
|---|---|
| Writes to shared dev data | Read-only role and credentials; launcher check; never call admin or sync routes. Sign-in may update a user row: NOVAPI checks. |
| Load on the shared dev database and OpenSearch | Agree a time window with the lead; capture, do not loop. |
| AWS credentials reach the local MinIO | If the S3 client uses the same chain, real credentials are sent to local MinIO. NOVAPI reports; decide before cloud mode starts. |
| SigV4 with a tunnel does not work | Fallback is a hostname mapping; if that fails, ask the lead for the dev NovApi log instead and measure on dev only. |
| Tunnel latency | Same for BEFORE and AFTER; do not quote absolute server times as production. |
