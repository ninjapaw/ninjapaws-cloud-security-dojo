import assert from "node:assert/strict";
import { test } from "node:test";
import { createRequire } from "node:module";
import { randomUUID, createHmac } from "node:crypto";
import { readFile } from "node:fs/promises";
import {
  createUserSession,
  getUser,
  checkUserCredentials,
  authorizeUserMutation,
  USER_SESSION_COOKIE,
  userSessionCookieOptions,
} from "../apps/pawton-manufacturing/src/lib/userAuth.mjs";
import {
  createSessionToken,
  verifySessionToken,
  authorizeAdminMutation,
  SESSION_COOKIE_NAME,
  ROTATED_SECRET_COOKIE_NAME,
} from "../apps/pawton-manufacturing/src/lib/adminAuth.mjs";
import { POST as loginPost } from "../apps/pawton-manufacturing/src/pages/api/user/login.js";
import { POST as legacyLoginPost } from "../apps/pawton-manufacturing/src/pages/api/admin/login.js";
import {
  createOrderService,
  validateDraft,
  orders,
} from "../apps/pawton-manufacturing/src/lib/orders.mjs";

const requireApp = createRequire(
  new URL("../apps/pawton-manufacturing/package.json", import.meta.url),
);
const sql = requireApp("mssql");
const draft = () => ({
  requestId: randomUUID(),
  customerId: 1,
  warehouseId: 2,
  deliveryDate: "2026-10-01",
  notes: "Test order",
  lines: [{ itemId: 3, quantity: 2, price: 0.01 }],
});
const anonymous = { get: () => undefined };
test("IaC provisions separate manager secrets and matching app settings without secret outputs", async () => {
  const read = (path) =>
    readFile(new URL(`../${path}`, import.meta.url), "utf8");
  const template = JSON.parse(
    await read("infra/sql-defender-scenario/main.json"),
  );
  const config = JSON.parse(await read("config/deploy.config.json"));
  assert.equal(config.sqlScenario.userPortalUsername, "dojo-manager");
  assert.equal(template.parameters.userPortalUsername.maxLength, 100);
  for (const name of ["userPortalPassword", "userSessionSecret"]) {
    assert.equal(template.parameters[name].type.toLowerCase(), "securestring");
    assert.equal(template.parameters[name].defaultValue, undefined);
    assert.ok(!JSON.stringify(template.outputs).includes(name));
  }
  assert.equal(template.parameters.userSessionSecret.minLength, 64);
  const settings = template.resources.find(
    (resource) => resource.type === "Microsoft.Web/sites",
  ).properties.siteConfig.appSettings;
  for (const [secretName, parameter, setting] of [
    ["user-portal-username", "userPortalUsername", "USER_PORTAL_USERNAME"],
    ["user-portal-password", "userPortalPassword", "USER_PORTAL_PASSWORD"],
    ["user-session-secret", "userSessionSecret", "USER_SESSION_SECRET"],
  ]) {
    const secret = template.resources.find(
      (resource) =>
        resource.type === "Microsoft.KeyVault/vaults/secrets" &&
        resource.name.includes(secretName),
    );
    assert.ok(secret, secretName);
    assert.equal(secret.condition, "[parameters('deployWebApp')]");
    assert.equal(secret.properties.value, `[parameters('${parameter}')]`);
    assert.equal(
      settings.find((entry) => entry.name === setting).value,
      secret.properties.value,
    );
  }
  const script = await read("scripts/deploy-sql-scenario.sh");
  assert.match(script, /user_portal_password="\$\(generate_password\)"/);
  assert.match(script, /user_session_secret=.*randomBytes\(32\)/);
  assert.match(script, /userPortalPassword="\$user_portal_password"/);
  assert.match(script, /userSessionSecret="\$user_session_secret"/);
  assert.match(script, /unset user_portal_password user_session_secret/);
  assert.doesNotMatch(
    script,
    /(?:printf|echo|record_check)[^\n]*\$(?:user_portal_password|user_session_secret)/,
  );
  assert.match(script, /az keyvault secret list --vault-name/);
  assert.doesNotMatch(script, /user-portal-password[^\n]*--query value/);
});

