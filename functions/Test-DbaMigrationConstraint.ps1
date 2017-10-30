function Test-DbaMigrationConstraint {
	<#
		.SYNOPSIS
			Show if you can migrate the database(s) between the servers.

		.DESCRIPTION
			When you want to migrate from a higher edition to a lower one there are some features that can't be used.
			This function will validate if you have any of this features in use and will report to you.
			The validation will be made ONLY on on SQL Server 2008 or higher using the 'sys.dm_db_persisted_sku_features' dmv.

			This function only validate SQL Server 2008 versions or higher.
			The editions supported by this function are:
				- Enterprise
				- Developer
				- Evaluation
				- Standard
				- Express

			Take into account the new features introduced on SQL Server 2016 SP1 for all versions. More information at https://blogs.msdn.microsoft.com/sqlreleaseservices/sql-server-2016-service-pack-1-sp1-released/

			The -Database parameter is auto-populated for command-line completion.

		.PARAMETER Source
			Source SQL Server. You must have sysadmin access and server version must be SQL Server version 2000 or higher.

		.PARAMETER SourceSqlCredential
			Allows you to login to servers using SQL Logins instead of Windows Authentication (AKA Integrated or Trusted). To use:

			$scred = Get-Credential, then pass $scred object to the -SourceSqlCredential parameter.

			Windows Authentication will be used if SourceSqlCredential is not specified. SQL Server does not accept Windows credentials being passed as credentials.

			To connect as a different Windows user, run PowerShell as that user.

		.PARAMETER Destination
			Destination SQL Server. You must have sysadmin access and the server must be SQL Server 2000 or higher.

		.PARAMETER DestinationSqlCredential
			Allows you to login to servers using SQL Logins instead of Windows Authentication (AKA Integrated or Trusted). To use:

			$dcred = Get-Credential, then pass this $dcred to the -DestinationSqlCredential parameter.

			Windows Authentication will be used if DestinationSqlCredential is not specified. SQL Server does not accept Windows credentials being passed as credentials.

			To connect as a different Windows user, run PowerShell as that user.

		.PARAMETER Database
			The database(s) to process. Options for this list are auto-populated from the server. If unspecified, all databases will be processed.

		.PARAMETER ExcludeDatabase
			The database(s) to exclude. Options for this list are auto-populated from the server.

		.PARAMETER EnableException
			By default, when something goes wrong we try to catch it, interpret it and give you a friendly warning message.
			This avoids overwhelming you with "sea of red" exceptions, but is inconvenient because it basically disables advanced scripting.
			Using this switch turns this "nice by default" feature off and enables you to catch exceptions with your own try/catch.

		.NOTES
			Tags: Migration

			Author: Claudio Silva (@ClaudioESSilva)
			Website: https://dbatools.io
			Copyright: (C) Chrissy LeMaire, clemaire@gmail.com
			License: GNU GPL v3 https://opensource.org/licenses/GPL-3.0

		.LINK
			https://dbatools.io/Test-DbaMigrationConstraint

		.EXAMPLE
			Test-DbaMigrationConstraint -Source sqlserver2014a -Destination sqlcluster

			All databases on sqlserver2014a will be verified for features in use that can't be supported on sqlcluster.

		.EXAMPLE
			Test-DbaMigrationConstraint -Source sqlserver2014a -Destination sqlcluster -SqlCredential $cred

			All databases will be verified for features in use that can't be supported on the destination server. SQL credentials are used to authenticate against sqlserver2014 and Windows Authentication is used for sqlcluster.

		.EXAMPLE
			Test-DbaMigrationConstraint -Source sqlserver2014a -Destination sqlcluster -Database db1

			Only db1 database will be verified for features in use that can't be supported on the destination server.
	#>
	[CmdletBinding(DefaultParameterSetName = "DbMigration")]
	param (
		[parameter(Mandatory = $true, ValueFromPipeline = $True)]
		[DbaInstance]$Source,
		[PSCredential]$SourceSqlCredential,
		[parameter(Mandatory = $true)]
		[DbaInstance]$Destination,
		[PSCredential]$DestinationSqlCredential,
		[Alias("Databases")]
		[object[]]$Database,
		[object[]]$ExcludeDatabase,
		[switch][Alias('Silent')]$EnableException
	)

	begin {
		<#
			1804890536 = Enterprise
			1872460670 = Enterprise Edition: Core-based Licensing
			610778273 = Enterprise Evaluation
			284895786 = Business Intelligence
			-2117995310 = Developer
			-1592396055 = Express
			-133711905= Express with Advanced Services
			-1534726760 = Standard
			1293598313 = Web
			1674378470 = SQL Database
		#>

		$editions = @{
			"Enterprise" = 10;
			"Developer"  = 10;
			"Evaluation" = 10;
			"Standard"   = 5;
			"Express"    = 1
		}
		$notesCanMigrate = "Database can be migrated."
		$notesCannotMigrate = "Database cannot be migrated."
	}
	process {
		try {
			Write-Message -Level Verbose -Message "Connecting to $Source."
			$sourceServer = Connect-SqlInstance -SqlInstance $Source -SqlCredential $SourceSqlCredential
		}
		catch {
			Stop-Function -Message "Failure" -Category ConnectionError -ErrorRecord $_ -Target $Source -Continue
		}

		try {
			Write-Message -Level Verbose -Message "Connecting to $Destination."
			$destServer = Connect-SqlInstance -SqlInstance $Destination -SqlCredential $DestinationSqlCredential
		}
		catch {
			Stop-Function -Message "Failure" -Category ConnectionError -ErrorRecord $_ -Target $Destination -Continue
		}

		if ($Database -eq 0) {
			$Database = $sourceServer.Databases | Where-Object isSystemObject -eq 0 | Select-Object Name, Status
		}

		if ($ExcludeDatabase) {
			$Database = $sourceServer.Databases | Where-Object Name -NotIn $ExcludeDatabase
		}

		if ($Database -gt 0) {
			if ($Database -contains "master" -or $Database -contains "msdb" -or $Database -contains "tempdb") {
				Stop-Function -Message "Migrating system databases is not currently supported."
				return
			}

			if ($sourceServer.VersionMajor -lt 9 -and $destServer.VersionMajor -gt 10) {
				Stop-Function -Message "Sql Server 2000 databases cannot be migrated to SQL Server version 2012 and above. Quitting."
				return
			}

			if ($sourceServer.Collation -ne $destServer.Collation) {
				Write-Message -Level Warning -Message "Collation on $Source, $($sourceServer.collation) differs from the $Destination, $($destServer.collation)."
			}

			if ($sourceServer.VersionMajor -gt $destServer.VersionMajor) {
				#indicate they must use 'Generate Scripts' and 'Export Data' options?
				Stop-Function -Message "You can't migrate databases from a higher version to a lower one. Quitting."
				return
			}

			if ($sourceServer.VersionMajor -lt 10) {
				Stop-Function -Message "This function does not support versions lower than SQL Server 2008 (v10)"
				return
			}

			#if editions differs, from higher to lower one, verify the sys.dm_db_persisted_sku_features - only available from SQL 2008 +
			if (($sourceServer.VersionMajor -ge 10 -and $destServer.VersionMajor -ge 10)) {
				foreach ($db in $Database) {
					if ([string]::IsNullOrEmpty($db.Status)) {
						$dbstatus = ($sourceServer.Databases | Where-Object Name -eq $db).Status.ToString()
						$dbName = $db
					}
					else {
						$dbstatus = $db.Status.ToString()
						$dbName = $db.Name
					}

					Write-Message -Level Verbose -Message "Checking database '$dbName'."

					if ($dbstatus.Contains("Offline") -eq $false) {
						[long]$destVersionNumber = $($destServer.VersionString).Replace(".", "")
						[string]$sourceVersion = "$($sourceServer.Edition) $($sourceServer.ProductLevel) ($($sourceServer.Version))"
						[string]$destVersion = "$($destServer.Edition) $($destServer.ProductLevel) ($($destServer.Version))"
						[string]$dbFeatures = ""

						try {
							$sql = "SELECT feature_name FROM sys.dm_db_persisted_sku_features"

							$skuFeatures = $sourceServer.Query($sql,$dbName)

							Write-Message -Level Verbose -Message "Checking features in use..."

							if ($skuFeatures.Count -gt 0) {
								foreach ($row in $skuFeatures) {
									$dbFeatures += ",$($row["feature_name"])"
								}

								$dbFeatures = $dbFeatures.TrimStart(",")
							}
						}
						catch {
							Stop-Function -Message "Issue collecting sku features." -ErrorRecord $_ -Target $sourceServer -Continue
						}

						#If SQL Server 2016 SP1 (13.0.4001.0) or higher
						if ($destVersionNumber -ge 13040010) {
							<#
								Need to verify if Edition = EXPRESS and database uses 'Change Data Capture' (CDC)
								This means that database cannot be migrated because Express edition doesn't have SQL Server Agent
							#>
							if ($editions.Item($destServer.Edition.ToString().Split(" ")[0]) -eq 1 -and $dbFeatures.Contains("ChangeCapture")) {
								[pscustomobject]@{
									SourceInstance      = $sourceServer.Name
									DestinationInstance = $destServer.Name
									SourceVersion       = $sourceVersion
									DestinationVersion  = $destVersion
									Database            = $dbName
									FeaturesInUse       = $dbFeatures
									Notes               = "$notesCannotMigrate. Destination server edition is EXPRESS which does not support 'ChangeCapture' feature that is in use."
								}
							}
							else {
								[pscustomobject]@{
									SourceInstance      = $sourceServer.Name
									DestinationInstance = $destServer.Name
									SourceVersion       = $sourceVersion
									DestinationVersion  = $destVersion
									Database            = $dbName
									FeaturesInUse       = $dbFeatures
									Notes               = $notesCanMigrate
								}
							}
						}
						#Version is lower than SQL Server 2016 SP1
						else {
							Write-Verbose "Source Server Edition: $($sourceServer.Edition) (Weight: $($editions.Item($sourceServer.Edition.ToString().Split(" ")[0])))"
							Write-Verbose "Destination Server Edition: $($destServer.Edition) (Weight: $($editions.Item($destServer.Edition.ToString().Split(" ")[0])))"

							#Check for editions. If destination edition is lower than source edition and exists features in use
							if (($editions.Item($destServer.Edition.ToString().Split(" ")[0]) -lt $editions.Item($sourceServer.Edition.ToString().Split(" ")[0])) -and (!([string]::IsNullOrEmpty($dbFeatures)))) {
								[pscustomobject]@{
									SourceInstance      = $sourceServer.Name
									DestinationInstance = $destServer.Name
									SourceVersion       = $sourceVersion
									DestinationVersion  = $destVersion
									Database            = $dbName
									FeaturesInUse       = $dbFeatures
									Notes               = "$notesCannotMigrate There are features in use not available on destination instance."
								}
							}
							#
							else {
								[pscustomobject]@{
									SourceInstance      = $sourceServer.Name
									DestinationInstance = $destServer.Name
									SourceVersion       = $sourceVersion
									DestinationVersion  = $destVersion
									Database            = $dbName
									FeaturesInUse       = $dbFeatures
									Notes               = $notesCanMigrate
								}
							}
						}
					}
					else {
						Write-Warning "Database '$dbName' is offline. Bring database online and re-run the command"
					}

				}
			}
			else {
				#SQL Server 2005 or under
				Write-Warning "This validation will not be made on versions lower than SQL Server 2008 (v10)."
				Write-Verbose "Source server version: $($sourceServer.versionMajor)."
				Write-Verbose "Destination server version: $($destServer.versionMajor)."
			}
		}
		else {
			Write-Output "There are no databases to validate."
		}
	}
	END {
		$sourceServer.ConnectionContext.Disconnect()
		$destServer.ConnectionContext.Disconnect()
		Test-DbaDeprecation -DeprecatedOn "1.0.0" -EnableException:$false -Alias Test-SqlMigrationConstraint
	}
}

