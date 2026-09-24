import { authorizeAdminMutation } from "../../../lib/adminAuth.mjs";
import { setSqlShellEnabled } from "../../../lib/adminDb.mjs";

export async function POST({ request, cookies, redirect }) {
  const denied = authorizeAdminMutation(request, cookies);
  if (denied) return denied;
  let form;
  try {
    form = await request.formData();
  } catch {
    return new Response("Invalid request.", { status: 400 });
  }
  if (form.get("confirm") !== "yes")
    return new Response("Confirmation required.", { status: 400 });
  const value = form.get("enabled");
  if (value !== null && value !== "true" && value !== "false")
    return new Response("Invalid SQL shell setting.", { status: 400 });
  try {
    const result = await setSqlShellEnabled(value === "true");
    return redirect(
      `/admin?shell=${result.enabled ? "enabled" : "disabled"}#sql-shell-settings`,
      303,
    );
  } catch {
    return redirect("/admin?shell=error#sql-shell-settings", 303);
  }
}
