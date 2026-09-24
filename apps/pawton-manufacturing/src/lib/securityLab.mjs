import { randomUUID } from "node:crypto";
import { getPool } from "./db.mjs";
import { runDataAuditProbe } from "./adminDb.mjs";

export const alertReferenceDocs =
  "https://learn.microsoft.com/azure/defender-for-cloud/alerts-sql-database-and-azure-synapse-analytics";

export const probes = [
  {
    id: "read",
    name: "Audited read sample",
    description:
      "Read one item from the sample database. No data is changed or returned to the browser.",
    script: "SELECT TOP (1) * FROM dbo.Items; /* dojo-audit-probe:<run-id> */",
  },
  {
    id: "data-change",
    name: "Rolled-back data-change sample",
    description:
      "Create an isolated probe table, insert, update, and delete one row, then roll back the entire transaction. Existing probe tables are never modified.",
    script:
      "BEGIN TRANSACTION;\nCREATE TABLE dbo.DojoAuditProbe (...);\nINSERT, UPDATE, and DELETE one isolated row;\nROLLBACK TRANSACTION; /* dojo-audit-probe:<run-id> */",
  },
  {
    id: "denied-write",
    name: "Permission-boundary sample",
    description:
      "Attempt a read in master using the application login. A SQL permission error is a database control, not Defender blocking.",
    script:
      "SELECT TOP (1) name FROM master.sys.sql_logins; /* dojo-audit-probe:<run-id> */",
  },
];

let nextRunAt = 0;
let running = false;
const simulationSampleStatements = {
  "brute-force": "SELECT TOP (1) ItemId, ItemName FROM dbo.Items",
  "suspicious-app":
    "SELECT APP_NAME() AS ApplicationName, HOST_NAME() AS HostName, ORIGINAL_LOGIN() AS OriginalLogin",
  "sql-injection":
    "DECLARE @itemName nvarchar(100) = N'dojo-injection-theme'; SELECT TOP (1) ItemId, ItemName FROM dbo.Items WHERE ItemName = @itemName",
  "principal-anomaly":
    "SELECT ORIGINAL_LOGIN() AS OriginalLogin, SUSER_SNAME() AS ServerPrincipal, USER_NAME() AS DatabasePrincipal",
  "external-source":
    "SELECT N'No external source, download, or shell command is executed.' AS SafetyNotice",
  "obfuscated-shell":
    "SELECT N'No encoded content or operating-system command is executed.' AS SafetyNotice",
};
export const simulationSampleIds = Object.freeze(
  Object.keys(simulationSampleStatements),
);

export function isSqlDemoActionsEnabled(env = process.env) {
  return env.ENABLE_SQL_DEMO_ACTIONS !== "false";
}

function startDemoRun() {
  if (running || Date.now() < nextRunAt)
    throw new Error(
      "Another sample is running or cooling down. Wait 60 seconds.",
    );
  running = true;
  nextRunAt = Date.now() + 60_000;
  return randomUUID();
}

export async function runAuditProbe(id) {
  if (!probes.some((probe) => probe.id === id))
    throw new Error("Unknown probe.");
  if (!isSqlDemoActionsEnabled())
    throw new Error("Local demos are disabled by the server configuration.");
  const runId = startDemoRun();
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

export async function runSimulationSample(id) {
  if (!simulationSampleIds.includes(id))
    throw new Error("Unknown simulation sample.");
  if (!isSqlDemoActionsEnabled())
    throw new Error("Local demos are disabled by the server configuration.");
  const statement = simulationSampleStatements[id];
  const runId = startDemoRun();
  try {
    const pool = await getPool();
    await pool
      .request()
      .query(`${statement}; /* dojo-simulation-sample:${id}:${runId} */`);
    return {
      runId,
      outcome:
        "Safe SQL evidence sample completed. It does not execute an attack or create a Defender alert; verify the run marker in Event 33205.",
    };
  } finally {
    running = false;
  }
}
