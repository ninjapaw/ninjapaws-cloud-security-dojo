SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Mode varchar(10) = 'PREVIEW';
DECLARE @DatabaseName nvarchar(128) = N'YourDatabase';
DECLARE @Scope varchar(10) = 'OBJECT';
DECLARE @SchemaName nvarchar(128) = N'dbo';
DECLARE @ObjectName nvarchar(128) = N'YourTable';
DECLARE @PrincipalName nvarchar(128) = N'public';
DECLARE @AuditName nvarchar(128) = N'DataAccessAudit';
DECLARE @ServerSpecName nvarchar(128) = N'ServerSecurityAuditSpec';
DECLARE @DatabaseSpecName nvarchar(128) = N'DataAccessAuditSpec';
DECLARE @Target varchar(20) = 'FILE';
DECLARE @FilePath nvarchar(4000) = N'/var/opt/mssql/audit/';
DECLARE @IncludeServerActivity bit = 0;
DECLARE @AuditSelect bit = 1;
DECLARE @AuditInsert bit = 1;
DECLARE @AuditUpdate bit = 1;
DECLARE @AuditDelete bit = 1;

IF @Mode IS NULL OR @Mode NOT IN ('PREVIEW', 'APPLY', 'VERIFY')
    THROW 50001, 'Mode must be PREVIEW, APPLY, or VERIFY.', 1;
IF CONVERT(int, SERVERPROPERTY('EngineEdition')) NOT IN (2, 3, 4)
    THROW 50001, 'This template targets SQL Server, not Azure SQL Database, Managed Instance, or Fabric.', 1;
IF @Scope IS NULL OR @Scope NOT IN ('DATABASE', 'SCHEMA', 'OBJECT')
    THROW 50001, 'Scope must be DATABASE, SCHEMA, or OBJECT (table or view).', 1;
IF @Target IS NULL OR @Target NOT IN ('FILE', 'APPLICATION_LOG')
    THROW 50001, 'Target must be FILE or APPLICATION_LOG.', 1;
IF EXISTS (SELECT 1 FROM (VALUES (@DatabaseName), (@PrincipalName), (@AuditName), (@ServerSpecName), (@DatabaseSpecName)) AS names(value)
           WHERE value IS NULL OR LEN(LTRIM(RTRIM(value))) = 0)
    THROW 50001, 'Database, principal, and audit names must not be empty.', 1;
IF @Scope IN ('SCHEMA', 'OBJECT') AND (@SchemaName IS NULL OR LEN(LTRIM(RTRIM(@SchemaName))) = 0)
    THROW 50001, 'Schema name is required for SCHEMA and OBJECT scope.', 1;
IF @Scope = 'OBJECT' AND (@ObjectName IS NULL OR LEN(LTRIM(RTRIM(@ObjectName))) = 0)
    THROW 50001, 'Object name is required for OBJECT scope.', 1;
IF DB_ID(@DatabaseName) IS NULL OR ISNULL(HAS_DBACCESS(@DatabaseName), 0) <> 1
    THROW 50001, 'Target database does not exist or is inaccessible.', 1;
IF @Target = 'APPLICATION_LOG' AND NOT EXISTS (SELECT 1 FROM sys.dm_os_host_info WHERE host_platform = N'Windows')
    THROW 50001, 'APPLICATION_LOG requires Windows SQL Server. Use FILE on Linux.', 1;
IF @Target = 'FILE' AND (@FilePath IS NULL OR LEN(@FilePath) = 0 OR RIGHT(@FilePath, 1) NOT IN (N'/', N'\'))
    THROW 50001, 'FilePath must be an existing server-side directory ending in a path separator.', 1;

DECLARE @Actions nvarchar(100) = N'';
IF @AuditSelect = 1 SET @Actions += N'SELECT, ';
IF @AuditInsert = 1 SET @Actions += N'INSERT, ';
IF @AuditUpdate = 1 SET @Actions += N'UPDATE, ';
IF @AuditDelete = 1 SET @Actions += N'DELETE, ';
IF LEN(@Actions) = 0
    THROW 50001, 'Select at least one data action.', 1;
SET @Actions = LEFT(@Actions, LEN(@Actions) - 1);

DECLARE @DatabaseIdentifier nvarchar(258) = QUOTENAME(@DatabaseName);
DECLARE @AuditIdentifier nvarchar(258) = QUOTENAME(@AuditName);
DECLARE @ServerSpecIdentifier nvarchar(258) = QUOTENAME(@ServerSpecName);
DECLARE @DatabaseSpecIdentifier nvarchar(258) = QUOTENAME(@DatabaseSpecName);
DECLARE @Securable nvarchar(600) = CASE @Scope
    WHEN 'DATABASE' THEN N'DATABASE::' + @DatabaseIdentifier
    WHEN 'SCHEMA' THEN N'SCHEMA::' + QUOTENAME(@SchemaName)
    ELSE N'OBJECT::' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@ObjectName) END;
DECLARE @CheckSql nvarchar(max) = N'USE ' + @DatabaseIdentifier + N';
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @Principal)
    THROW 50001, ''Database principal does not exist.'', 1;
