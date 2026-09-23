import { randomUUID } from "node:crypto";
import { getPool } from "./db.mjs";
import { runDataAuditProbe } from "./adminDb.mjs";

export const alertSimulationDocs =
  "https://learn.microsoft.com/azure/defender-for-cloud/simulate-alerts-sql-machines";
export const alertReferenceDocs =
  "https://learn.microsoft.com/azure/defender-for-cloud/alerts-sql-database-and-azure-synapse-analytics";
export const simulations = [
  {
    id: "brute-force",
    name: "Brute force authentication",
    description: "Simulated repeated authentication failures.",
    evidence: "SQL.VM_BruteForce",
  },
  {
    id: "suspicious-app",
    name: "Suspicious application",
    description: "Simulated access from a potentially harmful SQL client.",
    evidence: "SQL.VM_HarmfulApplication",
  },
  {
    id: "sql-injection",
    name: "SQL injection",
    description:
      "Simulated injection-related telemetry, without exploiting the application.",
    evidence: "SQL injection alert family",
  },
  {
    id: "principal-anomaly",
    name: "Principal anomaly",
    description: "Simulated anomalous activity involving a SQL principal.",
    evidence: "SQL.VM_PrincipalAnomaly",
  },
  {
    id: "external-source",
    name: "Shell external source anomaly",
    description:
      "Simulated shell activity referencing an unfamiliar external source. No download is performed here.",
    evidence: "SQL.VM_ShellExternalSourceAnomaly",
  },
  {
    id: "obfuscated-shell",
    name: "Shell obfuscation",
    description:
      "Simulated obfuscated shell telemetry. No operating-system command is executed here.",
    evidence: "SQL.VM_PotentialSqlInjection",
  },
];

export const probes = [
  {
    id: "read",
    name: "Audited read",
    description:
      "Read one item from the sample database. No data is changed or returned to the browser.",
  },
  {
    id: "data-change",
    name: "Data-change audit",
    description:
      "Create an isolated probe table, insert, update, and delete one row, then roll back the entire transaction. Existing probe tables are never modified.",
  },
  {
    id: "denied-write",
    name: "Permission boundary",
    description:
      "Attempt a read in master using the application login. A SQL permission error is a database control, not Defender blocking.",
  },
];

let nextRunAt = 0;
let running = false;

export async function runAuditProbe(id) {
  if (!probes.some((probe) => probe.id === id))
    throw new Error("Unknown probe.");
  if (process.env.ENABLE_SQL_DEMO_ACTIONS !== "true")
    throw new Error("Local demos are disabled by the server configuration.");
  if (running || Date.now() < nextRunAt)
    throw new Error(
      "Another probe is running or cooling down. Wait 60 seconds.",
    );
  running = true;
  nextRunAt = Date.now() + 60_000;
  const runId = randomUUID();
  try {
    if (id === "data-change") {
      await runDataAuditProbe(runId);
      return {
        runId,
        outcome:
          "INSERT, UPDATE, and DELETE completed and rolled back, including the probe table. Audit events describe statements, not committed before/after values. Verify the run marker in Event 33205.",
      };
    }
    const pool = await getPool();
    if (id === "read") {
      await pool
        .request()
        .query(
          `SELECT TOP (1) * FROM dbo.Items; /* dojo-audit-probe:${runId} */`,
        );
      return {
        runId,
        outcome:
          "Read completed; verify Event 33205 for this run marker. No Defender alert is guaranteed.",
      };
    }
    try {
      await pool
        .request()
        .query(
          `SELECT TOP (1) name FROM master.sys.sql_logins; /* dojo-audit-probe:${runId} */`,
        );
      return {
        runId,
        outcome:
          "Metadata query permitted. Metadata visibility may filter rows; no blocking claim is made.",
      };
    } catch (error) {
      if (error.number !== 229 && error.number !== 916 && error.number !== 297)
        throw error;
      return {
        runId,
        outcome:
          "SQL permissions denied access. This is SQL authorization, not a Defender prevention event.",
      };
    }
  } finally {
    running = false;
  }
}
