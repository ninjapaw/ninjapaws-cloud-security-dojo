import { defineMiddleware } from "astro:middleware";
import { ROBOTS_POLICY } from "./lib/pageMetadata.mjs";

export const onRequest = defineMiddleware(async (_context, next) => {
  const response = await next();
  const headers = new Headers(response.headers);
  headers.set("X-Robots-Tag", ROBOTS_POLICY);
  headers.set("Referrer-Policy", "strict-origin-when-cross-origin");
  headers.set("X-Content-Type-Options", "nosniff");
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
});
