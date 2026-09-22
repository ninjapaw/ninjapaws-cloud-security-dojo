import { DefaultAzureCredential } from "@azure/identity";
import { LogsQueryClient, Durations, LogsQueryResultStatus } from "@azure/monitor-query-logs";

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

// Server Audit records (event ID 33205, action_id LGEA/LGDA for sa enable/disable, among others)
// and instance-level login-audit entries (18453/18456) both land under Source "MSSQLSERVER" in
// the Windows Application log; that's the full set relevant to confirming an admin portal action.
export async function getRecentSaAuditEvents(minutesAgo = 15, take = 20) {
  if (!isAuditLogConfigured()) {
    return { configured: false, events: [] };
  }
  const workspaceId = process.env.LOG_ANALYTICS_WORKSPACE_ID;
  const kustoQuery = `
    Event
    | where TimeGenerated > ago(${minutesAgo}m)
    | where Source == "MSSQLSERVER"
    | project TimeGenerated, EventID, RenderedDescription
    | order by TimeGenerated desc
    | take ${take}
  `;
  const result = await getClient().queryWorkspace(workspaceId, kustoQuery, {
    duration: Durations.oneHour,
  });
  if (result.status === LogsQueryResultStatus.Success) {
    const table = result.tables[0];
    return { configured: true, events: table ? tableToObjects(table) : [] };
  }
  throw new Error(result.partialError?.message ?? "Log Analytics query failed.");
}
