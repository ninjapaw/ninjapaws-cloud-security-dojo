import { DefaultAzureCredential } from "@azure/identity";
import { defenderTarget } from "./defenderStatus.mjs";
import {
  LogsQueryClient,
  LogsQueryResultStatus,
} from "@azure/monitor-query-logs";

// Confirms, independently of the SQL connection the admin actions themselves used, that an
// sa enable/disable/rotate actually reached the Windows Application log and was forwarded to the
// standardized log-np-sentinel-centralus workspace -- the same pipeline documented in the
// repository README (AMA -> Data Collection Rule -> workspace). Authenticates with the Web App's
// own system-assigned managed identity (Log Analytics Reader, read-only), never a stored secret.
let cachedClient;

function getClient() {
  if (!cachedClient) {
    cachedClient = new LogsQueryClient(new DefaultAzureCredential());
  }
  return cachedClient;
}

export function isAuditLogConfigured() {
  return Boolean(process.env.LOG_ANALYTICS_WORKSPACE_ID);
}

function tableToObjects(table) {
  const columnNames = table.columnDescriptors.map((c) => c.name);
  return table.rows.map((row) =>
    Object.fromEntries(row.map((value, i) => [columnNames[i], value])),
  );
}

function extractField(renderedDescription, fieldName) {
  const match = new RegExp(
    `(?:^|\\s)${fieldName}:([\\s\\S]*?)(?=\\s+[A-Za-z_][A-Za-z0-9_]*:|$)`,
    "i",
  ).exec(renderedDescription ?? "");
  if (!match) {
    return null;
  }
  const raw = match[1].trim();
  return raw.length > 0 ? raw : null;
}

const operationRules = [
  { label: "Login enabled", action: "LGEA" },
  { label: "Login disabled", action: "LGDA" },
  { label: "Login password changed", action: "PWR" },
  { label: "Audit configuration changed", action: "AUSC" },
  {
    label: "Login enabled",
    pattern: /^ALTER\s+LOGIN\s+(?:\[(?:[^\]]|\]\])+\]|\S+)\s+ENABLE\b/i,
  },
  {
    label: "Login disabled",
    pattern: /^ALTER\s+LOGIN\s+(?:\[(?:[^\]]|\]\])+\]|\S+)\s+DISABLE\b/i,
  },
  {
    label: "Login password changed",
    pattern: /^ALTER\s+LOGIN\s+.*?\s+WITH\s+PASSWORD\b/i,
  },
  { label: "Login renamed", pattern: /^ALTER\s+LOGIN\s+.*?\s+WITH\s+NAME\b/i },
  {
    label: "Audit configuration changed",
    pattern: /^(CREATE|ALTER|DROP)\s+(SERVER|DATABASE)\s+AUDIT\b/i,
  },
  { label: "Login succeeded", action: "LGIS", eventIds: [18453, 18454] },
  { label: "Login failed", action: "LGIF", eventIds: [18456] },
];
const otherOperation = "Other SQL audit";
export const auditOperationFilters = [
  { value: "hide-login-succeeded", label: "Hide Login succeeded" },
  { value: "all", label: "All operations" },
  ...[...new Set(operationRules.map((rule) => rule.label)), otherOperation].map(
    (label) => ({ value: label, label }),
  ),
];

export function normalizeAuditFilter(value) {
  return auditOperationFilters.some((filter) => filter.value === value)
    ? value
    : "hide-login-succeeded";
}

function getAuditOperation({ ActionId, Statement, EventID }) {
  return (
    operationRules.find(
      (rule) =>
        (rule.action && rule.action === ActionId) ||
        rule.eventIds?.includes(EventID) ||
        rule.pattern?.test(Statement),
    )?.label ?? otherOperation
  );
}

function operationFilterQuery(value) {
  const filter = normalizeAuditFilter(value);
  if (filter === "all") return "";
  const cases = operationRules.map((rule) => {
    const conditions = [];
    if (rule.action)
      conditions.push(`AuditAction == ${JSON.stringify(rule.action)}`);
    if (rule.eventIds)
      conditions.push(`EventID in (${rule.eventIds.join(", ")})`);
    if (rule.pattern)
      conditions.push(
        `isnotempty(extract(${JSON.stringify(`(?i)${rule.pattern.source}`)}, 0, AuditStatement))`,
      );
    return `${conditions.join(" or ")}, ${JSON.stringify(rule.label)}`;
  });
  return String.raw`
    | extend AuditAction = trim(@"\s+", extract(@"(?is)(?:^|\s)action_id:(.*?)(?:\s+[a-z_][a-z0-9_]*:|$)", 1, RenderedDescription))
    | extend AuditStatement = trim(@"\s+", extract(@"(?is)(?:^|\s)statement:(.*?)(?:\s+[a-z_][a-z0-9_]*:|$)", 1, RenderedDescription))
    | extend Operation = case(${cases.join(", ")}, ${JSON.stringify(otherOperation)})
    | where Operation ${filter === "hide-login-succeeded" ? `!= "Login succeeded"` : `== ${JSON.stringify(filter)}`}
  `;
}

