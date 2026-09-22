import {
  isAuthenticated,
  generateSqlPassword,
  ROTATED_SECRET_COOKIE_NAME,
} from "../../../../lib/adminAuth.mjs";
import { rotateSaPassword } from "../../../../lib/adminDb.mjs";

export async function POST({ cookies, redirect }) {
  if (!isAuthenticated(cookies)) {
    return redirect("/admin/login", 303);
  }
  try {
    const newPassword = generateSqlPassword();
    await rotateSaPassword(newPassword);
    cookies.set(ROTATED_SECRET_COOKIE_NAME, newPassword, {
      httpOnly: true,
      secure: true,
      sameSite: "strict",
      path: "/",
      maxAge: 60,
    });
    return redirect("/admin?msg=sa_rotated", 303);
  } catch (err) {
    return redirect(`/admin?error=${encodeURIComponent(err.message)}`, 303);
  }
}