test("one Login entry point serves both roles and keeps orders protected", async () => {
  const readPage = (name) =>
    readFile(
      new URL(`../apps/pawton-manufacturing/src/${name}`, import.meta.url),
      "utf8",
    );
  const login = await readPage("pages/login.astro");
  const legacy = await readPage("pages/admin/login.astro");
  const list = await readPage("pages/orders/index.astro");
  const layout = await readPage("layouts/Layout.astro");
  assert.match(login, /<h1>Login<\/h1>/);
  assert.equal((login.match(/<form\b/g) ?? []).length, 1);
  assert.match(login, /method="post" action="\/api\/user\/login"/);
  assert.match(
    login,
    /name="username" autocomplete="username" maxlength="100" required disabled=\{!configured\}/,
  );
  assert.match(
    login,
    /name="password" autocomplete="current-password" maxlength="1024" required disabled=\{!configured\}/,
  );
  assert.match(
    login,
    /isUserLoginConfigured\(\) \|\| isAdminPortalConfigured\(\)/,
  );
  assert.match(login, /role="alert"/);
  assert.match(legacy, /encodeURIComponent\(error\)/);
  assert.doesNotMatch(legacy, /<form\b/);
  assert.match(login, /Astro.redirect\('\/admin'\)/);
  assert.match(login, /Astro.redirect\('\/orders'\)/);
  assert.match(list, /if \(!username\) return Astro.redirect\('\/login'\)/);
  assert.match(list, /<h1>Manage orders<\/h1>/);
  assert.match(list, /'Edit draft' : 'View order'/);
  assert.match(layout, /href="\/login">Login/);
  assert.doesNotMatch(layout, /href="\/admin\/login"/);
  assert.doesNotMatch(login, /Administrator sign-in|Log in as manager/);
  assert.match(layout, /href="\/orders">Manage orders/);
});

