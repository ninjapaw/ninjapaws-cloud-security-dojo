export const DEFAULT_TIME_ZONE = "America/New_York";

let cachedZone;
let cachedFormatter;
const timestampOptions = {
  year: "numeric",
  month: "short",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  timeZoneName: "short",
};

function getFormatter(value = process.env.PORTAL_TIME_ZONE) {
  const candidate =
    typeof value === "string" && value.trim()
      ? value.trim()
      : DEFAULT_TIME_ZONE;
  if (candidate === cachedZone && cachedFormatter) return cachedFormatter;
  try {
    cachedFormatter = new Intl.DateTimeFormat("en-US", {
      ...timestampOptions,
      timeZone: candidate,
    });
  } catch {
    cachedFormatter = new Intl.DateTimeFormat("en-US", {
      ...timestampOptions,
      timeZone: DEFAULT_TIME_ZONE,
    });
  }
  cachedZone = candidate;
  return cachedFormatter;
}

export function getPortalTimeZone(value = process.env.PORTAL_TIME_ZONE) {
  return getFormatter(value).resolvedOptions().timeZone;
}

export function formatTimestamp(
  value,
  timeZone = process.env.PORTAL_TIME_ZONE,
) {
  if (value === null || value === undefined || value === "")
    return "Unavailable";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Unavailable";
  return getFormatter(timeZone).format(date);
}
