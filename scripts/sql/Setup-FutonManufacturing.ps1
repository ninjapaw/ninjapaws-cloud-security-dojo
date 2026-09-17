<#
.SYNOPSIS
    Ninja Paws Cloud Security Dojo - Scenario 2 VM bootstrap.

.DESCRIPTION
    Runs once via the Custom Script Extension after SQL Server is available on the
    "SQL Server 2022 on Windows Server 2022" marketplace image. It:
      1. Downloads the Futon Manufacturing sample database scripts from
         microsoft/sql-server-samples and restores them in order.
      2. Applies SQL Server security best practices: Transparent Data Encryption,
         SQL Server Audit to the Windows Security event log (collected by Defender
         for Endpoint / MDE), a least-privilege application login instead of sa,
         and disabling the legacy SQL Server Browser service.

    This script uses sqlcmd.exe (bundled with every SQL Server engine install) rather than the
    SqlServer PowerShell module, because Install-Module can hang on an interactive repository-
    trust prompt that a Custom Script Extension has no stdin to answer. The application login
    password is supplied by the deploy script and never printed anywhere other than this VM's
    local transcript log.
#>

[CmdletBinding()]
param(
    [string]$DatabaseName = 'FutonManufacturing',
    [string]$SourceRepoRawBaseUrl = 'https://raw.githubusercontent.com/microsoft/sql-server-samples/master/samples/databases/futon-manufacturing',
    [string]$AppLoginName = 'futon_app',
    [Parameter(Mandatory = $true)]
    [string]$AppLoginPassword
)

$ErrorActionPreference = 'Stop'
$logPath = 'C:\NinjaPawsDojo\bootstrap.log'
New-Item -ItemType Directory -Path (Split-Path $logPath) -Force | Out-Null
Start-Transcript -Path $logPath -Append

function Get-RandomPassword {
    param([int]$Length = 24)
    $specials = '!@#$%^&*-_='
    $bytes = New-Object byte[] $Length
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $core = ([Convert]::ToBase64String($bytes) -replace '[^a-zA-Z0-9]', 'x').Substring(0, $Length)
    # Insert one random special character at a random position instead of a fixed suffix,
    # so no part of the generated password is predictable across runs.
    $specialChar = $specials[(Get-Random -Maximum $specials.Length)]
    $insertAt = Get-Random -Maximum ($core.Length + 1)
    return $core.Insert($insertAt, $specialChar)
}

Write-Host "== Ninja Paws Dojo :: Futon Manufacturing bootstrap starting =="

# sqlcmd.exe ships with every SQL Server engine install and needs no PowerShell Gallery access.
# Invoke-Sqlcmd (the SqlServer module) was avoided deliberately: Install-Module can block on an
# interactive "untrusted repository" prompt, and a Custom Script Extension has no stdin to answer it.
function Invoke-SqlFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    # -I: sqlcmd defaults QUOTED_IDENTIFIER to OFF (SSMS/Invoke-Sqlcmd default it ON), which breaks
    # CREATE TABLE statements using indexed views, computed columns, or filtered indexes.
    & sqlcmd -S localhost -E -b -I -i $Path
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd failed executing '$Path' (exit code $LASTEXITCODE)."
    }
}

function Invoke-SqlText {
    param([Parameter(Mandatory = $true)][string]$Query)
    & sqlcmd -S localhost -E -b -I -Q $Query
    if ($LASTEXITCODE -ne 0) {
        throw "sqlcmd failed executing inline query (exit code $LASTEXITCODE)."
    }
}

function Test-SqlSysadmin {
    $result = & sqlcmd -S localhost -E -h -1 -W -Q "SET NOCOUNT ON; SELECT CAST(IS_SRVROLEMEMBER('sysadmin') AS VARCHAR(1))" 2>$null
    return (($result -join '') -match '1')
}

# Custom Script Extension always runs as NT AUTHORITY\SYSTEM, but this marketplace image only
# grants sysadmin to the (disabled-by-default) 'sa' login -- SYSTEM itself starts with no SQL
# permissions at all. Recover access the standard, documented way: start the engine in
# single-user mode, where the connecting Windows administrator is treated as sysadmin regardless
# of actual role membership, grant SYSTEM sysadmin for real, then go back to normal service mode.
if (-not (Test-SqlSysadmin)) {
    Write-Host "NT AUTHORITY\SYSTEM has no SQL Server permissions yet; recovering sysadmin access via single-user mode."
    $serviceInfo = Get-CimInstance -ClassName Win32_Service -Filter "Name='MSSQLSERVER'"
    $exePath = ($serviceInfo.PathName -split '"')[1]
    Stop-Service -Name MSSQLSERVER -Force
    Start-Sleep -Seconds 5
    $singleUserProcess = Start-Process -FilePath $exePath -ArgumentList '-m', '-c' -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 15
    try {
        & sqlcmd -S localhost -E -Q "ALTER SERVER ROLE sysadmin ADD MEMBER [NT AUTHORITY\SYSTEM];"
        if ($LASTEXITCODE -ne 0) {
            throw "ALTER SERVER ROLE failed in single-user mode (exit code $LASTEXITCODE)."
        }
    } finally {
        Stop-Process -Id $singleUserProcess.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 5
        Start-Service -Name MSSQLSERVER
        Start-Sleep -Seconds 20
    }
    if (-not (Test-SqlSysadmin)) {
        throw "NT AUTHORITY\SYSTEM still lacks sysadmin after the single-user mode recovery attempt."
    }
    Write-Host "Sysadmin access recovered for NT AUTHORITY\SYSTEM."
}

