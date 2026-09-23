# Pawton Manufacturing

A fun, Ninja Paws-themed Astro/Node.js dashboard for Scenario 2. It reads live data from the
[Futon Manufacturing](https://github.com/microsoft/sql-server-samples/tree/master/samples/databases/futon-manufacturing)
sample database restored on the Scenario 2 SQL Server VM, over a private VNet connection.
Separate public SQL access depends on the deployment settings; a private app connection does not imply that the SQL VM has no public endpoint.

This is the demo application that makes Scenario 2 tangible: a real Node.js Web App, protected by
Microsoft Defender for App Service (subscription-wide, shared with Scenario 1), talking privately
to a SQL Server VM protected by Defender for Servers Plan 2 and Defender for SQL.

## Local development

```bash
npm install
SQL_SERVER_HOST=<vm-private-ip> SQL_APP_LOGIN_PASSWORD=<futon_app-password> npm run dev
```

Without `SQL_SERVER_HOST`/`SQL_APP_LOGIN_PASSWORD` set, every page still renders and reports that
the database is not configured, instead of failing to build.

## Environment variables

| Variable                     | Default                   | Purpose                                                                                                                                                       |
| ---------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SQL_SERVER_HOST`            | _(required)_              | Private IP of the Scenario 2 SQL Server VM                                                                                                                    |
| `SQL_DATABASE`               | `FutonManufacturing`      | Database name                                                                                                                                                 |
| `SQL_APP_LOGIN`              | `futon_app`               | Least-privilege SQL login                                                                                                                                     |
| `SQL_APP_LOGIN_PASSWORD`     | _(required)_              | Matches the Key Vault secret the VM also uses                                                                                                                 |
| `ADMIN_PORTAL_USERNAME`      | _(required for `/admin`)_ | Username accepted at `/admin/login`                                                                                                                           |
| `ADMIN_PORTAL_PASSWORD`      | _(required for `/admin`)_ | Password accepted at `/admin/login`                                                                                                                           |
| `ADMIN_SESSION_SECRET`       | _(required for `/admin`)_ | HMAC key signing the admin session cookie                                                                                                                     |
| `SQL_ADMIN_LOGIN`            | `dojo_admin_portal_svc`   | SQL login the admin portal uses to manage `sa`                                                                                                                |
| `SQL_ADMIN_LOGIN_PASSWORD`   | _(required for `/admin`)_ | Matches the Key Vault secret the VM also uses                                                                                                                 |
| `LOG_ANALYTICS_WORKSPACE_ID` | _(optional)_              | Workspace ID (GUID) of `log-np-sentinel-centralus`, queried with the Web App's own managed identity to confirm sa actions reached the Windows Application log |

Additional security lab settings:

- `SQL_VM_RESOURCE_ID` (set by Bicep): fixed VM ARM ID for extension-status reads, Azure links, and VM-scoped audit evidence.
- `AZURE_SUBSCRIPTION_ID` (set by Bicep): subscription for read-only Defender pricing queries; falls back to App Service metadata.
- `ENABLE_SQL_DEMO_ACTIONS` (default `false`): opt in to fixed local SQL audit probes; one in flight and a 60-second process-wide cooldown.
- `ALLOW_DEMO_BLANK_PASSWORDS` (default `false`): allow clearing only unprivileged `dojo_demo_` logins with no application database user mappings; never applies to SID `0x01` or application logins.

In Azure, connection settings are set by `infra/sql-defender-scenario/main.bicep`. The current training template supplies SQL passwords as protected app settings and also stores them in Key Vault; they are not Key Vault reference expressions. Do not copy this high-privilege pattern into production.
Without the admin credentials and session secret, sign-in remains unavailable. Without `LOG_ANALYTICS_WORKSPACE_ID`,
the "Windows Event confirmation" section reports itself as unconfigured instead of failing.

## Routes

- `/` — at-a-glance counts (items, warehouses, customers, open production orders)
- `/inventory`, `/sales`, `/production` — live report views
- `/health` — JSON health probe used as the Web App's health check path
- `/api/status` — JSON evidence endpoint, consistent with Scenario 1's `/api/status`
- `/users` — authenticated SQL login inventory and confirmed enable/disable/rotate actions. Built-in administrator controls retain Key Vault synchronization. System, Windows, server-role members, database owners, and application logins are protected from general actions. Visitors see only a sign-in prompt.
- `/admin` — security lab: live Azure plan/extension observations, opt-in audit probes, documented alert simulations, and forwarded Windows event evidence.
- `/admin/schema` — authenticated, permission-filtered tables, views, columns, database users, and roles. No schema mutation or arbitrary SQL console.
- `/admin/auditing` — authenticated SQL Audit configuration and separate T-SQL/KQL verification examples.

## Security lab

The lab separates **SQL authorization**, **SQL Audit**, and **Defender threat detection**. Defender for SQL is not a general SQL query firewall, and disabling it does not turn off SQL permissions or SQL Audit. Plan pricing and extension provisioning are evidence of configuration, not proof of sensor health or alert delivery. Refresh the page to re-read Azure; unavailable/403 responses remain explicitly unverified.

For live cloud status, an operator must grant the Web App managed identity read access, for example **Security Reader** at the intended subscription for pricing and **Reader** at the target VM for extension metadata. This change does not assign those roles automatically and never grants plan-write or VM-extension-write access. Local development uses `DefaultAzureCredential`; deployed App Service uses its managed identity. The current status reader targets Azure public cloud.

After setting `ENABLE_SQL_DEMO_ACTIONS=true`, authenticated operators can run fixed, confirmed probes:

- Audited read: one row from `dbo.Items`; values are not returned to the browser.
- Data-change audit: create `dbo.DojoAuditProbe`, INSERT/UPDATE/DELETE one row, then roll back the whole transaction and table. If that name already exists, abort without modifying it. The privileged admin pool runs this isolated DDL exercise. No business rows are changed.
- Permission boundary: query login metadata with the app login. SQL may filter visible metadata or deny access; neither outcome is falsely attributed to Defender blocking.

Each response contains a run UUID for correlating Windows Event ID 33205. A request completing is not proof that ingestion or a Defender alert occurred. Audit events can represent rolled-back statements; SQL Audit is not row-level before/after history. Probes do not execute shell commands, download payloads, or accept arbitrary queries, server names, or external targets. The cooldown is process-local, appropriate to this single-instance demo, not a distributed production rate limit.

Microsoft documents six safe telemetry simulations: brute-force authentication, suspicious application, SQL injection, principal anomaly, shell external source anomaly, and shell obfuscation. The lab links to Azure's **Simulate Alerts** workflow for each. These links are not direct trigger APIs; complete the selection and confirmation in Azure using your Azure identity. See [Simulate alerts for SQL servers on machines](https://learn.microsoft.com/azure/defender-for-cloud/simulate-alerts-sql-machines) and the [SQL alert reference](https://learn.microsoft.com/azure/defender-for-cloud/alerts-sql-database-and-azure-synapse-analytics). Allow several minutes and inspect the target resource's alert evidence. No guarantee is made that an ordinary local probe produces an alert.

Protection on/off comparisons remain an explicit Azure operation, not an application toggle. Subscription changes affect other workloads and billing. Microsoft's [resource-level disable procedure](https://learn.microsoft.com/azure/defender-for-cloud/disable-sql-on-machines) removes the SQL protection extension; review provisioning policy and the [restoration procedure](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-sql-usage) first. Record a baseline, use an isolated target, restore protection, and verify sensor health afterward. Keep SQL Audit enabled throughout.

## Login changes

All mutation endpoints require a valid signed admin session, exact same-origin POST, and explicit confirmation. User inventory and authenticated pages are not cached. The username and Logout action stay visible across pages. Renamed built-in administrators are identified by SID `0x01`, never by name alone. Built-in password rotation rejects empty values at the SQL service boundary.

The demo login action creates only `dojo_demo_reader`, with a random password and no user in the sample database. It never overwrites an existing login. General rotations are shown once and are not synchronized to arbitrary external secrets; only the existing built-in administrator workflow synchronizes Key Vault. Clearing a password requires the explicit opt-in above, a `dojo_demo_` prefix, no privileged server grants/role memberships/ownership, no application database user mapping, and all application databases online for verification. Public-role grants still apply: use an isolated server with reviewed public permissions and restricted networking. Clearing disables password-policy enforcement; rotate immediately afterward to restore a strong password and policy checking. Disabling a login prevents new logins but does not terminate existing sessions.

## Validation

Run `npm test` in this directory for offline session/origin/confirmation, protected-login, opt-in, audit-parser, target-resolution, and transaction-cleanup tests. Run `npm run build` for the Astro build. These checks do not execute SQL, produce live alerts, or change Azure protection. Validate actual DDL and Defender evidence on an isolated SQL Server before a live presentation.
