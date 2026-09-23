import {
  authorizeAdminMutation,
  generateSqlPassword,
  ROTATED_SECRET_COOKIE_NAME,
} from "../../../../lib/adminAuth.mjs";
import { rotateSaPassword } from "../../../../lib/adminDb.mjs";
import {
  requireAdminSecretsConfigured,
  storeTargetAdminPassword,
  verifyTargetAdminPassword,
} from "../../../../lib/adminSecrets.mjs";

export async function POST({ cookies, redirect, request }) {
  const denied = authorizeAdminMutation(request, cookies);
  if (denied) return denied;
  if ((await request.formData()).get("confirm") !== "yes")
    return new Response("Confirmation required.", { status: 400 });
  try {
    requireAdminSecretsConfigured();
    const newPassword = generateSqlPassword();
    await rotateSaPassword(newPassword);
    await storeTargetAdminPassword(newPassword);
    const secretMatches = await verifyTargetAdminPassword(newPassword);
    if (!secretMatches) {
      throw new Error(
        "SQL password rotated successfully, but the Key Vault secret did not match the new random password.",
      );
    }
    cookies.set(ROTATED_SECRET_COOKIE_NAME, newPassword, {
      httpOnly: true,
      secure: true,
      sameSite: "strict",
      path: "/",
      maxAge: 60,
    });
    return redirect("/users?msg=sa_rotated", 303);
  } catch (err) {
    return redirect("/users?error=operation_failed", 303);
  }
}
