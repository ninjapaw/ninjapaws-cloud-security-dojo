/*
  Safe SQL Audit samples for the Futon Manufacturing training database.

  Run only against an isolated training instance with SQL Server Audit enabled.
  Replace <run-id> with a unique identifier to correlate Windows Event ID 33205.
  The portal uses the same fixed operations; it does not accept arbitrary SQL.
*/

USE FutonManufacturing;
GO

-- Read-only audit sample.
SELECT TOP (1) *
FROM dbo.Items; /* dojo-audit-probe:<run-id> */
GO

-- Isolated data-change sample. It always rolls back and does not alter business rows.
BEGIN TRANSACTION;
IF OBJECT_ID('dbo.DojoAuditProbe', 'U') IS NOT NULL
    THROW 51000, 'DojoAuditProbe already exists; refusing to modify it.', 1;
CREATE TABLE dbo.DojoAuditProbe (Id int NOT NULL PRIMARY KEY, Note nvarchar(100) NOT NULL);
INSERT dbo.DojoAuditProbe (Id, Note) VALUES (1, N'dojo-audit-probe:<run-id>');
UPDATE dbo.DojoAuditProbe SET Note = N'updated dojo-audit-probe:<run-id>' WHERE Id = 1;
DELETE dbo.DojoAuditProbe WHERE Id = 1;
ROLLBACK TRANSACTION;
GO

-- Permission-boundary sample. Run as the least-privilege application login.
-- A SQL permission error is expected on hardened instances and is not a Defender block.
USE master;
GO
SELECT TOP (1) name
FROM sys.sql_logins; /* dojo-audit-probe:<run-id> */
GO