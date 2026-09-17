import { isDatabaseConfigured, query } from "../../lib/db.mjs";

export async function GET() {
  let dbConnectivity = "not_configured";
  let sampleRowCount = null;

  if (isDatabaseConfigured()) {
    try {
      const rows = await query("SELECT COUNT(*) AS Count FROM Items");
      dbConnectivity = "connected";
      sampleRowCount = rows[0]?.Count ?? null;
    } catch {
      dbConnectivity = "unreachable";
    }
  }

  const payload = {
    site: "Pawton Manufacturing",
    scenario_id: "defender-sql-scenario-2",
    sample_database: "Futon Manufacturing (microsoft/sql-server-samples)",
    db_connectivity: dbConnectivity,
    sample_item_count: sampleRowCount,
    network: {
      connection: "private regional VNet integration to the SQL Server VM",
      public_database_endpoint: false,
    },
    // Defender for App Service is a subscription-wide plan: if Scenario 1 already enabled it,
    // this Web App is protected automatically without any extra configuration here.
    defender_monitoring: {
      source: "deployment-configuration",
      app_service_threat_protection_requested: true,
      note: "Confirm the subscription-wide tier in Defender for Cloud > Environment settings.",
    },
    generated_at: new Date().toISOString(),
  };

  return new Response(JSON.stringify(payload, null, 2), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}
