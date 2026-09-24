import { defineConfig } from "astro/config";
import node from "@astrojs/node";

const customDomain = (process.env.PORTAL_CUSTOM_DOMAIN ?? "")
  .trim()
  .toLowerCase();
if (
  customDomain &&
  (customDomain.length > 253 ||
    !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(
      customDomain,
    ))
) {
  throw new Error(
    "PORTAL_CUSTOM_DOMAIN must be a hostname without a scheme, port, path, or wildcard.",
  );
}

// SSR is required: every page reads live data from the Scenario 2 SQL Server VM,
// so this cannot be a static build like the other Astro sites in this workspace.
export default defineConfig({
  output: "server",
  adapter: node({ mode: "standalone" }),
  security: {
    // Astro's built-in CSRF check (security.checkOrigin, on by default) compares the request's
    // Origin header against the Host it received -- but @astrojs/node's standalone server only
    // trusts a Host/X-Forwarded-Host value that matches one of these patterns; without this list
    // it silently falls back to a bare "localhost" with no port, so every admin portal form POST
    // (enable/disable/rotate sa, and login itself) would 403 in every environment, not just here.
    // WEBSITE_HOSTNAME is set automatically by Azure App Service at both build and run time.
    allowedDomains: [
      { hostname: "localhost" },
      { hostname: "127.0.0.1" },
      ...(customDomain ? [{ hostname: customDomain, protocol: "https" }] : []),
      ...(process.env.WEBSITE_HOSTNAME
        ? [{ hostname: process.env.WEBSITE_HOSTNAME, protocol: "https" }]
        : []),
    ],
  },
});
