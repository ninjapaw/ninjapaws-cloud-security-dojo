import { authorizeAdminMutation } from "../../../lib/adminAuth.mjs";
import { runAuditProbe } from "../../../lib/securityLab.mjs";

export async function POST({ request, cookies }) {
  const denied = authorizeAdminMutation(request, cookies);
  if (denied) return denied;
  const form = await request.formData();
  if (form.get("confirm") !== "yes")
    return new Response("Confirmation required.", { status: 400 });
  try {
    const result = await runAuditProbe(String(form.get("probe") ?? ""));
    return Response.json(result, { headers: { "Cache-Control": "no-store" } });
  } catch {
    return Response.json(
      {
        error:
          "Probe not completed. Check enablement, cooldown, and database connectivity.",
      },
      { status: 409, headers: { "Cache-Control": "no-store" } },
    );
  }
}
