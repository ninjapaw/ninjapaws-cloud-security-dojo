import { SESSION_COOKIE_NAME } from "../../../lib/adminAuth.mjs";

export async function POST({ cookies, redirect }) {
  cookies.delete(SESSION_COOKIE_NAME, { path: "/" });
  return redirect("/admin/login", 303);
}
