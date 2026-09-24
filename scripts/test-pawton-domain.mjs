import assert from "node:assert/strict";
import { test } from "node:test";
import { readFile } from "node:fs/promises";
import {
  validateDomain,
  desiredRecords,
  reconcileDns,
  verifyDns,
} from "./configure-pawton-dns.mjs";

const settings = {
  domain: "pawton.example.org",
  azureHostname: "pawton-dev.azurewebsites.net",
  verificationId: "A".repeat(64),
  zoneId: "b".repeat(32),
  token: "test-token-not-to-log",
};
function cloudflare(
  initial = [],
  zone = { name: "example.org", status: "active" },
) {
  const records = structuredClone(initial);
  const writes = [];
  const fetcher = async (url, options) => {
    assert.ok(
      url.startsWith(
        `https://api.cloudflare.com/client/v4/zones/${settings.zoneId}`,
      ),
    );
    assert.equal(options.headers.Authorization, `Bearer ${settings.token}`);
    assert.equal(options.redirect, "error");
    let result;
    if (!url.includes("/dns_records")) result = zone;
    else if (options.method === "POST") {
      result = JSON.parse(options.body);
      assert.ok(!options.body.includes(settings.token));
      records.push(result);
      writes.push(result);
    } else
      result = records.filter(
        (record) => record.name === new URL(url).searchParams.get("name"),
      );
    return Response.json({
      success: true,
      result,
      result_info: { total_pages: 1 },
    });
  };
  return { records, writes, fetcher };
}

test("hostname validation rejects URLs, wildcards, injection, and unsupported certificate names", () => {
  assert.equal(validateDomain("Pawton.Example.org"), settings.domain);
  for (const value of [
    "",
    "https://pawton.example.org",
    "*.example.org",
    "a.example.org/path",
    "a.example.org:443",
    "a';print 1",
    "a_1.example.org",
    "a".repeat(65) + ".org",
  ])
    assert.throws(() => validateDomain(value));
  assert.throws(() => desiredRecords({ ...settings, verificationId: "" }));
  assert.throws(() =>
    desiredRecords({ ...settings, azureHostname: "other.example.org" }),
  );
});

test("Cloudflare dry run writes nothing and a second apply is a no-op", async () => {
  const mock = cloudflare();
  assert.deepEqual(
    (await reconcileDns(settings, mock)).map((action) => action.action),
    ["would create", "would create"],
  );
  assert.equal(mock.writes.length, 0);
  assert.deepEqual(
    (await reconcileDns(settings, { ...mock, apply: true })).map(
      (action) => action.action,
    ),
    ["created", "created"],
  );
  assert.equal(mock.writes.length, 2);
  assert.deepEqual(mock.records, desiredRecords(settings));
  assert.equal(mock.records[1].proxied, false);
  assert.deepEqual(
    (await reconcileDns(settings, { ...mock, apply: true })).map(
      (action) => action.action,
    ),
    ["found", "found"],
  );
  assert.equal(mock.writes.length, 2);
});

test("existing DNS conflicts fail before any record is written", async () => {
  const [txt, cname] = desiredRecords(settings);
  for (const conflict of [
    { ...cname, content: "other.azurewebsites.net" },
    { ...cname, proxied: true },
    { ...cname, settings: { flatten_cname: true } },
    { ...cname, type: "A", content: "192.0.2.10" },
    { ...txt, content: "B".repeat(64) },
  ]) {
    const mock = cloudflare([conflict]);
    await assert.rejects(
      reconcileDns(settings, { ...mock, apply: true }),
      /Conflicting DNS/,
    );
    assert.equal(mock.writes.length, 0);
  }
  const duplicate = cloudflare([txt, txt]);
  await assert.rejects(
    reconcileDns(settings, { ...duplicate, apply: true }),
    /Conflicting DNS/,
  );
});

test("existing equivalent DNS records are preserved, including TTL and comments", async () => {
  const [txt, cname] = desiredRecords(settings);
  const mock = cloudflare([
    {
      ...txt,
      content: `"${txt.content}"`,
      ttl: 600,
      comment: "Owned externally",
    },
    { ...cname, content: cname.content.toUpperCase() + ".", ttl: 900 },
  ]);
  await reconcileDns(settings, { ...mock, apply: true });
  assert.equal(mock.writes.length, 0);
  assert.equal(mock.records[0].ttl, 600);
});