IF @ScopeValue IN (''SCHEMA'', ''OBJECT'') AND SCHEMA_ID(@Schema) IS NULL
    THROW 50001, ''Schema does not exist.'', 1;
IF @ScopeValue = ''OBJECT'' AND NOT EXISTS (
    SELECT 1 FROM sys.objects WHERE schema_id = SCHEMA_ID(@Schema) AND name = @Object AND type IN (''U'', ''V''))
    THROW 50001, ''Target table or view does not exist.'', 1;
IF @Apply = 1 AND EXISTS (SELECT 1 FROM sys.database_audit_specifications WHERE name = @Spec)
    THROW 50001, ''Database audit specification already exists. No changes made; use VERIFY or new audit names.'', 1;';
DECLARE @Apply bit = CASE WHEN @Mode = 'APPLY' THEN 1 ELSE 0 END;
EXEC sys.sp_executesql @CheckSql,
    N'@Principal nvarchar(128), @ScopeValue varchar(10), @Schema nvarchar(128), @Object nvarchar(128), @Spec nvarchar(128), @Apply bit',
    @PrincipalName, @Scope, @SchemaName, @ObjectName, @DatabaseSpecName, @Apply;

DECLARE @Destination nvarchar(max) = CASE @Target WHEN 'APPLICATION_LOG' THEN N'APPLICATION_LOG'
    ELSE N'FILE (FILEPATH = N''' + REPLACE(@FilePath, N'''', N'''''') + N''', MAXSIZE = 100 MB, MAX_ROLLOVER_FILES = 10)' END;
DECLARE @SetupSql nvarchar(max) = N'USE [master];
CREATE SERVER AUDIT ' + @AuditIdentifier + N' TO ' + @Destination + N'
WITH (QUEUE_DELAY = 1000, ON_FAILURE = CONTINUE);
';
IF @IncludeServerActivity = 1
    SET @SetupSql += N'CREATE SERVER AUDIT SPECIFICATION ' + @ServerSpecIdentifier + N'
FOR SERVER AUDIT ' + @AuditIdentifier + N'
ADD (FAILED_LOGIN_GROUP), ADD (SUCCESSFUL_LOGIN_GROUP),
ADD (LOGIN_CHANGE_PASSWORD_GROUP), ADD (SERVER_PRINCIPAL_CHANGE_GROUP),
ADD (SERVER_PERMISSION_CHANGE_GROUP), ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP), ADD (AUDIT_CHANGE_GROUP)
WITH (STATE = ON);
';
SET @SetupSql += N'USE ' + @DatabaseIdentifier + N';
CREATE DATABASE AUDIT SPECIFICATION ' + @DatabaseSpecIdentifier + N'
FOR SERVER AUDIT ' + @AuditIdentifier + N'
ADD (' + @Actions + N' ON ' + @Securable + N' BY ' + QUOTENAME(@PrincipalName) + N')
WITH (STATE = ON);
USE [master];
ALTER SERVER AUDIT ' + @AuditIdentifier + N' WITH (STATE = ON);';

DECLARE @VerifySql nvarchar(max) = N'USE [master];
SELECT audit.name, audit.is_state_enabled, audit.type_desc, audit.on_failure_desc, runtime.status_desc
FROM sys.server_audits AS audit
LEFT JOIN sys.dm_server_audit_status AS runtime ON runtime.audit_id = audit.audit_id
WHERE audit.name = N''' + REPLACE(@AuditName, N'''', N'''''') + N''';
SELECT spec.name, spec.is_state_enabled, detail.audit_action_name
FROM sys.server_audit_specifications AS spec
JOIN sys.server_audit_specification_details AS detail ON detail.server_specification_id = spec.server_specification_id
WHERE spec.name = N''' + REPLACE(@ServerSpecName, N'''', N'''''') + N''';
USE ' + @DatabaseIdentifier + N';
SELECT spec.name, spec.is_state_enabled, detail.audit_action_name, detail.class_desc,
       detail.major_id, detail.audited_principal_id
FROM sys.database_audit_specifications AS spec
JOIN sys.database_audit_specification_details AS detail ON detail.database_specification_id = spec.database_specification_id
WHERE spec.name = N''' + REPLACE(@DatabaseSpecName, N'''', N'''''') + N''';';

IF @Mode = 'PREVIEW'
BEGIN
    SELECT @SetupSql AS SetupSql, @VerifySql AS VerifySql;
    RETURN;
END;
IF @Mode = 'APPLY'
BEGIN
    IF EXISTS (SELECT 1 FROM sys.server_audits WHERE name = @AuditName)
       OR (@IncludeServerActivity = 1 AND EXISTS (SELECT 1 FROM sys.server_audit_specifications WHERE name = @ServerSpecName))
        THROW 50001, 'Server audit or specification already exists. No changes made; use VERIFY or new audit names.', 1;
    EXEC sys.sp_executesql @SetupSql;
END;
EXEC sys.sp_executesql @VerifySql;