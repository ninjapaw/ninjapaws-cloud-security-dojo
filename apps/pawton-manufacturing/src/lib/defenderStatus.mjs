import { DefaultAzureCredential } from "@azure/identity";

const credential = new DefaultAzureCredential();
const plans = [
  ["SqlServerVirtualMachines", "Defender for SQL on machines"],
  ["VirtualMachines", "Defender for Servers"],
  ["AppServices", "Defender for App Service"],
];

export function defenderTarget(environment = process.env) {
  const vmId = environment.SQL_VM_RESOURCE_ID || "";
  const match =
    /^\/subscriptions\/([a-f0-9-]{36})\/resourceGroups\/([^/]+)\/providers\/Microsoft.Compute\/virtualMachines\/([^/]+)$/i.exec(
      vmId,
    );
  const subscription =
    match?.[1] ||
    environment.AZURE_SUBSCRIPTION_ID ||
    environment.WEBSITE_OWNER_NAME?.split("+")[0];
  return {
    subscription: /^[a-f0-9-]{36}$/i.test(subscription || "")
      ? subscription
      : null,
    vmId: match ? vmId : null,
    portal: match
      ? `https://portal.azure.com/#resource${vmId.replace("/Microsoft.Compute/virtualMachines/", "/Microsoft.SqlVirtualMachine/sqlVirtualMachines/")}/overview`
      : "https://portal.azure.com/#view/Microsoft_Azure_Security/SecurityMenuBlade/~/0",
  };
}

async function armRead(path) {
  const token = await credential.getToken(
    "https://management.azure.com/.default",
    { abortSignal: AbortSignal.timeout(8000) },
  );
  const response = await fetch(`https://management.azure.com${path}`, {
    headers: { Authorization: `Bearer ${token.token}` },
    signal: AbortSignal.timeout(8000),
  });
  if (!response.ok)
    throw new Error(
      response.status === 403
        ? "Permission required (read-only Azure access)."
        : `Azure returned HTTP ${response.status}.`,
    );
  return response.json();
}

export async function getDefenderStatus() {
  const target = defenderTarget();
  const observations = await Promise.all(
    plans.map(async ([plan, label]) => {
      if (!target.subscription)
        return {
          label,
          state: "Unavailable",
          detail: "Subscription is not configured.",
        };
      try {
        const data = await armRead(
          `/subscriptions/${target.subscription}/providers/Microsoft.Security/pricings/${plan}?api-version=2024-01-01`,
        );
        return {
          label,
          state: data.properties?.pricingTier || "Unknown",
          detail: `Subscription plan${data.properties?.subPlan ? ` / ${data.properties.subPlan}` : ""}; not proof of machine protection.`,
        };
      } catch (error) {
        return {
          label,
          state: "Unavailable",
          detail:
            error.message?.includes("HTTP") ||
            error.message?.includes("Permission required")
              ? error.message
              : "Managed identity could not read Azure status.",
        };
      }
    }),
  );
  let extension = {
    label: "SQL protection extension",
    state: "Unavailable",
    detail: "SQL_VM_RESOURCE_ID is not configured.",
  };
  if (target.vmId) {
    try {
      const data = await armRead(
        `${target.vmId}/extensions?api-version=2024-11-01`,
      );
      const found = data.value?.find(
        (entry) =>
          entry.properties?.publisher ===
            "Microsoft.Azure.AzureDefenderForSQL" &&
          entry.properties?.type === "AdvancedThreatProtection.Windows",
      );
      extension = {
        label: "SQL protection extension",
        state: found?.properties?.provisioningState || "Not found",
        detail:
          "VM extension provisioning only. Confirm sensor health in Defender for Cloud.",
      };
    } catch {
      extension.detail =
        "Unable to read VM extensions. Verify the managed identity has VM read access.";
    }
  }
  return {
    target,
    checkedAt: new Date().toISOString(),
    observations: [...observations, extension],
  };
}

const attackAlertTypes = {
  "brute-force": /^SQL\.VM_BruteForce$/i,
  "suspicious-app": /^SQL\.VM_HarmfulApplication$/i,
  "sql-injection": /^SQL\.VM_.*SqlInjection$/i,
  "principal-anomaly": /^SQL\.VM_PrincipalAnomaly$/i,
  "external-source": /^SQL\.VM_ShellExternalSourceAnomaly$/i,
  "obfuscated-shell": /^SQL\.VM_PotentialSqlInjection$/i,
};

