import { randomBytes, randomUUID } from "node:crypto";
import sql from "mssql";

export class SimulationError extends Error {
  constructor(message, status = 409) {
    super(message);
    this.status = status;
  }
}

export const attackScenarios = [
  {
    id: "brute-force",
    name: "Brute force authentication",
    description:
      "Twelve failed SQL logins using one random, nonexistent test identity. No real account passwords are guessed.",
    evidence: "SQL.VM_BruteForce",
  },
  {
    id: "suspicious-app",
    name: "Suspicious application",
    description:
      "Connect with the sqlmap client name and execute one read-only metadata query. No attack tool is installed.",
    evidence: "SQL.VM_HarmfulApplication",
  },
  {
    id: "sql-injection",
    name: "SQL injection",
    description:
      "Execute a fixed tautology and UNION injection against an inline synthetic row. No application input or business data is exposed.",
    evidence: "SQL injection alert family",
  },
  {
    id: "principal-anomaly",
    name: "Principal anomaly",
    description:
      "Create a temporary database principal, grant a sample-table read, impersonate it, then roll back all changes.",
    evidence: "SQL.VM_PrincipalAnomaly",
  },
  {
    id: "external-source",
    name: "Shell external source anomaly",
    description:
      "Print a reserved external URL through the SQL shell. No network request or download occurs. Requires xp_cmdshell already enabled.",
    evidence: "SQL.VM_ShellExternalSourceAnomaly (limited probe)",
  },
  {
    id: "obfuscated-shell",
    name: "Shell obfuscation",
    description:
      "Run an encoded PowerShell command through the SQL shell that only prints the run marker. Requires xp_cmdshell already enabled.",
    evidence: "SQL.VM_PotentialSqlInjection",
  },
];

const privilegedScenarios = new Set([
  "principal-anomaly",
  "external-source",
  "obfuscated-shell",
]);

function connectionConfig(environment, privileged = false) {
  const user = privileged
    ? environment.SQL_ADMIN_LOGIN
    : environment.SQL_APP_LOGIN || "futon_app";
  const password = privileged
    ? environment.SQL_ADMIN_LOGIN_PASSWORD
    : environment.SQL_APP_LOGIN_PASSWORD;
  if (!environment.SQL_SERVER_HOST || !user || !password)
    throw new SimulationError(
      "This test's SQL connection is not configured.",
      503,
    );
  return {
    server: environment.SQL_SERVER_HOST,
    database: environment.SQL_DATABASE || "FutonManufacturing",
    user,
    password,
    port: 1433,
    options: {
      encrypt: true,
      trustServerCertificate: true,
      appName: "DojoSqlAttackLab",
    },
    connectionTimeout: 1500,
    requestTimeout: 5000,
    pool: { max: 1, min: 0, idleTimeoutMillis: 1000 },
  };
}

