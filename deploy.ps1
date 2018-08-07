#Requires -Version 5.0
using module .\Deployment.psm1

Param(
    [string] [Parameter(Mandatory=$false)] $ResourceGroupLocation = 'eastus',
    [string] $ResourceGroupName = 'management',
	[array] $LinkedResourceGroups = @('network', 'machines', 'web', 'workspaces', 'sql'),
    [switch] $UploadArtifacts,
    [switch] $UpdateStorage,
	[string] [ValidateSet("Complete", "Incremental")] $Mode = 'Incremental',
    [string] $TemplateFile = ".\azuredeploy.json",
    [string] $TemplateParametersFile = ".\azuredeploy.parameters.json",
    [switch] $ValidateOnly
)

try {
    [Microsoft.Azure.Common.Authentication.AzureSession]::ClientFactory.AddUserAgent("VSAzureTools-$UI$($host.name)".replace(' ','_'), '3.0.0')
} catch { }

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 5

function Format-ValidationOutput {
    param ($ValidationOutput, [int] $Depth = 0)
    Set-StrictMode -Off
    return @($ValidationOutput | Where-Object { $_ -ne $null } | ForEach-Object { @('  ' * $Depth + ': ' + $_.Message) + @(Format-ValidationOutput @($_.Details) ($Depth + 1)) })
}

$OptionalParameters = New-Object -TypeName Hashtable
$TemplateFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateFile))
$TemplateParametersFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateParametersFile))

$Deployment = [Deployment]::new($ResourceGroupName, $PSScriptRoot)

# Create or update the resource group using the specified template file and template parameters file
New-AzureRmResourceGroup -Name $ResourceGroupName -Location $ResourceGroupLocation -Verbose -Force

$LinkedResourceGroups | % { 
	New-AzureRmResourceGroup -Name $_ -Location $ResourceGroupLocation -Verbose -Force
}

if ($UploadArtifacts) {

	# Update storage if flagged.
	if ($UpdateStorage) {
		New-AzureRmResourceGroupDeployment -Name "storageAccounts" -ResourceGroupName $ResourceGroupName -TemplateFile ".\resources\storageAccounts.json"
	}
	$Deployment.UploadArtifacts()
}

$TemplateParams = Get-Content $TemplateFile -Raw | ConvertFrom-Json | Select parameters
if ($TemplateParams.parameters.PSObject.Properties.name -contains "secrets") {
	$OptionalParameters["secrets"] = $Deployment.GetSasTokens() | ConvertTo-Json -Depth 100
}
Get-ChildItem -Directory | % {
	if ($TemplateParams.parameters.PSObject.Properties.name -contains "_$($_.BaseName)LocationSasToken") {
		$OptionalParameters["_$($_.BaseName)LocationSasToken"] = $Deployment.GetToken("$($_.BaseName)LocationSasToken")
	}
}
Write-Host $Deployment.SasTokens

if ($ValidateOnly) {
	$ErrorMessages = Format-ValidationOutput (Test-AzureRmResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
																					-TemplateFile $TemplateFile `
																					-TemplateParameterFile $TemplateParametersFile `
																					@OptionalParameters)
	if ($ErrorMessages) {
		Write-Output '', 'Validation returned the following errors:', @($ErrorMessages), '', 'Template is invalid.'
	}
	else {
		Write-Output '', 'Template is valid.'
	}
}
else {
	#((Get-ChildItem $TemplateFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
	New-AzureRmResourceGroupDeployment -Name (Get-ChildItem $TemplateFile).BaseName `
										-ResourceGroupName $ResourceGroupName `
										-Mode $Mode `
										-TemplateFile $TemplateFile `
										-TemplateParameterFile $TemplateParametersFile `
										@OptionalParameters `
										-Force -Verbose `
										-ErrorVariable ErrorMessages
	if ($ErrorMessages) {
		Write-Output '', 'Template deployment returned the following errors:', @(@($ErrorMessages) | ForEach-Object { $_.Exception.Message.TrimEnd("`r`n") })
	}
}