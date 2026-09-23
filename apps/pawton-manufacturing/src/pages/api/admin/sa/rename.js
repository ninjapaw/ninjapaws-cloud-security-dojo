import { authorizeAdminMutation } from "../../../../lib/adminAuth.mjs";
import { renameSaLogin } from "../../../../lib/adminDb.mjs";
import {
  requireAdminSecretsConfigured,
  storeTargetAdminUsername,
} from "../../../../lib/adminSecrets.mjs";

export async function POST({ cookies, redirect, request }) {
  const denied = authorizeAdminMutation(request, cookies);
  if (denied) return denied;
  const formData = await request.formData();
  if (formData.get("confirm") !== "yes")
    return new Response("Confirmation required.", { status: 400 });
  try {
    requireAdminSecretsConfigured();
    const newUsername = String(formData.get("newUsername") ?? "").trim();
    const renamedUsername = await renameSaLogin(newUsername);
    await storeTargetAdminUsername(renamedUsername);
    return redirect("/users?msg=sa_renamed", 303);
  } catch (err) {
    return redirect("/users?error=operation_failed", 303);
  }
}
