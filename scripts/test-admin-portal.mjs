import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { createRequire } from "node:module";
import { test } from "node:test";
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
} from "../apps/pawton-manufacturing/src/lib/adminDb.mjs";
import { defenderTarget } from "../apps/pawton-manufacturing/src/lib/defenderStatus.mjs";
import {
  probes,
  runAuditProbe,
  simulations,
} from "../apps/pawton-manufacturing/src/lib/securityLab.mjs";
import { parseAuditEvent } from "../apps/pawton-manufacturing/src/lib/auditLog.mjs";

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

test("probe catalog is fixed, disabled by default, and distinct from simulations", async () => {
  assert.equal(simulations.length, 6);
  assert.deepEqual(
    probes.map((probe) => probe.id),
    ["read", "data-change", "denied-write"],
  );
  await assert.rejects(runAuditProbe("custom-sql"), /Unknown probe/);
  for (const probe of probes)
    await assert.rejects(runAuditProbe(probe.id), /disabled/);
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

test("all login and probe endpoints reject unauthenticated and unconfirmed requests", async () => {
  for (const endpoint of [
    "sa/enable",
    "sa/disable",
    "sa/rotate",
    "sa/rename",
    "users/action",
    "probe",
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
