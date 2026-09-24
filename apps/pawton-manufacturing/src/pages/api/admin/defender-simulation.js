import {
  authorizeAdminMutation,
  isAuthenticated,
} from "../../../lib/adminAuth.mjs";
import { getRunDefenderEvidence } from "../../../lib/defenderStatus.mjs";
import {
  sqlAttackRunner,
  SimulationError,
} from "../../../lib/sqlAttackLab.mjs";

export async function POST({ request, cookies }) {
  const denied = authorizeAdminMutation(request, cookies);
  if (denied) return denied;
  const headers = { "Cache-Control": "no-store" };
  let form;
  try {
    form = await request.formData();
  } catch {
    return Response.json(
      { error: "Invalid simulation request." },
      { status: 400, headers },
    );
  }
  if (form.get("confirm") !== "yes")
    return Response.json(
      { error: "Confirmation required." },
      { status: 400, headers },
    );
  try {
    const result = await sqlAttackRunner.run(
      String(form.get("simulation") ?? ""),
    );
    return Response.json(result, { status: 200, headers });
  } catch (error) {
    return Response.json(
      {
        run: error instanceof SimulationError ? error.run : undefined,
        error:
          error instanceof SimulationError
            ? error.message
            : "SQL lab test unavailable.",
      },
      {
        status: error instanceof SimulationError ? error.status : 502,
        headers,
      },
    );
  }
}

export async function GET({ request, cookies }) {
  const headers = { "Cache-Control": "no-store" };
  if (!isAuthenticated(cookies))
    return Response.json(
      { error: "Authentication required." },
      { status: 401, headers },
    );
  const runId = new URL(request.url).searchParams.get("runId") || "";
  if (!/^[a-f0-9-]{36}$/i.test(runId))
    return Response.json(
      { error: "Invalid run identifier." },
      { status: 400, headers },
    );
  const run = sqlAttackRunner.getRun(runId);
  if (!run)
    return Response.json(
      {
        error:
          "Run unavailable or expired. Records are retained for up to 24 hours (50 runs) and reset when the app restarts.",
      },
      { status: 404, headers },
    );
  return Response.json(
    { run, evidence: await getRunDefenderEvidence(run) },
    { headers },
  );
}
