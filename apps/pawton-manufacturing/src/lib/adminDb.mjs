import sql from "mssql";

// Separate connection pool from lib/db.mjs on purpose: that pool authenticates as the
// least-privilege futon_app login and must never be granted server-level permissions. This pool
// authenticates as dojo_admin_portal_svc, which SQL Server requires to hold CONTROL SERVER before
// it will let anything alter the sa login -- effectively sysadmin. Keeping the two pools distinct
// means a bug in the read-only dashboard code path can never accidentally reach this credential.
let adminPoolPromise;

const DEFAULT_SQL_TIMEOUT_MS = 5000;
const BUILT_IN_ADMIN_SID = "0x01";

function readTimeout(name) {
  const value = Number(process.env[name]);
  return Number.isFinite(value) && value > 0 ? value : DEFAULT_SQL_TIMEOUT_MS;
}

function readAdminConfig() {
  const { SQL_SERVER_HOST, SQL_ADMIN_LOGIN, SQL_ADMIN_LOGIN_PASSWORD } =
    process.env;
  if (!SQL_SERVER_HOST || !SQL_ADMIN_LOGIN || !SQL_ADMIN_LOGIN_PASSWORD) {
    return null;
  }
  return {
    server: SQL_SERVER_HOST,
    database: "master",
    user: SQL_ADMIN_LOGIN,
    password: SQL_ADMIN_LOGIN_PASSWORD,
    port: 1433,
    options: {
      encrypt: true,
      trustServerCertificate: true,
    },
    connectionTimeout: readTimeout("SQL_CONNECT_TIMEOUT_MS"),
    requestTimeout: readTimeout("SQL_REQUEST_TIMEOUT_MS"),
    pool: { max: 2, min: 0, idleTimeoutMillis: 30000 },
  };
}

export function isAdminDbConfigured() {
  return readAdminConfig() !== null;
}

async function getAdminPool() {
  if (!adminPoolPromise) {
    const config = readAdminConfig();
    if (!config) {
      throw new Error(
        "SQL_SERVER_HOST, SQL_ADMIN_LOGIN, and SQL_ADMIN_LOGIN_PASSWORD must be set.",
      );
    }
    // sql.connect() (used by lib/db.mjs for the futon_app pool) manages a single global,
    // process-wide connection singleton in the mssql package: once db.mjs has called it, a later
    // sql.connect(adminConfig) call silently returns that SAME pool instead of authenticating with
    // these admin credentials, so every "admin" query would actually run as futon_app and fail
    // with a permission error. new sql.ConnectionPool(config) creates a genuinely separate pool.
    adminPoolPromise = new sql.ConnectionPool(config).connect().catch((err) => {
      adminPoolPromise = undefined;
      throw err;
    });
  }
  return adminPoolPromise;
}

function quoteIdentifier(identifier) {
  if (!/^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(identifier)) {
    throw new Error(
      "The SQL login name must begin with a letter or underscore and contain only letters, numbers, or underscores.",
    );
  }
  return `[${identifier}]`;
}

async function getBuiltInAdminLogin() {
  const pool = await getAdminPool();
  const result = await pool
    .request()
    .query(
      `SELECT name, is_disabled, LOGINPROPERTY(name, 'PasswordLastSetTime') AS PasswordLastSetTime FROM sys.server_principals WHERE sid = ${BUILT_IN_ADMIN_SID};`,
    );
  const row = result.recordset[0];
  if (!row) {
    throw new Error("SQL Server's built-in administrator login was not found.");
  }
  return row;
}

export async function getSaStatus() {
  const row = await getBuiltInAdminLogin();
  return {
    username: row.name,
    enabled: row.is_disabled === false,
    passwordLastSetTime: row.PasswordLastSetTime ?? null,
  };
}

export async function setSaEnabled(enabled) {
  const pool = await getAdminPool();
  const currentLogin = await getBuiltInAdminLogin();
  await pool
    .request()
    .query(
      `ALTER LOGIN ${quoteIdentifier(currentLogin.name)} ${enabled ? "ENABLE" : "DISABLE"};`,
    );
}