function configure(context) {
  const values = {
    USER_PORTAL_USERNAME: "staff-test",
    USER_PORTAL_PASSWORD: "test-only",
    USER_SESSION_SECRET: "test-shared-secret",
    ADMIN_PORTAL_USERNAME: "admin-test",
    ADMIN_PORTAL_PASSWORD: "admin-only",
    ADMIN_SESSION_SECRET: "test-shared-secret",
  };
  const originals = Object.fromEntries(
    Object.keys(values).map((key) => [key, process.env[key]]),
  );
  Object.assign(process.env, values);
  context.after(() => {
    for (const [key, value] of Object.entries(originals)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  });
  const token = createUserSession();
  return {
    token,
    cookies: {
      get: (name) =>
        name === USER_SESSION_COOKIE ? { value: token } : undefined,
    },
  };
}
async function submitLogin(username, password, options = {}) {
  const values = new Map(options.initialCookies ?? []);
  const deleted = [];
  const saved = [];
  const cookies = {
    get: (name) => values.get(name),
    set: (name, value, settings) => {
      saved.push(name);
      values.set(name, { value, settings });
    },
    delete: (name) => {
      deleted.push(name);
      values.delete(name);
    },
  };
  const request = new Request(
    `https://portal.example${options.path ?? "/api/user/login"}`,
    {
      method: "POST",
      headers: {
        ...(options.origin === null
          ? {}
          : { Origin: options.origin ?? "https://portal.example" }),
        "X-Forwarded-For": options.client ?? randomUUID(),
      },
      body: options.body ?? new URLSearchParams({ username, password }),
    },
  );
  const response = await (options.handler ?? loginPost)({
    request,
    cookies,
    redirect: (location, status) =>
      new Response(null, { status, headers: { Location: location } }),
  });
  return { response, cookies, values, deleted, saved };
}

test("shared login issues only the matching role's session and rejects invalid requests", async (context) => {
  configure(context);
  assert.equal(legacyLoginPost, loginPost);
  const submit = submitLogin;
  for (const [username, password, destination, cookie] of [
    ["staff-test", "test-only", "/orders", USER_SESSION_COOKIE],
    ["admin-test", "admin-only", "/admin", SESSION_COOKIE_NAME],
  ]) {
    const result = await submit(username, password);
    assert.equal(result.response.status, 303);
    assert.equal(result.response.headers.get("location"), destination);
    assert.deepEqual([...result.values.keys()], [cookie]);
    assert.deepEqual(result.deleted, [
      SESSION_COOKIE_NAME,
      ROTATED_SECRET_COOKIE_NAME,
      USER_SESSION_COOKIE,
    ]);
    assert.equal(result.values.get(cookie).settings.secure, true);
    assert.equal(result.values.get(cookie).settings.httpOnly, true);
    assert.equal(
      getUser(result.cookies),
      cookie === USER_SESSION_COOKIE ? username : null,
    );
    assert.equal(
      verifySessionToken(result.values.get(cookie).value),
      cookie === SESSION_COOKIE_NAME,
    );
  }
  const invalid = await submit("admin-test", "wrong");
  assert.equal(
    invalid.response.headers.get("location"),
    "/login?error=invalid",
  );
  assert.equal(invalid.values.size, 0);
  assert.equal(
    (
      await submit("admin-test", "admin-only", {
        origin: "https://other.example",
      })
    ).response.status,
    403,
  );
  assert.equal(
    (await submit("", "", { body: "not a form" })).response.status,
    400,
  );
  assert.equal(
    (await submit("x".repeat(101), "test-only")).response.headers.get(
      "location",
    ),
    "/login?error=invalid",
  );
  const client = randomUUID();
  for (let attempt = 0; attempt < 5; attempt++)
    await submit(attempt % 2 ? "staff-test" : "admin-test", "wrong", {
      client,
    });
  for (const [username, password] of [
    ["admin-test", "admin-only"],
    ["staff-test", "test-only"],
  ]) {
    const blocked = await submit(username, password, { client });
    assert.equal(
      blocked.response.headers.get("location"),
      "/login?error=ratelimited",
    );
    assert.equal(blocked.values.size, 0);
  }
  process.env.USER_PORTAL_USERNAME = "admin-test";
  process.env.USER_PORTAL_PASSWORD = "admin-only";
  assert.equal(
    (await submit("admin-test", "admin-only")).response.headers.get("location"),
    "/orders",
  );
  delete process.env.USER_SESSION_SECRET;
  assert.equal(
    (await submit("admin-test", "admin-only")).response.headers.get("location"),
    "/admin",
  );
  delete process.env.ADMIN_SESSION_SECRET;
  assert.equal(
    (await submit("admin-test", "admin-only")).response.headers.get("location"),
    "/login?error=invalid",
  );
});

test("switching login roles removes existing sessions and rotated-secret cookies", async (context) => {
  configure(context);
  for (const [username, password, cookieName] of [
    ["staff-test", "test-only", USER_SESSION_COOKIE],
    ["admin-test", "admin-only", SESSION_COOKIE_NAME],
  ]) {
    const initialCookies = [
      [USER_SESSION_COOKIE, { value: createUserSession() }],
      [SESSION_COOKIE_NAME, { value: createSessionToken() }],
      [ROTATED_SECRET_COOKIE_NAME, { value: "test-only-rotated-value" }],
    ];
    const result = await submitLogin(username, password, { initialCookies });
    assert.equal(result.response.status, 303);
    assert.deepEqual([...result.values.keys()], [cookieName]);
    assert.notEqual(
      result.values.get(cookieName).value,
      new Map(initialCookies).get(cookieName).value,
    );
    assert.deepEqual(result.values.get(cookieName).settings, {
      httpOnly: true,
      secure: true,
      sameSite: "strict",
      path: "/",
      maxAge: 900,
    });
  }
});

test("both login endpoints reject malformed or invalid requests without changing sessions", async (context) => {
  configure(context);
  const initialCookies = [
    [USER_SESSION_COOKIE, { value: createUserSession() }],
  ];
  for (const [handler, path] of [
    [loginPost, "/api/user/login"],
    [legacyLoginPost, "/api/admin/login"],
  ]) {
    for (const [username, password, options, status] of [
      ["staff-test", "test-only", { origin: null }, 403],
      ["staff-test", "test-only", { origin: "null" }, 403],
      [
        "staff-test",
        "test-only",
        { origin: "https://portal.example.evil.test" },
        403,
      ],
      ["staff-test", "test-only", { origin: "http://portal.example" }, 403],
      ["staff-test", "test-only", { body: "invalid-form" }, 400],
      ["", "", { body: new URLSearchParams() }, 303],
      ["x".repeat(101), "test-only", {}, 303],
      ["staff-test", "x".repeat(1025), {}, 303],
      ["staff-test", "admin-only", {}, 303],
      ["admin-test", "test-only", {}, 303],
      ["unknown", "admin-only", {}, 303],
    ]) {
      const result = await submitLogin(username, password, {
        ...options,
        initialCookies,
        handler,
        path,
      });
      assert.equal(result.response.status, status);
      if (status === 303)
        assert.equal(
          result.response.headers.get("location"),
          "/login?error=invalid",
        );
      assert.deepEqual([...result.values], initialCookies);
      assert.deepEqual(result.deleted, []);
      assert.deepEqual(result.saved, []);
    }
  }
});

test("each role requires all of its configuration without disabling the other role", async (context) => {
  configure(context);
  for (const prefix of ["USER", "ADMIN"]) {
    for (const suffix of [
      "PORTAL_USERNAME",
      "PORTAL_PASSWORD",
      "SESSION_SECRET",
    ]) {
      const key = `${prefix}_${suffix}`;
      const original = process.env[key];
      for (const missing of [undefined, ""]) {
        if (missing === undefined) delete process.env[key];
        else process.env[key] = missing;
        for (const [role, username, password, destination] of [
          ["USER", "staff-test", "test-only", "/orders"],
          ["ADMIN", "admin-test", "admin-only", "/admin"],
        ]) {
          const result = await submitLogin(username, password);
          assert.equal(
            result.response.headers.get("location"),
            role === prefix ? "/login?error=invalid" : destination,
            key,
          );
          assert.equal(result.saved.length, role === prefix ? 0 : 1);
        }
      }
      process.env[key] = original;
    }
  }
});

test("login throttling is shared across endpoints and resets on success or window expiry", async (context) => {
  configure(context);
  let now = Date.now();
  context.mock.method(Date, "now", () => now);
  const client = randomUUID();
  const legacy = { handler: legacyLoginPost, path: "/api/admin/login", client };
  const failure = () => submitLogin("admin-test", "wrong", legacy);
  for (let attempt = 0; attempt < 4; attempt++) await failure();
  assert.equal(
    (
      await submitLogin("staff-test", "test-only", { client })
    ).response.headers.get("location"),
    "/orders",
  );
  for (let attempt = 0; attempt < 4; attempt++) await failure();
  assert.equal(
    (
      await submitLogin("admin-test", "admin-only", legacy)
    ).response.headers.get("location"),
    "/admin",
  );
  for (let attempt = 0; attempt < 5; attempt++) await failure();
  now += 899999;
  for (const options of [{ client }, legacy]) {
    const result = await submitLogin("admin-test", "admin-only", options);
    assert.equal(
      result.response.headers.get("location"),
      "/login?error=ratelimited",
    );
    assert.deepEqual(result.saved, []);
  }
  assert.equal(
    (await submitLogin("admin-test", "admin-only")).response.headers.get(
      "location",
    ),
    "/admin",
  );
  now += 1;
  assert.equal(
    (
      await submitLogin("admin-test", "admin-only", legacy)
    ).response.headers.get("location"),
    "/admin",
  );
});

test("both login routes accept credential length limits and distinguish equal usernames by password", async (context) => {
  configure(context);
  process.env.USER_PORTAL_USERNAME = "account".padEnd(100, "x");
  process.env.ADMIN_PORTAL_USERNAME = process.env.USER_PORTAL_USERNAME;
  process.env.USER_PORTAL_PASSWORD = "manager".padEnd(1024, "x");
  process.env.ADMIN_PORTAL_PASSWORD = "admin".padEnd(1024, "x");
  for (const options of [
    {},
    { handler: legacyLoginPost, path: "/api/admin/login" },
  ]) {
    for (const [password, destination] of [
      [process.env.USER_PORTAL_PASSWORD, "/orders"],
      [process.env.ADMIN_PORTAL_PASSWORD, "/admin"],
    ]) {
      const result = await submitLogin(
        process.env.USER_PORTAL_USERNAME,
        password,
        options,
      );
      assert.equal(result.response.status, 303);
      assert.equal(result.response.headers.get("location"), destination);
      assert.equal(result.saved.length, 1);
    }
  }
});

test("sessions issued through shared login expire at fifteen minutes and reject tampering or key rotation", async (context) => {
  configure(context);
  const issuedAt = Math.floor(Date.now() / 1000) * 1000;
  let now = issuedAt;
  context.mock.method(Date, "now", () => now);
  const manager = await submitLogin("staff-test", "test-only");
  const admin = await submitLogin("admin-test", "admin-only");
  const managerToken = manager.values.get(USER_SESSION_COOKIE).value;
  const adminToken = admin.values.get(SESSION_COOKIE_NAME).value;
  now = issuedAt + 899000;
  assert.equal(getUser(manager.cookies), "staff-test");
  assert.equal(verifySessionToken(adminToken), true);
  now = issuedAt + 900000;
  assert.equal(getUser(manager.cookies), null);
  assert.equal(verifySessionToken(adminToken), false);
  now = issuedAt;
  for (const token of [managerToken, adminToken]) {
    const parts = token.split(".");
    const payload = JSON.parse(
      Buffer.from(parts[0], "base64url").toString("utf8"),
    );
    payload.exp += 3600;
    const tampered = `${Buffer.from(JSON.stringify(payload)).toString("base64url")}.${parts[1]}`;
    assert.equal(getUser({ get: () => ({ value: tampered }) }), null);
    assert.equal(verifySessionToken(tampered), false);
  }
  process.env.USER_SESSION_SECRET = "rotated-manager-test-key";
  assert.equal(getUser(manager.cookies), null);
  assert.equal(verifySessionToken(adminToken), true);
  process.env.ADMIN_SESSION_SECRET = "rotated-admin-test-key";
  assert.equal(verifySessionToken(adminToken), false);
});

function mockSql(context, handler) {
  const events = [];
  const Transaction = class {
    async begin(level) {
      assert.equal(level, sql.ISOLATION_LEVEL.SERIALIZABLE);
      events.push("begin");
    }
    async commit() {
      events.push("commit");
    }
    async rollback() {
      events.push("rollback");
    }
  };
  const Request = class {
    values = {};
    input(name, type, value) {
      this.values[name] = value;
      return this;
    }
    async query(text) {
      events.push(text);
      return { recordset: await handler(text, this.values) };
    }
  };
  return {
    service: createOrderService(async () => ({}), { Transaction, Request }),
    events,
  };
}

test("staff sessions cannot authorize admin operations, even with matching signing keys", (context) => {
  const { token, cookies } = configure(context);
  assert.equal(getUser(cookies), "staff-test");
  assert.equal(getUser(anonymous), null);
  assert.equal(verifySessionToken(token), false);
  const admin = createSessionToken();
  assert.equal(getUser({ get: () => ({ value: admin }) }), null);
  const request = new Request("https://portal.example/api/orders", {
    headers: { Origin: "https://portal.example" },
  });
  assert.equal(authorizeUserMutation(request, cookies), null);
  assert.equal(authorizeAdminMutation(request, cookies).status, 401);
  assert.equal(authorizeUserMutation(request, anonymous).status, 401);
  assert.equal(
    authorizeUserMutation(
      new Request(request.url, {
        headers: { Origin: "https://other.example" },
      }),
      cookies,
    ).status,
    403,
  );
  assert.equal(getUser({ get: () => ({ value: token + "x" }) }), null);
  assert.deepEqual(userSessionCookieOptions, {
    httpOnly: true,
    secure: true,
    sameSite: "strict",
    path: "/",
    maxAge: 900,
  });
  const payload = Buffer.from(
    JSON.stringify({ role: "staff", exp: 1 }),
  ).toString("base64url");
  const signature = createHmac("sha256", process.env.USER_SESSION_SECRET)
    .update(
      JSON.stringify([
        "staff",
        process.env.USER_PORTAL_USERNAME,
        process.env.USER_PORTAL_PASSWORD,
        payload,
      ]),
    )
    .digest("base64url");
  assert.equal(
    getUser({ get: () => ({ value: `${payload}.${signature}` }) }),
    null,
  );
  process.env.USER_PORTAL_PASSWORD = "rotated";
  assert.equal(getUser(cookies), null);
});

test("staff login throttles failures and requires same-origin requests", async (context) => {
  configure(context);
  const request = new Request("https://portal.example/api/user/login", {
    headers: { "x-forwarded-for": "test-client" },
  });
  for (let attempt = 0; attempt < 5; attempt++)
    assert.equal(
      checkUserCredentials(request, "staff-test", "wrong"),
      "invalid",
    );
  assert.equal(
    checkUserCredentials(request, "staff-test", "test-only"),
    "ratelimited",
  );
  const now = Date.now();
  context.mock.method(Date, "now", () => now + 901000);
  assert.equal(
    checkUserCredentials(request, "staff-test", "test-only"),
    "success",
  );
  const { POST } =
    await import("../apps/pawton-manufacturing/src/pages/api/user/login.js");
  assert.equal((await POST({ request, cookies: anonymous })).status, 403);
});

test("staff sign-in clears admin cookies and logout clears only the staff session", async (context) => {
  configure(context);
  const { POST } =
    await import("../apps/pawton-manufacturing/src/pages/api/user/login.js");
  const deleted = [];
  let saved;
  const cookies = {
    delete: (name) => deleted.push(name),
    set: (name, value) => {
      saved = { name, value };
    },
  };
  const request = new Request("https://portal.example/api/user/login", {
    method: "POST",
    headers: { Origin: "https://portal.example" },
    body: new URLSearchParams({
      username: "staff-test",
      password: "test-only",
    }),
  });
  assert.equal(
    await POST({ request, cookies, redirect: (path) => path }),
    "/orders",
  );
  assert.equal(saved.name, USER_SESSION_COOKIE);
  assert.ok(deleted.includes("dojo_admin_session"));
  assert.ok(deleted.includes("dojo_admin_rotated_secret"));
  const logout =
    await import("../apps/pawton-manufacturing/src/pages/api/user/logout.js");
  deleted.length = 0;
  assert.equal(
    await logout.POST({
      request,
      cookies: { ...cookies, get: () => ({ value: saved.value }) },
      redirect: (path) => path,
    }),
    "/login",
  );
  assert.deepEqual(deleted, [USER_SESSION_COOKIE]);
});

test("draft validation ignores submitted prices and rejects invalid products, dates, and quantities", () => {
  assert.deepEqual(validateDraft(draft()).lines, [{ itemId: 3, quantity: 2 }]);
  for (const quantity of [0, -1, 1.2, 10001, "1 OR 1=1"])
    assert.throws(() =>
      validateDraft({ ...draft(), lines: [{ itemId: 3, quantity }] }),
    );
  for (const deliveryDate of ["", "invalid", "2026-02-30"])
    assert.throws(() => validateDraft({ ...draft(), deliveryDate }));
  assert.throws(() => validateDraft({ ...draft(), lines: [] }));
  assert.throws(() =>
    validateDraft({
      ...draft(),
      lines: [
        { itemId: 3, quantity: 1 },
        { itemId: 3, quantity: 1 },
      ],
    }),
  );
  assert.throws(() => validateDraft({ ...draft(), notes: "x".repeat(1001) }));
});

test("draft creation uses a transaction and catalog prices, and rolls back a failed line", async (context) => {
  let failLine = false;
  const { service, events } = mockSql(context, async (text, values) => {
    if (text.includes("WHERE OrderNumber =")) return [];
    if (text.includes("AS Customers")) return [{ Customers: 1, Warehouses: 1 }];
    if (text.includes("OUTPUT INSERTED.SalesOrderID")) {
      assert.equal(values.owner, "staff-test");
      return [{ SalesOrderID: 42 }];
    }
    if (text.includes("OUTPUT INSERTED.SODetailID")) {
      assert.match(text, /ListPrice FROM Items/);
      assert.equal(values.quantity, 2);
      assert.equal(values.price, undefined);
      return failLine ? [] : [{ SODetailID: 1 }];
    }
    return [];
  });
  assert.equal(await service.save(draft(), "staff-test"), 42);
  assert.equal(events.at(-1), "commit");
  assert.ok(events.some((text) => text.includes("SUM(LineTotal)")));
  failLine = true;
  events.length = 0;
  await assert.rejects(
    service.save(draft(), "staff-test"),
    /no longer available/,
  );
  assert.equal(events.at(-1), "rollback");
  assert.ok(!events.includes("commit"));
});

test("duplicate create submissions return the existing owned order without inserting", async (context) => {
  const { service, events } = mockSql(context, async (text, values) => {
    assert.match(text, /CreatedBy = @owner/);
    assert.equal(values.owner, "staff-test");
    return [{ SalesOrderID: 42 }];
  });
  assert.equal(await service.save(draft(), "staff-test"), 42);
  assert.equal(events.length, 3);
  assert.equal(events.at(-1), "commit");
});

test("ownership, draft state, and revision are enforced before order writes", async (context) => {
  let order = null;
  const { service, events } = mockSql(context, async (text, values) => {
    assert.match(text, /CreatedBy = @owner/);
    assert.equal(values.owner, "staff-test");
    return order ? [order] : [];
  });
  await assert.rejects(
    service.save(draft(), "staff-test", 42, "v1"),
    (error) => error.status === 404,
  );
  order = { SalesOrderID: 42, Status: "Confirmed", Revision: "v1" };
  await assert.rejects(
    service.save(draft(), "staff-test", 42, "v1"),
    (error) => error.status === 409,
  );
  order = { ...order, Status: "Draft", Revision: "v2" };
  await assert.rejects(
    service.transition(42, "staff-test", "confirm", "v1"),
    (error) => error.status === 409,
  );
  assert.equal(
    events.filter((text) =>
      /INSERT INTO|UPDATE SalesOrder|DELETE FROM/.test(text),
    ).length,
    0,
  );
});

test("confirm and cancel operate on drafts without inventory or production writes", async (context) => {
  const { service, events } = mockSql(context, async (text) => {
    if (text.includes("CONVERT(varchar"))
      return [{ SalesOrderID: 42, Status: "Draft", Revision: "v1" }];
    if (text.includes("COUNT(*)")) return [{ Count: 1 }];
    return [];
  });
  assert.equal(await service.transition(42, "staff-test", "confirm", "v1"), 42);
  assert.equal(await service.transition(42, "staff-test", "cancel", "v1"), 42);
  assert.doesNotMatch(events.join("\n"), /Inventory|ProductionOrder/);
});

test("order API rejects anonymous/admin-only/cross-origin requests before writing", async (context) => {
  const { cookies } = configure(context);
  context.mock.method(orders, "save", () => {
    throw new Error("Must not write");
  });
  const { POST } =
    await import("../apps/pawton-manufacturing/src/pages/api/orders.js");
  const request = (origin) =>
    new Request("https://portal.example/api/orders", {
      method: "POST",
      headers: { Origin: origin, Accept: "application/json" },
      body: new URLSearchParams(),
    });
  assert.equal(
    (
      await POST({
        request: request("https://portal.example"),
        cookies: anonymous,
      })
    ).status,
    401,
  );
  assert.equal(
    (await POST({ request: request("https://other.example"), cookies })).status,
    403,
  );
  const admin = createSessionToken();
  assert.equal(
    (
      await POST({
        request: request("https://portal.example"),
        cookies: { get: () => ({ value: admin }) },
      })
    ).status,
    401,
  );
});

test("order pages require staff authentication and order code uses no admin connection", async () => {
  const form = await readFile(
    new URL(
      "../apps/pawton-manufacturing/src/components/OrderForm.astro",
      import.meta.url,
    ),
    "utf8",
  );
  assert.match(form, /fetch\(form.getAttribute\('action'\)/);
  assert.doesNotMatch(form, /fetch\(form.action/);
  for (const name of ["index", "new", "[id]"]) {
    const source = await readFile(
      new URL(
        `../apps/pawton-manufacturing/src/pages/orders/${name}.astro`,
        import.meta.url,
      ),
      "utf8",
    );
    assert.match(source, /getUser\(Astro.cookies\)/);
    assert.match(source, /Astro.redirect\('\/login'\)/);
  }
  const service = await readFile(
    new URL("../apps/pawton-manufacturing/src/lib/orders.mjs", import.meta.url),
    "utf8",
  );
  assert.match(service, /from "\.\/db.mjs"/);
  assert.doesNotMatch(service, /adminDb|SQL_ADMIN|CONTROL SERVER/);
});
