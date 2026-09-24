import sql from "mssql";
import { readSqlConfig } from "./sqlConfig.mjs";

let poolPromise;

export function isDatabaseConfigured() {
  return readSqlConfig() !== null;
}

export async function getPool() {
  if (!poolPromise) {
    const config = readSqlConfig();
    if (!config) {
      throw new Error(
        "SQL_SERVER_HOST and SQL_APP_LOGIN_PASSWORD must be set.",
      );
    }
    poolPromise = new sql.ConnectionPool(config).connect().catch((err) => {
      poolPromise = undefined;
      throw err;
    });
  }
  return poolPromise;
}

export async function query(text) {
  const pool = await getPool();
  const result = await pool.request().query(text);
  return result.recordset;
}
