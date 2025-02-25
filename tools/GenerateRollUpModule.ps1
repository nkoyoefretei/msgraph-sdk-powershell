
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.
Param(
    [string] $RepositoryApiKey,
    [string] $RepositoryName = "PSGallery",
    [string] $ModuleMappingConfigPath = (Join-Path $PSScriptRoot "..\config\ModulesMapping.jsonc"),
    [int] $ModulePreviewNumber = -1,
    [switch] $Pack,
    [switch] $Publish
)
enum VersionState {
    Invalid
    Valid
    EqualToFeed
    NotOnFeed
}
$ErrorActionPreference = 'Stop'
$LASTEXITCODE = $null
if ($PSEdition -ne 'Core') {
    Write-Error 'This script requires PowerShell Core to execute. [Note] Generated cmdlets will work in both PowerShell Core or Windows PowerShell.'
}

if (-not (Test-Path $ModuleMappingConfigPath)) {
    Write-Error "Module mapping file not be found: $ModuleMappingConfigPath."
}

$ModulePrefix = "Microsoft.Graph"
$NuspecHelperPS1 = Join-Path $PSScriptRoot ".\NuspecHelper.ps1"
$PublishModulePS1 = Join-Path $PSScriptRoot ".\PublishModule.ps1" -Resolve
$ValidateUpdatedModuleVersionPS1 = Join-Path $PSScriptRoot ".\ValidateUpdatedModuleVersion.ps1" -Resolve
$ModuleMetadataJson = Join-Path $PSScriptRoot "..\config\ModuleMetadata.json" -Resolve
$ArtifactsLocation = Join-Path $PSScriptRoot "..\artifacts\"
$GraphModuleLocation = Join-Path $PSScriptRoot "..\src\Graph\Graph"
$RollUpModuleNuspec = Join-Path $GraphModuleLocation ".\$ModulePrefix"
$RequiredGraphModules = @()
[HashTable] $ModuleMapping = Get-Content $ModuleMappingConfigPath | ConvertFrom-Json -AsHashTable
[HashTable] $NuspecMetadata = Get-Content $ModuleMetadataJson | ConvertFrom-Json -AsHashTable
$NuspecMetadata.Remove("assemblyOriginatorKeyFile")

# Import scripts
. $NuspecHelperPS1

if ($null -eq $NuspecMetadata["version"]) {
    # Module version not set in module manifest (psd1).
    Write-Error "Version number is not set on $ModulePrefix module. Please set 'version' in $ModuleMetadataJson."
}
  
# Validate module version with the one on PSGallery.
[VersionState]$VersionState = & $ValidateUpdatedModuleVersionPS1 -ModuleName $ModulePrefix -NextVersion $NuspecMetadata["version"]