test("wrong/inactive zones and apex domains are rejected without writes", async () => {
  for (const zone of [
    { name: "other.org", status: "active" },
    { name: settings.domain, status: "active" },
    { name: "example.org", status: "pending" },
  ]) {
    const mock = cloudflare([], zone);
    await assert.rejects(
      reconcileDns(settings, { ...mock, apply: true }),
      /selected active Cloudflare zone/,
    );
    assert.equal(mock.writes.length, 0);
  }
});

test("Cloudflare errors never include upstream bodies or credentials", async () => {
  await assert.rejects(
    reconcileDns(settings, {
      fetcher: async () =>
        Response.json(
          { success: false, errors: [{ message: settings.token }] },
          { status: 403 },
        ),
    }),
    (error) =>
      /HTTP 403/.test(error.message) && !error.message.includes(settings.token),
  );
  await assert.rejects(
    reconcileDns(settings, {
      fetcher: async () => {
        throw new Error(settings.token);
      },
    }),
    (error) => !error.message.includes(settings.token),
  );
  await assert.rejects(
    reconcileDns({ ...settings, token: "" }),
    /CLOUDFLARE_API_TOKEN/,
  );
  await assert.rejects(
    reconcileDns({ ...settings, zoneId: "bad" }),
    /CLOUDFLARE_ZONE_ID/,
  );
});

test("public DNS must match both direct CNAME and ownership TXT", async () => {
  await verifyDns(settings, {
    resolveCname: async () => [settings.azureHostname + "."],
    resolveTxt: async () => [["A".repeat(32), "A".repeat(32)]],
  });
  for (const resolver of [
    {
      resolveCname: async () => ["proxy.example.org"],
      resolveTxt: async () => [[settings.verificationId]],
    },
    {
      resolveCname: async () => [settings.azureHostname],
      resolveTxt: async () => [["wrong"]],
    },
    {
      resolveCname: async () => {
        throw new Error("ENODATA");
      },
    },
  ])
    await assert.rejects(
      verifyDns(settings, resolver),
      /Public DNS is not ready/,
    );
});

test("Bicep, lifecycle, and Astro share the custom hostname without embedding Cloudflare secrets", async () => {
  const read = (path) =>
    readFile(new URL(`../${path}`, import.meta.url), "utf8");
  const main = JSON.parse(await read("infra/sql-defender-scenario/main.json"));
  assert.equal(main.parameters.webAppCustomDomain.defaultValue, "");
  const app = main.resources.find(
    (resource) => resource.type === "Microsoft.Web/sites",
  );
  assert.equal(
    app.properties.siteConfig.appSettings.find(
      (setting) => setting.name === "PORTAL_CUSTOM_DOMAIN",
    ).value,
    "[parameters('webAppCustomDomain')]",
  );
  const domain = JSON.parse(
    await read("infra/sql-defender-scenario/custom-domain.json"),
  );
  assert.equal(domain.parameters.enableTls.defaultValue, true);
  assert.equal(domain.parameters.customDomain.maxLength, 64);
  assert.deepEqual(domain.resources.map((resource) => resource.type).sort(), [
    "Microsoft.Web/certificates",
    "Microsoft.Web/sites/hostNameBindings",
  ]);
  assert.match(
    domain.resources.find((resource) =>
      resource.type.endsWith("hostNameBindings"),
    ).properties.sslState,
    /SniEnabled/,
  );
  assert.ok(!JSON.stringify(main).includes("CLOUDFLARE_API_TOKEN"));
  assert.ok(!JSON.stringify(domain).includes("CLOUDFLARE_API_TOKEN"));
  const astro = await read("apps/pawton-manufacturing/astro.config.mjs");
  assert.match(astro, /PORTAL_CUSTOM_DOMAIN/);
  assert.match(astro, /hostname: customDomain, protocol: "https"/);
  assert.doesNotMatch(astro, /checkOrigin:\s*false/);
  const lifecycle = await read("scripts/deploy-sql-scenario.sh");
  assert.match(lifecycle, /webAppCustomDomain="\$WEB_APP_CUSTOM_DOMAIN"/);
  assert.match(lifecycle, /domain\) run_custom_domain/);
  assert.match(lifecycle, /if \[\[ "\$MANAGE_CUSTOM_DOMAIN" == true \]\]/);
  const command = await read("scripts/deploy-pawton-domain.sh");
  assert.match(command, /if \[\[ -z "\$binding_state" \]\]/);
  assert.match(command, /enableTls=false/);
  assert.match(command, /enableTls=true/);
  assert.doesNotMatch(command, /curl[^\n]*(?:--insecure| -k)/);
});
