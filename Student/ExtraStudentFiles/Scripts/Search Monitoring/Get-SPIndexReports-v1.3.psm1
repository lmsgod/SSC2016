function Get-SPIndexReports {
<#
.SYNOPSIS 
	Builds SharePoint Search 2013 Index Health reports for analysis and troubleshooting.

.DESCRIPTION 
    Version 1.3 (last updated 11/3/2015) 

    This Get-SPIndexReports module/cmdlet can be used to retrieve detailed diagnostic information for monitoring and managing both the overall topology of the search system and the search index states. This cmdlet can provide a broad SSA-level report, or component-level reports for each index that is not in an "Unknown" state. 
	
	To report on the search index as a whole, the SSA-level report and current topology can be used to determine where to retrieve the component-level reports from. This cmdlet combines these reports into a single summary that can be used to check the overall status of an SSA's search index and interpret ULS log events relating to that search index.
	
	Although this cmdlet works to handle multiple SSAs, it is designed and intended primarily for farms with a single SSA.
	
	Notes:
	 - The core logic is directly based on the work from Dan Pandre:
	   Monitoring an SSA's index
	   http://social.technet.microsoft.com/wiki/contents/articles/30598.monitoring-an-ssa-s-index.aspx
	   
	 - Work converting/packaging that original work into this cmdlet by Brian Pendergrass
	 
.INPUTS
	$SearchServiceApplication [Microsoft.Office.Server.Search.Administration.SearchServiceApplication]
	
.PARAMETER Detailed
	Additional details will be included at the bottom of the report

.PARAMETER DiskReports
	Builds the Disk Reports ($SSA._DiskReports) and output without having to use the Detailed flag

.PARAMETER IncludeMMExitReports
	(Aliased as "MMExit")
	**Not yet fully implemented**
	Will also trigger a Merge-SPLogFile covering last 24 hours looking for event "acdru" (Master merge exit after [n] ms)
	This may be very heavy-handed and should be used conservatively 

.PARAMETER IgnoreReport
	Repopulates the data, but a report will not be generated
	
	After running this at least once, the customized $SSA has an equivalent alternative: 
	$SSA._RefreshIndexReportData()
	
.PARAMETER ReturnOutputAsSSAObjectOnly
	(Aliased as "OutputSSA") 
	Bypassess the report generation and instead, the return value of this cmdlet is as an $SSA object allowing for other more complex pipelining of commands, such as:
	"SSA" | Get-SPIndexReports -OutputSSA | % {$_.id}

.OUTPUTS
	Reports returned as an Object[]
	Also creates an object named $SSA into the shel's global scope
	
.EXAMPLE
	Assumes a single SSA has been provisioned in this farm (creates $SSA object in the global scope)
	
	Get-SPIndexReports -Verbose

.EXAMPLE
	Specify a single SSA object, name, or ID of an SSA provisioned in this farm (creates $SSA object in the global scope)
	
	#Equivalent invocations...
	Get-SPIndexReports "-the-name-of-my-SSA-"
	Get-SPIndexReports "f9ed646c-e520-4fc2-91fb-2ec963fae67a"
	Get-SPIndexReports $SSA
	Get-SPIndexReports         #assuming one SSA in the farm

.EXAMPLE
	Pipeline a single SSA object (creates $SSA object in the global scope)
	
	$targetSSA = Get-SPEnterpriseSearchServiceApplication "-the-name-of-my-SSA-"
	$targetSSA | Get-SPIndexReports 

.EXAMPLE
	Pipeline the name (or ID) of a single SSA object (creates $SSA object in the global scope)
	
	$targetSSAName = "-the-name-of-my-SSA-"
	$targetSSAName | Get-SPIndexReports 
	
.EXAMPLE
	Pipeline multiple SSA objects (creates a dictiontionary named $SSAs with a child object for each SSA)
	
	Get-SPEnterpriseSearchServiceApplication | Get-SPIndexReports 
	
.EXAMPLE
	Return the values as an $SSA object allowing for other more complex pipelining of commands (e.g. writng your own custom reports)
	"-the-name-of-my-SSA-" | Get-SPIndexReports -OutputSSA | foreach {$_.id}

#>
[CmdletBinding()]
param ( 
  [parameter(Mandatory=$false,ValueFromPipeline=$true,Position=0)][alias("SSA")] $SearchServiceApplication = $null,
  [switch]$Detailed,
  [alias("DiskReports")][switch]$IncludeDiskReports,
  [alias("MMExit")][switch]$IncludeMMExitReports,
  [switch]$IgnoreReport,
  [alias("OutputSSA")][switch]$ReturnOutputAsSSAObjectOnly
)

	BEGIN { 
		$results = @{}
	} 

	PROCESS {
		if ($SearchServiceApplication -eq $null) {
			$targetSSA = Get-SPSearchIndexReportData
		} else {
			$targetSSA = Get-SPSearchIndexReportData $SearchServiceApplication
		}

		if ($targetSSA -ne $null){ 
			$results[$targetSSA.Name] = $targetSSA
			#Only output the report when both of these flags are false
			if ((-not $refreshOnly) -and (-not $ReturnOutputAsSSAObjectOnly)) { 
				Out-SPSearchIndexReports $targetSSA 
			}
		}	
	}

	END { 
		if ($results.Count -eq 1) { 
			if ($ReturnOutputAsSSAObjectOnly) {
				return $results[$(($results.keys)[0])]
			} else {
				$global:SSA = $results[$(($results.keys)[0])]
				Write-Verbose ("`$SSA has been created in this shell with extend properties")
				Write-Verbose ("For Reference, see output to: `$SSA | gm | Where {`$_.Name -like `"_*`"}")
			}
		} else {
			$global:SSAs = $results
			if ($results.Count -gt 1) {
				Write-Verbose ("A dictionary object named `$SSAs has been created with child objects for each SSA")
			}
		}
		Write-Host 
	}
}

#======================================
# === Private Helper Functions ========
#======================================

function Get-SPSearchIndexReportData {
param ($targetSSA = $null)
	if (($targetSSA -ne $null) -and ($targetSSA -is [string])) {
	    Write-Host ("Getting reports from target SSA with name " + $targetSSA)
		$targetSSA = Get-SPEnterpriseSearchServiceApplication $targetSSA -ErrorAction SilentlyContinue 
	} 
	if ($targetSSA -isNot [Microsoft.Office.Server.Search.Administration.SearchServiceApplication]) {
		$targetSSA = Get-SPEnterpriseSearchServiceApplication
	}
	
	if ($targetSSA.count -gt 1) {
		Write-Error ("`n`n!!![Farm has multiple SSAs] Please specify a specific target SSA or pipepline multiple using syntax such as the following:`n  Get-SPEnterpriseSearchServiceApplication | Get-SPIndexReports`n`n")
		return $null
	}
	
	$tmpPath = $ENV:TMP
	if ($tmpPath -eq $null) { $tmpPath = $ENV:TEMP }
	if ($tmpPath -eq $null) { $tmpPath = $PWD.Path }

	function ssaSetCustomProperty {
		param ([string]$propertyName, $propertyValue)
		if ( $($targetSSA | Get-Member -Name $propertyName) -ne $null ) { 
            $targetSSA.$propertyName = $propertyValue 
		} else {
            $targetSSA | Add-Member -Force -MemberType NoteProperty   -Name $propertyName -Value $propertyValue 
		}
	}

	$targetSSA | Add-Member -Force -MemberType ScriptMethod -Name _GetIndexReports -Value { return $($this | Get-SPIndexReports) }
	$targetSSA | Add-Member -Force -MemberType ScriptMethod -Name _RefreshIndexReportData -Value { return $($this | Get-SPIndexReports -refreshOnly) }
	
	
	try { $ssaSystemStatus = $targetSSA | Get-SPEnterpriseSearchStatus -ErrorAction Stop }
	catch {
		Write-Error ($_.Exception.Message)
		Write-Warning ("~~~[Degraded Service] Attempt to retrieve Search Status Info from the System Manager failed")
		Write-Warning ("   (Note: The previous error may be expected/temporary if the Search Admin currently failing over)")
		Write-Verbose ($_.Exception)
		$ssaSystemStatus = $null
	}
	
	ssaSetCustomProperty "_SystemStatus" $ssaSystemStatus
	ssaSetCustomProperty "_Constellation" $($targetSSA.SystemManagerLocations.Segments[1].replace("/",""))
	ssaSetCustomProperty "_PrimarySearchAdmin" $($targetSSA.SystemManagerLocations.Segments[2].replace("/",""))
	ssaSetCustomProperty "_Indexers" $($targetSSA.ActiveTopology.GetComponents() | ? {$_ -is [Microsoft.Office.Server.Search.Administration.Topology.IndexComponent]})
	
	if ($ssaSystemStatus -ne $null) {
  	  ssaSetCustomProperty "_AdminReport" $(Get-SPEnterpriseSearchStatus -SearchApplication $targetSSA -Component $targetSSA._PrimarySearchAdmin -HealthReport)
	  ssaSetCustomProperty "_IndexSystem" $($targetSSA._AdminReport | ? {$_.name.startswith("active_index")} | % {$_.name -replace '.*\[(.*)\]','$1'})
	
	  $group = $targetSSA._SystemStatus | ? {$_.name -in $targetSSA._Indexers.name -and $_.state -eq "Unknown"}
	  if ($group.Count -eq 0) { $group = @() }
	  ssaSetCustomProperty "_hasStatusUnknown" $group

	  $group = $targetSSA._SystemStatus | ? {$_.name -in $targetSSA._Indexers.name -and $_.state -ne "Unknown"}
	  if ($group.Count -eq 0) { $group = @() }
	  ssaSetCustomProperty "_IndexerStatus" $group
		
	  ssaSetCustomProperty "_CellReports" @()
	}

	if ($targetSSA._MasterMergeChecked -ne $null) {
		$mergeCheckWindow = $targetSSA._MasterMergeChecked
	} else {
		$mergeCheckWindow = $(Get-Date).AddMinutes(-15)  
	}
	$ulsActionAbbrev = "MMTrigger"
	$ulsOutFilePath = Join-Path $tmpPath $("SPDiag\" + $targetSSA._Constellation + "\" + $ulsActionAbbrev)
	
	$mergedULS = Get-RecentULSExport $ulsOutFilePath $mergeCheckWindow
	if (($mergedULS -eq $null) -and ($Detailed)) {
      $mergedULS = Get-SPMergeULSbyEvent $ulsOutFilePath $mergeCheckWindow.AddMinutes(-2) @("aie8k","aie8l") $ulsActionAbbrev
	} 
  
  	#$mergedULS could still be null if the merge-splogfile gets 0 results...
  	if (($mergedULS -ne $null) -and (Test-Path $mergedULS)) {
	  Write-Verbose ("Parsing log file: " + $mergedULS)
	  $parsedULS = gc $mergedULS | % {[regex]::match($_,"(.*)OWSTIMER.*(IndexComponent\d+).*\) (.*), total=(\d+), master=(\d+), ratio=(\d+.\d+%), targetRatio=(\d+%)")} |
		  Where {$_.Success} | 
		  ForEach {New-Object PSObject -Property @{
			Time = [datetime]$_.groups[1].value;
			Component = $_.groups[2].value;
			UpdateGroup = $_.groups[3].value;
			Total = [int]$_.groups[4].value;
			Master = [int]$_.groups[5].value;
			Ratio = $_.groups[6].value;
			TargetRatio = $_.groups[7].value;
	      }}
  	} else {
  	  $parsedULS = @()
  	}
  
  	#$global:debugULSParsing = $parsedULS
  	if ($parsedULS.Count -gt 0) {
	  $mostRecentCheck = $($parsedULS | Sort Time -Descending | SELECT -first 1).Time
	  Write-Verbose ("Master Merge most recently checked by system: " + $mostRecentCheck)
	  ssaSetCustomProperty "_MasterMergeChecked" $mostRecentCheck
	  #Only use the events that occurred within 5 minutes of the most recent system check
	  ssaSetCustomProperty "_mmTriggerReportCache" $($parsedULS | Sort Time -Descending | ? {$_.Time -ge $mostRecentCheck.AddMinutes(-10)})
	} 

	$mergeEndWindow = $(Get-Date).AddDays(-1) #Last 24hrs
	$ulsActionAbbrev = "MMExit"
	$ulsOutFilePath = Join-Path $tmpPath $("SPDiag\" + $targetSSA._Constellation + "\" + $ulsActionAbbrev)
	
	$mergedULS = Get-RecentULSExport $ulsOutFilePath $mergeEndWindow
	if (($mergedULS -eq $null) -and ($IncludeMMExitReports)) {
	  Write-Host ("This may take several minutes to process [start time: " + $(Get-Date) + " ]")
      $mergedULS = Get-SPMergeULSbyEvent $ulsOutFilePath $mergeEndWindow "acdru" $ulsActionAbbrev
	} 

	#ToDo: Currently need to implement the parsing of each ULS event into a custom object
	if (($mergedULS -ne $null) -and (Test-Path $mergedULS)) {
	  Write-Host ("Parsing log file: " + $mergedULS)
	  $parsedULS = @() #so for now, just set this to an empty array
  	} else {
  	  $parsedULS = @()
  	}

  	if ($parsedULS.Count -gt 0) {
	  $mostRecentCompletion = $($parsedULS | Sort Time -Descending | SELECT -first 1).Time
	  Write-Verbose ("Master Merge most recently exited: " + $mostRecentCompletion)
	  ssaSetCustomProperty "_mmExitReportCache" $($parsedULS | Sort Time -Descending)
	} 

	if ($ssaSystemStatus -ne $null) {
	  $targetSSA._IndexerStatus | % {
		if (-not $ReturnOutputAsSSAObjectOnly) {
			Write-Host ("Getting reports data for " + $_.name + " (" + $_.name.replace("IndexComponent","NodeRunnerIndex") + ")")
		}
		
		$component = $_.name
		$health = Get-SPEnterpriseSearchStatus -HealthReport -Component $component -SearchApplication $targetSSA		
		$cellReport = New-Object PSObject

		foreach ($detail in $_.details) {
		  switch ($detail.key) {
		    "Primary"   {$cellReport | Add-Member $detail.key ($detail.value -match 'true')}
		    "Partition" {$cellReport | Add-Member $detail.key ([int]$detail.value)}
		    default     {$cellReport | Add-Member $detail.key $detail.value}
		  }
		}

		$cellReport | Add-Member Name $component
		$cellReport | Add-Member State $_.state
		$merge = ($health | ? {$_.name.startswith("plugin: master merge running")})
		
		$cellReport | Add-Member Cell ([int]($merge.name -split '\.')[2])
		$cellReport | Add-Member CellName ("[I.{0}.{1}]" -f $cellReport.Cell,$cellReport.Partition)

		$cellReport | Add-Member Merging ($merge.message -match 'true')
		
		if ($targetSSA._mmTriggerReportCache.Count -gt 0) {
			$mergeReports = $targetSSA._mmTriggerReportCache | Where {$_.Component -eq $component}
		} else { $mergeReports = @() }
		$cellReport | Add-Member MergeReports $mergeReports
		
		#$cellReport | Add-Member TotalDocs ([long]($health | ? {$_.name.startswith("part: number of documents including duplicate")} | % {[int]$_.message} | measure-object -sum).sum)
		$cellReport | Add-Member ActiveDocs ([int]($health | ? {$_.name.startswith("plugin: number of documents")}).message)
		$cellReport | Add-Member Generation ([int]($health | ? {$_.name.startswith("plugin: newest generation id")}).message)
		$cellReport | Add-Member CheckpointSize ([long]($health | ? {$_.name.startswith("plugin: size of newest checkpoint")}).message)
		 
		$targetSSA._CellReports += $cellReport
	  }
	}

	ssaSetCustomProperty "_DiskReports" @()	
	ForEach ($idx in $targetSSA._Indexers) {
		$diskReports = $targetSSA._DiskReports
		if ($Detailed -or $IncludeDiskReports) {
			$diskReport = New-Object PSObject
			$diskReport | Add-Member ServerName $idx.ServerName
			$diskReport | Add-Member Name $idx.name
			
			$idxPath = $idx.RootDirectory
			if (($idxPath -eq $null) -or ($idxPath -eq "")) {
				$idxPath = 	$targetSSA.AdminComponent.IndexLocation + "\Search\Nodes\" + $targetSSA._Constellation + "\" + $idx.Name + "\storage\data"
			} 
			$idxUnc = "\\" + $idx.ServerName + "\" + $idxPath.Replace(":\","$\")


			$cell = $targetSSA._CellReports | Where {$_.Name -ieq $idx.Name}
			if ($cell -ne $null) {
				$diskReport | Add-Member CellName $cell.CellName
				$cellNameValue = $cell.CellName.Substring(1, $cell.CellName.Length -2 ) #strip off the surrounding [ ] brackets
				$cellFolder = (Get-ChildItem -path $($idxUnc + "\" + $targetSSA._IndexSystem + "*" + $cellNameValue) | sort -Descending | SELECT -First 1).Name + "\"
				$idxUnc += "\" + $cellFolder + "\*"
				$idxPath = Join-Path $idxPath $cellFolder 
			}
			
			Write-Verbose $("Checking disk size: " + $idxPath)

			$diskReport | Add-Member Path $idxPath
			$diskReport | Add-Member DiskSize $(Get-ChildItem -path $($idxUnc) -Recurse -ErrorAction SilentlyContinue | measure -sum Length).Sum
			
			$volInfo = Get-WmiObject win32_volume -ComputerName $idx.ServerName | ? {$_.DriveLetter -match $idxPath[0]}
			$diskReport | Add-Member FreeSpace $volInfo.FreeSpace
			$diskReport | Add-Member Capacity $volInfo.Capacity

			if ($diskReport.DiskSize -gt 0) {
				$targetSSA._DiskReports += $diskReport
			}
			
			$idx | Add-Member Noderunner $(@())
			foreach ($noderunner in (Get-Process noderunner -ComputerName $idx.ServerName -ErrorAction SilentlyContinue)) {
				$noderunner | Add-Member -Force -MemberType NoteProperty -Name _ProcessCommandLine -Value $(
					(Get-WmiObject Win32_Process -ComputerName $idx.ServerName | Where {$_.processId -eq $noderunner.id}).CommandLine
				)			
				
				if ($noderunner._ProcessCommandLine -like $("*" + $idx.Name + "*")) 
				{ 
					$nodeReport = New-Object PSObject

					$nodeReport | Add-Member Component $($idx.Name)
					$nodeReport | Add-Member ServerName $($idx.ServerName)
					$nodeReport | Add-Member Name $($noderunner.Name)
					$nodeReport | Add-Member PID $($noderunner.Id)

					$nodeReport | Add-Member -Force -MemberType ScriptMethod -Name GetProcess -Value	{
						foreach ($noderunner in (Get-Process noderunner -ComputerName $this.ServerName -ErrorAction SilentlyContinue)) {
							$noderunner | Add-Member -Force -MemberType NoteProperty -Name _ProcessCommandLine -Value $(
								(Get-WmiObject Win32_Process -ComputerName $this.ServerName | where {$_.processId -eq $noderunner.id}).CommandLine
							)			
							if ($noderunner._ProcessCommandLine -like $("*" + $this.Component + "*")) { return $noderunner }
						}
					}
					
					$idx.Noderunner += $nodeReport

				}
			}
		}
	}
	ssaSetCustomProperty "_isCustomized" $true
	return $targetSSA
}

function Out-SPSearchIndexReports {
param ($targetSSA = $null)
	if (($targetSSA -ne $null) -and ($targetSSA._isCustomized)) {  
	  Write-Host
	  Write-Host -ForegroundColor DarkCyan $('-' * ($targetSSA.Name.length + 4))
	  Write-Host -ForegroundColor DarkCyan ("[ " + $targetSSA.Name + " ]")
	  Write-Host -ForegroundColor DarkCyan $('-' * ($targetSSA.Name.length + 4))
	  
	  if( $Host -and $Host.UI -and $Host.UI.RawUI ) {
		$rawUI = $Host.UI.RawUI
		$oldSize = $rawUI.BufferSize
        if ($oldSize.Width -lt 120) {
            $typeName = $oldSize.GetType().FullName
            $newSize = New-Object $typeName (120, $oldSize.Height)
            $rawUI.BufferSize = $newSize
        }
	  }
	  
	  if ($targetSSA._SystemStatus -ne $null) {
		$targetSSA._CellReports | Sort Partition,Cell | ft -auto Host,State,Name,CellName,Partition,Primary,Generation,ActiveDocs,Merging,@{l='CheckpointSize';e={($_.CheckpointSize / 1MB).tostring("#.#") + " (MB)"}}
		
		if ($targetSSA._hasStatusUnknown.Count -gt 0) {			
			Write-Warning ("The following components have an `"UNKNOWN`" status:")
			$targetSSA._hasStatusUnknown | ForEach {
				$c = $_.Name; 
				$p = $($targetSSA._Indexers | Where {$_.Name -eq $c}).IndexPartitionOrdinal;
				"{0} of Partition {1} cannot be contacted on server [{2}]" -f $c,$p,$_.details["Host"]
			}
		}
		
		$targetSSA._DiskReports | Sort Name | ft -auto ServerName,Name,@{l='Drive Capacity';e={($_.Capacity / 1MB).tostring("#.#") + " MB"}},@{l='Available Space';e={($_.FreeSpace / 1MB).tostring("#.#") + " MB"}},@{l='Size on Disk';e={($_.DiskSize / 1MB).tostring("#.#") +  " MB"}},Path
		 
		if ($targetSSA._CellReports.MergeReports.Count -gt 0) {
			if ($Detailed) {
				$targetSSA._CellReports.MergeReports | sort Component, UpdateGroup | ft -auto
			} else {
				$targetSSA._CellReports.MergeReports | ? {$_.UpdateGroup -match 'default'} | sort Component | ft -auto
			}
			$a = $($targetSSA._cellReports).Name
			$b = $($targetSSA._mmTriggerReportCache | SELECT Component -Unique).Component
			
			if ($a -ne $null) {
				$stillMerging = (Compare-Object $a $b).InputObject
				if ($stillMerging.Count -gt 0) {
					Write-Host -ForegroundColor Yellow ("A Merge Check report was not displayed for the following: ")
					Write-Host -ForegroundColor Gray ("(This may be normal if a long running merge is running or recently completed)")
					Write-Host -ForegroundColor Cyan $stillMerging
					Write-Host
				}
		}
			
		} else {
			if ($Detailed) {
				Write-Host -ForegroundColor Yellow ("No Merge Checks have occurred in the last 15 minutes.")
				Write-Host -ForegroundColor Gray ("  - This may be normal if a long running merge is running or recently completed")
				Write-Host
			}
		}
	 
		"Health Reports for Index System {0} of Constellation {1}:" -f $targetSSA._IndexSystem,$targetSSA._Constellation
		$targetSSA._AdminReport | sort name | ft -auto Name,Message,Level
	
		if ($Detailed) {
			"`nPrimary Search Admin for Constellation {0}: {1} on {2}" -f $targetSSA._Constellation,$targetSSA._PrimarySearchAdmin.replace("AdminComponent","NodeRunnerAdmin"),$targetSSA.SystemManagerLocations.Host
			"`nHome directory for {0}'s Constellation:`n{1}\Search\Nodes\{2}" -f $targetSSA.Name,$targetSSA.AdminComponent.IndexLocation,$targetSSA._Constellation
	 	}
	  } else {
		  Write-Warning ("System Status for " + $targetSSA.Name + " is `$null and thus cannot generate Index Report") 
	  }
	} else {
	  Write-Warning "---[unspecified SSA] Out-SPSearchIndexReports expects an `$targetSSA as an argument"
	  return $null
	}
}

function Get-RecentULSExport {
	param ($parentFolder, [DateTime]$windowStart)

	$currentLogFile = $null
	if (-not (Test-Path $parentFolder)) { 
  	  if (($Detailed) -or ($IncludeMMExitReports)) {
    	Write-Verbose ("Creating temp folder: " + $parentFolder)
		New-Item -path $parentFolder -ItemType Directory | Out-Null
	  }
	} else {
  	  $logs = gci $parentFolder -file | sort LastWriteTime -Descend 
	  if ($logs.Count -gt 0) {
	    $candidate = $logs | SELECT -first 1
		Write-Verbose ("Candidate log file: " + $candidate.FullName)
		Write-Verbose ("Existing log LastWriteTime: " + $candidate.LastWriteTime)
		Write-Verbose ("Start of window to compare:   " + $windowStart)
		if ($candidate.LastWriteTime -gt $windowStart) {
	  		$currentLogFile = $candidate.FullName
			Write-Verbose ("Log file is still curent, re-using: " + $currentLogFile)
	
			#Clean up old logs
			if ($logs.Count -gt 1) {
				Write-Verbose ("Removing old log files from `$temp path...")
				$logs | Where { $_.LastWriteTime -lt $candidate.LastWriteTime } | Remove-Item -Force
			}
		}
	  }
	}
	return $currentLogFile
}

function Get-SPMergeULSbyEvent {
	param ($targetPath, [DateTime]$windowStart, $eventFilter, $actionAbbrev)

	Write-Host ("[" + $actionAbbrev + "] Extracting info from ULS (Merge-SPLogFile with event filter: " + $eventFilter + ")...")
    $timestamp = $(Get-Date -format "yyyyMMdd_HHmmss")
    $ulsOutFileName = "uls-" + $actionAbbrev + "-" + $timestamp + ".log"
	$result = Join-Path $targetPath $ulsOutFileName 
    Write-Host ("Writing merge log to:")
	Write-Host (" >>>> " + $result)
	Merge-SPLogFile -Path $result -Overwrite -StartTime $windowStart -EventId $eventFilter
	
	if (Test-Path $result) { 
		return $result
	} else {
		return $null
	}	
}

Export-ModuleMember Get-SPIndexReports
