import {
  createHash,
  createHmac,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";
import {
  getAuthenticatedUsername,
  verifyAdminCredentials,
} from "./adminAuth.mjs";

export const USER_SESSION_COOKIE = "dojo_user_session";
const sessionSeconds = 15 * 60;
const attempts = new Map();

export function isUserLoginConfigured() {
  return Boolean(
    process.env.USER_PORTAL_USERNAME &&
    process.env.USER_PORTAL_PASSWORD &&
    process.env.USER_SESSION_SECRET,
  );
}

function equal(left, right) {
  const digest = (value) =>
    createHash("sha256")
      .update(String(value ?? ""))
      .digest();
  return timingSafeEqual(digest(left), digest(right));
}

function sign(payload) {
  // Bind sessions to the staff role and current credentials so rotation invalidates old cookies.
  return createHmac("sha256", process.env.USER_SESSION_SECRET)
    .update(
      JSON.stringify([
        "staff",
        process.env.USER_PORTAL_USERNAME,
        process.env.USER_PORTAL_PASSWORD,
        payload,
      ]),
    )
    .digest("base64url");
}

export function createUserSession() {
  if (!isUserLoginConfigured())
    throw new Error("User sign-in is not configured.");
  const payload = Buffer.from(
    JSON.stringify({
      role: "staff",
      exp: Math.floor(Date.now() / 1000) + sessionSeconds,
      nonce: randomBytes(16).toString("hex"),
    }),
  ).toString("base64url");
  return `${payload}.${sign(payload)}`;
}

export function getUser(cookies) {
  const administrator = getAuthenticatedUsername(cookies);
  if (administrator) return administrator;
  if (!isUserLoginConfigured()) return null;
  const token = cookies.get(USER_SESSION_COOKIE)?.value;
  if (typeof token !== "string" || token.length > 2048) return null;
  const parts = token.split(".");
  if (parts.length !== 2 || !equal(parts[1], sign(parts[0]))) return null;
  try {
    const payload = JSON.parse(
      Buffer.from(parts[0], "base64url").toString("utf8"),
    );
    const now = Math.floor(Date.now() / 1000);
    return payload.role === "staff" &&
      Number.isInteger(payload.exp) &&
      payload.exp > now &&
      payload.exp <= now + sessionSeconds
      ? process.env.USER_PORTAL_USERNAME
      : null;
  } catch {
    return null;
  }
}

export function checkUserCredentials(request, username, password) {
  return checkLoginCredentials(request, username, password, false);
}

export function checkPortalCredentials(request, username, password) {
  return checkLoginCredentials(request, username, password, true);
}

function checkLoginCredentials(request, username, password, allowAdmin) {
  const now = Date.now();
  for (const [key, entry] of attempts)
    if (entry.until <= now) attempts.delete(key);
  const key =
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "unknown";
  const entry = attempts.get(key);
  if ((entry?.count ?? 0) >= 5 || (!entry && attempts.size >= 1000))
    return "ratelimited";
  const userMatches = equal(username, process.env.USER_PORTAL_USERNAME);
  const passwordMatches = equal(password, process.env.USER_PORTAL_PASSWORD);
  const managerMatches =
    isUserLoginConfigured() && userMatches && passwordMatches;
  const adminMatches = allowAdmin && verifyAdminCredentials(username, password);
  if (managerMatches || adminMatches) {
    attempts.delete(key);
    return managerMatches ? "success" : "admin";
  }
  attempts.set(key, {
    count: (entry?.count ?? 0) + 1,
    until: entry?.until ?? now + sessionSeconds * 1000,
  });
  return "invalid";
}

export function authorizeUserMutation(request, cookies) {
  if (!getUser(cookies))
    return new Response("User sign-in required.", {
      status: 401,
      headers: { "Cache-Control": "no-store" },
    });
  if (request.headers.get("origin") !== new URL(request.url).origin)
    return new Response("Same-origin request required.", { status: 403 });
  return null;
}

export const userSessionCookieOptions = {
  httpOnly: true,
  secure: true,
  sameSite: "strict",
  path: "/",
  maxAge: sessionSeconds,
};
