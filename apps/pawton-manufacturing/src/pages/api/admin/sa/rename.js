import { isAuthenticated } from "../../../../lib/adminAuth.mjs";
import { renameSaLogin } from "../../../../lib/adminDb.mjs";
import {
  requireAdminSecretsConfigured,
  storeTargetAdminUsername,
} from "../../../../lib/adminSecrets.mjs";

export async function POST({ cookies, redirect, request }) {
  if (!isAuthenticated(cookies)) {
    return redirect("/admin/login", 303);
  }
  try {
    requireAdminSecretsConfigured();
    const formData = await request.formData();
    const newUsername = String(formData.get("newUsername") ?? "").trim();
    const renamedUsername = await renameSaLogin(newUsername);
    await storeTargetAdminUsername(renamedUsername);
    return redirect("/admin?msg=sa_renamed", 303);
  } catch (err) {
    return redirect(`/admin?error=${encodeURIComponent(err.message)}`, 303);
  }
}
