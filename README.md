# Ninja Paws Cloud Security Dojo

> **Independent community project.** This repository is not a Microsoft product,
> assessment, endorsement, or official security guidance. Some contributors may be
> Microsoft employees acting in an individual or community capacity. Use at your
> own risk and validate all demo behavior before using it in any environment. See
> [DISCLAIMER.md](DISCLAIMER.md).

A defensive cloud-security training environment demonstrating container vulnerability detection, remediation, validation, and Azure deployment.

Use only an isolated, authorized training environment. This repository intentionally includes vulnerable software and privileged SQL operations. Azure resources and Defender/Sentinel plans can incur charges. Never use real customer data or expose the lab to untrusted users.

## Contents

- [Quick start](#quick-start)
- [NGINX scenario](#defender-for-cloud---scenario-1)
- [SQL Server scenario](#defender-for-cloud---scenario-2)
- [Portal setup and configuration](#portal-setup-and-configuration)
- [Demo walkthrough](#demo-walkthrough)
- [Configuration](#configuration)
- [Azure deployment](#azure-deployment)
- [Validation and workflows](#workflows)
- [Contributing](CONTRIBUTING.md), [security reporting](SECURITY.md), and [disclaimer](DISCLAIMER.md)

## Defender for Cloud - Scenario 1

**NGINX CVE Detection and Remediation** is the default scenario. It deploys the intentionally affected NGINX `1.30.3` workload and advisory-relevant `map`/regex configuration to Azure App Service with Azure Container Registry, Defender for App Service, Defender for Containers, and Defender CSPM coverage. The demo proves the running package and configuration, reviews Defender findings, then swaps to fixed NGINX `1.30.4` with the affected configuration removed.

Scenarios are registered in `config/deploy.config.json`. Select this scenario with `--scenario defender-cloud-scenario-1`. Scenario 2 uses the separate SQL lifecycle described below.

### Reproduction and evidence

The reproduction tests whether Defender inventory identifies NGINX `1.30.3` and separately whether it associates [CVE-2026-42533](https://my.f5.com/manage/s/article/K000162097). An inventory entry alone is not proof of a vulnerability finding.

1. Build and run the training container using the [demo walkthrough](#demo-walkthrough).
2. Capture `/evidence` and the output of `scripts/verify.sh`. Build-time package evidence is preserved under `/opt` in the image.
3. Deploy the image to ACR and allow Defender assessment to complete.
4. Check the software inventory for NGINX `1.30.3`, then inspect the vulnerability findings separately.
5. Record the image digest, assessment time, inventory version, and whether the CVE was reported. Repeat after remediation.

Expected inventory: NGINX `1.30.3`. Actual findings depend on the assessment and must be recorded during your run; this repository does not claim a guaranteed Defender alert or CVE association.

## Defender for Cloud - Scenario 2

**SQL Server on Azure VM Protection** deploys SQL Server 2022 on a Windows Server 2022 Azure VM (the official `MicrosoftSQLServer:sql2022-ws2022` marketplace image), seeds it with the [Futon Manufacturing sample database](https://github.com/microsoft/sql-server-samples/tree/master/samples/databases/futon-manufacturing) from `microsoft/sql-server-samples`, and demonstrates full IaaS-workload coverage: **Microsoft Defender for Servers Plan 2** (which includes automatic Microsoft Defender for Endpoint onboarding, vulnerability assessment, Just-In-Time VM access, and file integrity monitoring) and **Microsoft Defender for SQL** (SQL-specific threat detection and vulnerability assessment for the database engine).

Because this scenario provisions a fundamentally different Azure architecture than Scenario 1 (an IaaS virtual machine and SQL Server engine, instead of App Service and a container registry), it uses its own deploy script, `scripts/deploy-sql-scenario.sh`, and its own Bicep template, `infra/sql-defender-scenario/main.bicep`, rather than sharing Scenario 1's App Service-specific lifecycle.

Security posture baked into the infrastructure:

- The SQL Server VM has a public endpoint for training clients on TCP 1433, protected by the VM NSG; Azure Bastion remains available for browser-based RDP.
- RDP over Bastion is available immediately: a standing NSG rule (`AllowBastionRdp`) permits RDP from the Bastion subnet without first approving a Defender for Cloud Just-in-Time access request. The JIT policy itself stays configured (Defender for Servers Plan 2 still reports and manages it), but its NSG deny rule is overridden by the explicit allow rule. Set `autoAllowBastionRdp` to `false` (in `config/deploy.config.json` or as a Bicep parameter) to require a JIT request before every RDP session instead.
- The VM is registered with the SQL IaaS Agent extension (`Microsoft.SqlVirtualMachine/sqlVirtualMachines`), so Azure manages automated patching and best-practice assessment. Automated backups are off by default because they require a storage account destination this training scenario doesn't provision; add one and enable `autoBackupSettings` in `infra/sql-defender-scenario/main.bicep` if you need them.
- Trusted Launch (Secure Boot + vTPM) and encryption-at-host are enabled on the VM.
- The bootstrap script (`scripts/sql/Setup-FutonManufacturing.ps1`) enables Transparent Data Encryption (TDE) on the restored database, creates a SQL Server Audit (`FutonManufacturingServerAuditSpec`) covering failed logins, successful logins, login password changes, server principal changes, server permission changes, server role membership changes, and audit configuration changes, and writes those events to the Windows Application log. It also enables the instance-level "both failed and successful logins" [login auditing](https://learn.microsoft.com/en-us/ssms/configure-login-auditing-sql-server-management-studio) setting (SSMS Server Properties > Security), provisions a least-privilege application login (`db_datareader`/`db_datawriter` only) instead of using `sa`, disables the `sa` login and the legacy SQL Server Browser service, and forces encrypted client connections.
- **Database data auditing is enabled as well.** `FutonManufacturingDbAuditSpec` records `SELECT`, `INSERT`, `UPDATE`, and `DELETE` activity across the database for the training workload. The bootstrap is idempotent and repairs missing action groups on redeploy, so an earlier partial configuration does not silently reduce coverage. The exact implementation, verification queries, production-scope cautions, and a copyable SQL pattern are available to authenticated operators at `/admin/auditing`; the source of truth is `scripts/sql/Setup-FutonManufacturing.ps1`.
- **SQL logs reach a configurable Sentinel workspace** — `sqlScenario.sentinelMode` defaults to `new`, which creates the Log Analytics/Sentinel workspace in the SQL scenario resource group (`NP-ninjapaws-dojo-sql-<env>-CentralUS`) for easy demo ownership and teardown. Set it to `existing` to use `centralWorkspaceResourceGroup` / `centralWorkspaceName` instead, preserving a shared workspace across scenarios. `infra/sql-defender-scenario/main.bicep` references the resolved workspace, and `scripts/deploy-sql-scenario.sh` creates it idempotently when needed. The `amaExtension` + `dataCollectionRule` pair does the actual forwarding: the `AzureMonitorWindowsAgent` extension on the VM collects the Windows `Application`, `System`, and `Security` event logs, and the associated Data Collection Rule (`${vmName}-dcr`) forwards them to the resolved workspace over the `Microsoft-Event` stream. Both the SQL Server Audit records above (Event ID 33205, `MSSQLSERVER` source) and the login-auditing entries (Event ID 18453/18456) land in the Windows Application log, so no separate SQL-specific diagnostic setting is needed — query them in the workspace with:

  ```kql
  Event
  | where Source == "MSSQLSERVER"
  | order by TimeGenerated desc
  ```

  Adding a database audit target beyond `APPLICATION_LOG` (for example `FILE` or a dedicated Log Analytics table via the SQL Server extended events pipeline) would need its own `dataCollectionRule` data source and is out of scope for this training scenario; the Application-log path above is sufficient to demonstrate Defender for SQL's log-based detections.

### Pawton Manufacturing: the live demo site

Scenario 2 also deploys **Pawton Manufacturing** ("paw" + "futon" — the fictional futon manufacturer behind the sample data), a small Astro/Node.js dashboard at `apps/pawton-manufacturing/` that reads the restored Futon Manufacturing data live: item/warehouse/customer counts, inventory valuation, sales by channel, and production order status. It exists to make Scenario 2 tangible with a real, running application instead of only infrastructure evidence, and it extends the story to a workload type Scenario 1 doesn't cover on its own:

- It runs on its own Azure App Service for Linux (Node 24), which **Microsoft Defender for App Service already protects** the moment that plan is Standard at subscription scope — the same plan Scenario 1 requests. No extra Defender activation is needed for this Web App; the deployment report includes a check that confirms the subscription-wide plan already covers it.
- It reaches SQL Server through **regional VNet integration** into the same VNet as the SQL VM; the NSG allows the Web App subnet and the configured public TCP 1433 endpoint.
- It authenticates with the same `futon_app` SQL login the bootstrap script creates. The training template stores the password in **Azure Key Vault** and supplies it directly as a protected App Service setting, not a Key Vault reference. This deliberate lab configuration is not a production secret-delivery recommendation.
- Together with Scenario 1, this now demonstrates Defender for App Service, Defender for Containers, Defender CSPM, Defender for Servers Plan 2, and Defender for SQL side by side, backed by running (not simulated) workloads.

The deployment script uploads the portal source after infrastructure provisioning and uses Azure's remote build service. See [portal setup and configuration](#portal-setup-and-configuration) for local development and prebuilt deployment requirements.

### Admin portal: a deliberate anti-pattern, not a template

Scenario 2 defaults `xp_cmdshell` to enabled for shell attack exercises. Set `sqlScenario.enableSqlShellAttackTests` to `"false"` in [deployment configuration](config/deploy.config.json) for a shell-disabled bootstrap. **Admin settings > SQL shell access** provides a confirmed on/off switch and live SQL status. Admin changes persist until bootstrap runs again with the deployment default. If status is unavailable, the control is disabled. Disabling shell access blocks new calls but does not stop already-running commands or turn off Defender.

Scenario 2 displays event, log, and status timestamps in Eastern time by default. See [display timezone](#display-timezone) to change it.

The portal now separates `/users` (SQL login management), `/admin` (security lab and live protection observations), `/admin/schema` (read-only database inspection), and `/admin/auditing` (audit setup and verification). The signed-in username and Logout control remain in the header.

The Auditing page displays and downloads a reusable [SQL Server Audit template](apps/pawton-manufacturing/public/sql/configure-auditing.sql). It supports existing database, schema, or table/view targets, selectable SELECT/INSERT/UPDATE/DELETE actions, a database principal, optional instance-wide security events, and FILE or Windows APPLICATION_LOG output. Set its variables and start with PREVIEW; APPLY creates new definitions without overwriting existing audits, and VERIFY reports their configuration and runtime state. This is audit-only, not the sample-data bootstrap. It supports SQL Server on Windows/Linux, not Azure SQL Database, Managed Instance, Fabric, or other database engines. Configure forwarding separately, review audit volume and file-retention limits, and inspect partial definitions if apply fails.

Local audit probes and direct SQL tests require configured connections and remain enabled unless `ENABLE_SQL_DEMO_ACTIONS=false`. They use fixed repository-owned scripts, not a simulator extension. SQL authorization, SQL auditing, and Defender detection are separate: a successful action is not proof of ingestion or an alert. See [direct SQL attack tests](#direct-sql-attack-tests) for each test's boundaries.

General user actions exclude system, Windows, privileged, and application identities. Manageable SQL logins, including `dojo_demo_reader`, have an inline **Rename login** action in the inventory. Names must start with a letter or underscore and contain at most 128 letters, digits, or underscores; duplicate, reserved, and configured service-account names are rejected. Rename preserves the account's principal ID and password. Blank passwords are never allowed for the built-in administrator (SID `0x01`); the optional `ALLOW_DEMO_BLANK_PASSWORDS=true` setting only enables clearing isolated, unprivileged `dojo_demo_` logins with no application database user mappings. Renaming outside the `dojo_demo_` prefix removes eligibility for that clear-password action; it does not rotate the existing password. This is an intentional training weakness, not a production feature. No demo, account change, or protection change runs automatically on page load.

Pawton Manufacturing's `/users` tab, gated behind the admin login form, lets an authenticated operator **enable, disable, rename, and rotate the password of the SQL Server built-in administrator login** directly from its **Server login inventory** row. The row is identified by SID `0x01` even after rename. **Rename login** opens an inline name-and-confirmation form; state changes and password rotation have their own confirmation controls. Rename and rotation remain unavailable without Key Vault configuration. Read this section fully before enabling it anywhere you care about.

- **Privilege risk.** The admin portal's SQL login, `dojo_admin_portal_svc`, holds `CONTROL SERVER` to manage the built-in administrator. Compromise of the app or its credentials can compromise the SQL instance. This is an intentional training anti-pattern, not a guaranteed Defender finding. **Do not copy it into production.**
- **Credential lifecycle.** The deployment generates the built-in SQL administrator password, applies it during VM bootstrap, and stores it in Key Vault as `sql-sa-login-password`; its initial name is stored as `sql-sa-login-username`. The portal detects the built-in administrator by SQL Server's fixed SID rather than assuming its name remains `sa`, so it can display the current name, enable/disable it, rotate its password, and rename it. Password rotation and rename create a new Key Vault secret version after the SQL operation succeeds. A redeploy preserves the stored current name rather than reverting a prior rename, but intentionally rotates the password again.
- **What's protected regardless.** Sign-in requires a random, per-deployment `ADMIN_PORTAL_USERNAME`/`ADMIN_PORTAL_PASSWORD` (Key Vault secrets `admin-portal-username`/`admin-portal-password`, generated fresh by `scripts/deploy-sql-scenario.sh` on every deploy). The session cookie is HMAC-signed (`ADMIN_SESSION_SECRET`), `HttpOnly`, `Secure`, `SameSite=Strict`, and expires after 15 minutes. Login attempts are rate-limited per client. The Web App uses its system-assigned managed identity and the Key Vault Secrets Officer role to update the two built-in-administrator secrets; this wider vault access is another deliberate dojo anti-pattern. A rotated password is shown exactly once in the session and retained in Key Vault, not in application settings.
- **Audit coverage.** `SERVER_PRINCIPAL_CHANGE_GROUP` covers login enable/disable and rename operations; `LOGIN_CHANGE_PASSWORD_GROUP` covers password changes; the database specification covers `SELECT`, `INSERT`, `UPDATE`, and `DELETE`. The bootstrap configures these for the Windows Application log and the AMA/DCR path to the resolved Sentinel workspace. SQL command success alone does not prove that auditing or forwarding worked: confirm Event ID 33205 with the matching target, operation, outcome and time. A SQL password-change event does not prove that Key Vault was updated.
- **The admin page confirms it independently.** A "Windows Event confirmation" section on `/admin` runs a live KQL query (`Event | where Source == "MSSQLSERVER"`) against the resolved workspace using the Web App's own system-assigned managed identity, granted only the read-only **Log Analytics Reader** role on that workspace — a much lower-risk grant than the `CONTROL SERVER` SQL credential the same portal already holds. The authenticated `/admin/auditing` page documents the exact SQL options, verification queries, event IDs, and replication steps. Ingestion typically takes a few minutes, so a just-performed action may not appear until a refresh.
- **Credentials.** After a deploy, the admin portal URL and generated credentials are written to `output/<environment>/admin-portal-credentials.txt` (gitignored, `chmod 600`) alongside the existing `sql-vm-credentials.txt`. Delete it when you finish the exercise.
- **Turning it off.** There is no separate toggle; the feature is inert without `ADMIN_PORTAL_USERNAME`/`ADMIN_PORTAL_PASSWORD`/`ADMIN_SESSION_SECRET`/`SQL_ADMIN_LOGIN_PASSWORD` set. Remove those four Web App settings (and stop passing the corresponding Bicep parameters) to disable sign-in entirely; `/admin` will then report every attempt as invalid.

Quick start:

```bash
bash scripts/deploy-sql-scenario.sh doctor --environment dev
bash scripts/deploy-sql-scenario.sh deploy --environment dev
```

Review the generated report at `output/dev/sql-deployment-dev.html` for the verification matrix (VM running state, SQL IaaS Agent registration, Defender for Servers Plan 2 tier/sub-plan, Defender for SQL tier, public SQL endpoint, Bastion availability, the Futon Manufacturing bootstrap result, and the Pawton Manufacturing dashboard's reachability and database connectivity), then connect through **Azure Bastion** in the portal or use the public SQL endpoint to explore the restored database and Defender findings, or open the dashboard URL printed at the end of the run. The generated Windows administrator password is written once to `output/dev/sql-vm-credentials.txt` (gitignored, never printed to the console or captured in CI logs) and stored in Key Vault as `vm-admin-password`; treat both locations as secrets and delete the local file once you finish the exercise. The `futon_app` SQL login password lives in Azure Key Vault (`az keyvault secret show --vault-name <name> --name sql-app-login-password`), not in any local file. When finished, tear the environment down to avoid ongoing VM charges:

```bash
bash scripts/deploy-sql-scenario.sh uninstall --environment dev --yes
```

The VM Bastion credentials are also stored in the Scenario 2 Key Vault as `vm-admin-username` and `vm-admin-password`. Retrieve them with `az keyvault secret show --vault-name <name> --name <secret-name>` using an identity authorized to read secrets.

Scenario 2 uses one stable Key Vault per environment. Redeployments update the existing `sql-app-login-password`, `vm-admin-username`, and `vm-admin-password` secrets instead of creating another vault. Public SQL access is configured per environment with `allowPublicSqlAccess`; it is disabled by default, enabled for the isolated `dev` training environment, and disabled for `prod`.

Key Vault internet access is configured with `allowPublicKeyVaultAccess`, defaulting to `true`; it is enabled for `dev` and disabled for `prod`. The template also includes a lab-specific policy-exception tag when public access is enabled. Review this against your organization's policies and verify the effective `publicNetworkAccess` value after deployment; a tag is not a universal policy exemption.

The generated deployment report includes the public SQL endpoint and port (`<public-ip>:1433`) for SQL clients. This broad inbound access is intended for the isolated training environment; restrict the NSG source to a known CIDR before using this pattern elsewhere.

This scenario provisions a billable Azure VM, managed disk, App Service plan, and Log Analytics workspace; use an isolated subscription and delete the resource group when the exercise ends.

The CI Defender posture audit (`.github/workflows/deploy.yml`, via the shared `kit-defender-posture.yml` from Pawprint) also requests Defender for Servers Plan 2 and Defender for SQL as part of the same subscription-scoped audit used for Scenario 1, so the whole subscription's Defender coverage stays consistent whether or not the SQL VM happens to be deployed at that moment. Override the CI tiers with the `DEFENDER_SERVERS_TIER`, `DEFENDER_SERVERS_SUBPLAN`, and `DEFENDER_SQL_TIER` GitHub Environment variables; set a tier to `disabled` to skip it.

### Sentinel SQL detection content

The repo-owned solution in `infra/sentinel-sql-solution/` adds **content on top of the existing Windows Application log -> AMA -> DCR -> `Event` table pipeline**. It does not replace ingestion, create another workspace, install the Marketplace SQL connector, change SQL credentials, or change Key Vault. This is a deployable custom content package, not a published Microsoft Marketplace/Content Hub solution. Marketplace SQL content may expect a different table/schema; installing it alone does not make its queries compatible with these `Event` records.

Prerequisites: an existing SQL VM and a resolved workspace, SQL audit events already reaching `Event`, and **Microsoft Sentinel already enabled on that workspace**. With `sentinelMode: "new"`, create and onboard the new workspace before deploying content; with `sentinelMode: "existing"`, use the existing workspace onboarding path below. Log Analytics ingestion does not imply Sentinel onboarding. The script deliberately refuses deployment when Sentinel onboarding cannot be read; enabling Sentinel can add charges and is a separate operator decision. Deployment needs workspace-scope Sentinel Contributor plus permission to write saved searches and resource-group deployments (for example Log Analytics Contributor for the workspace content and deployment scope). Read-only validation needs access to the VM/workspace metadata and Log Analytics queries. No new application identity or credential is created.

For an existing workspace that has not yet been onboarded, use the separate `onboard.bicep` template **only after approving Sentinel charges**. Register the prerequisite provider before onboarding and install the CLI extension used by `doctor`/`verify`:

```bash
az provider register --subscription <subscription-id> --namespace Microsoft.OperationsManagement --wait
az extension add --name log-analytics --yes --allow-preview true
az deployment group what-if --subscription <subscription-id> --resource-group NP-Sentinel-CentralUS --template-file infra/sentinel-sql-solution/onboard.bicep --mode Incremental
az deployment group create --subscription <subscription-id> --resource-group NP-Sentinel-CentralUS --name dojo-sentinel-onboard --template-file infra/sentinel-sql-solution/onboard.bicep --mode Incremental
```

The onboarding template targets the existing workspace and does not reconfigure ingestion, retention, AMA, or DCRs. It is deliberately not called by the content lifecycle script. The supplied onboarding configuration uses Microsoft-managed encryption; review it before applying to an existing customer-managed-key deployment. The content template embeds a differently named local parser (`DojoSqlAuditInline`) so it neither depends on saved-function deployment order nor collides with the published `DojoSqlAudit` alias. On Git Bash, the lifecycle script disables MSYS path conversion so `/subscriptions/...` IDs and `sqlVmResourceId=...` parameter values reach native Windows tools unchanged.

The package deploys:

| Content                             | Behavior                                                                                                                                                                                                                                                                                                                             |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `DojoSqlAudit(VmResourceId)` parser | Scopes to the SQL VM resource ID; parses 33205 and legacy login IDs 18453/18454/18456 into actor, target, action ID, operation, outcome, client, application and audit/ingestion times. Empty outcomes remain unknown. SID `0x01` identifies the built-in administrator after rename; name fallback applies only when SID is absent. |
| Login-change analytics              | Detects enable, disable, rename and password changes for all logins, including the built-in administrator. Includes failed attempts, clearly labeled by outcome. Routine `LGIS` successes cannot crowd changes out of a top-N result limit.                                                                                          |
| Built-in-admin sign-in analytics    | Detects successful built-in-administrator authentication using SQL Server Audit records, including renamed accounts.                                                                                                                                                                                                                 |
| Failed-login analytics              | Five or more failed SQL Server Audit logins per VM/account/client in 15 minutes. Uses only 33205, avoiding double counting the accompanying 18456 instance event.                                                                                                                                                                    |
| Audit-change analytics              | Detects audit creation, alteration or removal statements, including disabling an audit.                                                                                                                                                                                                                                              |
| Saved hunting and health queries    | A 24-hour login-change timeline in Hunting Queries and counts/latest ingestion by event/action in the Dojo SQL category.                                                                                                                                                                                                             |

Rules run every five minutes with a one-hour event lookback and a five-minute ingestion window for individual changes. Events delayed beyond that lookback require hunting; the burst rule intentionally uses a 15-minute event window. Exact duplicate collected records are collapsed, but differing SQL audit sequence groups are retained as distinct evidence. Continued failed-login bursts may re-alert; matching incidents are grouped for one hour. Expected bootstrap and portal operations can trigger these training detections. Raw descriptions and statements are excluded from rule results/custom details so potential password literals are not copied into incidents. The source `Event` records remain available to authorized investigators.

Login changes generate per-result alerts named by operation, target, and outcome, for example **Dojo SQL - Login enabled: sa (Succeeded)**. Incident grouping also matches that title, keeping enable, disable, and password-change outcomes separate. SQL Audit action `LGEA` identifies enablement; `LGDA` identifies disablement. When SQL leaves the target principal blank, login-change parsing uses `object_name`. SID `0x01` identifies the built-in administrator even after rename; without a SID only the name `sa` provides a fallback, so a renamed administrator cannot be identified conclusively from that record alone. A failed enable attempt remains labeled **Failed**, not a confirmed state change. Deploy the updated Sentinel content to apply these alert settings; existing incidents are not renamed and old events are not replayed. At high event volumes, Sentinel's per-run alert limits can still aggregate excess results.

```bash
bash scripts/deploy-sentinel-sql.sh plan --environment dev
bash scripts/deploy-sentinel-sql.sh doctor --environment dev
bash scripts/deploy-sentinel-sql.sh what-if --environment dev
bash scripts/deploy-sentinel-sql.sh deploy --environment dev
bash scripts/deploy-sentinel-sql.sh verify --environment dev
```

`plan` is offline. `doctor`, `what-if`, and `verify` do not change resources. `deploy` always runs an incremental what-if first and asks for confirmation (`--yes` for deliberate non-interactive deployment). All commands accept `--subscription`; none changes the CLI's selected subscription. Workspace and VM settings reuse `config/deploy.config.json`, with explicit `--workspace-group`, `--workspace-name`, `--vm-group`, and `--vm-name` overrides. `--disable-rules` deploys disabled analytics. Stable, VM-scoped rule IDs make redeployment update this content rather than duplicate it; the parser is shared within the workspace. There is no workspace-delete/uninstall operation. Removing the SQL scenario does not remove these centrally stored rules: disable them before teardown.

Local validation: `npm run test:sentinel`, `bash -n scripts/deploy-sentinel-sql.sh`, and `shellcheck -x -P scripts scripts/deploy-sentinel-sql.sh`. Compile `infra/sentinel-sql-solution/main.bicep` and regenerate its committed ARM sibling after changes. After installing the Pawton app dependencies, execute real read-only Kusto fixture tests with:

```bash
node scripts/test-sentinel-sql.mjs --workspace <workspace-customer-id>
```

The fixtures cover enable/disable, rename, password rotation, service-login noise, renamed-admin sign-in, unknown outcomes, legacy login IDs, exact duplicates, VM scope, and all four rule filters. Add `--vm-resource-id <sql-vm-resource-id>` to also print live aggregate event counts. Fixture success proves query behavior, not live audit coverage.

For a controlled end-to-end exercise, use the isolated demo portal to change the login state, record the time/current username, then restore the original state. After ingestion, check the login-change hunting query for Event ID 33205, target, outcome and operation; a routine `LGIS` record alone is not confirmation of an enable/disable. Inspect `sys.server_audit_specification_details`, `sys.server_audit_specifications`, and `sys.dm_server_audit_status` on the VM if changes are absent; then check the local Windows Application log before troubleshooting AMA/DCR forwarding. Do not enable a disabled administrator just to test log ingestion. An empty query result is not evidence of healthy auditing.

References: [SQL Server audit action groups](https://learn.microsoft.com/sql/relational-databases/security/auditing/sql-server-audit-action-groups-and-actions) and [Sentinel scheduled rule resource schema](https://learn.microsoft.com/azure/templates/microsoft.securityinsights/2025-09-01/alertrules).

## Portal setup and configuration

Pawton Manufacturing is the Scenario 2 Astro/Node.js app. From the repository root:

```bash
npm ci --prefix apps/pawton-manufacturing
npm run dev --prefix apps/pawton-manufacturing
```

Without SQL connection settings, pages report the database as unconfigured. Supply credentials through your process environment or an approved secret provider, not source control or shell commands retained in history. The deployed app uses private VNet connectivity to SQL; public SQL exposure is controlled separately.

### Portal environment variables

| Variable                                           | Default or requirement            | Purpose                                                                        |
| -------------------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------ |
| `SQL_SERVER_HOST`                                  | Required for database access      | SQL VM host/private IP                                                         |
| `SQL_DATABASE`                                     | `FutonManufacturing`              | Application database                                                           |
| `SQL_APP_LOGIN`                                    | `futon_app`                       | Application SQL identity                                                       |
| `SQL_APP_LOGIN_PASSWORD`                           | Required for database access      | Application password                                                           |
| `SQL_ADMIN_LOGIN`                                  | Required for admin SQL operations | Privileged identity; deployment supplies `dojo_admin_portal_svc`               |
| `SQL_ADMIN_LOGIN_PASSWORD`                         | Required for admin SQL operations | Privileged SQL password                                                        |
| `ADMIN_PORTAL_USERNAME`, `ADMIN_PORTAL_PASSWORD`   | Required for sign-in              | Operator credentials                                                           |
| `ADMIN_SESSION_SECRET`                             | Required for sign-in              | HMAC session-signing secret                                                    |
| `SQL_CONNECT_TIMEOUT_MS`, `SQL_REQUEST_TIMEOUT_MS` | `5000`                            | Positive connection/query timeouts; invalid values use the default             |
| `LOG_ANALYTICS_WORKSPACE_ID`                       | Optional workspace GUID           | Enables forwarded-event confirmation                                           |
| `SQL_VM_RESOURCE_ID`                               | Set by deployment                 | Fixed VM scope for evidence and extension reads                                |
| `AZURE_SUBSCRIPTION_ID`                            | Set by deployment                 | Read-only Defender plan queries; may fall back to App Service metadata         |
| `ENABLE_SQL_DEMO_ACTIONS`                          | Enabled unless `false`            | Controls audit samples and direct SQL tests                                    |
| `ALLOW_DEMO_BLANK_PASSWORDS`                       | `false`                           | Opt-in password clearing for restricted `dojo_demo_` accounts only             |
| `SQL_SHELL_ATTACK_TESTS_ENABLED`                   | `true`                            | Displays the bootstrap default; changing this alone does not change SQL Server |
| `PORTAL_TIME_ZONE`                                 | `America/New_York`                | Human-readable event and status timezone                                       |

The app and admin connection pools remain separate. Encryption is required; the lab trusts the VM's self-signed certificate. Admin operations use a deliberately privileged identity. The managed identity needs read access to Defender plans, VM extensions, and the configured workspace; missing access is reported as unavailable, not healthy.

For a prebuilt Linux deployment, set `WEBSITE_HOSTNAME` during the build so Astro trusts the deployed host for same-origin requests, and include Linux production dependencies. Source packages require remote build automation; prebuilt packages do not. Match App Service's build settings to the package type. Do not disable CSRF checks to bypass a hostname mismatch.

### Custom domain and Cloudflare

The portal supports an optional custom subdomain through the same deployment configuration. Dev defaults to `pawton.ninjapaws.org`; prod has no custom hostname until you configure one. Never point the same hostname at both environments.

| Configuration key                                                             | Environment override   | Default                                         |
| ----------------------------------------------------------------------------- | ---------------------- | ----------------------------------------------- |
| `environments.<env>.webAppCustomDomain` (or `sqlScenario.webAppCustomDomain`) | `PORTAL_CUSTOM_DOMAIN` | `pawton.ninjapaws.org` for dev; otherwise blank |
| `sqlScenario.manageCustomDomain`                                              | `MANAGE_CUSTOM_DOMAIN` | `false`                                         |
| `sqlScenario.cloudflareZoneId`                                                | `CLOUDFLARE_ZONE_ID`   | Blank                                           |

Per-environment values override `sqlScenario` values. CLI options `--custom-domain`, `--cloudflare-zone-id`, and `--manage-custom-domain` override configuration for a run. Set the Cloudflare zone ID from your zone overview. Supply `CLOUDFLARE_API_TOKEN` as an environment secret with **Zone Read** and **DNS Edit** scoped only to that zone. Do not put the token in JSON, command arguments, the portal's app settings, or Bicep parameters. In GitHub Actions, use Environment variables for the three overrides above and an Environment secret named `CLOUDFLARE_API_TOKEN`.

The domain lifecycle uses Cloudflare's API for DNS and [custom-domain.bicep](infra/sql-defender-scenario/custom-domain.bicep) for Azure hostname/certificate resources:

1. Read the existing Web App's default hostname and domain-verification ID.
2. Create missing `asuid.<hostname>` TXT and direct CNAME records. Matching records are preserved; conflicting records stop deployment before DNS writes.
3. Verify public DNS, add the hostname if absent, then issue an App Service managed certificate and bind SNI HTTPS. Existing non-managed TLS bindings are not replaced automatically.
4. Check the HTTPS Status page with certificate validation enabled. DNS propagation or certificate issuance can require a rerun; partial setup is safe to resume.

This path requires **Cloudflare DNS-only (grey cloud), with CNAME flattening off**. Keep that setting for managed certificate renewal. It does not enable Cloudflare's proxy/WAF, change zone-wide TLS settings, or bypass certificate verification. For orange-cloud proxying, use a separately reviewed origin-certificate/renewal design and Full (strict) TLS, not Flexible mode. A missing public CNAME is not proof the site is down: existing proxy or flattened configurations must be reviewed before adoption. Apex domains and wildcards are not supported by this helper; hostnames are limited to 64 characters by the managed-certificate path. Review public reachability and CAA restrictions before issuance.

```bash
# Offline plan; no credentials or network access required.
bash scripts/deploy-pawton-domain.sh plan --environment dev
# Read-only Azure, Cloudflare, DNS, and HTTPS checks.
bash scripts/deploy-pawton-domain.sh check --environment dev
# DNS and HTTPS only: does not redeploy the VM, rotate passwords, or rebuild the portal.
bash scripts/deploy-sql-scenario.sh domain --environment dev
```

Set `manageCustomDomain` to `true` (or pass `--manage-custom-domain`) to run this step after the portal deploys during the full SQL scenario lifecycle. The existing SQL deployment workflow also offers a `domain` stage, which skips the subscription-wide Defender posture job. Domain writes require the matching `dev`/`main` branch, Azure resource permissions for the app/certificate/deployment, and explicit confirmation (`--yes` for automation).

The main Bicep template writes `PORTAL_CUSTOM_DOMAIN` to the Web App. Astro must see it **at build time** for same-origin manager/admin sign-in; for prebuilt artifacts, supply both `PORTAL_CUSTOM_DOMAIN` and `WEBSITE_HOSTNAME` while building. A domain-only run does not rebuild an existing artifact. The default `azurewebsites.net` host remains supported. Host-only session cookies are not shared between the two domains, so sign in again after switching hosts.

Uninstall does not delete external Cloudflare records. Remove or repoint the CNAME before deleting the app to avoid a dangling DNS record; retain the ownership TXT until the migration is complete. Setting the hostname blank or disabling automation does not remove existing bindings. Local checks: `npm run test:domain` and `bash scripts/deploy-pawton-domain.sh plan`.

References: [App Service custom domains](https://learn.microsoft.com/azure/app-service/app-service-web-tutorial-custom-domain), [managed certificate requirements](https://learn.microsoft.com/azure/app-service/configure-ssl-certificate), and [Cloudflare DNS API](https://developers.cloudflare.com/api/resources/dns/subresources/records/methods/create/).

### Display timezone

Set `sqlScenario.portalTimeZone` in [deployment configuration](config/deploy.config.json), or change the running app's `PORTAL_TIME_ZONE` setting and restart. `America/New_York` observes EST in winter and EDT in summer; use `Etc/GMT+5` for fixed EST year-round, `UTC`, or another IANA timezone. Keep deployment configuration aligned with runtime changes.

Admin event tables, expanded Windows records, protection checks, and System status use the selected timezone. Blank/invalid zones fall back to Eastern time; malformed timestamps display `Unavailable`. Stored UTC timestamps, API ISO values, raw log descriptions, sorting, and relative query windows are unchanged. No SQL/VM timezone change or app rebuild is needed.

### Portal routes

The shared page head includes route descriptions, application identity, favicons, theme color, and Open Graph/Twitter previews with a static Pawton image. Public-page canonical URLs use the configured `PORTAL_CUSTOM_DOMAIN`, falling back to `WEBSITE_HOSTNAME`; local previews omit them. Query strings and private order identifiers are never included. Login, order-management, and admin pages use generic metadata without social-preview tags.

This intentionally vulnerable lab sends `noindex, nofollow, noarchive` in HTML metadata and `X-Robots-Tag` response headers. Crawling is allowed so search engines can read those directives; no search sitemap is published. These are crawler preferences, not access controls: authentication still protects restricted pages. Dynamic responses also set a strict-origin referrer policy and disable MIME sniffing.

| Route                                      | Purpose                                                                     |
| ------------------------------------------ | --------------------------------------------------------------------------- |
| `/`, `/inventory`, `/sales`, `/production` | Live sample-data reports                                                    |
| `/health`, `/api/status`, `/status`        | Health, JSON evidence, and human-readable system status                     |
| `/login`, `/users`                         | Shared manager/admin sign-in and authenticated SQL login management         |
| `/admin`                                   | Security observations, lab tests, SQL shell setting, and event confirmation |
| `/admin/schema`, `/admin/auditing`         | Authenticated schema and audit inspection                                   |

Record tables show 25 rows per page with bottom first/previous/next/last arrows and a **Go to record** number field. Inventory, Sales, Production, Users, and Schema include all rows visible to their existing report queries, without the former 25/500-row cutoffs. These sample-database tables are loaded once per page request and paged in the browser; Sales remains an aggregate report. Windows events use counted server-side pages with no 100-event cutoff within the fixed 30-minute window. **Refresh events** starts a new window; summary and raw-record views use the same page. Permissions and login-action confirmations are unchanged.

Windows Event confirmation has an operation **Filter** that defaults to **Hide Login succeeded**. Choose **All operations** to include successful logins, or select an individual operation. Filtering happens before counts and pagination, applies to both the table and raw records, and persists across page navigation and **Refresh events**. Applying a filter returns to the first page within the current time window. It only changes the view; no event records or audit collection settings are changed.

### Staff order management

The portal labels this non-admin role **Manager**: select **Login** and enter manager credentials, then use **Manage orders** to create an order, edit a draft, or view a confirmed/cancelled order. The same form accepts administrator credentials and opens the Security lab instead. Administrators inherit all manager workflows through **Manage orders**, using their own admin session and username, plus SQL administration, security exercises, and admin evidence controls. Managers cannot access those admin-only operations. Order ownership remains per username for both roles; administrator access does not impersonate the manager or bypass order ownership, draft-state, or revision checks.

Both roles use `/login`; the legacy `/admin/login` URL redirects there. Failed login attempts share one rate limit across roles and the legacy API endpoints. If both configured identities have identical credentials, the lower-privilege manager role takes precedence. A full SQL scenario deployment generates a manager password and independent 256-bit session key. Bicep stores them with the username in the scenario's Key Vault as `user-portal-username`, `user-portal-password`, and `user-session-secret`, and supplies the same values to `USER_PORTAL_USERNAME`, `USER_PORTAL_PASSWORD`, and `USER_SESSION_SECRET` on the Web App. This follows the existing lab's protected app-setting pattern, not live Key Vault references: editing a vault secret alone does not update the running app. No manager password or signing key is printed, placed in a deployment output, or saved to a local credential file.

The username defaults to `dojo-manager`. Override it with `sqlScenario.userPortalUsername`, `environments.<env>.userPortalUsername`, or the `USER_PORTAL_USERNAME` environment/GitHub Environment variable (1-100 letters, digits, dots, underscores, @ signs, or hyphens). Keep it stable because order ownership uses this username. Each full deployment rotates the manager password and session key, invalidating existing sessions; retrieve the current username/password from Key Vault using an authorized identity. Domain-only deployment does not rotate credentials. When `deployWebApp=false`, the three manager secrets are not provisioned. Direct Bicep callers must provide the secure `userPortalPassword` and `userSessionSecret` parameters.

For local development, supply the three `USER_*` settings through a local secret provider. There is no default password, public registration, or SQL-login-based sign-in. This lab version provides one configured manager identity; use an organizational identity provider before supporting multiple people in production.

Staff can create customer-order drafts, edit their own drafts, and explicitly confirm or cancel a saved draft. Orders appear under **Orders** with record navigation and line-item details. Prices and totals are calculated from the server's current catalog, not browser-submitted prices. Tax, shipping, discounts, payments, stock reservations, and production release are outside this workflow. Existing sample orders and orders owned by another username are not editable through the staff interface.

Writes use the existing application SQL connection and sales-order tables, never the privileged admin connection. Draft writes are transactional, duplicate create submissions reuse the order number, and stale draft revisions are rejected. Confirmation does not manufacture goods or move inventory. No schema migration is required for the upstream Futon Manufacturing schema.

Staff and administrators have different signed cookies. Signing in to one role clears the other role's cookie. Staff sessions expire after 15 minutes and become invalid when staff credentials change; changing the configured username also changes which orders are visible. SQL login administration, security exercises, and admin evidence controls remain administrator-only. A business order write can produce SQL Audit records but is not a guaranteed security alert.

### Direct SQL attack tests

All tests require a signed admin session, same-origin POST, and explicit confirmation. The CLI uses the same fixed catalog and environment configuration. It accepts no arbitrary SQL, commands, credentials, or targets. Direct SQL attack tests use `SQL_ATTACK_COOLDOWN_SECONDS`, with a 60-second fallback when missing or invalid. The deployment config sets `sqlScenario.sqlAttackCooldownSeconds` to `"15"`; an environment-specific `sqlAttackCooldownSeconds` or the deployment shell's `SQL_ATTACK_COOLDOWN_SECONDS` overrides it. Direct Bicep callers can pass `sqlAttackCooldownSeconds` (default 60). Values must be whole seconds from 1 to 3600. The interval runs from one test's start to the next, and overlapping runs remain blocked even after the interval expires. Audit-only samples retain their separate 60-second cooldown. Limits are process-local; do not use concurrent CLI instances or multiple app instances to bypass them.

| Test ID             | Activity and limits                                                                                                                                                     |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `brute-force`       | Twelve failed logins for a random nonexistent identity; no real-account guessing                                                                                        |
| `suspicious-app`    | Client name `sqlmap`, session/database discovery and at most five visible table names; no business-row reads or external attack tool                                    |
| `sql-injection`     | Fixed input compared under unsafe concatenation (two matches) and parameter binding (zero) over synthetic inline rows; unexpected counts fail                           |
| `principal-anomaly` | Temporary user without login, sample SELECT grant, impersonation, and rollback; no committed principal                                                                  |
| `external-source`   | SQL shell prints an `example.invalid` URL; no network request or download                                                                                               |
| `obfuscated-shell`  | Fixed SQL string concatenation constructs the shell procedure call; parameterized encoded PowerShell prints only a run marker, with no persistence or downloaded script |

The principal and shell tests use admin credentials. Shell tests require `xp_cmdshell` already enabled and return `state: blocked` otherwise; the runner never enables it. Every connection is closed after execution. The external-source test is a limited probe, not a reproduction of a download. None guarantees a Defender alert, particularly baseline-dependent anomaly detections.

Each portal scenario has a five-stage walkthrough: attack purpose, fixed execution steps, explicit authorization, observed execution/SQL response, and independent Defender evidence. Steps are a preview, not simulated live telemetry. The browser shows pending execution until the server responds, then checks Defender automatically; **Check Defender alerts** repeats only the read, never the attack. A failed request without a result is an unknown execution outcome, not proof of prevention.

The authenticated evidence endpoint reads [Defender for Cloud alerts](https://learn.microsoft.com/rest/api/defenderforcloud/alerts/list-by-resource-group?view=rest-defenderforcloud-2022-01-01) through the app's existing managed identity and Security Reader role. It requires a server-recorded run, scopes alerts to the configured VM (or its SQL VM resource), and compares activity times with a two-minute tolerance around the run. Run-marker/test-identity matches are distinguished from possible VM/time/alert-family matches; Sentinel incidents are not Defender detections. Missing alerts, missing permissions, partial pagination (five-page limit), and delayed detection are explicit. An alert's `Resolved` or `Dismissed` status is not a blocking verdict; the portal does not infer Defender prevention from SQL errors or an alert alone. Inspect the linked Defender evidence for prevention attribution.

Run records are process-local: at most 50 records for up to 24 hours, cleared on app restart. Each scenario displays its latest run for the current page lifetime; a reload clears that browser view. Results include start/end times, marker, test identity when applicable, and separate SQL/Defender conclusions. No passwords, query result rows, or raw connection errors are stored in these records. Evidence lookup does not execute attack payloads or modify protection settings or Azure permissions.

The opt-in `bounded SQL probes execute` test in `scripts/test-admin-portal.mjs` validates the synthetic injection comparison and metadata-discovery batch on a disposable local SQL Server. Set `DOJO_AUDIT_TEST_PORT` to its loopback port and `MSSQL_SA_PASSWORD` to its test password, then run `node --test --test-name-pattern="bounded SQL probes execute" scripts/test-admin-portal.mjs`. It does not validate Defender alert generation; never point integration tests at the live lab.

IaC already supplies the system-assigned identity, subscription-scoped Security Reader (also needed for subscription pricing), `SQL_VM_RESOURCE_ID`, one plan instance, and a single Node server process. No extra alert role, storage resource, or diagnostic pipeline is required for these walkthroughs. Keep the single-instance assumption unless run records and execution locking are moved to shared storage. Both Node runtime declarations target major version 24. The full scenario deployment packages source and enables Oryx; a manually prebuilt zip uses different live build overrides and must not be substituted for that source package without aligning the build settings. An IaC deployment alone does not publish the new application code.

```bash
node scripts/run-sql-attack-test.mjs --audit
node scripts/run-sql-attack-test.mjs --run suspicious-app --confirm isolated-lab
```

`--audit` and `--list` make no connection. Exit codes: 0 for audit/executed, 1 for failure, 2 for blocked/usage errors. Results include `runId`, `startedAt`, `state`, and `alertConfirmed: false`. Correlate `dojo-attack-test:<scenario>:<run-id>` with the VM, time window, and actual alert evidence; failed-logon identities use `dojo_invalid_<run-id-without-hyphens>`.

Audit-only samples are separate: a sample read, a rolled-back data change, or a permission-boundary query generates SQL Audit evidence, not a guaranteed Defender alert. The six themed audit samples use `dojo-simulation-sample` markers for Sentinel training incidents. SQL Audit can describe rolled-back statements; it is not committed row history.

Login mutations protect system, Windows, privileged, and application identities. The built-in administrator is recognized by SID `0x01`, including after rename. Only its credential changes synchronize to Key Vault; other rotated passwords are shown once. Optional blank-password changes require an unprivileged `dojo_demo_` identity with no application database user mapping; rotate to a strong password afterward. Disabling a login does not terminate existing sessions.

Defender protection changes remain explicit Azure operations and may affect other workloads or billing. Keep SQL Audit enabled, record the baseline, and restore protection after any authorized comparison. Consult the [SQL alert reference](https://learn.microsoft.com/azure/defender-for-cloud/alerts-sql-database-and-azure-synapse-analytics) and [SQL protection controls](https://learn.microsoft.com/azure/defender-for-cloud/disable-sql-on-machines).

## Quick Start

Prerequisites: Git, Node.js 24 (use the version in `.node-version` and npm version in `package.json`), Docker/Docker Compose, and Bash. Azure deployment additionally requires Azure CLI; GitHub OIDC bootstrap requires GitHub CLI.

```bash
git clone https://github.com/ninjapaw/ninjapaws-cloud-security-dojo.git
cd ninjapaws-cloud-security-dojo
npm ci
npm test
npm start
```

The direct application listens on `http://localhost:3000`.

Common commands are exposed through `package.json` so the same entry points work from PowerShell, Git Bash, WSL, Linux, and CI hosts that have Bash available:

```bash
npm run dojo
npm run test:repo
npm run deploy:plan
npm run deploy:doctor
npm run deploy:dev
```

### Repository layout

| Path                                        | Contents                                                       |
| ------------------------------------------- | -------------------------------------------------------------- |
| `src/`                                      | Scenario 1 dashboard and runtime evidence API                  |
| `apps/pawton-manufacturing/`                | Scenario 2 portal and bounded SQL lab actions                  |
| `config/deploy.config.json`                 | Scenario and environment configuration                         |
| `scripts/`                                  | Local lifecycle commands, SQL bootstrap, and validation        |
| `infra/`                                    | Bicep templates, generated ARM templates, and Sentinel content |
| `Dockerfile`, `entrypoint.sh`, `nginx.conf` | Scenario 1 container build and runtime                         |

### Endpoint surface

| Route         | Purpose                                                                   | Exposure                                                         |
| ------------- | ------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `/`           | Human-readable training dashboard                                         | Public application route                                         |
| `/health`     | Lightweight JSON health probe                                             | Public application route; used by App Service and rollout checks |
| `/api/status` | JSON CVE metadata, package/config evidence, image host, and runtime state | Public evidence route for the demo                               |

`/api/status` reports two different classes of truth, and the payload keeps them separate on purpose. `runtime_verification` is proven inside the container by reading the actual NGINX binary, Debian package, and rendered configuration. `defender_monitoring` reports the Defender coverage the deployment **requested**, because the container holds no Azure credentials and cannot query subscription plan state. Each monitoring flag is a plain `true`/`false`, and the block names Defender for Cloud as the authoritative source:

```json
{
  "defender_monitoring": {
    "source": "deployment-configuration",
    "plans": {
      "defender_for_app_service": "Standard",
      "defender_for_containers": "Standard",
      "defender_cspm": "Standard",
      "defender_for_resource_manager": "Standard"
    },
    "monitoring": {
      "app_service_threat_protection": true,
      "resource_manager_threat_detection": true,
      "container_registry_vulnerability_assessment": true,
      "cspm_serverless_protection": true,
      "cspm_serverless_containers": true,
      "devops_connector_requested": true,
      "github_advanced_security_expected": true
    }
  }
}
```

The deployment report's verification matrix is where those requests are checked against Azure, so a flag reading `true` here means "configured", while the matrix says whether Azure agrees.

`map` is an internal NGINX configuration directive rendered by `entrypoint.sh` into `/etc/nginx/scenario.conf`. In the affected image it combines regex matching and captures; the detector reports this as `runtime_verification.map_regex_enabled: true`. Inspect that evidence through `/api/status`.

Use the application URL printed by your deployment report. The repository does not provide a supported public hosted service.

Run the containerized stack:

```bash
docker compose up --build -d
curl http://localhost:8080/health
docker compose logs -f dojo
docker compose down
```

## Demo Walkthrough

This walkthrough demonstrates a controlled cloud-security story: deploy an intentionally vulnerable image, prove what is running, review Defender coverage, redeploy a patched state, then compare evidence before cleanup.

Use an isolated Azure subscription and the `dev` environment. The default NGINX `1.30.3` image is intentionally in the affected range for the real F5 advisory; do not expose it to production users or sensitive data. Defender findings are asynchronous, so a missing finding is not proof that an image is clean until assessment processing has completed.

Prerequisites for the Azure walkthrough:

- Azure CLI installed and authenticated with permission to read the subscription and manage the target resource group
- A Git checkout on the `dev` branch
- Defender plan activation permission (`Microsoft.Security/pricings/*`) at subscription scope when `defender.managePlans` is enabled. The OIDC setup script grants the built-in `Security Admin` role for this purpose.
- Agreement to possible Defender for Cloud charges, because plan tiers are subscription-scoped

Baseline deployment:

```bash
bash scripts/deploy.sh deploy --environment dev --defaults --yes
```

Open `output/dev/deployment-dev.html` and review the task list, verification matrix, environment access links, and audit trail. Use the report's application URL to inspect `/`, `/api/status`, and `/health`.

In `/api/status`, treat `runtime_verification` and `defender_monitoring` differently. Runtime evidence is proven inside the container; Defender monitoring reports what the deployment requested, while the deployment report compares those requests against Azure. The vulnerable baseline should show `vulnerability.detected: true`, `vulnerability.status: vulnerable`, `runtime_verification.scenario_config_state: affected`, and `runtime_verification.map_regex_enabled: true`.

For Defender coverage, use the final report and Defender for Cloud Recommendations together. The report should record expected `Standard` coverage for App Service, Containers, CSPM, and Resource Manager, while Kubernetes runtime and unrelated resource plans are marked not applicable. A target CVE result of **Not sure** means Defender assessment evidence was not conclusive yet; do not present it as clean.

Patched-state demonstration:

```bash
NGINX_VERSION=1.30.4 VULNERABILITY_STATUS=patched \
  bash scripts/deploy.sh deploy --environment dev --defaults --yes
```

Then verify that `/api/status` reports `vulnerability.detected: false`, `vulnerability.status: not_detected`, `runtime_verification.scenario_config_state: remediated`, and `runtime_verification.map_regex_enabled: false`. The new report should show a changed build fingerprint or a clearly recorded image reuse decision. Defender Recommendations still need independent review after the asynchronous rescan.

Return to the vulnerable lab state when the demo is over:

```bash
NGINX_VERSION=1.30.3 VULNERABILITY_STATUS=vulnerable \
  bash scripts/deploy.sh deploy --environment dev --defaults --yes
```

Evidence to retain for an audit-friendly demo:

- `output/dev/deployment-dev.html`
- `output/dev/deployment-dev.json`
- `output/dev/deployment-dev.log`
- `output/dev/deployment-dev.console.html`
- The Defender Recommendations view or export showing assessment state and timestamp
- The run ID and commit from the report's audit trail
- The audit-trail item **Registry image security findings: On — audited**, backed by the live `ContainerRegistriesVulnerabilityAssessments` state

Cleanup:

```bash
bash scripts/deploy.sh uninstall --environment dev --yes
```

The lifecycle does not automatically deactivate subscription-wide Defender plans. Review and manage those plans explicitly in Defender for Cloud if the subscription is no longer used for this demo.

## Configuration

All Docker build arguments are non-secret configuration. Defaults are safe fallbacks; GitHub Environment variables are the source of truth for `dev` and `prod` deployments.

Branch isolation is explicit: `dev` deploys to `NP-ninjapaws-dojo-Dev-CentralUS`, ACR `ninjapawsdojodev`, and App Service `ninjapaws-dojo-app-dev`; `main` deploys to `NP-ninjapaws-dojo-Prod-CentralUS`, ACR `ninjapawsdojoprod`, and App Service `ninjapaws-dojo-app-prod`.

| Variable               |                      Default | Purpose                                                                                                     |
| ---------------------- | ---------------------------: | ----------------------------------------------------------------------------------------------------------- |
| `BASE_OS_IMAGE`        |                     `ubuntu` | Base OS image repository                                                                                    |
| `BASE_OS_VERSION`      |                      `24.04` | Ubuntu image version                                                                                        |
| `NGINX_VERSION`        |                     `1.30.3` | Pinned NGINX package                                                                                        |
| `NODE_MAJOR_VERSION`   |                         `24` | NodeSource major version                                                                                    |
| `VULNERABILITY_STATUS` |                 `vulnerable` | Scenario configuration intent; the app derives the authoritative vulnerability result from runtime evidence |
| `PORT`                 |                       `3000` | Internal Node.js port behind NGINX                                                                          |
| `WEBSITES_PORT`        |                         `80` | Port exposed by the container to Azure App Service                                                          |
| `NPM_REGISTRY_URL`     | `https://registry.npmjs.org` | npm registry or approved enterprise mirror used during the image build                                      |
| `NPM_USE_MIRROR`       |                       `true` | Use `NPM_REGISTRY_URL` when true; use npm's direct default when false                                       |
| `NPM_NETWORK_MODE`     |                     `online` | `online` downloads dependencies; `offline` disables npm network access and requires a populated npm cache   |
| `DEFENDER_ENABLED`     |                       `true` | Training dashboard flag; this is separate from Defender for Cloud subscription plans                        |

Defender for Cloud settings live under the `defender` object in `config/deploy.config.json`. The checked-in defaults are intentionally suited to this vulnerable App Service container scenario:

| Setting                       | Default          | Purpose                                                                                                 |
| ----------------------------- | ---------------- | ------------------------------------------------------------------------------------------------------- |
| `defender.scanAfterVerify`    | `true`           | Adds a post-verification Defender scan task to `deploy`, `rollout`, `repair`, and `verify`              |
| `defender.managePlans`        | `true`           | Allows the lifecycle to activate the configured Microsoft Security pricing tiers                        |
| `defender.targetCve`          | `CVE-2026-42533` | Real CVE from the F5 NGINX advisory searched for in the latest Defender assessment payload              |
| `defender.plans.AppServices`  | `Standard`       | Defender for App Service attack detection for the App Service workload                                  |
| `defender.plans.Containers`   | `Standard`       | Defender for Containers vulnerability assessment for Azure Container Registry images                    |
| `defender.plans.CloudPosture` | `Standard`       | Defender CSPM: attack paths, cloud security explorer, and the serverless/registry extensions below      |
| `defender.plans.Arm`          | `Standard`       | Defender for Resource Manager: threat detection on the control-plane operations this lifecycle performs |
| `defender.manageExtensions`   | `true`           | Allows the lifecycle to apply the plan extension sets below                                             |

Defender for Resource Manager is enabled because this project is unusually control-plane heavy: it creates and deletes resource groups, assigns RBAC roles, changes subscription-scoped Defender pricing, creates security connectors, and drives ACR builds — all through ARM. The GitHub OIDC identity it uses holds `Contributor` and `Role Based Access Control Administrator`, which is exactly the kind of identity an attacker would target for privilege escalation. This plan detects suspicious ARM operations, exploitation toolkits such as MicroBurst and PowerZure, and anomalous use of that automation. It bills at a flat subscription rate rather than per resource.

`CloudPosture` defaults to `Standard` rather than `Free` because the capabilities this scenario demonstrates — attack path analysis, serverless posture, and registry access for container image posture — are Defender CSPM features. Foundational CSPM (`Free`) provides recommendations and secure score only.

Defender CSPM extensions are applied as one set, because the API replaces the whole collection on every write:

| CSPM extension                                | Default | Why                                                                                                                                      |
| --------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `AgentlessServerlessPosture`                  | `true`  | Serverless protection covers App Service and Functions, which is exactly the workload this project deploys                               |
| `ServerlessContainers`                        | `true`  | Serverless container posture for Container Apps, Container Instances, and ECS on Fargate; also supplies registry-aware container context |
| `ContainerRegistriesVulnerabilityAssessments` | `true`  | Registry access, required for full serverless container and image posture                                                                |
| `AgentlessDiscoveryForKubernetes`             | `false` | No AKS or Kubernetes workload is deployed                                                                                                |
| `AgentlessVmScanning`                         | `false` | Scenario 1 deploys no virtual machines                                                                                                   |
| `SensitiveDataDiscovery`                      | `false` | Scenario 1 stores no application data; discovery stays opt-in                                                                            |
| `EntraPermissionsManagement`                  | `false` | CIEM has tenant-wide scope beyond this scenario                                                                                          |
| `ApiPosture`                                  | `false` | Preview capability is outside the required App Service and ACR scenario                                                                  |

Defender for Containers extensions follow the same pattern:

| Containers extension                          | Default | Why                                                                           |
| --------------------------------------------- | ------- | ----------------------------------------------------------------------------- |
| `ContainerRegistriesVulnerabilityAssessments` | `true`  | On; generates and links findings artifacts for every new or updated ACR image |
| `AgentlessDiscoveryForKubernetes`             | `false` | Not applicable to App Service                                                 |
| `AgentlessVmScanning`                         | `false` | Scenario 1 deploys no virtual machines                                        |
| `ContainerSensor`                             | `false` | The runtime threat sensor is an AKS component                                 |

DevOps and code security settings:

| Setting                                    | Default            | Purpose                                                                      |
| ------------------------------------------ | ------------------ | ---------------------------------------------------------------------------- |
| `defender.devops.connectorEnabled`         | `true`             | Creates the Defender for Cloud GitHub connector if the subscription has none |
| `defender.devops.connectorName`            | `ninjapaws-github` | Name of the `Microsoft.Security/securityConnectors` resource                 |
| `defender.devops.githubOwner`              | `ninjapaw`         | GitHub organization reported in the connector guidance                       |
| `defender.devops.advancedSecurityExpected` | `true`             | Reports GitHub Advanced Security state in the verification matrix            |

The lifecycle creates the GitHub connector resource, but **it cannot finish onboarding non-interactively**. Authorizing the connector and installing the DevOps security GitHub application is an interactive consent flow, so the report records the connector as **Not sure** with the remaining manual step rather than claiming coverage it has not proven. Complete it under **Defender for Cloud > Environment settings > Add environment > GitHub**, following [Connect your GitHub environment](https://learn.microsoft.com/azure/defender-for-cloud/quickstart-onboard-github). Once authorized, DevOps resources can take up to 8 hours to appear.

GitHub Advanced Security is a GitHub product, not an Azure plan, so the lifecycle reports it rather than enabling it. Code scanning already runs in this repository through the checked-in CodeQL workflow, which is free for public repositories. When a GitHub connector is authorized, Defender for Cloud maps GHAS findings to the running workload and prioritizes them with runtime risk factors such as internet exposure. Private repositories require a GitHub Advanced Security licence.

These settings are configurable per environment and can also be overridden with `DEFENDER_SCAN_ENABLED`, `DEFENDER_MANAGE_PLANS`, `DEFENDER_MANAGE_EXTENSIONS`, `DEFENDER_TARGET_CVE`, `DEFENDER_APPSERVICES_TIER`, `DEFENDER_CONTAINERS_TIER`, `DEFENDER_CSPM_TIER`, `DEFENDER_CSPM_SERVERLESS_PROTECTION`, `DEFENDER_CSPM_SERVERLESS_CONTAINERS`, `DEFENDER_CSPM_REGISTRY_ASSESSMENT`, `DEFENDER_CSPM_KUBERNETES_DISCOVERY`, `DEFENDER_CSPM_VM_SCANNING`, `DEFENDER_CSPM_SENSITIVE_DATA`, `DEFENDER_CSPM_PERMISSIONS_MANAGEMENT`, `DEFENDER_CSPM_API_POSTURE`, `DEFENDER_CONTAINERS_REGISTRY_ASSESSMENT`, `DEFENDER_CONTAINERS_KUBERNETES_DISCOVERY`, `DEFENDER_CONTAINERS_VM_SCANNING`, `DEFENDER_CONTAINERS_SENSOR`, `DEFENDER_DEVOPS_CONNECTOR_ENABLED`, `DEFENDER_DEVOPS_CONNECTOR_NAME`, `DEFENDER_DEVOPS_GITHUB_OWNER`, and the GitHub Environment variable `ADVANCED_SECURITY_EXPECTED`. Set a plan tier to `disabled` to mark that workload as **Not applicable** without changing the subscription plan. Plan activation can incur Azure charges; review subscription pricing and permissions before enabling `defender.managePlans` in a shared or production subscription.

The lifecycle does **not** automatically deactivate an already-enabled Defender plan when a workload is set to `disabled`; pricing plans apply at subscription scope, so silently turning off protection from an application deployment would be unsafe. The report instead records unrequested plans as **Not applicable** and leaves subscription-wide deactivation to an explicit Defender for Cloud administrator action.

`entrypoint.sh` generates NGINX from `nginx.conf` at startup, replacing `__APP_PORT__` with `PORT`. This is a deliberate dual-port design: **WEBSITES_PORT=80** tells Azure App Service which container port accepts traffic, while **PORT=3000** is the Node.js upstream behind NGINX. Changing `PORT` changes the NGINX upstream automatically; changing `WEBSITES_PORT` requires changing the container listener and App Service configuration together. Startup also records the actual NGINX binary and Debian package versions, which `/api/status` exposes under `runtime_verification` and the deployment report verifies.

Never put credentials in these variables. Runtime secrets belong in Azure Key Vault with managed identity. GitHub Environment secrets are reserved for values GitHub itself must keep confidential when OIDC or Key Vault cannot provide them.

### Secrets by scenario

Scenario 1 provisions no Key Vault: App Service pulls from ACR using managed identity, GitHub Actions uses OIDC, and the container has no database or API credentials. Its settings contain only non-secret configuration.

Scenario 2 does provision Key Vault for SQL and administrator credentials. Its privileged portal and direct password app settings are deliberate lab anti-patterns, described in [Scenario 2](#defender-for-cloud---scenario-2). Do not treat either scenario as a production secret-management template.

### Defender endpoint blocks during npm builds

On Windows hosts managed by Microsoft Defender Exploit Guard, the Docker build may be blocked before npm can download dependencies. The relevant host event is Windows Defender Operational Event `1126`, typically showing:

```text
Destination: https://registry.npmjs.org
Process Name: com.docker.backend.exe
```

That is a network-policy block on Docker Desktop, not a malicious npm path and not a reason to skip dependency installation. The preferred resolution is for the endpoint administrator to allow the approved registry, or to point `NPM_REGISTRY_URL` at the organization’s approved npm mirror/cache:

```powershell
$env:NPM_REGISTRY_URL = 'https://npm-mirror.contoso.example/repository/npm-group/'
docker build --build-arg NPM_REGISTRY_URL=$env:NPM_REGISTRY_URL -t ninja-paws-dojo .
```

To skip mirror configuration for a diagnostic comparison:

```powershell
$env:NPM_USE_MIRROR = 'false'
docker build --build-arg NPM_USE_MIRROR=$env:NPM_USE_MIRROR -t ninja-paws-dojo .
```

When `NPM_USE_MIRROR=false`, npm uses its direct default registry. This does not bypass Defender Exploit Guard; a host policy that blocks `registry.npmjs.org` will still block the build. The same variables can be stored as non-secret GitHub Environment variables. Do not put credentials in the URL. There is intentionally no `SKIP_NPM_INSTALL` option because it would create an incomplete image and bypass dependency integrity checks.

To disable npm network access entirely:

```powershell
$env:NPM_NETWORK_MODE = 'offline'
docker build --build-arg NPM_NETWORK_MODE=$env:NPM_NETWORK_MODE -t ninja-paws-dojo .
```

Offline mode still runs `npm ci --offline --ignore-scripts`; it does not skip dependency installation. It succeeds only when the required package tarballs are already in the npm cache or supplied by a prebuilt dependency image/build layer. On a clean Docker builder, offline mode will fail with a missing-cache error, which is intentional and safer than silently omitting dependencies.

### Subscription, tenant, and region setup

The lifecycle uses the Azure CLI's persisted current subscription from `az account show`, so a subscription selected with `az account set` or a previous `--subscription` selection is reused on later runs. Pass `--subscription <id>` when you want to switch it explicitly. If no region was supplied, it presents a numbered region list with **Central US (`centralus`)** as the default; pressing Enter accepts that default. `--defaults` uses the current Azure subscription and Central US without prompting. GitHub Actions is non-interactive and uses the GitHub Environment values.

The OIDC bootstrap command stores `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, and `AZURE_LOCATION` as GitHub **Environment variables**. Subscription and tenant IDs are identifiers, not credentials, so GitHub variables are the correct storage class; putting them in Key Vault would add complexity without protecting a secret. The bootstrap creates no client secret and deploys through short-lived GitHub OIDC tokens. Any actual client secret, API key, connection string, or runtime password belongs in an Azure Key Vault reference or GitHub Environment secret, never in this repository.

Deployment state and audit fields mask subscription and tenant IDs before writing them to JSON, HTML, or report text. Direct Azure portal links may still contain the full subscription ID because Azure requires it for a resource deep link. The full ID and tenant remain in process memory for Azure CLI operations and are never intentionally written as credential material.

Bootstrap or refresh the GitHub Environment configuration with:

```bash
bash scripts/setup-azure-github-oidc.sh --environment dev
```

Use `--defaults` for Central US and the current Azure subscription, or choose a numbered region during the interactive prompt. Pass `--subscription <id>` when you need to change subscriptions. Review the generated GitHub Environment variables before enabling `--provision`; Defender plan tiers can incur subscription charges.

The same command also creates Scenario 2's resource group (`NP-ninjapaws-dojo-sql-<env>-CentralUS` by default, override with `--sql-resource-group`) and grants the same OIDC identity Contributor and Role Based Access Control Administrator there — so one GitHub Environment/service principal can run either `deploy.yml` (Scenario 1) or `deploy-sql-scenario.yml` (Scenario 2), including from pawprint's hosted dispatch.

## Azure Deployment

Use `scripts/manage.sh` as the management entry point. With no arguments, it runs a read-only wizard that detects `dev` or `main` from the current Git branch, validates the Azure connection, confirms subscription read access, inspects the configured environment, and offers only lifecycle actions supported by the detected state. `scripts/deploy.sh` remains available for direct automation and supports `plan`, `doctor`, `provision`, `build`, `deploy`, `verify`, `repair`, and guarded `uninstall` stages.

```bash
bash scripts/manage.sh
```

The wizard presents unavailable actions in the terminal instead of attempting them. For example, uninstall is unavailable until a matching resource group with the required ownership tags exists; verify and rollout require both the App Service and registry. Selecting an action hands off to the established lifecycle command, including its existing confirmations and branch guards.

Mutating stages are branch-locked: a `dev` checkout can only target the `dev` Environment, and a `main` checkout can only target `prod`. `plan`, `doctor`, and `verify` remain read-only diagnostic stages and may be pointed at either environment explicitly.

```bash
bash scripts/test.sh --skip-azure
bash scripts/deploy.sh plan
bash scripts/deploy.sh doctor
bash scripts/deploy.sh deploy
```

Run `scripts/test.sh` before deployment from a host shell. It checks the local Bash, Node.js, Azure CLI, Bicep, and repository prerequisites and reports host package requirements such as ICU before compiling infrastructure. `scripts/deploy.sh doctor` performs the authenticated Azure preflight and Bicep/what-if checks; neither command changes Azure resources.

Use `--defaults` to accept built-in values and `--yes` for non-interactive confirmation. The wizard shows Bicep progress, resource operations, and writes fresh per-run artifacts under `output/<environment>/`, relative to the directory where the script was launched.

`uninstall` uses a focused teardown wizard rather than deployment prompts: it shows the branch-locked environment, offers the configured resource group as the default, and defaults to waiting for Azure to confirm deletion. It then verifies the live Ninja Paws ownership tags before asking for the destructive confirmation. Use `--no-wait` only when an automation caller intentionally needs an asynchronous deletion request.

Each lifecycle run also writes an auto-refreshing HTML status dashboard to `output/<environment>/deployment-<environment>.html`. Open that local file in a browser while the command runs to see the latest stage, percentage, environment coordinates, image, and links to detailed logs/state. No web server is required; the terminal remains the authoritative live stream. Use `--no-status-html` when a file report is not wanted.

The report shows stage outcomes, durations, failure details, verification evidence, and next steps. Use **Generate PDF** to open the browser's print dialog and save a snapshot. Set `DEPLOY_BROWSER` or `BROWSER` to choose an opener, or use `--no-open-status` in headless terminals and CI.

The task list is built dynamically from the command you ran, so it always reflects the real work:

| Command                                  | Tasks after preflight and planning                                                    |
| ---------------------------------------- | ------------------------------------------------------------------------------------- |
| `plan`                                   | dry run only; preflight is marked _Not applicable_                                    |
| `doctor`                                 | compile Bicep, what-if against the resource group                                     |
| `provision`                              | create and tag the resource group, deploy the Bicep infrastructure                    |
| `build`                                  | fingerprint the build context, build or reuse the image                               |
| `rollout`                                | configure App Service, restart and wait for health, verify                            |
| `verify`                                 | verify Azure resources, then run the Defender scan and workload-coverage task         |
| `deploy` / `setup` / `update` / `repair` | all stages end to end, followed by the Defender scan and workload-coverage task       |
| `uninstall`                              | locate the resource group, confirm ownership tags, request deletion, confirm teardown |

### Defender for Cloud scan and workload coverage

For deployment-shaped commands, the report runs a Defender task **after** App Service and endpoint verification. The task performs these actions and records each result in the verification matrix:

1. Activates or verifies the configured Defender for App Service, Defender for Containers, and Defender CSPM pricing tiers.
2. Reads the latest Defender for Cloud assessment inventory for the target resource group.
3. Searches the assessment payload for the configured target CVE.
4. Verifies that App Service attack detection and ACR image vulnerability assessment are covered.
5. Records Kubernetes runtime coverage and unrelated workload plans as **Not applicable** for Scenario 1. SQL/VM coverage belongs to Scenario 2; Resource Manager protection is configured separately at subscription scope.

The scan task is deliberately honest about timing. Defender vulnerability assessment is asynchronous and its engines continuously rescan or rescan on their service schedule; the Azure CLI does not provide a supported synchronous "scan this image now" operation for this deployment shape. The task therefore forces a fresh post-deployment assessment inventory read and reports **Not sure** when the target CVE is not yet present, rather than treating an empty or still-initializing result as proof that the image is clean.

**What the plans monitor here:**

- **Defender for App Service:** requests and responses to the app, App Service internal logs, the hosting sandbox, and the underlying platform VM/management surface for attack detection and security recommendations.
- **Defender for Containers:** the Azure Container Registry image supply chain and known image vulnerabilities, including CVE findings. It does not turn this App Service deployment into an AKS workload and does not provide Kubernetes sensor coverage here.
- **Defender CSPM:** foundational posture and recommendation visibility for the subscription and deployed Azure resources.

The report's Environment access panel links directly to App Service Metrics/diagnostics and the Defender for Cloud Recommendations blade. When the scan returns **Not sure**, open the linked Recommendations blade and filter by the target image or CVE after Defender has finished processing the image.

Official references: [What is Microsoft Defender for Cloud?](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-cloud-introduction), [Defender for App Service](https://learn.microsoft.com/azure/defender-for-cloud/tutorial-enable-app-service-plan), [Defender for Containers](https://learn.microsoft.com/azure/defender-for-cloud/defender-for-containers-introduction), and [view vulnerabilities for running containers](https://learn.microsoft.com/azure/defender-for-cloud/view-and-remediate-vulnerabilities-containers).

The final report stops refreshing and retains **Pass**, **Failure**, **Not sure**, and **Not applicable** outcomes alongside evidence and links to the application and Azure resources.

### Content-addressed builds

Every build first computes a **fingerprint**: a SHA-256 over each file the Dockerfile copies (`Dockerfile`, `package.json`, `package-lock.json`, `src/app.js`, `nginx.conf`, `entrypoint.sh`) plus every build argument. That fingerprint is pushed as an extra tag (`fp-<hash>`) alongside the immutable Git-SHA tag.

Use the Git-SHA tag or image digest for deployments. `latest`, `vulnerable`, and `remediated` are convenience aliases for demos and must not be used as production rollout selectors. Separate ACRs provide the dev/prod image boundary; separate image names are unnecessary.

On the next run the script looks up `fp-<hash>` in ACR:

- **Hash already present** — nothing changed. The build and upload are skipped entirely; the Git-SHA, `latest`, and training-status tags are aliased to the existing manifest digest server-side with `az acr import`, which transfers no layers.
- **App Service already configured for that exact image and passing `/health`** — the rollout and restart are skipped too, so a no-op deploy causes no downtime.
- **Hash absent** — the content genuinely changed, so a full `az acr build` runs.

The report shows the resolved manifest digest, the fingerprint, and whether the image was _Unchanged (rebuild and upload skipped)_ or _Changed (rebuilt and pushed)_. Verification asserts that the deployed tag and the current source fingerprint resolve to the same digest, so drift between the working tree and the running container is caught. Use `--force-rebuild` to bypass both skips.

Every run starts with a clean environment output directory. The previous run is archived under `output/archive/<timestamp>-<environment>/` by default, preserving troubleshooting history without allowing stale files to affect the current run. Use `--no-archive` only when automatic deletion of the previous output is explicitly preferred.

The **Live Console** artifact at `output/<environment>/deployment-<environment>.console.html` preserves deployment messages. Answer interactive prompts in the terminal, not the report.

Initial GitHub OIDC setup is separate and runs once per Environment:

```bash
az login
gh auth login
bash scripts/setup-azure-github-oidc.sh --environment dev --provision
bash scripts/setup-azure-github-oidc.sh --environment prod --provision
```

The bootstrap creates the Entra federated credential, assigns deployment roles, and writes non-secret identifiers/configuration to GitHub Environment variables. It does not create a client secret.

## Promotion and Releases

1. Develop on feature branches and merge into `dev` after validation.
2. Run **Deploy to Azure** manually from `dev` when the `dev` GitHub Environment is ready.
3. Run **Promote dev to main** from `dev` to open a promotion PR.
4. Review and merge that PR through protected `main`.
5. Run **Deploy to Azure** manually from `main` to promote the stable baseline to the `prod` GitHub Environment.

For releases, run **Request release from dev** and choose `patch`, `minor`, `major`, or `custom`. It creates a release PR that updates `package.json` and `package-lock.json`. After merge, **Publish main release** validates metadata, rejects duplicate/backward versions, creates `vX.Y.Z`, publishes the GitHub Release, and pushes the versioned and `latest` ACR images.

Package metadata must match the repository name and description, remain MIT licensed, retain the repository URL, and keep the lockfile synchronized. `NODE_MAJOR_VERSION` controls release validation and Docker builds.

## Workflows

Reusable Bicep validation and Defender posture checks come from [Pawprint](https://github.com/ninjapaw/pawprint). Workflow files contain the pinned revisions; scenario code and deployment configuration remain owned by this repository.

- `validate-infrastructure.yml`: installs dependencies, runs repository/runtime and portal tests, builds the portal, and delegates Bicep compilation/drift checks to the shared Pawprint contract
- `validate-remediation.yml`: container remediation and endpoint validation
- `deploy.yml`: branch-aware staged Azure deployment (Scenario 1: NGINX CVE / App Service + ACR)
- `deploy-sql-scenario.yml`: plan/doctor/deploy/uninstall lifecycle for Scenario 2 (SQL Server on Azure VM); a separate workflow because it's a separate architecture and resource group from Scenario 1
- `promote-dev-to-main.yml`: opens the dev-to-main promotion PR
- `request-release.yml`: prepares a versioned release PR
- `publish-release.yml`: publishes tags, GitHub Releases, and ACR images
- `uninstall.yml`: protected, exact-name-confirmed Azure and Environment cleanup

Run the shared checks locally:

```bash
npm ci
npm ci --prefix apps/pawton-manufacturing
npm test
bash scripts/test.sh --skip-azure
npm test --prefix apps/pawton-manufacturing
npm run build --prefix apps/pawton-manufacturing
bash scripts/test.sh
```

`npm test` covers the container runtime; the portal has its own dependency graph and test command. `scripts/test.sh --skip-azure` also runs container tests, shared-helper checks, offline Sentinel contracts, and deployment-report smoke checks. It works from any current directory. The non-skipped Azure path compiles local Bicep but does not deploy resources. These checks do not replace disposable-VM SQL bootstrap validation or live Defender/Sentinel detection testing.

## Security

Do not commit secrets, customer data, production credentials, or private infrastructure details. Report security issues privately according to [SECURITY.md](SECURITY.md). See [CONTRIBUTING.md](CONTRIBUTING.md) for review and promotion requirements.

## License and Ownership Notice

The source is provided under the [MIT License](LICENSE). The MIT license does not grant rights to Microsoft trademarks, names, logos, or third-party materials. Microsoft trademarks and product names remain the property of Microsoft Corporation. This repository is an unapproved, unofficial community demonstration and should not imply Microsoft sponsorship or authorization.
