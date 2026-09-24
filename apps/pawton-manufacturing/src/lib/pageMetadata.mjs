export const ROBOTS_POLICY = "noindex, nofollow, noarchive";
export const SITE_NAME = "Pawton Manufacturing";

const descriptions = {
  "/": "Pawton Manufacturing is a fictional manufacturing dashboard and isolated cloud-security training lab from Ninja Paws.",
  "/inventory":
    "Inventory valuation and warehouse reporting for the fictional Pawton Manufacturing training dataset.",
  "/sales":
    "Sales-channel reporting for the fictional Pawton Manufacturing training dataset.",
  "/production":
    "Production-order status and manufacturing reports for the Pawton Manufacturing training lab.",
  "/status":
    "Application and database status for the Pawton Manufacturing training environment. Configuration is separate from verified security coverage.",
};

export function pageMetadata(
  pathname,
  title = "Overview",
  environment = process.env,
) {
  const path = pathname.replace(/\/$/, "") || "/";
  const publicPage = Object.hasOwn(descriptions, path);
  const managerPage =
    path === "/login" || path === "/orders" || path.startsWith("/orders/");
  const description =
    descriptions[path] ??
    (managerPage
      ? "Authorized manager access to customer-order management in the Pawton Manufacturing training environment."
      : "Restricted administrator access to the Pawton Manufacturing cloud-security training environment.");
  const host = (
    environment.PORTAL_CUSTOM_DOMAIN ||
    environment.WEBSITE_HOSTNAME ||
    ""
  )
    .trim()
    .toLowerCase();
  const validHost =
    host.length <= 253 &&
    /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(host);
  const origin = validHost ? `https://${host}` : null;
  return {
    title: `${publicPage ? title : managerPage ? "Order management" : "Administration"} — ${SITE_NAME}`,
    description,
    robots: ROBOTS_POLICY,
    canonical:
      publicPage && origin ? `${origin}${path === "/" ? "/" : path}` : null,
    socialImage: publicPage && origin ? `${origin}/pawton-social.png` : null,
    social: publicPage,
  };
}
