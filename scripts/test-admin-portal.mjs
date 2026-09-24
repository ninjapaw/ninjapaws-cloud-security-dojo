import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { createRequire, stripTypeScriptTypes } from "node:module";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { runInNewContext } from "node:vm";
import {
  pageMetadata,
  ROBOTS_POLICY,
} from "../apps/pawton-manufacturing/src/lib/pageMetadata.mjs";
import {
  readSqlConfig,
  readSqlTimeout,
} from "../apps/pawton-manufacturing/src/lib/sqlConfig.mjs";
import {
  DEFAULT_TIME_ZONE,
  getPortalTimeZone,
  formatTimestamp,
} from "../apps/pawton-manufacturing/src/lib/timeZone.mjs";
import {
  authorizeAdminMutation,
  createSessionToken,
  getAuthenticatedUsername,
} from "../apps/pawton-manufacturing/src/lib/adminAuth.mjs";
import {
  loginRestriction,
  validateLoginAction,
  rotateSaPassword,
  changeSqlLogin,
  runDataAuditProbe,
  setSqlShellEnabled,
} from "../apps/pawton-manufacturing/src/lib/adminDb.mjs";

test("page metadata uses configured canonical origins and route-specific descriptions", () => {
  const environment = {
    PORTAL_CUSTOM_DOMAIN: "Pawton.Example.org",
    WEBSITE_HOSTNAME: "fallback.azurewebsites.net",
  };
  const home = pageMetadata("/", "Overview", environment);
  assert.equal(home.canonical, "https://pawton.example.org/");
  assert.equal(
    home.socialImage,
    "https://pawton.example.org/pawton-social.png",
  );
  assert.match(home.description, /fictional/);
  const inventory = pageMetadata("/inventory/", "Inventory", environment);
  assert.equal(inventory.canonical, "https://pawton.example.org/inventory");
  assert.match(inventory.description, /Inventory valuation/);
  assert.notEqual(inventory.description, home.description);
  assert.equal(
    pageMetadata("/", "Overview", {
      WEBSITE_HOSTNAME: "fallback.azurewebsites.net",
    }).canonical,
    "https://fallback.azurewebsites.net/",
  );
  for (const host of [
    "",
    "localhost",
    "https://evil.example",
    "example.org/path",
    "example.org:443",
    "*.example.org",
  ]) {
    assert.equal(
      pageMetadata("/", "Overview", { PORTAL_CUSTOM_DOMAIN: host }).canonical,
      null,
    );
  }
});

test("private page metadata excludes order identifiers and user-provided titles", () => {
  assert.equal(pageMetadata("/login").title, "Login — Pawton Manufacturing");
  assert.match(pageMetadata("/login").description, /Manager and administrator/);
  for (const path of [
    "/login",
    "/orders",
    "/orders/12345",
    "/admin",
    "/admin/schema",
    "/users",
  ]) {
    const metadata = pageMetadata(path, "Customer private name", {
      PORTAL_CUSTOM_DOMAIN: "pawton.example.org",
    });
    assert.equal(metadata.social, false);
    assert.equal(metadata.canonical, null);
    assert.equal(metadata.socialImage, null);
    assert.ok(!JSON.stringify(metadata).includes("Customer private name"));
    assert.ok(!JSON.stringify(metadata).includes("12345"));
    assert.equal(metadata.robots, ROBOTS_POLICY);
  }
  assert.match(pageMetadata("/", "Overview", {}).robots, /noindex/);
});