$scriptFiles = @(
    '01-schema.sql',
    '02-sample-data.sql',
    '03-manufacturing-reports.sql',
    '05-sales-schema-enhancements.sql',
    '06-sales-sample-data.sql',
    '07-sales-reports.sql'
)

$downloadDir = 'C:\NinjaPawsDojo\futon-manufacturing'
New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null

foreach ($file in $scriptFiles) {
    $uri = "$SourceRepoRawBaseUrl/$file"
    $dest = Join-Path $downloadDir $file
    Write-Host "Downloading $uri"
    Invoke-WebRequest -Uri $uri -OutFile $dest -UseBasicParsing
}

Write-Host "== Restoring Futon Manufacturing sample database =="
foreach ($file in $scriptFiles) {
    $path = Join-Path $downloadDir $file
    Write-Host "Executing $file"
    Invoke-SqlFile -Path $path
}

Write-Host "== Applying SQL Server security best practices =="

# 1. Transparent Data Encryption protects the data and log files at rest.
$tdeSql = @"
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = 'FutonManufacturingTDECert')
BEGIN
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$(Get-RandomPassword)';
    CREATE CERTIFICATE FutonManufacturingTDECert WITH SUBJECT = 'Futon Manufacturing TDE protector';
END
USE $DatabaseName;
IF NOT EXISTS (SELECT 1 FROM sys.dm_database_encryption_keys WHERE database_id = DB_ID())
BEGIN
    CREATE DATABASE ENCRYPTION KEY WITH ALGORITHM = AES_256 ENCRYPTION BY SERVER CERTIFICATE FutonManufacturingTDECert;
    ALTER DATABASE $DatabaseName SET ENCRYPTION ON;
END
"@
Invoke-SqlText -Query $tdeSql

# 2. Server audit writes to the Windows Application log. SECURITY_LOG would need the SQL
#    service account granted "Generate security audits" plus an auditpol change on the host,
#    neither of which this training image has configured; Application log needs neither and
#    Defender for Endpoint / Sentinel can still collect it.
$auditSql = @"
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.server_audits WHERE name = 'FutonManufacturingAudit')
BEGIN
    CREATE SERVER AUDIT FutonManufacturingAudit TO APPLICATION_LOG
        WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);
    ALTER SERVER AUDIT FutonManufacturingAudit WITH (STATE = ON);
END
IF NOT EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = 'FutonManufacturingServerAuditSpec')
BEGIN
    CREATE SERVER AUDIT SPECIFICATION FutonManufacturingServerAuditSpec
        FOR SERVER AUDIT FutonManufacturingAudit
        ADD (FAILED_LOGIN_GROUP),
        ADD (SUCCESSFUL_LOGIN_GROUP),
        ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),
        ADD (SERVER_PERMISSION_CHANGE_GROUP)
        WITH (STATE = ON);
END
USE $DatabaseName;
IF NOT EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = 'FutonManufacturingDbAuditSpec')
BEGIN
    CREATE DATABASE AUDIT SPECIFICATION FutonManufacturingDbAuditSpec
        FOR SERVER AUDIT FutonManufacturingAudit
        ADD (SELECT, INSERT, UPDATE, DELETE ON DATABASE::$DatabaseName BY public)
        WITH (STATE = ON);
END
"@
Invoke-SqlText -Query $auditSql

# 3. Least-privilege application login: db_datareader/db_datawriter only, never sysadmin, and
#    never the shared sa account. The password is supplied by the deploy script (the same value
#    it also writes to Key Vault for the dashboard Web App), never generated locally, so both
#    sides of the connection always agree on the credential.
$appPassword = $AppLoginPassword
$loginSql = @"
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '$AppLoginName')
BEGIN
    CREATE LOGIN [$AppLoginName] WITH PASSWORD = N'$appPassword', CHECK_POLICY = ON, CHECK_EXPIRATION = ON;
END
USE $DatabaseName;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '$AppLoginName')
BEGIN
    CREATE USER [$AppLoginName] FOR LOGIN [$AppLoginName];
    ALTER ROLE db_datareader ADD MEMBER [$AppLoginName];
    ALTER ROLE db_datawriter ADD MEMBER [$AppLoginName];
END
-- Disable the shared sa login; the dojo never uses it after bootstrap.
ALTER LOGIN [sa] DISABLE;
"@
Invoke-SqlText -Query $loginSql
Write-Host "Application login '$AppLoginName' created; its password matches the Key Vault secret the dashboard Web App reads."

# 4. Turn off the SQL Server Browser service; the dojo uses a fixed static port (1433) and does
#    not need named-instance discovery, which is an unnecessary attack surface on the network.
Set-Service -Name SQLBrowser -StartupType Disabled -ErrorAction SilentlyContinue
Stop-Service -Name SQLBrowser -Force -ErrorAction SilentlyContinue

# 5. Force encrypted connections at the server level (Force Encryption), matching the
#    "Defender for SQL" recommendation to require TLS between clients and the engine.
Write-Host "Enabling Force Encryption via registry (requires a service restart to take effect)"
$sqlRegPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer\SuperSocketNetLib'
if (Test-Path $sqlRegPath) {
    Set-ItemProperty -Path $sqlRegPath -Name 'ForceEncryption' -Value 1 -ErrorAction SilentlyContinue
}
Restart-Service -Name MSSQLSERVER -Force

Write-Host "== Ninja Paws Dojo :: Futon Manufacturing bootstrap complete =="
Stop-Transcript
