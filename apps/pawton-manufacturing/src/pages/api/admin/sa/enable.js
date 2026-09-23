import { authorizeAdminMutation } from "../../../../lib/adminAuth.mjs";
import { setSaEnabled } from "../../../../lib/adminDb.mjs";

export async function POST({ cookies, redirect, request }) {
  const denied = authorizeAdminMutation(request, cookies);
  if (denied) return denied;
  if ((await request.formData()).get("confirm") !== "yes")
    return new Response("Confirmation required.", { status: 400 });
  try {
    await setSaEnabled(true);
    return redirect("/users?msg=sa_enabled", 303);
  } catch (err) {
    return redirect("/users?error=operation_failed", 303);
  }
}