test("shared head and middleware provide crawler and social metadata without disabling authentication", async () => {
  const root = new URL("../apps/pawton-manufacturing/", import.meta.url);
  const layout = await readFile(
    new URL("src/layouts/Layout.astro", root),
    "utf8",
  );
  for (const tag of [
    'name="description"',
    'name="robots"',
    'property="og:title"',
    'property="og:image"',
    'name="twitter:card"',
    'name="theme-color"',
    'rel="canonical"',
  ])
    assert.ok(layout.includes(tag), tag);
  assert.match(layout, /pageMetadata\(Astro.url.pathname, title\)/);
  const middleware = await readFile(new URL("src/middleware.ts", root), "utf8");
  assert.match(middleware, /await next\(\)/);
  assert.match(
    middleware,
    /headers\.set\(["']X-Robots-Tag["'],\s*ROBOTS_POLICY\)/,
  );
  assert.match(middleware, /strict-origin-when-cross-origin/);
  assert.match(middleware, /nosniff/);
  const robots = await readFile(new URL("public/robots.txt", root), "utf8");
  assert.match(robots, /User-agent: \*\r?\nAllow: \//);
  const image = await readFile(new URL("public/pawton-social.png", root));
  assert.equal(image.readUInt32BE(16), 1200);
  assert.equal(image.readUInt32BE(20), 630);
});

test("shared SQL configuration preserves credential and pool separation", () => {
  const environment = {
    SQL_SERVER_HOST: "localhost",
    SQL_APP_LOGIN_PASSWORD: "app-test-only",
    SQL_ADMIN_LOGIN: "admin_test",
    SQL_ADMIN_LOGIN_PASSWORD: "admin-test-only",
  };
  const app = readSqlConfig({ environment });
  const admin = readSqlConfig({ environment, privileged: true });
  assert.equal(app.user, "futon_app");
  assert.equal(app.database, "FutonManufacturing");
  assert.equal(app.password, environment.SQL_APP_LOGIN_PASSWORD);
  assert.equal(admin.user, "admin_test");
  assert.equal(admin.database, "master");
  assert.equal(admin.password, environment.SQL_ADMIN_LOGIN_PASSWORD);
  assert.equal(app.pool.max, 5);
  assert.equal(admin.pool.max, 2);
  assert.notEqual(app.options, admin.options);
  assert.deepEqual(app.options, {
    encrypt: true,
    trustServerCertificate: true,
  });
  assert.equal(readSqlConfig({ environment: {} }), null);
  assert.equal(
    readSqlConfig({
      environment: { ...environment, SQL_ADMIN_LOGIN_PASSWORD: "" },
      privileged: true,
    }),
    null,
  );
  for (const value of [undefined, "", "invalid", "0", "-1", "Infinity"]) {
    assert.equal(readSqlTimeout("timeout", { timeout: value }), 5000);
  }
  assert.equal(readSqlTimeout("timeout", { timeout: "1200" }), 1200);
  const custom = readSqlConfig({
    environment: {
      ...environment,
      SQL_DATABASE: "Custom",
      SQL_APP_LOGIN: "reader",
      SQL_REQUEST_TIMEOUT_MS: "1200",
    },
  });
  assert.equal(custom.database, "Custom");
  assert.equal(custom.user, "reader");
  assert.equal(custom.requestTimeout, 1200);
});

test("portal timestamps use configurable Eastern time without changing instants", () => {
  assert.equal(DEFAULT_TIME_ZONE, "America/New_York");
  assert.equal(getPortalTimeZone(""), DEFAULT_TIME_ZONE);
  assert.equal(getPortalTimeZone("invalid/zone"), DEFAULT_TIME_ZONE);
  assert.equal(getPortalTimeZone(" UTC "), "UTC");
  assert.match(
    formatTimestamp("2026-01-15T15:00:00Z", DEFAULT_TIME_ZONE),
    /10:00:00 AM EST/,
  );
  assert.match(
    formatTimestamp("2026-07-15T15:00:00Z", DEFAULT_TIME_ZONE),
    /11:00:00 AM EDT/,
  );
  assert.match(
    formatTimestamp("2026-07-15T15:00:00Z", "Etc/GMT+5"),
    /10:00:00 AM GMT-5/,
  );
  assert.match(
    formatTimestamp("2026-07-15T15:00:00Z", "UTC"),
    /03:00:00 PM UTC/,
  );
  assert.match(
    formatTimestamp("2026-01-01T02:00:00Z", DEFAULT_TIME_ZONE),
    /Dec 31, 2025/,
  );
  const instant = new Date("2026-07-15T15:00:00Z");
  formatTimestamp(instant, "Asia/Tokyo");
  assert.equal(instant.toISOString(), "2026-07-15T15:00:00.000Z");
  for (const value of [null, undefined, "", "not-a-date"]) {
    assert.equal(formatTimestamp(value), "Unavailable");
  }
});

test("timestamp formatting reuses one formatter and refreshes on zone changes", (context) => {
  const OriginalFormatter = Intl.DateTimeFormat;
  let created = 0;
  context.mock.method(Intl, "DateTimeFormat", function (locale, options) {
    created++;
    return new OriginalFormatter(locale, options);
  });
  const instant = "2026-07-15T15:00:00Z";
  for (let index = 0; index < 30; index++)
    formatTimestamp(instant, "Pacific/Honolulu");
  assert.equal(created, 1);
  assert.equal(getPortalTimeZone("Pacific/Honolulu"), "Pacific/Honolulu");
  assert.equal(created, 1);
  formatTimestamp(instant, "UTC");
  assert.equal(created, 2);
});

test("portal timezone reads runtime configuration without a rebuild", () => {
  const original = process.env.PORTAL_TIME_ZONE;
  try {
    process.env.PORTAL_TIME_ZONE = "UTC";
    assert.match(formatTimestamp("2026-07-15T15:00:00Z"), /03:00:00 PM UTC/);
    process.env.PORTAL_TIME_ZONE = "America/New_York";
    assert.match(formatTimestamp("2026-07-15T15:00:00Z"), /11:00:00 AM EDT/);
  } finally {
    if (original === undefined) delete process.env.PORTAL_TIME_ZONE;
    else process.env.PORTAL_TIME_ZONE = original;
  }
});

test("portal timezone is wired through deployment and timestamp views", async () => {
  const read = (path) =>
    readFile(new URL(`../${path}`, import.meta.url), "utf8");
  const config = JSON.parse(await read("config/deploy.config.json"));
  const template = JSON.parse(
    await read("infra/sql-defender-scenario/main.json"),
  );
  assert.equal(config.sqlScenario.portalTimeZone, DEFAULT_TIME_ZONE);
  assert.equal(
    template.parameters.portalTimeZone.defaultValue,
    DEFAULT_TIME_ZONE,
  );
  const webApp = template.resources.find(
    (resource) => resource.type === "Microsoft.Web/sites",
  );
  const setting = webApp.properties.siteConfig.appSettings.find(
    (entry) => entry.name === "PORTAL_TIME_ZONE",
  );
  assert.equal(setting.value, "[parameters('portalTimeZone')]");
  const deploy = await read("scripts/deploy-sql-scenario.sh");
  assert.match(deploy, /config_setting portalTimeZone America\/New_York/);
  assert.match(deploy, /portalTimeZone="\$PORTAL_TIME_ZONE"/);
  const admin = await read(
    "apps/pawton-manufacturing/src/pages/admin/index.astro",
  );
  assert.match(admin, /formatTimestamp\(defender.checkedAt, portalTimeZone\)/);
  assert.equal(
    admin.match(/formatTimestamp\(event.TimeGenerated, portalTimeZone\)/g)
      .length,
    3,
  );
  assert.match(admin, /datetime=\{event.TimeGenerated\}/);
  assert.doesNotMatch(admin, /toISOString\(\)/);
  const status = await read("apps/pawton-manufacturing/src/pages/status.astro");
  assert.match(
    status,
    /formatTimestamp\(status.generated_at, portalTimeZone\)/,
  );
  assert.doesNotMatch(status, /toLocaleString\(\)/);
  const audit = await read("apps/pawton-manufacturing/src/lib/auditLog.mjs");
  assert.match(audit, /order by TimeGenerated desc/);
  assert.doesNotMatch(audit, /datetime_utc_to_local|PORTAL_TIME_ZONE/);
});

test("system status navigation uses the page and checks status without a self HTTP request", async () => {
  const overview = await readFile(
    new URL(
      "../apps/pawton-manufacturing/src/pages/index.astro",
      import.meta.url,
    ),
    "utf8",
  );
  const status = await readFile(
    new URL(
      "../apps/pawton-manufacturing/src/pages/status.astro",
      import.meta.url,
    ),
    "utf8",
  );
  assert.match(overview, /href="\/status">View system status<\/a>/);
  assert.match(
    status,
    /import \{ GET as getStatus \} from '\.\/api\/status\.js'/,
  );
  assert.match(status, /await getStatus\(\)/);
  assert.doesNotMatch(status, /\bfetch\(/);
  assert.match(status, /Database check passing/);
  assert.match(status, /Public database exposure.*Not verified/);
  assert.doesNotMatch(status, /All core checks passing/);
  assert.match(
    status,
    /import \{ isAuthenticated \} from '\.\.\/lib\/adminAuth\.mjs'/,
  );
  assert.match(
    status,
    /\{isAuthenticated\(Astro\.cookies\) && <a href="\/api\/status">View JSON evidence<\/a>\}/,
  );
});

test("status endpoint reports missing configuration without caching or leaking secrets", async () => {
  const originalHost = process.env.SQL_SERVER_HOST;
  delete process.env.SQL_SERVER_HOST;
  try {
    const { GET } =
      await import("../apps/pawton-manufacturing/src/pages/api/status.js");
    const response = await GET();
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("Cache-Control"), "no-store");
    const status = await response.json();
    assert.equal(status.db_connectivity, "not_configured");
    assert.equal(status.sample_item_count, null);
    assert.ok(Number.isFinite(Date.parse(status.generated_at)));
    assert.doesNotMatch(
      JSON.stringify(status),
      /SQL_APP_LOGIN_PASSWORD|SQL_ADMIN_LOGIN_PASSWORD/,
    );
  } finally {
    if (originalHost === undefined) delete process.env.SQL_SERVER_HOST;
    else process.env.SQL_SERVER_HOST = originalHost;
  }
});

test("SQL shell settings use fixed SQL, verify the result, and close on failure", async () => {
  let closed = 0;
  let fail = false;
  let mismatch = false;
  let requested;
  const factory = () => ({
    connect: async () => {},
    close: async () => {
      closed++;
    },
    request: () => {
      const request = {
        input: (name, type, value) => {
          assert.equal(name, "enabled");
          requested = value;
          return request;
        },
        query: async (text) => {
          assert.match(text, /sp_getapplock/);
          assert.match(text, /sp_configure 'xp_cmdshell', @enabled/);
          assert.match(
            text,
            /BEGIN CATCH[\s\S]*sp_configure 'show advanced options', 0/,
          );
          assert.doesNotMatch(text, /WITH OVERRIDE|GRANT|ALTER SERVER ROLE/);
          if (fail) throw new Error("SQL failure");
          return {
            recordset: [{ enabled: mismatch ? !requested : requested }],
          };
        },
      };
      return request;
    },
  });
  await assert.rejects(setSqlShellEnabled("true", factory), /boolean/);
  assert.deepEqual(await setSqlShellEnabled(true, factory), { enabled: true });
  assert.deepEqual(await setSqlShellEnabled(false, factory), {
    enabled: false,
  });
  mismatch = true;
  await assert.rejects(setSqlShellEnabled(true, factory), /verification/);
  fail = true;
  await assert.rejects(setSqlShellEnabled(true, factory), /SQL failure/);
  assert.equal(closed, 4);
});

test("SQL shell lab default is wired from config through ARM and bootstrap", async () => {
  const read = (path) =>
    readFile(new URL(`../${path}`, import.meta.url), "utf8");
  const config = JSON.parse(await read("config/deploy.config.json"));
  const template = JSON.parse(
    await read("infra/sql-defender-scenario/main.json"),
  );
  assert.equal(config.sqlScenario.enableSqlShellAttackTests, "true");
  assert.equal(
    template.parameters.enableSqlShellAttackTests.defaultValue,
    true,
  );
  const bootstrap = template.resources.find(
    (resource) =>
      resource.type === "Microsoft.Compute/virtualMachines/extensions" &&
      resource.name.includes("futon-manufacturing-bootstrap"),
  );
  assert.match(
    bootstrap.properties.protectedSettings.commandToExecute,
    /-EnableSqlShellAttackTests.*enableSqlShellAttackTests/,
  );
  const deploy = await read("scripts/deploy-sql-scenario.sh");
  assert.match(deploy, /config_setting enableSqlShellAttackTests true/);
  assert.match(
    deploy,
    /enableSqlShellAttackTests="\$ENABLE_SQL_SHELL_ATTACK_TESTS"/,
  );
  const script = await read("scripts/sql/Setup-FutonManufacturing.ps1");
  assert.match(script, /\[ValidateSet\('true', 'false'\)\]/);
  assert.match(script, /sp_configure 'xp_cmdshell', @desired/);
  assert.match(script, /SQL shell setting verification failed/);
});

test("SQL shell endpoint rejects cross-origin and invalid values without SQL access", async () => {
  const { POST } =
    await import("../apps/pawton-manufacturing/src/pages/api/admin/sql-shell.js");
  const request = (origin, enabled) =>
    new Request("https://demo.example/api/admin/sql-shell", {
      method: "POST",
      headers: { Origin: origin },
      body: new URLSearchParams({ confirm: "yes", enabled }),
    });
  assert.equal(
    (await POST({ request: request("https://evil.example", "true"), cookies }))
      .status,
    403,
  );
  assert.equal(
    (
      await POST({
        request: request("https://demo.example", "custom-sql"),
        cookies,
      })
    ).status,
    400,
  );
});
import { defenderTarget } from "../apps/pawton-manufacturing/src/lib/defenderStatus.mjs";
import {
  isSqlDemoActionsEnabled,
  probes,
  runAuditProbe,
  runSimulationSample,
  simulationSampleIds,
} from "../apps/pawton-manufacturing/src/lib/securityLab.mjs";
import { parseAuditEvent } from "../apps/pawton-manufacturing/src/lib/auditLog.mjs";
import {
  createSqlAttackRunner,
  attackScenarios,
} from "../apps/pawton-manufacturing/src/lib/sqlAttackLab.mjs";

test("direct SQL lab tests are bounded, isolated, cleaned up, and do not claim alerts", async () => {
  const environment = {
    SQL_SERVER_HOST: "offline-lab",
    SQL_APP_LOGIN_PASSWORD: "offline",
    SQL_ADMIN_LOGIN: "offline-admin",
    SQL_ADMIN_LOGIN_PASSWORD: "offline",
  };
  const configs = [];
  const queries = [];
  let closed = 0;
  let clock = 0;
  const runner = createSqlAttackRunner({
    environment,
    now: () => clock,
    makePool: (config) => {
      configs.push(config);
      return {
        connect: async () => {
          if (config.user.startsWith("dojo_invalid_"))
            throw Object.assign(new Error("expected login failure"), {
              code: "ELOGIN",
            });
        },
        close: async () => {
          closed++;
        },
        request: () => {
          const request = {
            input: () => request,
            query: async (text) => {
              queries.push(text);
              return { recordset: [{ principalId: null, enabled: 0 }] };
            },
          };
          return request;
        },
      };
    },
  });
  assert.equal((await runner.availability()).ids.length, 6);
  await assert.rejects(runner.run("arbitrary"), /Unknown/);
  for (const { id } of attackScenarios) {
    const result = await runner.run(id);
    assert.equal(result.alertConfirmed, false);
    assert.equal(
      result.state,
      ["external-source", "obfuscated-shell"].includes(id)
        ? "blocked"
        : "executed",
    );
    await assert.rejects(runner.run(id), /cooling down/);
    clock += 60001;
  }
  assert.equal(
    configs.filter((config) => config.user.startsWith("dojo_invalid_")).length,
    12,
  );
  assert.ok(
    configs.every(
      (config) =>
        config.server === "offline-lab" &&
        config.options.encrypt &&
        config.pool.max === 1,
    ),
  );
  assert.ok(configs.some((config) => config.options.appName === "sqlmap"));
  assert.equal(closed, configs.length);
  assert.ok(queries.some((text) => text.includes("OR 1=1 UNION SELECT")));
  assert.ok(
    queries.some(
      (text) =>
        text.includes("CREATE USER") &&
        text.includes("ROLLBACK TRANSACTION") &&
        text.includes("REVERT"),
    ),
  );
  assert.ok(
    queries.every(
      (text) => !/sp_configure|RECONFIGURE|COMMIT|EXEC @result/.test(text),
    ),
  );
  environment.ENABLE_SQL_DEMO_ACTIONS = "false";
  await assert.rejects(runner.run("brute-force"), /disabled/);
  assert.deepEqual((await runner.availability()).ids, []);
});
test("shell tests execute only fixed marker commands and validate output", async () => {
  const commands = [];
  let clock = 0;
  let validOutput = true;
  const runner = createSqlAttackRunner({
    environment: {
      SQL_SERVER_HOST: "offline",
      SQL_ADMIN_LOGIN: "admin",
      SQL_ADMIN_LOGIN_PASSWORD: "offline",
    },
    now: () => clock,
    makePool: () => ({
      connect: async () => {},
      close: async () => {},
      request: () => {
        let command;
        const request = {
          input: (name, type, value) => {
            command = value;
            return request;
          },
          query: async (text) => {
            if (text.includes("sys.configurations"))
              return { recordset: [{ enabled: 1 }] };
            commands.push(command);
            const decoded = command.includes("-EncodedCommand")
              ? Buffer.from(command.split(" ").at(-1), "base64").toString(
                  "utf16le",
                )
              : command;
            const marker = decoded.match(
              /dojo-attack-test:[a-z-]+:[a-f0-9-]{36}/,
            )?.[0];
            assert.ok(marker);
            return {
              recordsets: [
                [{ output: validOutput ? marker : "unexpected" }],
                [{ exitCode: 0 }],
              ],
            };
          },
        };
        return request;
      },
    }),
  });
  for (const id of ["external-source", "obfuscated-shell"]) {
    assert.equal((await runner.run(id)).state, "executed");
    clock += 60001;
  }
  assert.match(
    commands[0],
    /^cmd.exe \/d \/c echo https:\/\/example.invalid\/dojo-attack-test:/,
  );
  assert.match(
    Buffer.from(commands[1].split(" ").at(-1), "base64").toString("utf16le"),
    /^Write-Output 'dojo-attack-test:obfuscated-shell:[a-f0-9-]{36}'$/,
  );
  validOutput = false;
  await assert.rejects(runner.run("external-source"), /expected marker/);
});

test("direct SQL runner rejects overlap and closes failed connections without leaking errors", async () => {
  let finishConnection;
  let closed = 0;
  const pending = new Promise((resolve) => {
    finishConnection = resolve;
  });
  const runner = createSqlAttackRunner({
    environment: {
      SQL_SERVER_HOST: "offline",
      SQL_APP_LOGIN_PASSWORD: "offline",
    },
    makePool: () => ({
      connect: () => pending,
      close: async () => {
        closed++;
      },
      request: () => ({
        query: async () => {
          throw new Error("sensitive connection details");
        },
      }),
    }),
  });
  const firstRun = runner.run("sql-injection");
  await assert.rejects(runner.run("suspicious-app"), /running or cooling down/);
  finishConnection();
  await assert.rejects(firstRun, (error) => {
    assert.doesNotMatch(error.message, /sensitive/);
    return error.status === 502;
  });
  assert.equal(closed, 1);
});

process.env.ADMIN_PORTAL_USERNAME = "test-operator";
process.env.ADMIN_PORTAL_PASSWORD = randomBytes(32).toString("hex");
process.env.ADMIN_SESSION_SECRET = randomBytes(32).toString("hex");
delete process.env.ENABLE_SQL_DEMO_ACTIONS;
delete process.env.ALLOW_DEMO_BLANK_PASSWORDS;
const cookies = { get: () => ({ value: createSessionToken() }) };
const anonymous = { get: () => undefined };
const demo = { name: "dojo_demo_reader", type_desc: "SQL_LOGIN" };

test("mutations require a signed session and exact same origin", () => {
  const request = new Request("https://demo.example/api/admin/probe", {
    method: "POST",
    headers: { Origin: "https://demo.example" },
  });
  assert.equal(authorizeAdminMutation(request, anonymous).status, 401);
  assert.equal(authorizeAdminMutation(request, cookies), null);
  assert.equal(
    authorizeAdminMutation(
      new Request(request.url, { method: "POST" }),
      cookies,
    ).status,
    403,
  );
  assert.equal(
    authorizeAdminMutation(
      new Request(request.url, {
        method: "POST",
        headers: { Origin: "https://other.example" },
      }),
      cookies,
    ).status,
    403,
  );
  assert.equal(getAuthenticatedUsername(anonymous), null);
  assert.equal(getAuthenticatedUsername(cookies), "test-operator");
  assert.equal(
    authorizeAdminMutation(request, {
      get: () => ({ value: "tampered.signature" }),
    }).status,
    401,
  );
});

test("built-in, system, Windows, privileged and service logins are protected", () => {
  for (const login of [
    { ...demo, isBuiltInAdmin: true, name: "renamed_admin" },
    { ...demo, name: "sa" },
    { ...demo, name: "##system##" },
    { ...demo, name: "futon_app" },
    { ...demo, name: "dojo_admin_portal_svc" },
    { ...demo, type_desc: "WINDOWS_LOGIN" },
    { ...demo, hasServerPrivileges: true },
  ]) {
    assert.ok(loginRestriction(login, {}));
    for (const action of ["enable", "disable", "rotate", "clear"])
      assert.throws(() =>
        validateLoginAction(login, action, {
          ALLOW_DEMO_BLANK_PASSWORDS: "true",
        }),
      );
  }
});

test("blank passwords require explicit opt-in and the demo prefix", async () => {
  assert.throws(() => validateLoginAction(demo, "clear", {}));
  assert.throws(() =>
    validateLoginAction({ ...demo, name: "ordinary_user" }, "clear", {
      ALLOW_DEMO_BLANK_PASSWORDS: "true",
    }),
  );
  validateLoginAction(demo, "clear", { ALLOW_DEMO_BLANK_PASSWORDS: "true" });
  validateLoginAction(demo, "rotate", {});
  assert.throws(() => validateLoginAction(demo, "drop", {}));
  await assert.rejects(rotateSaPassword(""), /strong password/);
  await assert.rejects(changeSqlLogin(NaN, "disable", ""), /identifier/);
});

test("probe catalog is fixed, enabled by default unless explicitly disabled, and distinct from simulations", async () => {
  assert.deepEqual(
    simulationSampleIds,
    attackScenarios.map((scenario) => scenario.id),
  );
  assert.deepEqual(
    probes.map((probe) => probe.id),
    ["read", "data-change", "denied-write"],
  );
  assert.ok(probes.every((probe) => probe.script.includes("dojo-audit-probe")));
  assert.equal(isSqlDemoActionsEnabled({}), true);
  assert.equal(
    isSqlDemoActionsEnabled({ ENABLE_SQL_DEMO_ACTIONS: "false" }),
    false,
  );
  await assert.rejects(runAuditProbe("custom-sql"), /Unknown probe/);
  await assert.rejects(
    runSimulationSample("custom-sample"),
    /Unknown simulation sample/,
  );
  process.env.ENABLE_SQL_DEMO_ACTIONS = "false";
  await assert.rejects(runAuditProbe("read"), /disabled/);
  await assert.rejects(runSimulationSample("brute-force"), /disabled/);
  delete process.env.ENABLE_SQL_DEMO_ACTIONS;
});

test("VM target is server-configured and invalid identifiers stay unconfigured", () => {
  const vm =
    "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/demo/providers/Microsoft.Compute/virtualMachines/sqlvm";
  assert.equal(defenderTarget({ SQL_VM_RESOURCE_ID: vm }).vmId, vm);
  assert.match(
    defenderTarget({ SQL_VM_RESOURCE_ID: vm }).portal,
    /Microsoft.SqlVirtualMachine/,
  );
  assert.equal(
    defenderTarget({ SQL_VM_RESOURCE_ID: "https://evil.example" }).vmId,
    null,
  );
  assert.equal(
    defenderTarget({ AZURE_SUBSCRIPTION_ID: "invalid" }).subscription,
    null,
  );
});

test("record pager browses every record with arrows and validated record jumps", async () => {
  const source = await readFile(
    new URL(
      "../apps/pawton-manufacturing/src/components/RecordPager.astro",
      import.meta.url,
    ),
    "utf8",
  );
  const script = stripTypeScriptTypes(
    source.match(/<script>([\s\S]*?)<\/script>/)[1],
  );
  for (const total of [0, 1, 25, 26, 63, 501]) {
    const rows = Array.from({ length: total }, (_, index) => ({
      index,
      hidden: index >= 25,
    }));
    const input = {
      value: "1",
      focus() {},
      reportValidity: () =>
        Number(input.value) >= 1 && Number(input.value) <= total,
    };
    const range = { textContent: "" };
    const form = {
      addEventListener: (_, handler) => {
        form.submit = handler;
      },
    };
    const buttons = ["first", "previous", "next", "last"].map((action) => {
      const button = {
        dataset: { pageAction: action },
        disabled: false,
        addEventListener: (_, handler) => {
          button.click = handler;
        },
      };
      return button;
    });
    let Pager;
    class Element {
      dataset = {
        target: "records",
        total: String(total),
        size: "25",
        server: "false",
      };
      querySelector(selector) {
        return selector === 'input[name="record"]'
          ? input
          : selector === ".record-range"
            ? range
            : form;
      }
      querySelectorAll() {
        return buttons;
      }
    }
    const target = { querySelectorAll: () => rows, scrollIntoView() {} };
    runInNewContext(script, {
      HTMLElement: Element,
      customElements: {
        get: () => undefined,
        define: (_, value) => {
          Pager = value;
        },
      },
      document: { getElementById: () => target },
    });
    new Pager().connectedCallback();
    const assertStart = (start) => {
      assert.deepEqual(
        rows.filter((row) => !row.hidden).map((row) => row.index),
        Array.from(
          { length: Math.min(25, total - start) },
          (_, index) => start + index,
        ),
      );
      assert.equal(buttons[0].disabled, start === 0);
      assert.equal(
        buttons[2].disabled,
        start >= Math.max(0, Math.floor((total - 1) / 25) * 25),
      );
      assert.equal(
        range.textContent,
        `${total ? start + 1 : 0}–${Math.min(start + 25, total)} of ${total} records`,
      );
    };
    assertStart(0);
    for (let start = 25; start < total; start += 25) {
      buttons[2].click();
      assertStart(start);
    }
    buttons[3].click();
    assertStart(Math.max(0, Math.floor((total - 1) / 25) * 25));
    buttons[0].click();
    assertStart(0);
    if (total) {
      input.value = String(total);
      form.submit({ preventDefault() {} });
      assertStart(Math.floor((total - 1) / 25) * 25);
      input.value = "invalid";
      form.submit({ preventDefault() {} });
      assertStart(Math.floor((total - 1) / 25) * 25);
      buttons[1].click();
      assertStart(Math.max(0, Math.floor((total - 1) / 25) * 25 - 25));
    }
  }
});

test("record tabs have no TOP cutoffs and use independent bottom pagers", async () => {
  for (const name of [
    "inventory",
    "sales",
    "production",
    "users",
    "admin/schema",
  ]) {
    const source = await readFile(
      new URL(
        `../apps/pawton-manufacturing/src/pages/${name}.astro`,
        import.meta.url,
      ),
      "utf8",
    );
    assert.doesNotMatch(source, /SELECT TOP|Showing up to|Up to 500/);
    assert.match(source, /<RecordPager target=/);
    assert.match(source, /data-record hidden=\{index >= 25\}/);
  }
  const admin = await readFile(
    new URL(
      "../apps/pawton-manufacturing/src/pages/admin/index.astro",
      import.meta.url,
    ),
    "utf8",
  );
  assert.match(admin, /getRecentSaAuditEvents\(30, 25,/);
  assert.match(admin, /<RecordPager target="windows-events".*server/);
  assert.doesNotMatch(admin, /latest 100|data-event-pagination/);
});

test("Windows event pages use fixed scoped windows, bounded queries, and clamped record numbers", async () => {
  const { getRecentSaAuditEvents } =
    await import("../apps/pawton-manufacturing/src/lib/auditLog.mjs");
  const previousWorkspace = process.env.LOG_ANALYTICS_WORKSPACE_ID;
  const previousVm = process.env.SQL_VM_RESOURCE_ID;
  process.env.LOG_ANALYTICS_WORKSPACE_ID =
    "00000000-0000-0000-0000-000000000000";
  process.env.SQL_VM_RESOURCE_ID =
    "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/demo/providers/Microsoft.Compute/virtualMachines/sqlvm";
  try {
    for (const [record, expectedStart] of [
      ["1", 0],
      ["26", 25],
      ["52", 50],
      ["99999", 1000],
      ["1; take 9999", 0],
      ["-1", 0],
    ]) {
      const queries = [];
      const client = {
        queryWorkspace: async (_, query, interval) => {
          queries.push(query);
          assert.equal(
            interval.endTime.toISOString(),
            "2026-01-01T12:00:00.000Z",
          );
          assert.equal(
            interval.startTime.toISOString(),
            "2026-01-01T11:30:00.000Z",
          );
          assert.match(query, /_ResourceId =~/);
          assert.match(query, /ingestion_time\(\) <= datetime/);
          return {
            status: "Success",
            tables: [
              {
                columnDescriptors: query.endsWith("| count")
                  ? [{ name: "Count" }]
                  : [{ name: "RenderedDescription" }],
                rows: query.endsWith("| count")
                  ? [[1003]]
                  : [
                      [
                        "action_id:LGEA object_name:sa statement:ALTER LOGIN [sa] ENABLE;",
                      ],
                    ],
              },
            ],
          };
        },
      };
      const result = await getRecentSaAuditEvents(30, 25, {
        record,
        until: "2026-01-01T12:00:00.000Z",
        client,
      });
      assert.equal(result.total, 1003);
      assert.equal(result.start, expectedStart);
      assert.equal(result.events[0].TargetLogin, "sa");
      assert.equal(queries.length, 2);
      assert.ok(
        queries[1].includes(
          `RowNumber > ${expectedStart} and RowNumber <= ${expectedStart + 25}`,
        ),
      );
      assert.doesNotMatch(queries[1], /take 9999/);
    }
    let calls = 0;
    const empty = await getRecentSaAuditEvents(30, 25, {
      client: {
        queryWorkspace: async () => {
          calls++;
          return {
            status: "Success",
            tables: [{ columnDescriptors: [{ name: "Count" }], rows: [[0]] }],
          };
        },
      },
    });
    assert.equal(empty.total, 0);
    assert.equal(calls, 1);
    await assert.rejects(
      getRecentSaAuditEvents(30, 25, {
        client: {
          queryWorkspace: async () => ({
            status: "PartialFailure",
            partialError: { message: "Incomplete results" },
          }),
        },
      }),
      /Incomplete results/,
    );
  } finally {
    if (previousWorkspace === undefined)
      delete process.env.LOG_ANALYTICS_WORKSPACE_ID;
    else process.env.LOG_ANALYTICS_WORKSPACE_ID = previousWorkspace;
    if (previousVm === undefined) delete process.env.SQL_VM_RESOURCE_ID;
    else process.env.SQL_VM_RESOURCE_ID = previousVm;
  }
});

test("audit parser preserves unknown outcomes and field boundaries", () => {
  const event = parseAuditEvent({
    RenderedDescription:
      "action_id:UP succeeded:true session_server_principal_name:session server_principal_name:actor target_server_principal_name:target client_ip:10.0.0.1",
  });
  assert.equal(event.Success, true);
  assert.equal(event.LoginName, "actor");
  assert.equal(event.ActionId, "UP");
  assert.equal(
    parseAuditEvent({ RenderedDescription: "action_id:UP" }).Success,
    null,
  );
  assert.equal(
    parseAuditEvent({ RenderedDescription: "succeeded:false" }).Success,
    false,
  );
  assert.equal(
    parseAuditEvent({
      RenderedDescription:
        "server_principal_name: target_server_principal_name:target",
    }).LoginName,
    "target",
  );
});

test("audit parser labels login state changes and their target", () => {
  const event = parseAuditEvent({
    RenderedDescription:
      "action_id:LGDA succeeded:true server_principal_name:portal-service target_server_principal_name:sa statement:ALTER LOGIN [sa] DISABLE; client_ip:10.0.0.1",
  });
  assert.equal(event.Operation, "Login disabled");
  assert.equal(event.LoginName, "portal-service");
  assert.equal(event.TargetLogin, "sa");
  assert.match(event.Summary, /Login disabled.*target: sa/);
});

test("audit parser displays enabled sa and renamed accounts without treating failed attempts as success", () => {
  const objectTarget = parseAuditEvent({
    EventID: 33205,
    RenderedDescription:
      "action_id:LGEA succeeded:true server_principal_name:portal-service target_server_principal_name: target_server_principal_sid: object_name:sa statement:ALTER LOGIN [sa] ENABLE; additional_information:",
  });
  assert.equal(objectTarget.TargetLogin, "sa");
  assert.match(objectTarget.Summary, /Login enabled.*target: sa.*success/);
  const nonLogin = parseAuditEvent({
    EventID: 33205,
    RenderedDescription:
      "action_id:SL object_name:sa statement:SELECT 1 additional_information:",
  });
  assert.equal(nonLogin.TargetLogin, null);
  for (const target of ["sa", "renamed_admin", "admin with spaces"]) {
    for (const action of ["LGEA", "AL"]) {
      for (const succeeded of ["true", "false", ""]) {
        const event = parseAuditEvent({
          EventID: 33205,
          RenderedDescription: `action_id:${action} succeeded:${succeeded} server_principal_name:portal-service target_server_principal_name:${target} target_server_principal_sid:0x01 statement:ALTER LOGIN [${target}] ENABLE; additional_information:`,
        });
        assert.equal(event.Operation, "Login enabled");
        assert.equal(event.TargetLogin, target);
        assert.equal(
          event.Success,
          succeeded === "true" ? true : succeeded === "false" ? false : null,
        );
        assert.ok(event.Summary.includes(`Login enabled • target: ${target}`));
        assert.ok(
          event.Summary.endsWith(
            succeeded === "true"
              ? "success"
              : succeeded === "false"
                ? "failed"
                : "unknown",
          ),
        );
      }
    }
  }
});

test("all login and probe endpoints reject unauthenticated and unconfirmed requests", async () => {
  for (const endpoint of [
    "sa/enable",
    "sa/disable",
    "sa/rotate",
    "sa/rename",
    "users/action",
    "probe",
    "simulation-sample",
    "defender-simulation",
    "sql-shell",
  ]) {
    const route = await import(
      `../apps/pawton-manufacturing/src/pages/api/admin/${endpoint}.js`
    );
    const makeRequest = () =>
      new Request(`https://demo.example/api/admin/${endpoint}`, {
        method: "POST",
        headers: { Origin: "https://demo.example" },
        body: new URLSearchParams(),
      });
    assert.equal(
      (await route.POST({ request: makeRequest(), cookies: anonymous })).status,
      401,
    );
    assert.equal(
      (await route.POST({ request: makeRequest(), cookies })).status,
      400,
    );
  }
});

test("Defender endpoint rejects cross-origin and arbitrary scenario requests", async () => {
  const { POST } =
    await import("../apps/pawton-manufacturing/src/pages/api/admin/defender-simulation.js");
  const makeRequest = (origin) =>
    new Request("https://demo.example/api/admin/defender-simulation", {
      method: "POST",
      headers: { Origin: origin },
      body: new URLSearchParams({
        confirm: "yes",
        simulation: "custom-command",
      }),
    });
  assert.equal(
    (await POST({ request: makeRequest("https://other.example"), cookies }))
      .status,
    403,
  );
  const response = await POST({
    request: makeRequest("https://demo.example"),
    cookies,
  });
  assert.equal(response.status, 400);
  assert.equal(response.headers.get("Cache-Control"), "no-store");
  assert.match((await response.json()).error, /Unknown/);
});

test("data-change probe rolls back on success and SQL failure, never commits", async () => {
  const requireApp = createRequire(
    new URL("../apps/pawton-manufacturing/package.json", import.meta.url),
  );
  const sql = requireApp("mssql");
  const originalPool = sql.ConnectionPool;
  const originalTransaction = sql.Transaction;
  const commands = [];
  let rollbackCount = 0;
  let shouldFail = false;
  sql.ConnectionPool = class {
    async connect() {
      return this;
    }
  };
  sql.Transaction = class {
    on() {}
    async begin() {}
    request() {
      return {
        query: async (text) => {
          commands.push(text);
          if (shouldFail) throw new Error("SQL failure");
        },
      };
    }
    async rollback() {
      rollbackCount++;
    }
    async commit() {
      assert.fail("A probe must never commit.");
    }
  };
  process.env.SQL_SERVER_HOST = "offline-test";
  process.env.SQL_ADMIN_LOGIN = "offline-test";
  process.env.SQL_ADMIN_LOGIN_PASSWORD = "offline-test";
  try {
    await runDataAuditProbe("00000000-0000-0000-0000-000000000001");
    shouldFail = true;
    await assert.rejects(
      runDataAuditProbe("00000000-0000-0000-0000-000000000002"),
      /SQL failure/,
    );
    assert.equal(rollbackCount, 2);
    assert.match(commands[0], /IF OBJECT_ID/);
    assert.match(commands[0], /INSERT.*DojoAuditProbe/);
    assert.match(commands[0], /UPDATE.*DojoAuditProbe/);
    assert.match(commands[0], /DELETE.*DojoAuditProbe/);
    await assert.rejects(runDataAuditProbe("invalid"), /identifier/);
  } finally {
    sql.ConnectionPool = originalPool;
    sql.Transaction = originalTransaction;
    delete process.env.SQL_SERVER_HOST;
    delete process.env.SQL_ADMIN_LOGIN;
    delete process.env.SQL_ADMIN_LOGIN_PASSWORD;
  }
});
