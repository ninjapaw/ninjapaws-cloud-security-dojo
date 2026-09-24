export function readSqlTimeout(name, environment = process.env) {
  const value = Number(environment[name]);
  return Number.isFinite(value) && value > 0 ? value : 5000;
}

export function readSqlConfig({
  environment = process.env,
  privileged = false,
} = {}) {
  const {
    SQL_SERVER_HOST: server,
    SQL_DATABASE: database = "FutonManufacturing",
    SQL_APP_LOGIN: appLogin = "futon_app",
    SQL_APP_LOGIN_PASSWORD: appPassword,
    SQL_ADMIN_LOGIN: adminLogin,
    SQL_ADMIN_LOGIN_PASSWORD: adminPassword,
  } = environment;
  const user = privileged ? adminLogin : appLogin;
  const password = privileged ? adminPassword : appPassword;
  if (!server || !password || (privileged && !user)) return null;
  return {
    server,
    database: privileged ? "master" : database,
    user,
    password,
    port: 1433,
    options: { encrypt: true, trustServerCertificate: true },
    connectionTimeout: readSqlTimeout("SQL_CONNECT_TIMEOUT_MS", environment),
    requestTimeout: readSqlTimeout("SQL_REQUEST_TIMEOUT_MS", environment),
    pool: { max: privileged ? 2 : 5, min: 0, idleTimeoutMillis: 30000 },
  };
}
