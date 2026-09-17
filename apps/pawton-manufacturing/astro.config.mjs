import { defineConfig } from "astro/config";
import node from "@astrojs/node";

// SSR is required: every page reads live data from the Scenario 2 SQL Server VM,
// so this cannot be a static build like the other Astro sites in this workspace.
export default defineConfig({
  output: "server",
  adapter: node({ mode: "standalone" }),
});
