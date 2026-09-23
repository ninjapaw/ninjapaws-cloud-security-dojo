import { DefaultAzureCredential } from "@azure/identity";
import {
  LogsQueryClient,
  Durations,
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
    `${fieldName}:(.+?)(?=\\s+[A-Za-z_][A-Za-z0-9_]*:|$)`,
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
  const succeeded = extractField(event.RenderedDescription, "succeeded");
  const status = succeeded
    ? `${succeeded.toLowerCase() === "true" ? "success" : "failed"}`
    : "unknown";

  const summaryParts = [];
  if (actionId) summaryParts.push(actionId);
  if (loginName) summaryParts.push(loginName);
  if (databaseName) summaryParts.push(databaseName);
  if (clientIp) summaryParts.push(clientIp);
  summaryParts.push(status);
  return summaryParts.join(" • ");
}

// SQL Server audit records that matter for the admin portal are the server-principal change group
// and the login audit event stream. The generic LGIS entries are useful for noise reduction, but the
// actions we care about are login enable/disable/password change, so filter to the relevant event
// IDs and parse the key-value schema into a readable summary rather than dumping the whole XML blob.
export async function getRecentSaAuditEvents(minutesAgo = 15, take = 20) {
  if (!isAuditLogConfigured()) {
    return { configured: false, events: [] };
  }
  const workspaceId = process.env.LOG_ANALYTICS_WORKSPACE_ID;
  const kustoQuery = `
    Event
    | where TimeGenerated > ago(${minutesAgo}m)
    | where Source == "MSSQLSERVER"
    | where EventID in (33205, 18453, 18454, 18456)
    | extend ActionId = extract(@"action_id:(\S+)", 1, RenderedDescription)
    | extend Success = tostring(extract(@"succeeded:(true|false)", 1, RenderedDescription))
    | extend LoginName = coalesce(
        extract(@"server_principal_name:(.+?)(?=\s+[A-Za-z_][A-Za-z0-9_]*:|$)", 1, RenderedDescription),
        extract(@"target_server_principal_name:(.+?)(?=\s+[A-Za-z_][A-Za-z0-9_]*:|$)", 1, RenderedDescription),
        extract(@"session_server_principal_name:(.+?)(?=\s+[A-Za-z_][A-Za-z0-9_]*:|$)", 1, RenderedDescription)
      )
    | extend ClientIp = coalesce(
        extract(@"client_ip:(.+?)(?=\s+[A-Za-z_][A-Za-z0-9_]*:|$)", 1, RenderedDescription),
        extract(@"address:(.+?)(?=\s+[A-Za-z_][A-Za-z0-9_]*:|$)", 1, RenderedDescription)
      )
    | project TimeGenerated, EventID, EventLevelName, Computer, RenderedDescription, ActionId, Success, LoginName, ClientIp
    | order by TimeGenerated desc
    | take ${take}
  `;
  const result = await getClient().queryWorkspace(workspaceId, kustoQuery, {
    duration: Durations.oneHour,
  });
  if (result.status === LogsQueryResultStatus.Success) {
    const table = result.tables[0];
    const events = table ? tableToObjects(table) : [];
    for (const event of events) {
      event.ActionId =
        event.ActionId ?? extractField(event.RenderedDescription, "action_id");
      event.Success = event.Success
        ? event.Success.toLowerCase() === "true"
        : (
            extractField(event.RenderedDescription, "succeeded") || "unknown"
          ).toLowerCase() === "true";
      event.LoginName =
        event.LoginName ??
        extractField(event.RenderedDescription, "server_principal_name") ??
        extractField(event.RenderedDescription, "target_server_principal_name");
      event.ClientIp =
        event.ClientIp ??
        extractField(event.RenderedDescription, "client_ip") ??
        extractField(event.RenderedDescription, "address");
      event.Summary = formatAuditSummary(event);
    }
    return { configured: true, events };
  }
  throw new Error(
    result.partialError?.message ?? "Log Analytics query failed.",
  );
}
