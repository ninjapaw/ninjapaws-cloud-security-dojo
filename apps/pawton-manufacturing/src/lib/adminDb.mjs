import sql from "mssql";

// Separate connection pool from lib/db.mjs on purpose: that pool authenticates as the
// least-privilege futon_app login and must never be granted server-level permissions. This pool
// authenticates as dojo_admin_portal_svc, which SQL Server requires to hold CONTROL SERVER before
// it will let anything alter the sa login -- effectively sysadmin. Keeping the two pools distinct
// means a bug in the read-only dashboard code path can never accidentally reach this credential.
let adminPoolPromise;

const DEFAULT_SQL_TIMEOUT_MS = 5000;

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
    adminPoolPromise = sql.connect(config).catch((err) => {
      adminPoolPromise = undefined;
      throw err;
    });
  }
  return adminPoolPromise;
}

export async function getSaStatus() {
  const pool = await getAdminPool();
  const result = await pool
    .request()
    .query(
      "SELECT is_disabled, LOGINPROPERTY('sa', 'PasswordLastSetTime') AS PasswordLastSetTime FROM sys.server_principals WHERE name = 'sa'",
    );
  const row = result.recordset[0];
  return {
    enabled: row ? row.is_disabled === false : null,
    passwordLastSetTime: row?.PasswordLastSetTime ?? null,
  };
}

export async function setSaEnabled(enabled) {
  const pool = await getAdminPool();
  // The login name is a fixed literal ('sa'), never user input, so this does not need
  // parameterization; only values (like the rotated password below) come from user-adjacent input.
  await pool
    .request()
    .query(`ALTER LOGIN [sa] ${enabled ? "ENABLE" : "DISABLE"};`);
}

export async function rotateSaPassword(newPassword) {
  const pool = await getAdminPool();
  await pool
    .request()
    .input("newPassword", sql.NVarChar, newPassword)
    .query("ALTER LOGIN [sa] WITH PASSWORD = @newPassword;");
}
