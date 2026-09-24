import {
  verifyAdminCredentials,
  createSessionToken,
  sessionCookieOptions,
  isLoginRateLimited,
  recordLoginFailure,
  clearLoginFailures,
  SESSION_COOKIE_NAME,
} from "../../../lib/adminAuth.mjs";
import { USER_SESSION_COOKIE } from "../../../lib/userAuth.mjs";

export async function POST({ request, cookies, redirect }) {
  if (isLoginRateLimited(request)) {
    return redirect("/admin/login?error=ratelimited", 303);
  }

  const form = await request.formData();
  const username = String(form.get("username") ?? "");
  const password = String(form.get("password") ?? "");

  if (!verifyAdminCredentials(username, password)) {
    recordLoginFailure(request);
    return redirect("/admin/login?error=invalid", 303);
  }

  clearLoginFailures(request);
  cookies.delete(USER_SESSION_COOKIE, { path: "/" });
  cookies.set(SESSION_COOKIE_NAME, createSessionToken(), sessionCookieOptions);
  return redirect("/admin", 303);
}