if ($VersionState.Equals([VersionState]::Invalid)) {
    Write-Warning "The specified version in $ModulePrefix module is either higher or lower than what's on $RepositoryName. Update 'version' in $ModuleMetadataJson."
}
elseif ($VersionState.Equals([VersionState]::EqualToFeed)) {
    Write-Warning "$ModulePrefix module skipped. Version has not changed and is equal to what's on $RepositoryName."
}
elseif ($VersionState.Equals([VersionState]::Valid) -or $VersionState.Equals([VersionState]::NotOnFeed)) {
    $NuspecMetadata["version"] = $VersionState.Equals([VersionState]::NotOnFeed) ? "0.1.1" : $NuspecMetadata["version"]

    $RollUpModuleArtifactLocation = "$ArtifactsLocation\graph"
    if (-not (Test-Path $RollUpModuleArtifactLocation)) {
        New-Item -Path $RollUpModuleArtifactLocation -Type Directory
    }
    else {
        Remove-Item -Path "$RollUpModuleArtifactLocation\*" -Recurse -Force
    }

    if (-not (Test-Path $GraphModuleLocation)) {
        New-Item -Path $GraphModuleLocation -Type Directory
    }
    $AllowPreRelease = $true
    if ($ModulePreviewNumber -eq -1) {
        $AllowPreRelease = $false
    }

    # Add auth module as a dependency.
    Find-Module "Microsoft.Graph.Authentication" -Repository $RepositoryName -AllowPrerelease:$AllowPreRelease
    $ExistingAuthModule = Find-Module "Microsoft.Graph.Authentication" -Repository $RepositoryName -AllowPrerelease:$AllowPreRelease
    Install-Module $ExistingAuthModule.Name -Repository $RepositoryName -Force -AllowClobber -AllowPrerelease:$AllowPreRelease
    
    Write-Host "Adding dependency: $($ExistingAuthModule.Name) $($ExistingAuthModule.Version)" -ForegroundColor Green
    if ($ExistingAuthModule.Version -like '*preview*' ) {
        $version = $ExistingAuthModule.Version.Remove($ExistingAuthModule.Version.IndexOf('-'))
        $RequiredGraphModules += @{ ModuleName = $ExistingAuthModule.Name ; ModuleVersion = $version }
    }
    else {
        $RequiredGraphModules += @{ ModuleName = $ExistingAuthModule.Name ; ModuleVersion = $ExistingAuthModule.Version }
    }

    foreach ($RequiredModule in $ModuleMapping.Keys) {
        # Install module locally in order to specify it as a dependency of the roll-up module down.
        # New-ModuleManifest expects all required modules to be installed locally.
        # https://stackoverflow.com/questions/46216038/how-do-i-define-requiredmodules-in-a-powershell-module-manifest-psd1.
        $ExistingWorkloadModule = Find-Module "$ModulePrefix.$RequiredModule" -Repository $RepositoryName -AllowPrerelease:$AllowPreRelease -ErrorAction SilentlyContinue
        if ($null -ne $ExistingWorkloadModule) {
            Write-Host "Adding dependency: $($ExistingWorkloadModule.Name) $($ExistingWorkloadModule.Version)" -ForegroundColor Green
            Install-Module $ExistingWorkloadModule.Name -Repository $RepositoryName -Force -AllowClobber -AllowPrerelease:$AllowPreRelease
            #Remove "-preview" from Version Name if present
            if ($ExistingWorkloadModule.Version -like '*preview*' ) {
                $version = $ExistingWorkloadModule.Version.Remove($ExistingWorkloadModule.Version.IndexOf('-'))
                $RequiredGraphModules += @{ ModuleName = $ExistingWorkloadModule.Name ; RequiredVersion = $version }
            }
            else {
                $RequiredGraphModules += @{ ModuleName = $ExistingWorkloadModule.Name ; RequiredVersion = $ExistingWorkloadModule.Version }
            }   
        }
        else {
            Write-Warning "Skipped: $ModulePrefix.$RequiredModule"
        }
    }

    [HashTable]$ModuleManifestSettings = @{
        Path                   = "$GraphModuleLocation\$ModulePrefix.psd1"
        CompatiblePSEditions   = "Core", "Desktop"
        PowerShellVersion      = "5.1"
        DotNetFrameworkVersion = "4.7.2"
        ModuleVersion          = $NuspecMetadata["version"]
        RequiredModules        = $RequiredGraphModules
        Author                 = $NuspecMetadata["authors"]
        CompanyName            = $NuspecMetadata["owners"]
        Copyright              = $NuspecMetadata["copyright"]
        Description            = $NuspecMetadata["description"]
        Tags                   = $NuspecMetadata["tags"]
        LicenseUri             = $NuspecMetadata["licenseUri"]
        ProjectUri             = $NuspecMetadata["projectUri"]
        IconUri                = $NuspecMetadata["iconUri"]
        ReleaseNotes           = $NuspecMetadata["releaseNotes"]
        AliasesToExport        = @()
        CmdletsToExport        = @()
        FunctionsToExport      = @()
        GUID                   = $NuspecMetadata["guid"]
    }

    Write-Host -ForegroundColor Green "Creating '$ModulePrefix' module manifest and nuspec..."
    if ($ModulePreviewNumber -ge 0) {
        # Prerelease is only supported in PowerShell 7 (preview) and above.
        $ModuleManifestSettings["Prerelease"] = "preview$ModulePreviewNumber"
        $NuspecMetadata["version"] = $NuspecMetadata["version"] + "-preview$ModulePreviewNumber"
    }
    $NuspecMetadata["dependencies"] = $RequiredGraphModules
    $NuspecMetadata["id"] = $ModulePrefix

    New-ModuleManifest @ModuleManifestSettings

    if (-not (Test-Path "$RollUpModuleNuspec.nuspec")) {
        Copy-Item (Join-Path $PSScriptRoot "\Templates\$ModulePrefix.nuspec") -Destination $GraphModuleLocation
    }

    $NuspecMetadata.Remove("guid")
    Set-NuSpecValuesFromManifest -NuSpecFilePath "$RollUpModuleNuspec.nuspec" -Manifest $NuspecMetadata

    if ($Pack) {
        Write-Host -ForegroundColor Green "Packing '$ModulePrefix' module..."
        & nuget pack "$RollUpModuleNuspec.nuspec" -OutputDirectory $RollUpModuleArtifactLocation -Prop Configuration=Release
    }

    if ($LASTEXITCODE) {
        Write-Error "Failed to pack $ModulePrefix module."
    }

    if ($Publish) {
        # Publish roll-up module
        & $PublishModulePS1 -Modules "Graph" -ModulePrefix $ModulePrefix -ArtifactsLocation $ArtifactsLocation -RepositoryName $RepositoryName -RepositoryApiKey $RepositoryApiKey
    }
}

Write-Host -ForegroundColor Green "-------------Done-------------"