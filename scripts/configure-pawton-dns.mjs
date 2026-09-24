import { Resolver } from "node:dns/promises";
import { pathToFileURL } from "node:url";

export function validateDomain(value) {
  const domain = String(value ?? "")
    .trim()
    .toLowerCase();
  if (
    domain.length > 64 ||
    !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(domain)
  ) {
    throw new Error(
      "Custom domain must be a subdomain of at most 64 characters, without scheme, port, path, or wildcard.",
    );
  }
  return domain;
}

export function desiredRecords({ domain, azureHostname, verificationId }) {
  domain = validateDomain(domain);
  if (!/^[a-z0-9.-]+\.azurewebsites\.net$/i.test(azureHostname ?? ""))
    throw new Error(
      "Expected the Web App's default azurewebsites.net hostname.",
    );
  if (!/^[a-f0-9]{64}$/i.test(verificationId ?? ""))
    throw new Error("Azure custom-domain verification ID is unavailable.");
  return [
    { type: "TXT", name: `asuid.${domain}`, content: verificationId, ttl: 300 },
    {
      type: "CNAME",
      name: domain,
      content: azureHostname.toLowerCase(),
      ttl: 300,
      proxied: false,
    },
  ];
}

function sameRecord(actual, expected) {
  if (actual.type !== expected.type) return false;
  if (expected.type === "CNAME") {
    return (
      actual.content?.toLowerCase().replace(/\.$/, "") === expected.content &&
      actual.proxied === false &&
      actual.settings?.flatten_cname !== true
    );
  }
  return actual.content?.replace(/^"|"$/g, "") === expected.content;
}

export async function reconcileDns(
  settings,
  { apply = false, fetcher = fetch } = {},
) {
  const records = desiredRecords(settings);
  const { zoneId, token } = settings;
  if (!/^[a-f0-9]{32}$/i.test(zoneId ?? ""))
    throw new Error("Set CLOUDFLARE_ZONE_ID to the Cloudflare zone ID.");
  if (!token)
    throw new Error(
      "Set CLOUDFLARE_API_TOKEN with Zone Read and DNS Edit permissions for this zone only.",
    );
  const base = `https://api.cloudflare.com/client/v4/zones/${zoneId}`;
  const call = async (suffix, body) => {
    let response;
    try {
      response = await fetcher(base + suffix, {
        method: body ? "POST" : "GET",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: body ? JSON.stringify(body) : undefined,
        redirect: "error",
        signal: AbortSignal.timeout(30000),
      });
    } catch {
      throw new Error(
        "Cloudflare request failed or timed out. Check connectivity and retry; partial DNS creation is safe to resume.",
      );
    }
    let result;
    try {
      result = await response.json();
    } catch {
      throw new Error("Cloudflare returned an invalid response.");
    }
    if (!response.ok || result.success !== true)
      throw new Error(
        `Cloudflare request rejected (HTTP ${response.status}). Check the scoped token and zone permissions.`,
      );
    return result;
  };
  const zone = (await call("")).result;
  if (
    zone?.status !== "active" ||
    !records[1].name.endsWith(`.${zone.name?.toLowerCase()}`)
  ) {
    throw new Error(
      "The hostname must be a subdomain of the selected active Cloudflare zone; apex domains are not supported.",
    );
  }
  const inspect = async (record) => {
    const response = await call(
      `/dns_records?${new URLSearchParams({ name: record.name, per_page: "100" })}`,
    );
    if (
      !Array.isArray(response.result) ||
      (response.result_info?.total_pages ?? 1) > 1
    )
      throw new Error(
        "Ambiguous DNS results; review the exact hostname in Cloudflare.",
      );
    const entries = response.result;
    if (entries.some((entry) => entry.name?.toLowerCase() !== record.name))
      throw new Error("Cloudflare returned unexpected DNS names.");
    if (!entries.length) return false;
    if (entries.length !== 1 || !sameRecord(entries[0], record)) {
      throw new Error(
        `Conflicting DNS record at ${record.name}; existing records are never overwritten. Use a direct DNS-only CNAME and matching asuid TXT record.`,
      );
    }
    return true;
  };
  const present = [];
  for (const record of records) present.push(await inspect(record));
  const actions = [];
  for (const [index, record] of records.entries()) {
    if (!present[index] && apply) {
      await call("/dns_records", record);
      if (!(await inspect(record)))
        throw new Error(
          `DNS record ${record.name} could not be read back. Retry the domain command.`,
        );
    }
    actions.push({
      type: record.type,
      name: record.name,
      action: present[index] ? "found" : apply ? "created" : "would create",
    });
  }
  return actions;
}

export async function verifyDns(
  settings,
  resolver = new Resolver({ timeout: 5000, tries: 2 }),
) {
  const [txt, cname] = desiredRecords(settings);
  try {
    const aliases = await resolver.resolveCname(cname.name);
    const text = await resolver.resolveTxt(txt.name);
    if (
      aliases.some(
        (alias) => alias.toLowerCase().replace(/\.$/, "") === cname.content,
      ) &&
      text.some((chunks) => chunks.join("") === txt.content)
    )
      return;
  } catch {}
  throw new Error(
    "Public DNS is not ready. Keep Cloudflare DNS-only with CNAME flattening off, allow propagation, then rerun the domain command. No TLS binding was attempted.",
  );
}

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(process.argv[1]).href
) {
  try {
    const mode = process.argv[2] ?? "plan";
    const settings = {
      domain: process.env.PAWTON_DOMAIN,
      azureHostname: process.env.PAWTON_AZURE_HOSTNAME,
      verificationId: process.env.PAWTON_VERIFICATION_ID,
      zoneId: process.env.CLOUDFLARE_ZONE_ID,
      token: process.env.CLOUDFLARE_API_TOKEN,
    };
    if (mode === "validate") validateDomain(settings.domain);
    else if (mode === "verify") {
      await verifyDns(settings);
      console.log("[found] Public CNAME and asuid TXT records verified.");
    } else if (["plan", "apply"].includes(mode)) {
      for (const action of await reconcileDns(settings, {
        apply: mode === "apply",
      }))
        console.log(`[${action.action}] ${action.type} ${action.name}`);
    } else throw new Error("Expected validate, plan, apply, or verify.");
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
