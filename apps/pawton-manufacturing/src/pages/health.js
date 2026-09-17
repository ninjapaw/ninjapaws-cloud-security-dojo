import { isDatabaseConfigured, query } from "../lib/db.mjs";

export async function GET() {
  const body = { status: "starting", database: "not_configured" };

  if (isDatabaseConfigured()) {
    try {
      await query("SELECT 1 AS ok");
      body.status = "healthy";
      body.database = "connected";
    } catch (err) {
      body.status = "degraded";
      body.database = "unreachable";
      body.error = err.message;
    }
  }

  return new Response(JSON.stringify(body), {
    status: body.database === "unreachable" ? 503 : 200,
    headers: { "Content-Type": "application/json" },
  });
}
