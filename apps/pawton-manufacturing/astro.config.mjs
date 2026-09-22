import { defineConfig } from "astro/config";
import node from "@astrojs/node";

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
      ...(process.env.WEBSITE_HOSTNAME
        ? [{ hostname: process.env.WEBSITE_HOSTNAME, protocol: "https" }]
        : []),
    ],
  },
});