function formatAuditSummary(event) {
  const status =
    event.Success === true
      ? "success"
      : event.Success === false
        ? "failed"
        : "unknown";

  const summaryParts = [];
  summaryParts.push(event.Operation);
  if (event.TargetLogin) summaryParts.push(`target: ${event.TargetLogin}`);
  else if (event.LoginName) summaryParts.push(event.LoginName);
  if (event.ClientIp) summaryParts.push(event.ClientIp);
  summaryParts.push(status);
  return summaryParts.join(" • ");
}

export function parseAuditEvent(event) {
  const succeeded = extractField(
    event.RenderedDescription,
    "succeeded",
  )?.toLowerCase();
  const parsed = {
    ...event,
    ActionId: extractField(event.RenderedDescription, "action_id"),
    Statement: extractField(event.RenderedDescription, "statement"),
    Success: succeeded === "true" ? true : succeeded === "false" ? false : null,
    LoginName:
      extractField(event.RenderedDescription, "server_principal_name") ||
      extractField(event.RenderedDescription, "target_server_principal_name") ||
      extractField(event.RenderedDescription, "session_server_principal_name"),
    TargetLogin: extractField(
      event.RenderedDescription,
      "target_server_principal_name",
    ),
    ClientIp:
      extractField(event.RenderedDescription, "client_ip") ||
      extractField(event.RenderedDescription, "address"),
  };
  parsed.Operation = getAuditOperation(parsed);
  if (
    !parsed.TargetLogin &&
    [
      "Login enabled",
      "Login disabled",
      "Login password changed",
      "Login renamed",
    ].includes(parsed.Operation)
  ) {
    parsed.TargetLogin = extractField(event.RenderedDescription, "object_name");
  }
  parsed.Summary = formatAuditSummary(parsed);
  return parsed;
}

// SQL Server audit records that matter for the admin portal are the server-principal change group
// and the login audit event stream.
export async function getRecentSaAuditEvents(
  minutesAgo = 15,
  take = 25,
  {
    record = "1",
    until = "",
    operation = "hide-login-succeeded",
    client = null,
  } = {},
) {
  const minutes =
    Number.isInteger(minutesAgo) && minutesAgo > 0 && minutesAgo <= 1440
      ? minutesAgo
      : 15;
  const pageSize =
    Number.isInteger(take) && take > 0 && take <= 100 ? take : 25;
  const requestedRecord = Number(record);
  const safeRecord =
    Number.isSafeInteger(requestedRecord) && requestedRecord > 0
      ? requestedRecord
      : 1;
  const requestedEnd = Date.parse(until);
  const endTime = new Date(
    Number.isFinite(requestedEnd)
      ? Math.min(requestedEnd, Date.now())
      : Date.now(),
  );
  const startTime = new Date(endTime.getTime() - minutes * 60000);
  const windowEnd = endTime.toISOString();
  if (!isAuditLogConfigured()) {
    return { configured: false, events: [], total: 0, start: 0, windowEnd };
  }
  const workspaceId = process.env.LOG_ANALYTICS_WORKSPACE_ID;
  const vmId = defenderTarget().vmId;
  // Freeze event and ingestion time together so late arrivals do not shift subsequent pages.
  const kustoQuery = `
    Event
    | where TimeGenerated > datetime(${startTime.toISOString()}) and TimeGenerated <= datetime(${windowEnd})
    | where ingestion_time() <= datetime(${windowEnd})
    ${vmId ? `| where _ResourceId =~ '${vmId.replaceAll("'", "''")}'` : ""}
    | where EventLog == 'Application'
    | where Source == 'MSSQLSERVER'
    | where EventID in (33205, 18453, 18454, 18456)
    ${operationFilterQuery(operation)}
    | project TimeGenerated, EventLog, Source, EventID, EventLevelName, Computer, RenderedDescription
  `;
  const queryClient = client ?? getClient();
  const runQuery = async (queryText) => {
    const result = await queryClient.queryWorkspace(workspaceId, queryText, {
      startTime,
      endTime,
    });
    if (result.status !== LogsQueryResultStatus.Success) {
      throw new Error(
        result.partialError?.message ?? "Log Analytics query failed.",
      );
    }
    return result.tables[0] ? tableToObjects(result.tables[0]) : [];
  };
  const counts = await runQuery(`${kustoQuery}\n| count`);
  const total = Number(counts[0]?.Count ?? 0);
  const lastStart = Math.max(0, Math.floor((total - 1) / pageSize) * pageSize);
  const start = Math.min(
    lastStart,
    Math.floor((safeRecord - 1) / pageSize) * pageSize,
  );
  const rows = total
    ? await runQuery(`${kustoQuery}
    | order by TimeGenerated desc, Computer asc, EventID asc, RenderedDescription asc
    | serialize RowNumber = row_number()
    | where RowNumber > ${start} and RowNumber <= ${start + pageSize}
    | project-away RowNumber`)
    : [];
  return {
    configured: true,
    events: rows.map(parseAuditEvent),
    total,
    start,
    windowEnd,
  };
}
