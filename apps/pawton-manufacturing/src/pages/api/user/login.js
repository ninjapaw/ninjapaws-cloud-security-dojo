import {
  checkUserCredentials,
  createUserSession,
  USER_SESSION_COOKIE,
  userSessionCookieOptions,
} from "../../../lib/userAuth.mjs";
import {
  SESSION_COOKIE_NAME,
  ROTATED_SECRET_COOKIE_NAME,
} from "../../../lib/adminAuth.mjs";

export async function POST({ request, cookies, redirect }) {
  if (request.headers.get("origin") !== new URL(request.url).origin)
    return new Response("Same-origin request required.", { status: 403 });
  let form;
  try {
    form = await request.formData();
  } catch {
    return new Response("Invalid form.", { status: 400 });
  }
  const username = String(form.get("username") ?? "");
  const password = String(form.get("password") ?? "");
  if (username.length > 100 || password.length > 1024)
    return redirect("/login?error=invalid", 303);
  const result = checkUserCredentials(request, username, password);
  if (result !== "success") return redirect(`/login?error=${result}`, 303);
  cookies.delete(SESSION_COOKIE_NAME, { path: "/" });
  cookies.delete(ROTATED_SECRET_COOKIE_NAME, { path: "/" });
  cookies.set(
    USER_SESSION_COOKIE,
    createUserSession(),
    userSessionCookieOptions,
  );
  return redirect("/orders", 303);
}
