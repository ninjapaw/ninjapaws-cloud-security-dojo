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
    about:
      "Repeated login attempts can indicate password guessing. This test exercises failed-authentication detection without targeting a real account.",
    boundary: {
      path: "Application server -> SQL listener -> SQL authentication. The twelve login attempts are database connections, not web login requests.",
      waf: "A WAF can rate-limit or block HTTP login requests that traverse it. It cannot inspect these separate SQL protocol connections or enforce SQL account lockout. Blocking the portal's HTTP trigger would prevent this test from starting, not demonstrate database protection.",
      prevention:
        "Restrict SQL network access, remove unnecessary public exposure, use strong credentials, and apply supported login/password policies. SQL authentication rejects the nonexistent identity in this test; that is not WAF or Defender prevention.",
      detection:
        "SQL Audit records failed authentication. Defender for SQL may detect a brute-force pattern; twelve failures do not guarantee an alert. An attacker already on an allowed network still needs database-layer controls.",
    },
    steps: [
      "Verify a randomly generated login does not exist.",
      "Attempt twelve SQL connections with that identity and random passwords.",
      "Count authentication rejections and close every connection.",
    ],
    expected:
      "Twelve SQL authentication rejections. Completing the test means the failures were observed, not that access was gained.",
  },
  {
    id: "suspicious-app",
    name: "Suspicious application",
    description:
      "Connect with the sqlmap client name and execute one read-only metadata query. No attack tool is installed.",
    evidence: "SQL.VM_HarmfulApplication",
    about:
      "Attack tools can identify themselves through SQL client metadata. A suspicious application name is a detection signal, not proof that exploitation occurred.",
    boundary: {
      path: "Application server -> authenticated SQL session -> client metadata and database query. This crosses from web-request inspection into database-session behavior.",
      waf: "A WAF may detect suspicious HTTP payloads or user agents, but this test sets sqlmap as the SQL client's application name. That metadata and the subsequent query travel over the backend SQL connection, outside the WAF's HTTP inspection.",
      prevention:
        "Restrict which hosts and identities can connect and give the application login only required permissions. A client application name is caller-supplied metadata, not a trustworthy authorization boundary; least privilege limits what an authenticated tool can do.",
      detection:
        "Defender for SQL may flag a harmful application signal, while SQL Audit can provide session/query evidence. This test only emulates the name: it neither runs sqlmap nor proves exploitation or automatic blocking.",
    },
    steps: [
      "Connect using the application login with the client name sqlmap.",
      "Read the application name and original SQL login.",
      "Close the connection without changing data.",
    ],
    expected:
      "The metadata query completes. This emulates a client-name signal; it does not install or run sqlmap.",
  },
  {
    id: "sql-injection",
    name: "SQL injection",
    description:
      "Execute a fixed tautology and UNION injection against an inline synthetic row. No application input or business data is exposed.",
    evidence: "SQL injection alert family",
    about:
      "SQL injection changes query meaning using input such as an always-true condition or UNION. This direct SQL test uses synthetic values, not a vulnerable application endpoint.",
    boundary: {
      path: "Application server -> SQL engine -> synthetic query evaluation. The test sends fixed SQL directly; it does not inject through an HTTP parameter.",
      waf: "A WAF can detect and, in prevention mode, block recognizable SQL injection in HTTP requests it inspects. Here the HTTP request contains only a scenario selection; the SQL is generated on the server afterward. The WAF cannot inspect that backend query. This is not proof that a WAF rule was bypassed.",
      prevention:
        "Parameterized queries and safe query construction prevent untrusted input from becoming executable SQL in real applications. Least-privileged database identities limit impact. WAF rules add defense in depth but do not repair unsafe application query construction.",
      detection:
        "Defender for SQL may detect suspicious query patterns at the database layer. SQL Audit and application logs provide separate evidence. The synthetic query does not establish a portal vulnerability, data loss, or a Defender block.",
    },
    steps: [
      "Connect with the application SQL login.",
      "Execute a fixed OR 1=1 and UNION query against an inline synthetic row.",
      "Discard the query output and close the connection.",
    ],
    expected:
      "A read-only query completes. It does not demonstrate a vulnerability in this portal or expose business records.",
  },
  {
    id: "principal-anomaly",
    name: "Principal anomaly",
    description:
      "Create a temporary database principal, grant a sample-table read, impersonate it, then roll back all changes.",
    evidence: "SQL.VM_PrincipalAnomaly",
    about:
      "Unexpected database identities or unusual access patterns can indicate account misuse. Anomaly detection depends on the machine's learned activity baseline.",
    boundary: {
      path: "Privileged SQL session -> database user creation -> permission grant -> impersonated read. Activity occurs inside the database's identity and authorization boundary.",
      waf: "A WAF cannot evaluate CREATE USER, GRANT, or EXECUTE AS in a backend SQL session. Those operations may follow a permitted web request, a compromised service credential, or direct administrator access without any malicious HTTP payload to inspect.",
      prevention:
        "Separate application and administrative identities; restrict user-management, grant, and impersonation privileges. Those SQL permissions, not the WAF, determine whether the operations are allowed. This lab intentionally uses its privileged connection and rolls the changes back.",
      detection:
        "SQL Audit can record identity and permission changes even when rolled back. Defender for SQL may detect unusual principal behavior, depending on its baseline. A completed administrative operation or an anomaly alert alone is not proof of prevention.",
    },
    steps: [
      "Start a transaction using the privileged lab connection.",
      "Create a temporary database user and grant a read on dbo.Items.",
      "Impersonate that user for one read, revert identity, and roll back the transaction.",
    ],
    expected:
      "The read completes and the temporary user and grant are rolled back. No persistent principal is intended.",
  },
  {
    id: "external-source",
    name: "Shell external source anomaly",
    description:
      "Print a reserved external URL through the SQL shell. No network request or download occurs. Requires xp_cmdshell already enabled.",
    evidence: "SQL.VM_ShellExternalSourceAnomaly (limited probe)",
    about:
      "Shell commands referencing external sources can accompany payload downloads. This limited probe only prints a reserved URL and does not reproduce a download.",
    boundary: {
      path: "Privileged SQL session -> xp_cmdshell -> operating-system command. A real download would cross a further boundary from the host to an external destination; this probe does not.",
      waf: "An inbound WAF does not govern SQL-launched processes or the VM's outbound connections. Printing a URL through the SQL shell is outside its HTTP request inspection. An egress firewall or proxy is a different control from a WAF.",
      prevention:
        "Keep xp_cmdshell disabled unless required, restrict shell execution privileges, constrain the execution identity, and apply host application controls. Egress filtering can restrict real downloads, but this echo-only probe cannot validate an outbound-network block.",
      detection:
        "Defender for SQL may observe suspicious shell usage; endpoint protection can provide process or file evidence for actual host activity. No download, connection, or file is created here, so neither download detection nor blocking is demonstrated.",
    },
    steps: [
      "Read the current xp_cmdshell setting without changing it.",
      "If enabled, use the SQL shell to echo an example.invalid URL containing the run marker.",
      "Verify the printed marker and successful shell exit status.",
    ],
    expected:
      "SQL blocks the test if xp_cmdshell is disabled; otherwise the URL is printed. No outbound request, file download, or persistence is requested.",
  },
  {
    id: "obfuscated-shell",
    name: "Shell obfuscation",
    description:
      "Run an encoded PowerShell command through the SQL shell that only prints the run marker. Requires xp_cmdshell already enabled.",
    evidence: "SQL.VM_PotentialSqlInjection",
    about:
      "Encoded shell commands can conceal intent. Here the encoded payload is fixed and only prints a unique marker, allowing observation without a destructive payload.",
    boundary: {
      path: "Privileged SQL session -> xp_cmdshell -> PowerShell execution. The test reaches the host's process and script controls, deeper than the web-request boundary.",
      waf: "A WAF may flag encoded content present in inspected HTTP input. In this test the fixed encoded command is generated server-side and executed through SQL, so it is not present in that HTTP input. The WAF does not inspect the resulting host process.",
      prevention:
        "Disable unnecessary SQL shell access and restrict SQL/OS privileges. Host application control and supported endpoint prevention policies may restrict script execution or malicious behavior, depending on configuration. Encoded PowerShell is not inherently malicious, and this harmless marker is not guaranteed to be blocked.",
      detection:
        "SQL auditing, PowerShell logging, and endpoint process telemetry provide different views. Defender for SQL or endpoint detections may flag suspicious behavior; verify the product and action in actual evidence. A PowerShell error or successful marker alone proves neither Defender blocking nor a protection failure.",
    },
    steps: [
      "Read the current xp_cmdshell setting without changing it.",
      "If enabled, execute a fixed encoded PowerShell Write-Output command through SQL.",
      "Verify the printed marker and successful shell exit status.",
    ],
    expected:
      "SQL blocks the test if xp_cmdshell is disabled; otherwise the marker is printed. An execution error alone does not identify which protection blocked it.",
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
  const runs = new Map();
  function getRun(runId) {
    for (const [key, value] of runs) {
      if (now() - Date.parse(value.startedAt) > 86400000) runs.delete(key);
    }
    return runs.get(runId) || null;
  }
  function remember(result) {
    getRun(result.runId);
    runs.set(result.runId, result);
    if (runs.size > 50) runs.delete(runs.keys().next().value);
    return result;
  }
  const configuredCooldown = Number(environment.SQL_ATTACK_COOLDOWN_SECONDS);
  const cooldownSeconds =
    Number.isInteger(configuredCooldown) &&
    configuredCooldown >= 1 &&
    configuredCooldown <= 3600
      ? configuredCooldown
      : 60;

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
        `Another SQL lab test is running or cooling down. Wait ${cooldownSeconds} seconds.`,
        429,
      );
    const config = connectionConfig(environment, privilegedScenarios.has(id));
    const runId = randomUUID();
    const marker = `dojo-attack-test:${id}:${runId}`;
    const startedAt = new Date(now()).toISOString();
    running = true;
    nextRunAt = now() + cooldownSeconds * 1000;
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
      return remember({
        runId,
        startedAt,
        completedAt: new Date(now()).toISOString(),
        marker,
        correlationIdentity:
          id === "brute-force"
            ? `dojo_invalid_${runId.replaceAll("-", "")}`
            : null,
        scenario: id,
        state: detail?.blocked ? "blocked" : "executed",
        sqlProtection: detail?.blocked
          ? "SQL Server blocked shell execution because xp_cmdshell is disabled."
          : id === "brute-force"
            ? "SQL authentication rejected all twelve attempts."
            : "SQL permitted the fixed test activity.",
        defenderBlocking:
          "Not confirmed. SQL results alone do not identify a Defender prevention action.",
        alertConfirmed: false,
        outcome: `${detail?.blocked ? "Attack test blocked." : "Attack test completed successfully."} ${detail?.detail || detail} Defender alert generation is not guaranteed; verify the configured VM's Defender alerts separately.`,
      });
    } catch (error) {
      const failure =
        error instanceof SimulationError
          ? error
          : new SimulationError(
              "SQL lab test did not complete. Check SQL connectivity, permissions, and audit evidence before retrying. No Defender alert is confirmed.",
              502,
            );
      failure.run = remember({
        runId,
        startedAt,
        completedAt: new Date(now()).toISOString(),
        marker,
        correlationIdentity:
          id === "brute-force"
            ? `dojo_invalid_${runId.replaceAll("-", "")}`
            : null,
        scenario: id,
        state: "failed",
        alertConfirmed: false,
        outcome: failure.message,
        sqlProtection:
          "Incomplete or failed. Some activity may have occurred; this is not proof of blocking.",
        defenderBlocking:
          "Not confirmed. Review independent Defender evidence.",
      });
      throw failure;
    } finally {
      running = false;
    }
  }

  return { availability, run, getRun };
}

export const sqlAttackRunner = createSqlAttackRunner();
