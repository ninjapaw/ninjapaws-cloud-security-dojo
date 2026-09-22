import { isAuthenticated } from "../../../../lib/adminAuth.mjs";
import { setSaEnabled } from "../../../../lib/adminDb.mjs";

export async function POST({ cookies, redirect }) {
  if (!isAuthenticated(cookies)) {
    return redirect("/admin/login", 303);
  }
  try {
    await setSaEnabled(false);
    return redirect("/admin?msg=sa_disabled", 303);
  } catch (err) {
    return redirect(`/admin?error=${encodeURIComponent(err.message)}`, 303);
  }
}