export function createSqlAttackRunner({
  environment = process.env,
  makePool = (config) => new sql.ConnectionPool(config),
  now = Date.now,
} = {}) {
  let running = false;
  let nextRunAt = 0;

  function checkEnabled() {
    if (environment.ENABLE_SQL_DEMO_ACTIONS === "false")
      throw new SimulationError(
        "SQL lab tests are disabled by the server configuration.",
        503,
      );
  }

  async function availability() {
    try {
      checkEnabled();
      const ids = attackScenarios
        .filter(({ id }) => {
          try {
            connectionConfig(environment, privilegedScenarios.has(id));
            return true;
          } catch {
            return false;
          }
        })
        .map(({ id }) => id);
      return {
        ids,
        reason: ids.length ? null : "SQL lab connections are not configured.",
      };
    } catch (error) {
      return { ids: [], reason: error.message };
    }
  }

  async function withConnection(config, action) {
    const pool = makePool(config);
    try {
      await pool.connect();
      return await action(pool);
    } finally {
      await pool.close();
    }
  }

  async function run(id) {
    if (!attackScenarios.some((scenario) => scenario.id === id))
      throw new SimulationError("Unknown SQL lab test.", 400);
    checkEnabled();
    if (running || now() < nextRunAt)
      throw new SimulationError(
        "Another SQL lab test is running or cooling down. Wait 60 seconds.",
        429,
      );
    const config = connectionConfig(environment, privilegedScenarios.has(id));
    const runId = randomUUID();
    const marker = `dojo-attack-test:${id}:${runId}`;
    const startedAt = new Date(now()).toISOString();
    running = true;
    nextRunAt = now() + 60_000;
    try {
      let detail;
      if (id === "brute-force") {
        const login = `dojo_invalid_${runId.replaceAll("-", "")}`;
        await withConnection(config, async (pool) => {
          const result = await pool
            .request()
            .input("login", sql.NVarChar(128), login)
            .query("SELECT SUSER_ID(@login) AS principalId");
          if (result.recordset[0]?.principalId != null)
            throw new SimulationError(
              "Test identity already exists; no login attempts were made.",
            );
        });
        for (let attempt = 0; attempt < 12; attempt++) {
          try {
            await withConnection(
              {
                ...config,
                user: login,
                password: randomBytes(32).toString("hex"),
              },
              async () => {
                throw new SimulationError(
                  "Unexpected successful authentication; test aborted.",
                );
              },
            );
          } catch (error) {
            if (error.code !== "ELOGIN") throw error;
          }
        }
        detail = `Twelve authentication failures observed for ${login}. Correlate SQL login failures by this identity.`;
      } else {
        if (id === "suspicious-app") config.options.appName = "sqlmap";
        detail = await withConnection(config, async (pool) => {
          if (["external-source", "obfuscated-shell"].includes(id)) {
            const status = await pool
              .request()
              .query(
                "SELECT CAST(value_in_use AS int) AS enabled FROM sys.configurations WHERE name = 'xp_cmdshell'",
              );
            if (status.recordset[0]?.enabled !== 1)
              return {
                blocked: true,
                detail:
                  "SQL Server has xp_cmdshell disabled. No shell command ran and no server setting was changed.",
              };
            const command =
              id === "external-source"
                ? `cmd.exe /d /c echo https://example.invalid/${marker}`
                : `powershell.exe -NoProfile -NonInteractive -EncodedCommand ${Buffer.from(`Write-Output '${marker}'`, "utf16le").toString("base64")}`;
            const result = await pool
              .request()
              .input("command", sql.VarChar(8000), command)
              .query(
                `DECLARE @result int; EXEC @result = master.dbo.xp_cmdshell @command; SELECT @result AS exitCode; /* ${marker} */`,
              );
            const records = result.recordsets?.flat() || [];
            if (
              !records.some((row) => row.exitCode === 0) ||
              !records.some((row) =>
                Object.values(row).some(
                  (value) =>
                    typeof value === "string" && value.includes(marker),
                ),
              )
            )
              throw new SimulationError(
                "Shell probe did not return its expected marker and success status.",
                502,
              );
            return "SQL shell printed the test marker. No download, outbound connection, or persistence was requested.";
          }
          let statement;
          if (id === "suspicious-app")
            statement =
              "SELECT APP_NAME() AS ApplicationName, ORIGINAL_LOGIN() AS OriginalLogin";
          if (id === "sql-injection")
            statement =
              "SELECT TOP (1) ItemId FROM (VALUES (1, N'dojo')) AS sample(ItemId, ItemName) WHERE ItemName = N'' OR 1=1 UNION SELECT 2 -- fixed synthetic injection";
          if (id === "principal-anomaly") {
            const principal = `dojo_probe_${runId.replaceAll("-", "")}`;
            statement = `SET XACT_ABORT ON;
BEGIN TRANSACTION;
BEGIN TRY
  CREATE USER [${principal}] WITHOUT LOGIN;
  GRANT SELECT ON dbo.Items TO [${principal}];
  EXECUTE AS USER = '${principal}';
  SELECT TOP (1) ItemId FROM dbo.Items;
  REVERT;
  ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
  REVERT;
  IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
  THROW;
END CATCH`;
          }
          await pool.request().query(`/* ${marker} */\n${statement};`);
          return id === "principal-anomaly"
            ? "Temporary principal created and impersonated; the read completed and all principal and grant changes were rolled back."
            : "Fixed read-only SQL test completed. No database rows were modified or returned to the browser.";
        });
      }
      return {
        runId,
        startedAt,
        scenario: id,
        state: detail?.blocked ? "blocked" : "executed",
        alertConfirmed: false,
        outcome: `${detail?.detail || detail} Defender alert generation is not guaranteed; verify the configured VM's Defender alerts separately.`,
      };
    } catch (error) {
      if (error instanceof SimulationError) throw error;
      throw new SimulationError(
        "SQL lab test did not complete. Check SQL connectivity, permissions, and audit evidence before retrying. No Defender alert is confirmed.",
        502,
      );
    } finally {
      running = false;
    }
  }

  return { availability, run };
}

export const sqlAttackRunner = createSqlAttackRunner();
