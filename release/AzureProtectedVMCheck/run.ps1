using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function processed a request."

#####
#
# TT 20211210 AzureProtectedVMCheck
# This script is executed by an Azure Function App
# It checks if some VMs in a specific subscription are not protected
# (backed up) in an Azure recovery vault
# It can be triggered by any monitoring system to get the results and status
#
# "subscriptionid" GET parameter allows to specify the subscription to check
#
# "exclusion" GET parameter can be passed with comma separated VM names that 
# should be excluded from the check
#
# used AAD credentials read access to the specified subscription
#
# API ref:
# https://docs.microsoft.com/en-us/rest/api/compute/virtual-machines/list-all
# https://docs.microsoft.com/fr-fr/rest/api/backup/backup-status/get
#
#####

$exclusion = [string] $Request.Query.exclusion
if (-not $exclusion) {
    $exclusion = ""
}

$subscriptionid = [string] $Request.Query.Subscriptionid
if (-not $subscriptionid) {
    $subscriptionid = "00000000-0000-0000-0000-000000000000"
}

# init variables
$signature = $env:Signature
$maxConcurrentJobs = [int] $env:MaxConcurrentJobs
[System.Collections.ArrayList] $exclusionsTab = $exclusion.split(",")
foreach ($current in ($env:AzureProtectedVMCheckGlobalExceptions).split(",")) {
	$exclusionsTab.Add($current)
}
$alert = 0
$body_critical = ""
$body_ok = ""

# connect with SPN account creds
$tenantId = $env:TenantId
$applicationId = $env:AzureProtectedVMCheckApplicationID
$password = $env:AzureProtectedVMCheckSecret
$securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
$credential = new-object -typename System.Management.Automation.PSCredential -argumentlist $applicationId, $securePassword
Connect-AzAccount -Credential $credential -Tenant $tenantId -ServicePrincipal

# get token
$azContext = Get-AzContext
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
$token = $profileClient.AcquireAccessToken($azContext.Subscription.TenantId)

# create http headers
$headers = @{}
$headers.Add("Authorization", "bearer " + "$($Token.Accesstoken)")
$headers.Add("contenttype", "application/json")

Try {
	$uri = "https://management.azure.com/subscriptions/$subscriptionid/providers/Microsoft.Compute/virtualMachines?api-version=2021-07-01"
	$results = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
	$vms = $results.value
	while ($results.nextLink) {
		$uri = $results.nextLink
		$results = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
		$vms += $results.value
	}
} Catch {
    if($_.ErrorDetails.Message) {
		$msg = ($_.ErrorDetails.Message | ConvertFrom-Json).error
		$body_critical += $msg.code + ": " + $msg.message + "`n"
		$alert++
    }
}

# if many VMs, too long execution would cause an http timeout from the
# monitoring system calling the function
# multithreading is required to avoid long execution time if many VMs
if ($vms.count -lt $maxConcurrentJobs) {
	$MaxRunspaces = $vms.count
}
else {
	$MaxRunspaces = $maxConcurrentJobs
}
$RunspacePool = [runspacefactory]::CreateRunspacePool(1, $MaxRunspaces)
$RunspacePool.Open()
$Jobs = New-Object System.Collections.ArrayList
foreach ($vm in $vms) {
	$PowerShell = [powershell]::Create()
	$PowerShell.RunspacePool = $RunspacePool
	[void]$PowerShell.AddScript({
	    Param ($headers, $subscriptionid, $vm, $exclusionsTab)

		$rg = $vm.id.split("/")[4]
		if ($exclusionsTab -contains $vm.name -or $exclusionsTab -contains $rg) {
			$out = "OK - $($vm.Name): VM excluded from protection check"
		}
		else {
			$uri = "https://management.azure.com/Subscriptions/$subscriptionid/providers/Microsoft.RecoveryServices/locations/$($vm.location)/backupStatus?api-version=2021-10-01"
			$httpBody = "{`
				  `"resourceType`": `"VM`",`
				  `"resourceId`": `"$($vm.id)`"`
				}"
			Try {
				$protectionState = Invoke-RestMethod -Method Post -Uri $uri -Body $httpBody -Headers $headers -ContentType "application/json"
				if ($protectionState.protectionStatus -eq "Protected") {
					$out = "OK - $($vm.Name): VM is protected"
				}
				else {
					$out = "CRITICAL - $($vm.Name): VM is NOT protected"
				}
			} Catch {
				if($_.ErrorDetails.Message) {
					$msg = ($_.ErrorDetails.Message | ConvertFrom-Json).error
					$out = "CRITICAL - " + $msg.code + ": " + $msg.message
				}
			}
		}
		echo $out
	}).AddArgument($headers).AddArgument($subscriptionid).AddArgument($vm).AddArgument($exclusionsTab)
	
	$JobObj = New-Object -TypeName PSObject -Property @{
		Runspace = $PowerShell.BeginInvoke()
		PowerShell = $PowerShell  
    }
    $Jobs.Add($JobObj) | Out-Null
}
while ($Jobs.Runspace.IsCompleted -contains $false) {
	$running = ($Jobs.Runspace | where {$_.IsCompleted -eq $false}).count
    Write-Host (Get-date).Tostring() "Still $running jobs running..."
	Start-Sleep 1
}
foreach ($job in $Jobs) {
	$current = $job.PowerShell.EndInvoke($job.Runspace)
	$job.PowerShell.Dispose()
	if ($current -match "CRITICAL") {
		$alert++
		$body_critical += $current + "`n"
	}
	else {
		$body_ok += $current + "`n"
	}
}

# sort results
$sorted = $body_critical.split("`n") | Sort-Object
$body_critical = ""
$sorted | % {$body_critical += $_ + "`n"}

$sorted = $body_ok.split("`n") | Sort-Object
$body_ok = ""
$sorted | % {$body_ok += $_ + "`n"}

# add ending status and signature to results
$body_ok += "`n$signature`n"
if ($alert) {
    $body = "Status CRITICAL - No protection on $alert/$($vms.count) VM(s)!`n$body_critical`n$body_ok"
}
else {
    $body = "Status OK - No alert on any $($vms.count) VM(s)`n$body_ok"
}
Write-Host $body

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = $body
})
