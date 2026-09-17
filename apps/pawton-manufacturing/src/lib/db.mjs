import sql from "mssql";

let poolPromise;

function readConfig() {
  const {
    SQL_SERVER_HOST,
    SQL_DATABASE = "FutonManufacturing",
    SQL_APP_LOGIN = "futon_app",
    SQL_APP_LOGIN_PASSWORD,
  } = process.env;

  if (!SQL_SERVER_HOST || !SQL_APP_LOGIN_PASSWORD) {
    return null;
  }

  return {
    server: SQL_SERVER_HOST,
    database: SQL_DATABASE,
    user: SQL_APP_LOGIN,
    password: SQL_APP_LOGIN_PASSWORD,
    port: 1433,
    options: {
      // The VM presents a self-signed certificate on its private, VNet-only endpoint;
      // encryption stays required (the VM forces it), only public CA trust is relaxed.
      encrypt: true,
      trustServerCertificate: true,
    },
    pool: { max: 5, min: 0, idleTimeoutMillis: 30000 },
  };
}

export function isDatabaseConfigured() {
  return readConfig() !== null;
}

export async function getPool() {
  if (!poolPromise) {
    const config = readConfig();
    if (!config) {
      throw new Error(
        "SQL_SERVER_HOST and SQL_APP_LOGIN_PASSWORD must be set.",
      );
    }
    poolPromise = sql.connect(config);
  }
  return poolPromise;
}

export async function query(text) {
  const pool = await getPool();
  const result = await pool.request().query(text);
  return result.recordset;
}
