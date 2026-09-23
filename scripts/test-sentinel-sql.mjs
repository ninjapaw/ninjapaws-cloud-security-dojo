import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";

const root = new URL("../", import.meta.url);
const parser = readFileSync(
  new URL("infra/sentinel-sql-solution/queries/DojoSqlAudit.kql", root),
  "utf8",
);
const bicep = readFileSync(
  new URL("infra/sentinel-sql-solution/main.bicep", root),
  "utf8",
);
const arm = JSON.parse(
  readFileSync(new URL("infra/sentinel-sql-solution/main.json", root), "utf8"),
);
const filters = [
  ...bicep.matchAll(/filter: (?:replace\()?'''([\s\S]*?)'''/g),
].map((match) => match[1].replace("FAILED_LOGIN_THRESHOLD", "5"));

assert.equal(filters.length, 4);
assert(
  bicep.includes("let DojoSqlAuditInline ="),
  "Inline rules must not shadow the published workspace parser",
);
assert.equal(arm.variables.detections.length, 4);
assert.equal(
  Object.values(arm.variables)
    .find((value) => typeof value === "string" && value.startsWith("Event"))
    .replace(/\r\n/g, "\n")
    .trim(),
  parser.replace(/\r\n/g, "\n").trim(),
  "Recompile the ARM sibling after editing the parser",
);
assert(
  arm.resources.every((resource) =>
    [
      "Microsoft.OperationalInsights/workspaces/savedSearches",
      "Microsoft.SecurityInsights/alertRules",
    ].includes(resource.type),
  ),
  "Content must not alter ingestion, onboarding, or the workspace",
);
const analytics = arm.resources.find((resource) =>
  resource.type.endsWith("/alertRules"),
);
assert.equal(analytics.kind, "Scheduled");
assert.equal(analytics.properties.queryFrequency, "PT5M");
assert.equal(analytics.properties.queryPeriod, "PT1H");
assert.equal(analytics.properties.suppressionEnabled, false);
assert(
  !parser.includes("(?="),
  "KQL parsing must not depend on unsupported lookahead",
);
assert(
  !parser.includes("(?<="),
  "KQL parsing must not depend on unsupported lookbehind",
);
assert(!parser.split("| project ").at(-1).includes("Statement"));
assert(!parser.split("| project ").at(-1).includes("RenderedDescription"));
console.log(
  "Sentinel content contract checks passed (4 rules, scoped parser, no ingestion/onboarding resources).",
);

const workspaceIndex = process.argv.indexOf("--workspace");
if (workspaceIndex === -1) {
  console.log(
    "Live KQL tests skipped. Supply --workspace <customer-id> to run read-only fixtures against Log Analytics.",
  );
  process.exit(0);
}
const workspaceId = process.argv[workspaceIndex + 1];
assert.match(workspaceId ?? "", /^[0-9a-f-]{36}$/i);
const requireApp = createRequire(
  new URL("apps/pawton-manufacturing/package.json", root),
);
const { LogsQueryClient, LogsQueryResultStatus } = requireApp(
  "@azure/monitor-query-logs",
);
const { AzureCliCredential } = requireApp("@azure/identity");
const client = new LogsQueryClient(new AzureCliCredential());

function audit({
  action = "AL",
  actor = "portal-service",
  target = "renamed_admin",
  sid = "01",
  statement = "",
  succeeded = "true",
  sequence = "test",
  actorSid = "abcd",
} = {}) {
  return `Audit event: audit_schema_version:1 event_time:2026-09-23 15:00:00.1234567 sequence_number:1 action_id:${action} succeeded:${succeeded} client_ip:10.20.3.254 permission_bitmask:0 sequence_group_id:${sequence} session_server_principal_name:session-actor server_principal_name:${actor} server_principal_sid:${actorSid} database_principal_name: target_server_principal_name:${target} target_server_principal_sid:${sid} target_database_principal_name: server_instance_name:fixture database_name: schema_name: object_name: statement:${statement} additional_information:<action_info/> user_defined_information: application_name:node-mssql connection_id:test`;
}

const fixtures = [
  {
    name: "enable",
    description: audit({
      action: "LGEA",
      statement: "ALTER LOGIN [renamed_admin] ENABLE;",
    }),
    operation: "Login enabled",
    outcome: "Succeeded",
  },
  {
    name: "disable",
    description: audit({
      action: "LGDA",
      statement: "ALTER LOGIN [renamed_admin] DISABLE;",
    }),
    operation: "Login disabled",
    outcome: "Succeeded",
  },
  {
    name: "fallback-enable",
    description: audit({
      statement: "ALTER LOGIN [admin with spaces] ENABLE;",
    }),
    operation: "Login enabled",
    outcome: "Succeeded",
  },
  {
    name: "fallback-disable",
    description: audit({ statement: "ALTER LOGIN [renamed_admin] DISABLE;" }),
    operation: "Login disabled",
    outcome: "Succeeded",
  },
  {
    name: "rename",
    description: audit({
      statement: "ALTER LOGIN [renamed_admin] WITH NAME = [other_admin];",
    }),
    operation: "Login renamed",
    outcome: "Succeeded",
  },
  {
    name: "password",
    description: audit({
      statement: "ALTER LOGIN [renamed_admin] WITH PASSWORD = ***;",
    }),
    operation: "Login password changed",
    outcome: "Succeeded",
  },
  {
    name: "service-login",
    description: audit({
      action: "LGIS",
      actor: "NT SERVICE\\SQLSERVERAGENT",
      target: "",
      sid: "",
      statement: "-- network protocol: LPC\nset ansi_nulls on",
    }),
    operation: "Login succeeded",
    outcome: "Succeeded",
  },
  {
    name: "admin-login",
    description: audit({
      action: "LGIS",
      actor: "renamed_admin",
      actorSid: "01",
      target: "",
      sid: "",
    }),
    operation: "Login succeeded",
    outcome: "Succeeded",
  },
  {
    name: "unknown-outcome",
    description: audit({ succeeded: "", target: "", sid: "" }),
    operation: "Other SQL audit",
    outcome: "Unknown",
  },
  {
    name: "audit-change",
    description: audit({
      statement: "ALTER SERVER AUDIT [training] WITH (STATE = OFF);",
    }),
    operation: "Audit configuration changed",
    outcome: "Succeeded",
  },
  {
    name: "audit-state",
    description: audit({ action: "AUSC" }),
    operation: "Audit configuration changed",
    outcome: "Succeeded",
  },
  {
    name: "password-action",
    description: audit({ action: "PWR" }),
    operation: "Login password changed",
    outcome: "Succeeded",
  },
  {
    name: "failed-change",
    description: audit({ action: "LGDA", succeeded: "false" }),
    operation: "Login disabled",
    outcome: "Failed",
  },
  {
    name: "windows-login",
    eventId: 18453,
    description:
      "Login succeeded for user 'NT SERVICE\\SQLTELEMETRY'. [CLIENT: <local machine>]",
    operation: "Login succeeded",
    outcome: "Succeeded",
  },
  {
    name: "sql-login",
    eventId: 18454,
    description: "Login succeeded for user 'futon_app'. [CLIENT: 10.20.3.254]",
    operation: "Login succeeded",
    outcome: "Succeeded",
  },
  {
    name: "instance-failure",
    eventId: 18456,
    description: "Login failed for user 'sa'. [CLIENT: 10.20.3.254]",
    operation: "Login failed",
    outcome: "Failed",
  },
];
for (let attempt = 0; attempt < 5; attempt += 1) {
  fixtures.push({
    name: "failure-burst",
    description: audit({
      action: "LGIF",
      actor: "test-login",
      succeeded: "false",
      sequence: `attempt-${attempt}`,
    }),
    operation: "Login failed",
    outcome: "Failed",
  });
}

const rows = [
  ...fixtures,
  fixtures[0],
  { ...fixtures[0], name: "out-of-scope", resourceId: "/other-vm" },
]
  .map((fixture) =>
    [
      fixture.name,
      fixture.eventId ?? 33205,
      fixture.resourceId ?? "/fixture-vm",
      fixture.description,
    ]
      .map((value) => JSON.stringify(value))
      .join(", "),
  )
  .join(",\n");
const fixtureQuery = `let Event = datatable(Computer:string, EventID:int, _ResourceId:string, RenderedDescription:string)[${rows}]
| extend TimeGenerated = now() - 1m, EventLog = 'Application', Source = 'MSSQLSERVER';
let DojoSqlAuditFixture = (VmResourceId:string) { ${parser} };
DojoSqlAuditFixture('/fixture-vm')`;

async function queryRows(query) {
  const result = await client.queryWorkspace(workspaceId, query, {
    duration: "P1D",
  });
  assert.equal(
    result.status,
    LogsQueryResultStatus.Success,
    result.partialError?.message,
  );
  const table = result.tables[0];
  const names = table.columnDescriptors.map((column) => column.name);
  return table.rows.map((row) =>
    Object.fromEntries(row.map((value, index) => [names[index], value])),
  );
}

const parsed = await queryRows(fixtureQuery);
assert.equal(
  parsed.length,
  fixtures.length,
  "Drop out-of-scope rows and exact duplicate ingestion",
);
for (const fixture of fixtures) {
  const actual = parsed.find((row) => row.Computer === fixture.name);
  assert(actual, fixture.name);
  assert.equal(actual.Operation, fixture.operation, fixture.name);
  assert.equal(actual.Outcome, fixture.outcome, fixture.name);
}
assert.equal(
  parsed.find((row) => row.Computer === "service-login").TargetLogin,
  "",
);
assert.equal(
  parsed.find((row) => row.Computer === "service-login").Actor,
  "NT SERVICE\\SQLSERVERAGENT",
);
assert.equal(
  parsed.find((row) => row.Computer === "enable").IsBuiltInAdmin,
  true,
);
assert.equal(
  parsed.find((row) => row.Computer === "admin-login").IsBuiltInAdminActor,
  true,
);
assert.equal(
  parsed.find((row) => row.Computer === "unknown-outcome").Succeeded,
  null,
);
console.log(
  `Live KQL parser: ${fixtures.length} fixtures passed, including empty fields, renamed sa, legacy IDs and deduplication.`,
);

const expectedComputers = [
  [
    "enable",
    "disable",
    "fallback-enable",
    "fallback-disable",
    "rename",
    "password",
    "password-action",
    "failed-change",
  ],
  ["admin-login"],
  ["failure-burst"],
  ["audit-change", "audit-state"],
];
for (const [index, filter] of filters.entries()) {
  const results = await queryRows(
    `${fixtureQuery}\n| extend IngestedAt = now()\n${filter}`,
  );
  assert.deepEqual(
    results.map((row) => row.Computer).sort(),
    expectedComputers[index].sort(),
  );
}
const stale = await queryRows(
  `${fixtureQuery}\n| extend IngestedAt = ago(10m)\n${filters[0]}`,
);
assert.equal(
  stale.length,
  0,
  "A scheduled change rule should not re-alert on old ingestion",
);
console.log(
  "Live KQL: all four detection filters and stale-ingestion exclusion passed. No Azure resources or SQL logins changed.",
);

const vmIndex = process.argv.indexOf("--vm-resource-id");
if (vmIndex !== -1) {
  const vmResourceId = process.argv[vmIndex + 1];
  assert(vmResourceId?.startsWith("/subscriptions/"));
  const encodedVm = Buffer.from(vmResourceId).toString("base64");
  const counts =
    await queryRows(`let VmResourceId = base64_decode_tostring('${encodedVm}'); ${parser}
| where TimeGenerated > ago(24h)
| summarize Events=count(), LastEvent=max(TimeGenerated) by EventID, ActionId, Operation
| order by Events desc`);
  console.table(counts);
  console.log(
    counts.length
      ? "Live SQL Event rows parsed; counts do not prove every admin operation was audited."
      : "No live SQL Event rows found for this VM in the last 24 hours.",
  );
}
