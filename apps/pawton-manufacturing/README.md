# Pawton Manufacturing

A fun, Ninja Paws-themed Astro/Node.js dashboard for Scenario 2. It reads live data from the
[Futon Manufacturing](https://github.com/microsoft/sql-server-samples/tree/master/samples/databases/futon-manufacturing)
sample database restored on the Scenario 2 SQL Server VM, over a private VNet connection — there
is no public database endpoint.

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

In Azure, these are set by `infra/sql-defender-scenario/main.bicep`; the password app setting is a
Key Vault reference, never a plaintext value. Without the four `ADMIN_*`/`SQL_ADMIN_*` variables
set, `/admin` still renders but every sign-in attempt fails and the sa status card reports "not
configured", instead of the app failing to build or start. Without `LOG_ANALYTICS_WORKSPACE_ID`,
the "Windows Event confirmation" section reports itself as unconfigured instead of failing.

## Routes

- `/` — at-a-glance counts (items, warehouses, customers, open production orders)
- `/inventory`, `/sales`, `/production` — live report views
- `/health` — JSON health probe used as the Web App's health check path
- `/api/status` — JSON evidence endpoint, consistent with Scenario 1's `/api/status`
- `/admin` — **high-privilege**: sign in, then enable/disable/rotate the SQL Server `sa` login.
  See "Admin portal" in the repository root `README.md` before enabling this in any environment
  you care about.
