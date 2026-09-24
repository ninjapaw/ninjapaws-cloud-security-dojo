import {
  authorizeAdminMutation,
  generateSqlPassword,
  ROTATED_SECRET_COOKIE_NAME,
} from "../../../../lib/adminAuth.mjs";
import { changeSqlLogin, createDemoLogin } from "../../../../lib/adminDb.mjs";

export async function POST({ request, cookies, redirect }) {
  const denied = authorizeAdminMutation(request, cookies);
  if (denied) return denied;
  const form = await request.formData();
  if (form.get("confirm") !== "yes")
    return new Response("Confirm the login change.", { status: 400 });
  const action = String(form.get("action") ?? "");
  const password = generateSqlPassword();
  try {
    if (action === "create-demo") await createDemoLogin(password);
    else
      await changeSqlLogin(
        Number(form.get("principalId")),
        action,
        password,
        String(form.get("newUsername") ?? ""),
      );
    if (action === "rotate" || action === "create-demo") {
      cookies.set(ROTATED_SECRET_COOKIE_NAME, password, {
        httpOnly: true,
        secure: true,
        sameSite: "strict",
        path: "/",
        maxAge: 60,
      });
    }
    return redirect("/users?msg=login_updated", 303);
  } catch {
    return redirect("/users?msg=login_failed", 303);
  }
}
