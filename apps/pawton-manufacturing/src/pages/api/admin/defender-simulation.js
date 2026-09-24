import { authorizeAdminMutation } from "../../../lib/adminAuth.mjs";
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