export async function rotateSaPassword(newPassword) {
  if (typeof newPassword !== "string" || newPassword.length < 20)
    throw new Error(
      "A generated strong password is required for the built-in administrator.",
    );
  const pool = await getAdminPool();
  const currentLogin = await getBuiltInAdminLogin();
  const wasDisabled =
    currentLogin.is_disabled === true || currentLogin.is_disabled === 1;

  try {
    if (wasDisabled) {
      await pool
        .request()
        .query(`ALTER LOGIN ${quoteIdentifier(currentLogin.name)} ENABLE;`);
    }

    await pool
      .request()
      .query(
        `ALTER LOGIN ${quoteIdentifier(currentLogin.name)} WITH PASSWORD = N'${newPassword.replaceAll("'", "''")}';`,
      );

    const verifyConfig = {
      ...readAdminConfig(),
      user: currentLogin.name,
      password: newPassword,
      database: "master",
      connectionTimeout: readTimeout("SQL_CONNECT_TIMEOUT_MS"),
      requestTimeout: readTimeout("SQL_REQUEST_TIMEOUT_MS"),
    };
    const verifyPool = new sql.ConnectionPool(verifyConfig);
    try {
      await verifyPool.connect();
    } finally {
      await verifyPool.close();
    }

    return { username: currentLogin.name, wasDisabled };
  } finally {
    if (wasDisabled) {
      await pool
        .request()
        .query(`ALTER LOGIN ${quoteIdentifier(currentLogin.name)} DISABLE;`);
    }
  }
}

export async function renameSaLogin(newUsername) {
  const pool = await getAdminPool();
  const currentLogin = await getBuiltInAdminLogin();
  const quotedNewUsername = quoteIdentifier(newUsername);
  await pool
    .request()
    .query(
      `ALTER LOGIN ${quoteIdentifier(currentLogin.name)} WITH NAME = ${quotedNewUsername};`,
    );
  return newUsername;
}

export function loginRestriction(login, environment = process.env) {
  if (login.isBuiltInAdmin)
    return "Built-in administrator: use the dedicated controls.";
  if (login.type_desc !== "SQL_LOGIN")
    return "Windows and system identities are read-only.";
  if (login.name.startsWith("##") || login.name.toLowerCase() === "sa")
    return "Reserved SQL identity.";
  const serviceNames = [
    environment.SQL_APP_LOGIN || "futon_app",
    environment.SQL_ADMIN_LOGIN || "dojo_admin_portal_svc",
  ];
  if (
    serviceNames.some((name) => name.toLowerCase() === login.name.toLowerCase())
  )
    return "Application service identity: managed by deployment.";
  if (login.hasServerPrivileges || login.hasDatabasePrivileges)
    return "Privileged login: manage through SQL Server administration.";
  return null;
}

export function validateLoginAction(login, action, environment = process.env) {
  if (!["enable", "disable", "rotate", "clear"].includes(action))
    throw new Error("Unsupported login action.");
  const restriction = loginRestriction(login, environment);
  if (restriction) throw new Error(restriction);
  if (
    action === "clear" &&
    (environment.ALLOW_DEMO_BLANK_PASSWORDS !== "true" ||
      !/^dojo_demo_[a-z0-9_]+$/i.test(login.name))
  ) {
    throw new Error(
      "Blank passwords require ALLOW_DEMO_BLANK_PASSWORDS=true and an unprivileged dojo_demo_ login.",
    );
  }
}

export async function listSqlLogins() {
  const pool = await getAdminPool();
  const result = await pool.request().query(`
    SELECT principal_id, name, type_desc, is_disabled,
      CAST(CASE WHEN sid = 0x01 THEN 1 ELSE 0 END AS bit) AS isBuiltInAdmin,
      CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.databases d WHERE d.owner_sid = p.sid)
        OR EXISTS (SELECT 1 FROM sys.server_role_members r WHERE r.member_principal_id = p.principal_id)
        OR EXISTS (SELECT 1 FROM sys.server_permissions x WHERE x.grantee_principal_id = p.principal_id
          AND x.state IN ('G', 'W') AND x.permission_name <> 'CONNECT SQL') THEN 1 ELSE 0 END AS bit) AS hasServerPrivileges,
      LOGINPROPERTY(name, 'PasswordLastSetTime') AS passwordLastSetTime
    FROM sys.server_principals p WHERE type IN ('S', 'U', 'G') ORDER BY name;`);
  return result.recordset;
}

