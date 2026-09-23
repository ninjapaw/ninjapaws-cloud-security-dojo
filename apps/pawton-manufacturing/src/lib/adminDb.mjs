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
      .input("newPassword", sql.NVarChar, newPassword)
      .query(
        `ALTER LOGIN ${quoteIdentifier(currentLogin.name)} WITH PASSWORD = @newPassword;`,
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