export async function getRunDefenderEvidence(
  run,
  { environment = process.env, read = armRead, now = Date.now } = {},
) {
  const target = defenderTarget(environment);
  const result = {
    checkedAt: new Date(now()).toISOString(),
    state: "unavailable",
    alerts: [],
    blocking:
      "Not confirmed. Alert presence or lifecycle status does not prove Defender blocked execution.",
    portal: target.portal,
    detail: "A configured SQL VM and a valid recorded run are required.",
  };
  const started = Date.parse(run?.startedAt);
  const completed = Date.parse(run?.completedAt);
  if (
    !target.vmId ||
    !attackAlertTypes[run?.scenario] ||
    !Number.isFinite(started) ||
    !Number.isFinite(completed)
  )
    return result;
  const groupScope = target.vmId.split(/\/providers\//i)[0];
  const path = `${groupScope}/providers/Microsoft.Security/alerts`;
  const sqlVmId = target.vmId.replace(
    /Microsoft\.Compute\/virtualMachines/i,
    "Microsoft.SqlVirtualMachine/sqlVirtualMachines",
  );
  const resourceIds = [target.vmId, sqlVmId].map((value) =>
    value.toLowerCase(),
  );
  let next = `${path}?api-version=2022-01-01`;
  try {
    for (let page = 0; next && page < 5; page++) {
      const data = await read(next);
      if (!Array.isArray(data.value))
        throw new Error("Invalid alert response.");
      for (const entry of data.value) {
        const properties = entry.properties || {};
        if (/sentinel/i.test(properties.productName || "")) continue;
        if (
          !properties.resourceIdentifiers?.some((resource) =>
            resourceIds.includes(
              String(resource.azureResourceId || "").toLowerCase(),
            ),
          )
        )
          continue;
        const first = Date.parse(properties.startTimeUtc);
        const last = Date.parse(
          properties.endTimeUtc || properties.startTimeUtc,
        );
        if (
          !Number.isFinite(first) ||
          !Number.isFinite(last) ||
          first > completed + 120000 ||
          last < started - 120000
        )
          continue;
        const evidence = JSON.stringify([
          properties.description,
          properties.entities,
          properties.extendedProperties,
          properties.supportingEvidence,
        ]);
        const correlated = [run.marker, run.correlationIdentity].some(
          (value) => value && evidence.includes(value),
        );
        if (
          !correlated &&
          !attackAlertTypes[run.scenario].test(properties.alertType || "")
        )
          continue;
        let portal = result.portal;
        try {
          const link = new URL(properties.alertUri);
          if (
            link.protocol === "https:" &&
            link.hostname === "portal.azure.com" &&
            !link.username &&
            !link.password
          )
            portal = link.href;
        } catch {}
        result.alerts.push({
          id: String(properties.systemAlertId || entry.name || ""),
          title: String(
            properties.alertDisplayName ||
              properties.alertType ||
              "Defender alert",
          ),
          type: String(properties.alertType || "Unknown"),
          severity: String(properties.severity || "Unknown"),
          status: String(properties.status || "Unknown"),
          startedAt: properties.startTimeUtc,
          correlation: correlated
            ? "Run marker or test identity matched"
            : "VM, activity window and alert family only; attribution unconfirmed",
          correlated,
          portal,
        });
      }
      next = null;
      if (data.nextLink) {
        const link = new URL(data.nextLink, "https://management.azure.com");
        if (
          link.origin !== "https://management.azure.com" ||
          link.username ||
          link.password ||
          link.pathname.toLowerCase() !== path.toLowerCase()
        )
          throw new Error("Invalid alert continuation.");
        next = `${link.pathname}${link.search}`;
      }
    }
    result.state = next
      ? "partial"
      : result.alerts.some((alert) => alert.correlated)
        ? "correlated"
        : result.alerts.length
          ? "possible"
          : "none-yet";
    result.detail = next
      ? "Partial results: the five-page lookup limit was reached. Review Defender for the complete list."
      : result.alerts.length
        ? "Review alert evidence below. Time and family matches alone do not prove this run caused an alert."
        : "No matching Defender alerts returned yet. Detection and ingestion can be delayed; this does not prove no detection or that the machine is unprotected.";
    return result;
  } catch {
    return {
      ...result,
      state: "unavailable",
      detail:
        "Defender alerts could not be fully read. Check managed-identity Security Reader access and Azure connectivity; no negative detection verdict is available.",
    };
  }
}
