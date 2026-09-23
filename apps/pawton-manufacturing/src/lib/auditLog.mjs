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

function formatAuditSummary(event) {
  const actionId =
    event.ActionId ?? extractField(event.RenderedDescription, "action_id");
  const loginName =
    extractField(event.RenderedDescription, "server_principal_name") ||
    extractField(event.RenderedDescription, "target_server_principal_name") ||
    extractField(event.RenderedDescription, "session_server_principal_name");
  const clientIp =
    extractField(event.RenderedDescription, "client_ip") ||
    extractField(event.RenderedDescription, "address");
  const databaseName = extractField(event.RenderedDescription, "database_name");
  const status =
    event.Success === true
      ? "success"
      : event.Success === false
        ? "failed"
        : "unknown";

  const summaryParts = [];
  if (actionId) summaryParts.push(actionId);
  if (loginName) summaryParts.push(loginName);
  if (databaseName) summaryParts.push(databaseName);
  if (clientIp) summaryParts.push(clientIp);
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
    Success: succeeded === "true" ? true : succeeded === "false" ? false : null,
    LoginName:
      extractField(event.RenderedDescription, "server_principal_name") ||
      extractField(event.RenderedDescription, "target_server_principal_name") ||
      extractField(event.RenderedDescription, "session_server_principal_name"),
    ClientIp:
      extractField(event.RenderedDescription, "client_ip") ||
      extractField(event.RenderedDescription, "address"),
  };
  parsed.Summary = formatAuditSummary(parsed);
  return parsed;
}

// SQL Server audit records that matter for the admin portal are the server-principal change group
// and the login audit event stream. Keep KQL deliberately schema-light: the Event table varies
// slightly between AMA deployments, while the JavaScript parser below can safely handle the raw
// RenderedDescription field without asking Kusto to evaluate a large set of regex expressions.
export async function getRecentSaAuditEvents(minutesAgo = 15, take = 20) {
  if (!isAuditLogConfigured()) {
    return { configured: false, events: [] };
  }
  const workspaceId = process.env.LOG_ANALYTICS_WORKSPACE_ID;
  const vmId = defenderTarget().vmId;
  const kustoQuery = `
    Event
    | where TimeGenerated > ago(${minutesAgo}m)
    ${vmId ? `| where _ResourceId =~ '${vmId.replaceAll("'", "''")}'` : ""}
    | where EventLog == 'Application'
    | where Source == 'MSSQLSERVER'
    | where EventID in (33205, 18453, 18454, 18456)
    | project TimeGenerated, EventLog, Source, EventID, EventLevelName, Computer, RenderedDescription
    | order by TimeGenerated desc
    | take ${take}
  `;
  const result = await getClient().queryWorkspace(workspaceId, kustoQuery, {
    // Use an explicit ISO 8601 interval so the request remains compatible across SDK releases.
    duration: "PT1H",
  });
  if (result.status === LogsQueryResultStatus.Success) {
    const table = result.tables[0];
    const events = table ? tableToObjects(table).map(parseAuditEvent) : [];
    return { configured: true, events };
  }
  throw new Error(
    result.partialError?.message ?? "Log Analytics query failed.",
  );
}