export async function changeSqlLogin(principalId, action, password) {
  if (!Number.isSafeInteger(principalId) || principalId < 1)
    throw new Error("Invalid login identifier.");
  const pool = await getAdminPool();
  const login = (await listSqlLogins()).find(
    (entry) => entry.principal_id === principalId,
  );
  if (!login) throw new Error("Login no longer exists.");
  validateLoginAction(login, action);
  if (action === "clear") {
    const unavailable = await pool
      .request()
      .query(
        "SELECT COUNT(*) AS count FROM sys.databases WHERE state <> 0 AND database_id > 4;",
      );
    if (unavailable.recordset[0].count > 0)
      throw new Error(
        "Cannot verify login isolation while an application database is offline.",
      );
    const databases = await pool
      .request()
      .query(
        "SELECT name FROM sys.databases WHERE state = 0 AND database_id > 4;",
      );
    for (const database of databases.recordset) {
      const identifier = `[${database.name.replaceAll("]", "]]")}]`;
      const result = await pool
        .request()
        .input("loginName", sql.NVarChar(128), login.name).query(`
        SELECT COUNT(*) AS mappings FROM ${identifier}.sys.database_principals
        WHERE sid = SUSER_SID(@loginName);`);
      if (result.recordset[0].mappings > 0)
        throw new Error(
          "Blank-password demo logins must not have users in application databases.",
        );
    }
  }
  if (
    action === "rotate" &&
    (typeof password !== "string" || password.length < 20)
  )
    throw new Error("A generated strong password is required.");
  const identifier = quoteIdentifier(login.name);
  if (action === "enable" || action === "disable") {
    await pool
      .request()
      .query(
        `ALTER LOGIN ${identifier} ${action === "enable" ? "ENABLE" : "DISABLE"};`,
      );
  } else if (action === "clear") {
    await pool.request()
      .query(`ALTER LOGIN ${identifier} WITH CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
      ALTER LOGIN ${identifier} WITH PASSWORD = '';`);
  } else {
    const literal = `N'${password.replaceAll("'", "''")}'`;
    await pool.request()
      .query(`ALTER LOGIN ${identifier} WITH PASSWORD = ${literal};
      ALTER LOGIN ${identifier} WITH CHECK_POLICY = ON;`);
  }
  return login.name;
}

export async function createDemoLogin(password) {
  if (typeof password !== "string" || password.length < 20)
    throw new Error("A generated strong password is required.");
  const pool = await getAdminPool();
  const literal = `N'${password.replaceAll("'", "''")}'`;
  await pool.request().query(`
    IF SUSER_ID('dojo_demo_reader') IS NOT NULL THROW 50001, 'Demo login already exists. No changes made.', 1;
    CREATE LOGIN [dojo_demo_reader] WITH PASSWORD = ${literal}, CHECK_POLICY = ON, DEFAULT_DATABASE = [master];`);
  return "dojo_demo_reader";
}

export async function runDataAuditProbe(runId) {
  if (!/^[a-f0-9-]{36}$/.test(runId))
    throw new Error("Invalid run identifier.");
  const database = quoteIdentifier(
    process.env.SQL_DATABASE || "FutonManufacturing",
  );
  const pool = await getAdminPool();
  const transaction = new sql.Transaction(pool);
  let rolledBack = false;
  transaction.on("rollback", () => {
    rolledBack = true;
  });
  await transaction.begin();
  try {
    await transaction.request().query(`
      IF OBJECT_ID('${database}.dbo.DojoAuditProbe') IS NOT NULL THROW 50001, 'Probe object already exists; nothing changed.', 1;
      CREATE TABLE ${database}.dbo.DojoAuditProbe (ProbeId int NOT NULL, ProbeValue nvarchar(100) NOT NULL);
      INSERT ${database}.dbo.DojoAuditProbe VALUES (1, N'${runId}');
      UPDATE ${database}.dbo.DojoAuditProbe SET ProbeValue = N'updated-${runId}' WHERE ProbeId = 1;
      DELETE ${database}.dbo.DojoAuditProbe WHERE ProbeId = 1; /* dojo-audit-probe:${runId} */`);
  } finally {
    if (!rolledBack) await transaction.rollback();
  }
}
