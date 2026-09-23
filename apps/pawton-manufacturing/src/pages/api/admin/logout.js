import {
  SESSION_COOKIE_NAME,
  ROTATED_SECRET_COOKIE_NAME,
  authorizeAdminMutation,
} from "../../../lib/adminAuth.mjs";

export async function POST({ cookies, redirect, request }) {
  const denied = authorizeAdminMutation(request, cookies);
  if (denied) return denied;
  cookies.delete(SESSION_COOKIE_NAME, { path: "/" });
  cookies.delete(ROTATED_SECRET_COOKIE_NAME, { path: "/" });
  return redirect("/admin/login", 303);
}
