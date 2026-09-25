import { createHash } from "node:crypto";

export const externalSourceUrl =
  "https://ninjapaws-pawton-dev.azurewebsites.net/lab/external-source-canary.txt";
export const externalSourceContent =
  "Pawton SQL lab inert download canary. Never execute this file.";

export function externalSourceCommand(marker) {
  if (!/^dojo-attack-test:external-source:[a-f0-9-]{36}$/.test(marker))
    throw new Error("Invalid external-source marker.");
  const hash = createHash("sha256").update(externalSourceContent).digest("hex");
  const script = [
    "$ErrorActionPreference = 'Stop';",
    "$ProgressPreference = 'SilentlyContinue';",
    "$directory = $null; $response = $null; $stream = $null; $file = $null; $failed = $false;",
    "try {",
    "$directory = Join-Path ([IO.Path]::GetTempPath()) ('dojo-external-' + [guid]::NewGuid().ToString('N'));",
    "$null = New-Item -ItemType Directory -Path $directory;",
    "$path = Join-Path $directory 'canary.txt';",
    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12;",
    `$request = [Net.HttpWebRequest]::Create('${externalSourceUrl}?runId=${marker.split(":").at(-1)}');`,
    "$request.AllowAutoRedirect = $false; $request.Timeout = 10000; $request.ReadWriteTimeout = 3000; $request.MaximumResponseHeadersLength = 16;",
    "$request.UseDefaultCredentials = $false;",
    "$response = $request.GetResponse();",
    "if ([int]$response.StatusCode -ne 200 -or $response.ContentLength -gt 1024) { throw 'Unexpected response'; };",
    "$stream = $response.GetResponseStream();",
    "$file = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None);",
    "$buffer = New-Object byte[] 1025; $total = 0; $timer = [Diagnostics.Stopwatch]::StartNew();",
    "while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {",
    "$total += $count; if ($total -gt 1024 -or $timer.ElapsedMilliseconds -gt 10000) { throw 'Download limit exceeded'; };",
    "$file.Write($buffer, 0, $count); };",
    "$file.Dispose(); $file = $null;",
    "$hasher = [Security.Cryptography.SHA256]::Create();",
    "try { $digest = [BitConverter]::ToString($hasher.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-', ''); } finally { $hasher.Dispose(); };",
    `if ($digest -ne '${hash}') { throw 'Canary mismatch'; };`,
    "} catch { $failed = $true; } finally {",
    "try { if ($file) { $file.Dispose(); }; if ($stream) { $stream.Dispose(); }; if ($response) { $response.Dispose(); }; } catch { $failed = $true; };",
    "try { if ($directory -and (Test-Path -LiteralPath $directory)) { Remove-Item -LiteralPath $directory -Recurse -Force; }; } catch { $failed = $true; };",
    "};",
    "if ($failed) { Write-Output 'External download or cleanup failed; no Defender action is inferred.'; exit 1; };",
    `Write-Output '${marker}:download-verified-and-removed';`,
  ].join(" ");
  return `powershell.exe -NoProfile -NonInteractive -Command "${script}"`;
}
