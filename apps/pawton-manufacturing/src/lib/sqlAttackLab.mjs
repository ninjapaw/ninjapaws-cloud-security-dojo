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
    protection: {
      noAlert:
        "Twelve rejected logins with a nonexistent identity are a bounded probe, not a guaranteed brute-force detection threshold. This does not reproduce the documented valid-user or successful-sign-in variants. Do not target real accounts or increase password guessing to force an alert; use the supported Brute force authentication simulation to validate alert delivery.",
      steps: [
        "Restrict the SQL listener with private connectivity and scoped network rules; remove unnecessary public SQL exposure after reviewing dependent clients.",
        "Use strong credentials and supported SQL login password/lockout policies for real SQL logins. Keep application and administrative identities separate.",
        "Keep Defender for SQL enabled for detection and investigate authentication alerts. Alert-driven response automation acts after detection; it is not inline login prevention.",
      ],
      verification:
        "This test should already show twelve authentication rejections. That is SQL authentication enforcement. Verify network denial separately from an approved disallowed source; this portal runs from an allowed application host and cannot prove that network boundary.",
      simulation: "Brute force authentication",
    },
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
      "Connect with the sqlmap client name, inspect session/database metadata, and enumerate at most five visible user-table names. No business rows are read or attack tool installed.",
    evidence: "SQL.VM_HarmfulApplication",
    protection: {
      noAlert:
        "The test supplies sqlmap as client metadata and performs bounded session/database and table-name discovery. It does not run an attack tool, and these signals need not produce an alert. Review the actual client, login, target, and activity time in a HarmfulApplication alert before attributing it to this run; an older alert of the same type is not new run evidence.",
      steps: [
        "Allow SQL connections only from approved hosts and identities, using scoped network access and least-privileged database permissions.",
        "Remove unnecessary rights from application logins. Do not use the SQL application-name string as an authorization rule: the caller can change it.",
        "Use Defender for SQL alerts to investigate suspicious clients. Apply any identity revocation or network containment only after confirming scope and operational impact.",
      ],
      verification:
        "An approved client with valid credentials may still run this metadata query. Test denied connections and denied protected operations separately with a restricted test identity. A successful metadata query is not a failed prevention control.",
      simulation: "Authentication from suspicious application",
    },
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
      "Read session/database metadata and at most five visible table names, without querying their rows.",
      "Close the connection without changing data.",
    ],
    expected:
      "The metadata query completes. This emulates a client-name signal; it does not install or run sqlmap.",
  },
  {
    id: "sql-injection",
    name: "SQL injection",
    description:
      "Compare a fixed injection string passed through unsafe concatenation versus parameter binding against two synthetic rows. No browser-supplied SQL or business data is used.",
    evidence: "SQL injection alert family",
    protection: {
      noAlert:
        "The fixed input changes the meaning of an intentionally concatenated query over synthetic rows, while parameter binding prevents that change. This is an isolated demonstration, not exploitation of an HTTP endpoint, and it need not generate a detection. Microsoft documents PotentialSqlInjection for both injection and SQL shell obfuscation; the alert type alone cannot distinguish them. Use the supported SQL injection simulation to validate alert delivery.",
      steps: [
        "Use parameterized queries for data values and allowlisted identifiers at the application input boundary; avoid concatenating untrusted input into SQL.",
        "Restrict the application login to required data operations. Use WAF prevention rules for inspected HTTP requests as an additional layer, not as a substitute for parameterization.",
        "Keep Defender for SQL enabled to detect suspicious query activity. There is no Defender for SQL setting that turns this valid synthetic SELECT into a guaranteed blocked query.",
      ],
      verification:
        "Verify that a benign injection-shaped input is treated as literal data by an isolated application's parameterized query. This direct-SQL test may still complete after hardening because it bypasses the application input boundary by design; it cannot validate an HTTP injection block.",
      simulation: "SQL injection",
    },
    about:
      "SQL injection occurs when input becomes executable query syntax. The same fixed input is compared as concatenated SQL and as a bound value over two synthetic rows; only the deliberately unsafe query should match both rows.",
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
      "Run the same fixed OR 1=1 input against two synthetic rows using parameter binding and then unsafe concatenation.",
      "Require zero parameterized matches and two concatenated matches; close the connection without returning any rows to the browser.",
    ],
    expected:
      "Unsafe concatenation matches two synthetic rows; parameter binding matches zero. Unexpected counts fail the test. This does not expose business records or establish a vulnerability in the portal's order endpoints.",
  },
  {
    id: "principal-anomaly",
    name: "Principal anomaly",
    description:
      "Create a temporary database principal, grant a sample-table read, impersonate it, then roll back all changes.",
    evidence: "SQL.VM_PrincipalAnomaly",
    protection: {
      noAlert:
        "The documented PrincipalAnomaly is a login from a principal not seen in 60 days, with context-dependent suppression of expected changes. Creating a temporary database user and using EXECUTE AS within an existing session is not a new login and does not reproduce that history. Use the supported Principal anomaly simulation rather than creating persistent accounts or waiting for a baseline to force detection.",
      steps: [
        "Remove unnecessary user-management, permission-granting, and impersonation rights from application identities. Review inherited role membership as well as direct grants.",
        "Keep privileged administration separate. This scenario intentionally uses the lab admin SQL connection; restrictions on the application login do not restrict that connection.",
        "Audit principal and permission changes and use Defender for SQL for anomaly detection. Remediating excessive permissions is SQL hardening, not a Defender blocking mode.",
      ],
      verification:
        "In a disposable database, verify that a restricted test identity cannot create users, grant access, or impersonate principals. Do not remove the portal's administrative permissions on the shared lab merely to force this scenario to fail.",
      simulation: "Principal anomaly",
    },
    about:
      "A login from a principal not seen in 60 days can indicate account misuse. This related identity-management exercise uses a temporary database user within an existing session; it does not reproduce the documented login anomaly.",
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
    protection: {
      noAlert:
        "This probe only echoes an example.invalid URL. It performs no download or outbound connection, so external-source behavior is not fully reproduced and no alert is guaranteed. Use the supported Shell external source anomaly simulation to validate alert delivery; do not replace the reserved URL with a real download destination to force an alert.",
      steps: [
        "For an approved lab comparison, use Disable SQL shell access in this page's SQL shell section and verify the live state is Disabled. This is a server-wide SQL change; review other consumers first.",
        "Restrict privileges that can execute or re-enable xp_cmdshell. For lasting hardening, review the deployment's enableSqlShellAttackTests value because bootstrap can reapply its configured default.",
        "For real outbound activity, use scoped egress controls and host application control. Defender for Endpoint prevention is a separate product/control from Defender for SQL; verify its onboarding and applicable policies independently.",
      ],
      verification:
        "After disabling shell access, this runner should report blocked at its xp_cmdshell precheck. Confirm the disabled SQL state independently. This demonstrates the SQL configuration gate, not a Defender block or an egress block; the echo-only probe cannot test outbound filtering.",
      simulation: "Shell external source anomaly",
    },
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
      "Construct a fixed SQL shell call with SQL string concatenation, then run encoded PowerShell that only prints the run marker. Requires xp_cmdshell already enabled.",
    evidence: "SQL.VM_PotentialSqlInjection",
    protection: {
      noAlert:
        "The SQL batch constructs the fixed xp_cmdshell procedure name using string concatenation, closer to the documented SQL-layer obfuscation behavior. The encoded payload remains only PowerShell Write-Output of a marker. This is a detection-fidelity improvement, not a guaranteed alert trigger; a successful marker is not proof that Defender missed malicious execution.",
      steps: [
        "For an approved lab comparison, use Disable SQL shell access in this page's SQL shell section and verify the live state is Disabled. Review the server-wide impact before changing it.",
        "Restrict SQL privileges that can execute or re-enable xp_cmdshell, and keep the SQL execution identity least privileged. Review enableSqlShellAttackTests for future bootstrap runs so hardening is not silently undone.",
        "Where shell access is genuinely required, assess host application control and Defender for Endpoint prevention policies on an isolated target. These are separate from Defender for SQL, and a harmless encoded command is not guaranteed to be blocked by endpoint protection either.",
      ],
      verification:
        "With xp_cmdshell disabled, this runner should stop at its configuration precheck and report blocked before starting PowerShell. Independently verify the SQL setting; do not label the precheck as Defender prevention. If testing host controls, require an explicit endpoint action/event, not just a SQL error or a missing marker.",
      simulation: "Shell obfuscation",
    },
    about:
      "SQL string concatenation can conceal an operating-system procedure call. This test constructs that fixed call inside SQL and passes a fixed encoded PowerShell command that only prints a unique marker. No arbitrary SQL or shell input is accepted.",
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
      "If enabled, construct the fixed SQL shell procedure name inside SQL and execute the parameterized marker-only PowerShell command.",
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
                id === "obfuscated-shell"
                  ? `DECLARE @result int;
DECLARE @statement nvarchar(max) = N'EXEC @shellResult = master.dbo.' + N'xp_' + N'cmdshell @shellCommand;';
EXEC sys.sp_executesql @statement, N'@shellCommand varchar(8000), @shellResult int OUTPUT', @shellCommand = @command, @shellResult = @result OUTPUT;
SELECT @result AS exitCode; /* ${marker} */`
                  : `DECLARE @result int; EXEC @result = master.dbo.xp_cmdshell @command; SELECT @result AS exitCode; /* ${marker} */`,
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
              "SELECT APP_NAME() AS ApplicationName, ORIGINAL_LOGIN() AS OriginalLogin, DB_NAME() AS DatabaseName; SELECT TOP (5) SCHEMA_NAME(schema_id) AS SchemaName, name AS TableName FROM sys.tables WHERE is_ms_shipped = 0 ORDER BY schema_id, name";
          if (id === "sql-injection") {
            const result = await pool.request().query(`/* ${marker} */
DECLARE @input nvarchar(100) = N''' OR 1=1 --';
DECLARE @safeMatches int, @unsafeMatches int;
DECLARE @safeStatement nvarchar(max) = N'SELECT @matched = COUNT(*) FROM (VALUES (1, N''dojo''), (2, N''training'')) AS sample(ItemId, ItemName) WHERE ItemName = @value;';
EXEC sys.sp_executesql @safeStatement, N'@value nvarchar(100), @matched int OUTPUT', @value = @input, @matched = @safeMatches OUTPUT;
DECLARE @unsafeStatement nvarchar(max) = N'SELECT @matched = COUNT(*) FROM (VALUES (1, N''dojo''), (2, N''training'')) AS sample(ItemId, ItemName) WHERE ItemName = N''' + @input + N'''';
EXEC sys.sp_executesql @unsafeStatement, N'@matched int OUTPUT', @matched = @unsafeMatches OUTPUT;
SELECT @safeMatches AS SafeMatches, @unsafeMatches AS UnsafeMatches;`);
            if (
              result.recordset?.[0]?.SafeMatches !== 0 ||
              result.recordset?.[0]?.UnsafeMatches !== 2
            )
              throw new SimulationError(
                "Synthetic injection comparison did not return its expected counts.",
                502,
              );
            return "Fixed input changed the concatenated query to match both synthetic rows; parameter binding matched zero rows. No business tables were queried or changed. This demonstrates an isolated query-construction flaw, not a vulnerability in the portal's order endpoints.";
          }
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
