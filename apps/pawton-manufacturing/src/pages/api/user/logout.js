import {
  authorizeUserMutation,
  USER_SESSION_COOKIE,
} from "../../../lib/userAuth.mjs";

export async function POST({ request, cookies, redirect }) {
  const denied = authorizeUserMutation(request, cookies);
  if (denied) return denied;
  cookies.delete(USER_SESSION_COOKIE, { path: "/" });
  return redirect("/login", 303);
}
