import { createHmac, timingSafeEqual, randomBytes } from "node:crypto";

export const SESSION_COOKIE_NAME = "dojo_admin_session";
// Holds a just-rotated sa password for exactly one page render; the /admin page reads and
// immediately clears it, so a refresh or a second visitor to the same session never sees it again.
export const ROTATED_SECRET_COOKIE_NAME = "dojo_admin_rotated_secret";
const SESSION_TTL_SECONDS = 15 * 60;
const MAX_LOGIN_ATTEMPTS = 5;
const LOGIN_WINDOW_MS = 15 * 60 * 1000;

// In-memory only: this app runs as a single App Service instance (no autoscale configured for
// this training scenario), so a per-process rate limit map is sufficient. It resets on restart,
// which is an accepted tradeoff for a training environment rather than a general-purpose control.
const loginAttempts = new Map();

function isAdminPortalConfigured() {
  const { ADMIN_PORTAL_USERNAME, ADMIN_PORTAL_PASSWORD, ADMIN_SESSION_SECRET } =
    process.env;
  return Boolean(
    ADMIN_PORTAL_USERNAME && ADMIN_PORTAL_PASSWORD && ADMIN_SESSION_SECRET,
  );
}

function timingSafeStringEqual(a, b) {
  const bufA = Buffer.from(String(a ?? ""), "utf8");
  const bufB = Buffer.from(String(b ?? ""), "utf8");
  // Pad to equal length before comparing so the comparison itself never leaks length via timing;
  // a length mismatch still returns false because a byte in the padding is guaranteed not to match.
  const maxLen = Math.max(bufA.length, bufB.length, 1);
  const paddedA = Buffer.alloc(maxLen);
  const paddedB = Buffer.alloc(maxLen);
  bufA.copy(paddedA);
  bufB.copy(paddedB);
  return bufA.length === bufB.length && timingSafeEqual(paddedA, paddedB);
}

function clientKeyFor(request) {
  // Best-effort client identifier for rate limiting behind App Service's front end; this is not
  // an authoritative client identity and must never be used for anything security-critical beyond
  // slowing down brute force from a single source.
  return (
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || "unknown"
  );
}

export function isLoginRateLimited(request) {
  const key = clientKeyFor(request);
  const entry = loginAttempts.get(key);
  if (!entry) return false;
  if (Date.now() - entry.firstAttemptAt > LOGIN_WINDOW_MS) {
    loginAttempts.delete(key);
    return false;
  }
  return entry.count >= MAX_LOGIN_ATTEMPTS;
}

export function recordLoginFailure(request) {
  const key = clientKeyFor(request);
  const entry = loginAttempts.get(key);
  if (!entry || Date.now() - entry.firstAttemptAt > LOGIN_WINDOW_MS) {
    loginAttempts.set(key, { count: 1, firstAttemptAt: Date.now() });
  } else {
    entry.count += 1;
  }
}

export function clearLoginFailures(request) {
  loginAttempts.delete(clientKeyFor(request));
}

export function verifyAdminCredentials(username, password) {
  if (!isAdminPortalConfigured()) return false;
  const { ADMIN_PORTAL_USERNAME, ADMIN_PORTAL_PASSWORD } = process.env;
  const userOk = timingSafeStringEqual(username, ADMIN_PORTAL_USERNAME);
  const passOk = timingSafeStringEqual(password, ADMIN_PORTAL_PASSWORD);
  return userOk && passOk;
}

function sign(payload) {
  const secret = process.env.ADMIN_SESSION_SECRET;
  return createHmac("sha256", secret).update(payload).digest("base64url");
}

export function createSessionToken() {
  const payload = JSON.stringify({
    exp: Math.floor(Date.now() / 1000) + SESSION_TTL_SECONDS,
    nonce: randomBytes(8).toString("hex"),
  });
  const encodedPayload = Buffer.from(payload, "utf8").toString("base64url");
  return `${encodedPayload}.${sign(encodedPayload)}`;
}

export function verifySessionToken(token) {
  if (!token || !isAdminPortalConfigured()) return false;
  const parts = token.split(".");
  if (parts.length !== 2) return false;
  const [encodedPayload, signature] = parts;
  if (!timingSafeStringEqual(signature, sign(encodedPayload))) return false;
  try {
    const payload = JSON.parse(
      Buffer.from(encodedPayload, "base64url").toString("utf8"),
    );
    return typeof payload.exp === "number" && payload.exp > Date.now() / 1000;
  } catch {
    return false;
  }
}

export function isAuthenticated(cookies) {
  return verifySessionToken(cookies.get(SESSION_COOKIE_NAME)?.value);
}

export function getAuthenticatedUsername(cookies) {
  return isAuthenticated(cookies) ? process.env.ADMIN_PORTAL_USERNAME : null;
}

export function authorizeAdminMutation(request, cookies) {
  if (!isAuthenticated(cookies)) {
    return new Response("Your session has expired. Sign in again.", {
      status: 401,
    });
  }
  if (request.headers.get("origin") !== new URL(request.url).origin) {
    return new Response("Same-origin request required.", { status: 403 });
  }
  return null;
}

export const sessionCookieOptions = {
  httpOnly: true,
  secure: true,
  sameSite: "strict",
  path: "/",
  maxAge: SESSION_TTL_SECONDS,
};

export function generateSqlPassword(length = 28) {
  const specials = "!@#$%^&*-_=";
  const bytes = randomBytes(length);
  const core = bytes
    .toString("base64")
    .replace(/[^a-zA-Z0-9]/g, "x")
    .slice(0, length);
  const specialChar = specials[randomBytes(1)[0] % specials.length];
  const insertAt = randomBytes(1)[0] % (core.length + 1);
  return core.slice(0, insertAt) + specialChar + core.slice(insertAt);
}
