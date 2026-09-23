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
