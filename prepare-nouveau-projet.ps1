[CmdletBinding()]
param(
    [string] $ProjectName,
    [string] $ProjectType,
    [string] $CustomProjectType,
    [switch] $NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = [Version] '1.11.10'
$CurrentConfigVersion = 8
$LegacyConfigVersion = 1
$ConfigFileName = 'prepare-nouveau-projet.config.json'
$ConfigDisabledSuffix = 'desactive'
$KnownProjectTypes = @('cmd', 'bat', 'ps1', 'py', 'autre')
$KnownProjectTypesDisplay = $KnownProjectTypes -join ', '
$FallbackProjectType = 'py'
$FallbackCreatePythonVenv = $true
$FallbackPythonInstallLocation = 'depot'
$PythonDepotFolderName = 'Python'
$ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath $ConfigFileName
$script:OriginalConsoleInputEncoding = $null
$script:OriginalConsoleOutputEncoding = $null
$script:OriginalCommandOutputEncoding = $null
$script:OriginalConsoleCodePage = $null

function Set-Utf8ConsoleEncoding {
    $utf8Encoding = [System.Text.UTF8Encoding]::new($false)

    try {
        $script:OriginalConsoleCodePage = [Console]::OutputEncoding.CodePage
        $script:OriginalConsoleInputEncoding = [Console]::InputEncoding
        $script:OriginalConsoleOutputEncoding = [Console]::OutputEncoding
        [Console]::InputEncoding = $utf8Encoding
        [Console]::OutputEncoding = $utf8Encoding
    }
    catch {
        Write-Verbose "Impossible de modifier l'encodage de la console : $($_.Exception.Message)"
    }

    try {
        $script:OriginalCommandOutputEncoding = $OutputEncoding
        $global:OutputEncoding = $utf8Encoding
    }
    catch {
        Write-Verbose "Impossible de modifier l'encodage des sorties PowerShell : $($_.Exception.Message)"
    }

    if ($env:ComSpec) {
        try {
            & $env:ComSpec /d /c 'chcp 65001' | Out-Null
        }
        catch {
            Write-Verbose "Impossible de basculer la console en UTF-8 : $($_.Exception.Message)"
        }
    }
}

function Restore-ConsoleEncoding {
    if ($null -ne $script:OriginalConsoleInputEncoding) {
        try {
            [Console]::InputEncoding = $script:OriginalConsoleInputEncoding
        }
        catch {
            Write-Verbose "Impossible de restaurer l'encodage d'entrée de la console : $($_.Exception.Message)"
        }
    }

    if ($null -ne $script:OriginalConsoleOutputEncoding) {
        try {
            [Console]::OutputEncoding = $script:OriginalConsoleOutputEncoding
        }
        catch {
            Write-Verbose "Impossible de restaurer l'encodage de sortie de la console : $($_.Exception.Message)"
        }
    }

    if ($null -ne $script:OriginalCommandOutputEncoding) {
        try {
            $global:OutputEncoding = $script:OriginalCommandOutputEncoding
        }
        catch {
            Write-Verbose "Impossible de restaurer l'encodage des sorties PowerShell : $($_.Exception.Message)"
        }
    }

    if ($env:ComSpec -and $null -ne $script:OriginalConsoleCodePage) {
        try {
            & $env:ComSpec /d /c "chcp $($script:OriginalConsoleCodePage)" | Out-Null
        }
        catch {
            Write-Verbose "Impossible de restaurer la page de code de la console : $($_.Exception.Message)"
        }
    }
}

function Write-StepInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    Write-Host $Message -ForegroundColor DarkCyan
}

function Get-NormalizedProjectType {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ProjectType,

        [switch] $AllowDefault,

        [string] $DefaultProjectType = $FallbackProjectType
    )

    $normalizedDefaultProjectType = "$DefaultProjectType".Trim().ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($normalizedDefaultProjectType) -or $KnownProjectTypes -notcontains $normalizedDefaultProjectType) {
        throw "Le type de projet par défaut '$DefaultProjectType' est invalide. Types connus : $KnownProjectTypesDisplay"
    }

    $projectTypeText = if ($null -eq $ProjectType) { '' } else { $ProjectType.Trim() }

    if ([string]::IsNullOrWhiteSpace($projectTypeText)) {
        if ($AllowDefault) {
            return $normalizedDefaultProjectType
        }

        throw "Le type de projet ne peut pas être vide. Types connus : $KnownProjectTypesDisplay"
    }

    $normalizedProjectType = $projectTypeText.ToLowerInvariant()

    if ($normalizedProjectType -eq 'other') {
        $normalizedProjectType = 'autre'
    }

    if ($KnownProjectTypes -notcontains $normalizedProjectType) {
        throw "Type de projet inconnu '$ProjectType'. Types connus : $KnownProjectTypesDisplay"
    }

    return $normalizedProjectType
}

function Get-NormalizedCustomProjectType {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $CustomProjectType
    )

    $normalizedCustomProjectType = if ($null -eq $CustomProjectType) { '' } else { $CustomProjectType.Trim() }

    if ([string]::IsNullOrWhiteSpace($normalizedCustomProjectType)) {
        throw 'Le type de projet personnalisé ne peut pas être vide.'
    }

    return $normalizedCustomProjectType
}

function Get-NormalizedBooleanSetting {
    param(
        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory = $true)]
        [string] $SettingName,

        [Nullable[bool]] $DefaultValue
    )

    if ($Value -is [bool]) {
        return [bool] $Value
    }

    if ($Value -is [int] -or $Value -is [long]) {
        if ([int64] $Value -eq 1) {
            return $true
        }

        if ([int64] $Value -eq 0) {
            return $false
        }
    }

    $valueText = if ($null -eq $Value) { '' } else { "$Value".Trim() }

    if ([string]::IsNullOrWhiteSpace($valueText)) {
        if ($PSBoundParameters.ContainsKey('DefaultValue')) {
            return [bool] $DefaultValue
        }

        throw "$SettingName ne peut pas être vide."
    }

    switch -Regex ($valueText) {
        '^(1|o|oui|y|yes|true|vrai)$' { return $true }
        '^(0|n|non|no|false|faux)$' { return $false }
        default {
            throw "$SettingName est invalide. Valeurs acceptées : true/false, o/oui ou n/non."
        }
    }
}

function Get-NormalizedPathCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    $trimmedPath = $Path.Trim()

    if ($trimmedPath.Length -ge 2) {
        $hasDoubleQuotes = $trimmedPath.StartsWith('"') -and $trimmedPath.EndsWith('"')
        $hasSimpleQuotes = $trimmedPath.StartsWith("'") -and $trimmedPath.EndsWith("'")

        if ($hasDoubleQuotes -or $hasSimpleQuotes) {
            $trimmedPath = $trimmedPath.Substring(1, $trimmedPath.Length - 2).Trim()
        }
    }

    if ([string]::IsNullOrWhiteSpace($trimmedPath)) {
        throw 'Le chemin ne peut pas être vide.'
    }

    try {
        return [System.IO.Path]::GetFullPath($trimmedPath)
    }
    catch {
        throw "Le chemin '$Path' est invalide."
    }
}

function Get-NormalizedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path
    )

    return Get-NormalizedPathCandidate -Path $Path
}

function Get-NormalizedExistingFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $Label = 'Fichier'
    )

    $normalizedPath = Get-NormalizedPathCandidate -Path $Path

    if (-not (Test-Path -LiteralPath $normalizedPath)) {
        throw "$Label introuvable : $normalizedPath"
    }

    $item = Get-Item -LiteralPath $normalizedPath
    if ($item.PSIsContainer) {
        throw "$Label invalide : '$normalizedPath' est un dossier."
    }

    return $normalizedPath
}

function Add-UniqueCaseInsensitiveString {
    param(
        [AllowNull()]
        [System.Collections.Generic.List[string]] $List,

        [Parameter(Mandatory = $true)]
        [string] $Value
    )

    if ($null -eq $List) {
        throw 'La liste cible ne peut pas être nulle.'
    }

    foreach ($existingValue in $List) {
        if ($existingValue.Equals($Value, [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }

    $List.Add($Value)
}

function Read-ProjectName {
    while ($true) {
        $projectName = Read-Host 'Nom du projet'

        if ([string]::IsNullOrWhiteSpace($projectName)) {
            Write-Host 'Le nom du projet ne peut pas être vide.' -ForegroundColor Yellow
            continue
        }

        $projectName = $projectName.Trim()
        $invalidCharacters = @([System.IO.Path]::GetInvalidFileNameChars() | Where-Object {
            $projectName.Contains($_)
        })

        if ($invalidCharacters.Count -gt 0) {
            Write-Host 'Le nom du projet contient des caractères invalides pour un dossier.' -ForegroundColor Yellow
            continue
        }

        return $projectName
    }
}

function Read-ProjectType {
    param(
        [Parameter(Mandatory = $true)]
        [string] $DefaultProjectType
    )

    Write-Host "Types de projet connus : $KnownProjectTypesDisplay"

    while ($true) {
        $projectType = Read-Host "Type du projet (Entrée = $DefaultProjectType)"

        try {
            return Get-NormalizedProjectType -ProjectType $projectType -AllowDefault -DefaultProjectType $DefaultProjectType
        }
        catch {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        }
    }
}

function Read-CustomProjectType {
    while ($true) {
        $customProjectType = Read-Host 'Type de projet personnalisé'

        try {
            return Get-NormalizedCustomProjectType -CustomProjectType $customProjectType
        }
        catch {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        }
    }
}

function Read-ExistingProjectAction {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectName,

        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    Write-Host "Le dossier '$ProjectName' existe déjà : $ProjectPath" -ForegroundColor Yellow
    Write-Host '1. Changer le nom'
    Write-Host '2. Fermer sans rien faire'

    while ($true) {
        $answer = (Read-Host 'Choix (1/2)').Trim()

        switch -Regex ($answer) {
            '^(1|c|changer)$' { return 'Rename' }
            '^(2|f|fermer)$' { return 'Cancel' }
            default {
                Write-Host 'Choisissez 1 pour changer le nom ou 2 pour fermer.' -ForegroundColor Yellow
            }
        }
    }
}

function Read-Confirmation {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Prompt
    )

    while ($true) {
        $answer = Read-Host $Prompt

        try {
            return Get-NormalizedBooleanSetting -Value $answer -SettingName 'La réponse'
        }
        catch {
            Write-Host 'Répondez par O ou N.' -ForegroundColor Yellow
        }
    }
}

function Read-ConfirmationWithDefault {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Prompt,

        [Parameter(Mandatory = $true)]
        [bool] $DefaultValue
    )

    $promptSuffix = if ($DefaultValue) { '(O/n)' } else { '(o/N)' }
    $defaultLabel = if ($DefaultValue) { 'O' } else { 'N' }

    while ($true) {
        $answer = Read-Host "$Prompt $promptSuffix"

        try {
            return Get-NormalizedBooleanSetting -Value $answer -SettingName 'La réponse' -DefaultValue $DefaultValue
        }
        catch {
            Write-Host "Répondez par O ou N. Entrée = $defaultLabel." -ForegroundColor Yellow
        }
    }
}

function Read-CreatePythonVenv {
    param(
        [Parameter(Mandatory = $true)]
        [bool] $DefaultCreatePythonVenv
    )

    return Read-ConfirmationWithDefault -Prompt 'Créer un environnement virtuel Python ".venv" ?' -DefaultValue $DefaultCreatePythonVenv
}

function Get-NormalizedPythonInstallLocationSetting {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $InstallLocation,

        [switch] $AllowDefault,

        [string] $DefaultInstallLocation = $FallbackPythonInstallLocation
    )

    $normalizedDefaultInstallLocation = if ([string]::IsNullOrWhiteSpace($DefaultInstallLocation)) {
        $FallbackPythonInstallLocation
    }
    else {
        $DefaultInstallLocation.Trim().ToLowerInvariant()
    }

    if ($normalizedDefaultInstallLocation -notin @('depot', 'default')) {
        throw "Le comportement par défaut d'installation Python '$DefaultInstallLocation' est invalide."
    }

    $installLocationText = if ($null -eq $InstallLocation) { '' } else { $InstallLocation.Trim() }

    if ([string]::IsNullOrWhiteSpace($installLocationText)) {
        if ($AllowDefault) {
            return $normalizedDefaultInstallLocation
        }

        throw 'Le comportement d''installation Python ne peut pas être vide.'
    }

    switch -Regex ($installLocationText.ToLowerInvariant()) {
        '^(1|d|depot)$' { return 'depot' }
        '^(2|defaut|default)$' { return 'default' }
        default {
            throw "Le comportement d'installation Python '$InstallLocation' est invalide."
        }
    }
}

function Read-PythonInstallLocationChoice {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $PythonDepotPath,

        [Parameter(Mandatory = $true)]
        [string] $DefaultPythonInstallLocation
    )

    if ([string]::IsNullOrWhiteSpace("$PythonDepotPath")) {
        return 'Default'
    }

    $normalizedDefaultInstallLocation = Get-NormalizedPythonInstallLocationSetting `
        -InstallLocation $DefaultPythonInstallLocation `
        -AllowDefault `
        -DefaultInstallLocation $FallbackPythonInstallLocation
    $defaultChoiceLabel = if ($normalizedDefaultInstallLocation -eq 'depot') { '1' } else { '2' }

    Write-Host "Dépôt Python dédié aux venv disponible : $PythonDepotPath"
    Write-Host '1. Installer dans le dépôt venv'
    Write-Host '2. Utiliser l''installation par défaut'

    while ($true) {
        $answer = (Read-Host "Choix de l'emplacement d'installation (Entrée = $defaultChoiceLabel)").Trim()

        try {
            $normalizedInstallLocation = Get-NormalizedPythonInstallLocationSetting `
                -InstallLocation $answer `
                -AllowDefault `
                -DefaultInstallLocation $normalizedDefaultInstallLocation

            if ($normalizedInstallLocation -eq 'depot') {
                return 'Depot'
            }

            return 'Default'
        }
        catch {
            Write-Host "Choisissez 1 pour le dépôt venv ou 2 pour l'installation par défaut. Entrée = $defaultChoiceLabel." -ForegroundColor Yellow
        }
    }
}

function Read-ProjectsRootPath {
    while ($true) {
        $projectsRootPath = Read-Host 'Chemin du dossier projet'

        try {
            return Get-NormalizedPath -Path $projectsRootPath
        }
        catch {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        }
    }
}

function Get-DefaultPythonDepotPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectsRootPath
    )

    $normalizedProjectsRootPath = Get-NormalizedPath -Path $ProjectsRootPath
    $parentDirectoryPath = Split-Path -Path $normalizedProjectsRootPath -Parent

    if ([string]::IsNullOrWhiteSpace($parentDirectoryPath)) {
        throw "Impossible de déterminer le dossier parent du dossier projet '$normalizedProjectsRootPath'."
    }

    return Join-Path -Path $parentDirectoryPath -ChildPath $PythonDepotFolderName
}

function Read-OptionalPythonDepotPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectsRootPath
    )

    $defaultPythonDepotPath = Get-DefaultPythonDepotPath -ProjectsRootPath $ProjectsRootPath

    Write-Host 'Aucun dépôt Python dédié aux venv n''est configuré.' -ForegroundColor Yellow
    Write-Host "Chemin proposé : $defaultPythonDepotPath"

    while ($true) {
        $answer = Read-Host 'Créer ce dépôt Python ? (Entrée/O = chemin proposé, N = ignorer, ou chemin complet personnalisé)'

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $defaultPythonDepotPath
        }

        try {
            $confirmation = Get-NormalizedBooleanSetting -Value $answer -SettingName 'La réponse'
            if ($confirmation) {
                return $defaultPythonDepotPath
            }

            return $null
        }
        catch {
        }

        try {
            return Get-NormalizedPath -Path $answer
        }
        catch {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        }
    }
}

function Ensure-DirectoryExists {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [string] $Label = 'Dossier'
    )

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path

        if (-not $item.PSIsContainer) {
            throw "Le chemin '$Path' existe déjà, mais ce n'est pas un dossier."
        }

        return
    }

    New-Item -ItemType Directory -Path $Path | Out-Null
    Write-Host "$Label créé : $Path" -ForegroundColor Green
}

function Write-Utf8TextFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $Content,

        [switch] $WithoutBom
    )

    $utf8Encoding = if ($WithoutBom) {
        [System.Text.UTF8Encoding]::new($false)
    }
    else {
        [System.Text.UTF8Encoding]::new($true)
    }

    [System.IO.File]::WriteAllText($Path, $Content, $utf8Encoding)
}

function Test-ConfigPropertyExists {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Config,

        [Parameter(Mandatory = $true)]
        [string] $PropertyName
    )

    return $Config.PSObject.Properties.Match($PropertyName).Count -gt 0
}

function Get-ConfigVersionValue {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RawConfig,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath
    )

    if (-not (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'ConfigVersion')) {
        return $LegacyConfigVersion
    }

    $configVersionText = "$($RawConfig.ConfigVersion)".Trim()

    if ([string]::IsNullOrWhiteSpace($configVersionText)) {
        throw "Le fichier de configuration '$ConfigPath' contient une version de configuration vide."
    }

    $configVersion = 0
    if (-not [int]::TryParse($configVersionText, [ref] $configVersion)) {
        throw "Le fichier de configuration '$ConfigPath' contient une version de configuration invalide."
    }

    if ($configVersion -lt 1) {
        throw "Le fichier de configuration '$ConfigPath' contient une version de configuration invalide."
    }

    return $configVersion
}

function Get-ScriptVersionValue {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RawConfig,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath
    )

    if (-not (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'ScriptVersion')) {
        return $null
    }

    $scriptVersionText = "$($RawConfig.ScriptVersion)".Trim()

    if ([string]::IsNullOrWhiteSpace($scriptVersionText)) {
        return $null
    }

    try {
        return [Version] $scriptVersionText
    }
    catch {
        throw "Le fichier de configuration '$ConfigPath' contient une version de script invalide."
    }
}

function Get-ConfigContentWithoutComments {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Content
    )

    $contentWithoutComments = [System.Text.RegularExpressions.Regex]::Replace(
        $Content,
        '^\s*//.*(?:\r?\n|$)',
        '',
        [System.Text.RegularExpressions.RegexOptions]::Multiline
    )

    return $contentWithoutComments.Trim()
}

function Get-NormalizedPythonInterpreterSource {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Source,

        [string] $DefaultSource = 'custom'
    )

    $normalizedSource = if ([string]::IsNullOrWhiteSpace($Source)) { $DefaultSource } else { $Source.Trim().ToLowerInvariant() }

    switch ($normalizedSource) {
        'py' { return 'pymanager' }
        'pymanager' { return 'pymanager' }
        'depot' { return 'depot' }
        'custom' { return 'custom' }
        default {
            throw "La source Python '$Source' est invalide."
        }
    }
}

function ConvertTo-CanonicalPythonInterpreterEntries {
    param(
        [AllowNull()]
        [object[]] $Entries
    )

    $interpreterEntries = @($Entries)
    $orderedEntries = $interpreterEntries | Sort-Object `
        @{ Expression = {
                switch ($_.Source) {
                    'pymanager' { 0 }
                    'depot' { 1 }
                    'custom' { 2 }
                    default { 9 }
                }
            }
        }, `
        @{ Expression = {
                try {
                    [Version] $_.Version
                }
                catch {
                    [Version] '0.0.0'
                }
            }; Descending = $true
        }, `
        @{ Expression = { $_.ExecutablePath.ToLowerInvariant() } }

    return @(
        $orderedEntries | ForEach-Object {
            [PSCustomObject] ([ordered]@{
                    Source = $_.Source
                    Version = $_.Version
                    ExecutablePath = $_.ExecutablePath
                })
        }
    )
}

function Test-PythonInterpreterEntryCollectionsEqual {
    param(
        [AllowNull()]
        [object[]] $Left,

        [AllowNull()]
        [object[]] $Right
    )

    $leftJson = (ConvertTo-CanonicalPythonInterpreterEntries -Entries $Left | ConvertTo-Json -Depth 5)
    $rightJson = (ConvertTo-CanonicalPythonInterpreterEntries -Entries $Right | ConvertTo-Json -Depth 5)
    return $leftJson -eq $rightJson
}

function Get-NormalizedCustomPythonPathsCollection {
    param(
        [AllowNull()]
        [object[]] $Paths
    )

    $normalizedPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($pathEntry in @($Paths)) {
        if ($null -eq $pathEntry) {
            continue
        }

        $pathText = "$pathEntry".Trim()
        if ([string]::IsNullOrWhiteSpace($pathText)) {
            continue
        }

        try {
            $normalizedPath = Get-NormalizedPathCandidate -Path $pathText
            Add-UniqueCaseInsensitiveString -List $normalizedPaths -Value $normalizedPath
        }
        catch {
            continue
        }
    }

    return @($normalizedPaths | Sort-Object)
}

function Get-LegacyCustomPythonPathsFromConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RawConfig,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [AllowNull()]
        [System.Collections.Generic.List[string]] $SyncReasons = [System.Collections.Generic.List[string]]::new()
    )

    if (-not (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'CustomPythonPaths')) {
        return @()
    }

    $normalizedPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($pathEntry in @($RawConfig.CustomPythonPaths)) {
        if ($null -eq $pathEntry) {
            continue
        }

        $pathText = "$pathEntry".Trim()
        if ([string]::IsNullOrWhiteSpace($pathText)) {
            continue
        }

        try {
            $normalizedPath = Get-NormalizedPathCandidate -Path $pathText
            Add-UniqueCaseInsensitiveString -List $normalizedPaths -Value $normalizedPath

            if ($pathText -cne $normalizedPath) {
                $SyncReasons.Add("Un chemin Python personnalisé de '$ConfigPath' a été normalisé en '$normalizedPath'.")
            }
        }
        catch {
            $SyncReasons.Add("Un chemin Python personnalisé invalide de '$ConfigPath' a été ignoré.")
        }
    }

    return @($normalizedPaths | Sort-Object)
}

function Merge-LegacyCustomPythonPathsIntoKnownPythonInterpreters {
    param(
        [AllowNull()]
        [object[]] $KnownPythonInterpreters,

        [AllowNull()]
        [object[]] $LegacyCustomPythonPaths,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [AllowNull()]
        [System.Collections.Generic.List[string]] $SyncReasons = [System.Collections.Generic.List[string]]::new()
    )

    $mergedInterpreters = [System.Collections.Generic.List[object]]::new()
    $mergedPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($knownInterpreter in @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $KnownPythonInterpreters)) {
        Add-UniqueCaseInsensitiveString -List $mergedPaths -Value $knownInterpreter.ExecutablePath
        $mergedInterpreters.Add($knownInterpreter)
    }

    foreach ($legacyCustomPythonPath in @(Get-NormalizedCustomPythonPathsCollection -Paths $LegacyCustomPythonPaths)) {
        $alreadyKnown = $false
        foreach ($mergedPath in $mergedPaths) {
            if ($mergedPath.Equals($legacyCustomPythonPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $alreadyKnown = $true
                break
            }
        }

        if ($alreadyKnown) {
            continue
        }

        try {
            $customInterpreter = New-PythonInterpreterEntry -ExecutablePath $legacyCustomPythonPath -Source 'custom'
            Add-UniqueCaseInsensitiveString -List $mergedPaths -Value $customInterpreter.ExecutablePath
            $mergedInterpreters.Add($customInterpreter)
            $SyncReasons.Add("Le chemin Python personnalisé '$legacyCustomPythonPath' de '$ConfigPath' a été migré vers KnownPythonInterpreters.")
        }
        catch {
            $SyncReasons.Add("Le chemin Python personnalisé '$legacyCustomPythonPath' de '$ConfigPath' n'a pas pu être migré vers KnownPythonInterpreters et a été ignoré.")
        }
    }

    return @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $mergedInterpreters)
}

function Get-NormalizedKnownPythonInterpretersFromConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RawConfig,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [AllowNull()]
        [System.Collections.Generic.List[string]] $SyncReasons = [System.Collections.Generic.List[string]]::new()
    )

    if (-not (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'KnownPythonInterpreters')) {
        $SyncReasons.Add("Le catalogue KnownPythonInterpreters de '$ConfigPath' a été ajouté.")
        return @()
    }

    $knownInterpreters = [System.Collections.Generic.List[object]]::new()
    $knownPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($rawInterpreter in @($RawConfig.KnownPythonInterpreters)) {
        if ($null -eq $rawInterpreter) {
            continue
        }

        try {
            $source = Get-NormalizedPythonInterpreterSource -Source $rawInterpreter.Source -DefaultSource 'custom'
            $version = "$($rawInterpreter.Version)".Trim()
            $executablePath = Get-NormalizedPathCandidate -Path "$($rawInterpreter.ExecutablePath)"

            if ([string]::IsNullOrWhiteSpace($version)) {
                throw 'Version vide.'
            }

            $alreadyKnown = $false
            foreach ($knownPath in $knownPaths) {
                if ($knownPath.Equals($executablePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $alreadyKnown = $true
                    break
                }
            }

            if ($alreadyKnown) {
                continue
            }

            Add-UniqueCaseInsensitiveString -List $knownPaths -Value $executablePath
            $knownInterpreters.Add([PSCustomObject]@{
                    Source = $source
                    Version = $version
                    ExecutablePath = $executablePath
                })
        }
        catch {
            $SyncReasons.Add("Une entrée KnownPythonInterpreters invalide de '$ConfigPath' a été ignorée.")
        }
    }

    return @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $knownInterpreters)
}

function Get-NormalizedPythonDepotPathFromConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RawConfig,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [AllowNull()]
        [System.Collections.Generic.List[string]] $SyncReasons = [System.Collections.Generic.List[string]]::new()
    )

    if (-not (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'PythonDepotPath')) {
        return $null
    }

    $pythonDepotPathText = "$($RawConfig.PythonDepotPath)".Trim()
    if ([string]::IsNullOrWhiteSpace($pythonDepotPathText)) {
        return $null
    }

    try {
        $pythonDepotPath = Get-NormalizedPath -Path $pythonDepotPathText
        Ensure-DirectoryExists -Path $pythonDepotPath -Label 'Dépôt Python'

        if ($pythonDepotPathText -cne $pythonDepotPath) {
            $SyncReasons.Add("Le paramètre PythonDepotPath de '$ConfigPath' a été normalisé en '$pythonDepotPath'.")
        }

        return $pythonDepotPath
    }
    catch {
        $SyncReasons.Add("Le paramètre PythonDepotPath de '$ConfigPath' est invalide et a été vidé.")
        return $null
    }
}

function Get-NormalizedDefaultPythonInstallLocationFromConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RawConfig,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [AllowNull()]
        [System.Collections.Generic.List[string]] $SyncReasons = [System.Collections.Generic.List[string]]::new()
    )

    if (-not (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'DefaultPythonInstallLocation')) {
        $SyncReasons.Add("Le paramètre DefaultPythonInstallLocation de '$ConfigPath' a été ajouté avec la valeur '$FallbackPythonInstallLocation'.")
        return $FallbackPythonInstallLocation
    }

    try {
        $defaultPythonInstallLocation = Get-NormalizedPythonInstallLocationSetting `
            -InstallLocation $RawConfig.DefaultPythonInstallLocation `
            -AllowDefault `
            -DefaultInstallLocation $FallbackPythonInstallLocation

        if ("$($RawConfig.DefaultPythonInstallLocation)".Trim().ToLowerInvariant() -cne $defaultPythonInstallLocation) {
            $SyncReasons.Add("Le paramètre DefaultPythonInstallLocation de '$ConfigPath' a été normalisé en '$defaultPythonInstallLocation'.")
        }

        return $defaultPythonInstallLocation
    }
    catch {
        $SyncReasons.Add("Le paramètre DefaultPythonInstallLocation de '$ConfigPath' est invalide. Il a été remplacé par '$FallbackPythonInstallLocation'.")
        return $FallbackPythonInstallLocation
    }
}

function New-ProjectConfigData {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectsRootPath,

        [Parameter(Mandatory = $true)]
        [string] $DefaultProjectType,

        [Parameter(Mandatory = $true)]
        [bool] $DefaultCreatePythonVenv,

        [Parameter(Mandatory = $true)]
        [string] $DefaultPythonInstallLocation,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $PythonDepotPath,

        [AllowNull()]
        [object[]] $KnownPythonInterpreters
    )

    return [ordered]@{
        ConfigVersion = $CurrentConfigVersion
        ScriptVersion = $ScriptVersion.ToString()
        ProjectsRootPath = $ProjectsRootPath
        DefaultProjectType = $DefaultProjectType
        DefaultCreatePythonVenv = $DefaultCreatePythonVenv
        DefaultPythonInstallLocation = $DefaultPythonInstallLocation
        PythonDepotPath = $PythonDepotPath
        KnownPythonInterpreters = @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $KnownPythonInterpreters)
    }
}

function Get-ProjectConfigText {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $ConfigData
    )

    $commentLines = @(
        '// Configuration du script prepare-nouveau-projet',
        "// Types de projet connus : $KnownProjectTypesDisplay",
        '// Modifiez "DefaultProjectType" pour changer le type utilisé quand vous appuyez seulement sur Entrée.',
        '// Modifiez "DefaultCreatePythonVenv" : true = O par défaut, false = N par défaut pour les projets Python.',
        '// Modifiez "DefaultPythonInstallLocation" : "depot" = installer par défaut dans le dépôt venv, "default" = utiliser l''installation par défaut de pymanager.',
        '// "PythonDepotPath" est le dépôt dédié aux versions Python installées pour créer des venv.',
        '// Si "PythonDepotPath" est vide, le script vous proposera un dépôt par défaut à côté du dossier projet.',
        '// "KnownPythonInterpreters" est le catalogue synchronisé des versions Python détectées avec leur source, leur version et leur chemin.',
        '// "KnownPythonInterpreters" est synchronisé automatiquement depuis "pymanager list --format=exe" ou "py list --format=exe", plus les chemins Python personnalisés que vous avez déjà saisis.',
        ''
    )

    $json = $ConfigData | ConvertTo-Json -Depth 6
    return (($commentLines -join [Environment]::NewLine) + $json + [Environment]::NewLine)
}

function Save-ProjectConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [Parameter(Mandatory = $true)]
        [string] $ProjectsRootPath,

        [Parameter(Mandatory = $true)]
        [string] $DefaultProjectType,

        [Parameter(Mandatory = $true)]
        [bool] $DefaultCreatePythonVenv,

        [Parameter(Mandatory = $true)]
        [string] $DefaultPythonInstallLocation,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $PythonDepotPath = $null,

        [AllowNull()]
        [object[]] $KnownPythonInterpreters = @(),

        [string] $Message = 'Configuration enregistrée'
    )

    $normalizedProjectsRootPath = Get-NormalizedPath -Path $ProjectsRootPath
    $normalizedDefaultProjectType = Get-NormalizedProjectType -ProjectType $DefaultProjectType
    $normalizedDefaultCreatePythonVenv = Get-NormalizedBooleanSetting -Value $DefaultCreatePythonVenv -SettingName 'Le paramètre DefaultCreatePythonVenv'
    $normalizedDefaultPythonInstallLocation = Get-NormalizedPythonInstallLocationSetting `
        -InstallLocation $DefaultPythonInstallLocation `
        -AllowDefault `
        -DefaultInstallLocation $FallbackPythonInstallLocation
    $normalizedPythonDepotPath = $null
    if (-not [string]::IsNullOrWhiteSpace("$PythonDepotPath")) {
        $normalizedPythonDepotPath = Get-NormalizedPath -Path $PythonDepotPath
        Ensure-DirectoryExists -Path $normalizedPythonDepotPath -Label 'Dépôt Python'
    }
    $normalizedKnownPythonInterpreters = @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $KnownPythonInterpreters)
    Ensure-DirectoryExists -Path $normalizedProjectsRootPath -Label 'Dossier projet'

    $config = New-ProjectConfigData `
        -ProjectsRootPath $normalizedProjectsRootPath `
        -DefaultProjectType $normalizedDefaultProjectType `
        -DefaultCreatePythonVenv $normalizedDefaultCreatePythonVenv `
        -DefaultPythonInstallLocation $normalizedDefaultPythonInstallLocation `
        -PythonDepotPath $normalizedPythonDepotPath `
        -KnownPythonInterpreters $normalizedKnownPythonInterpreters
    $configText = Get-ProjectConfigText -ConfigData $config
    Write-Utf8TextFile -Path $ConfigPath -Content $configText

    Write-Host "$Message : $ConfigPath" -ForegroundColor Green

    return [PSCustomObject]@{
        ConfigVersion = $CurrentConfigVersion
        ScriptVersion = $ScriptVersion
        ProjectsRootPath = $normalizedProjectsRootPath
        DefaultProjectType = $normalizedDefaultProjectType
        DefaultCreatePythonVenv = $normalizedDefaultCreatePythonVenv
        DefaultPythonInstallLocation = $normalizedDefaultPythonInstallLocation
        PythonDepotPath = $normalizedPythonDepotPath
        KnownPythonInterpreters = $normalizedKnownPythonInterpreters
    }
}

function Get-DisabledConfigPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath
    )

    $directoryPath = Split-Path -Path $ConfigPath -Parent
    $fileNameWithoutExtension = [System.IO.Path]::GetFileNameWithoutExtension($ConfigPath)
    $extension = [System.IO.Path]::GetExtension($ConfigPath)
    $disabledFileNameBase = "$fileNameWithoutExtension.$ConfigDisabledSuffix"
    $candidatePath = Join-Path -Path $directoryPath -ChildPath ($disabledFileNameBase + $extension)
    $counter = 1

    while (Test-Path -LiteralPath $candidatePath) {
        $candidatePath = Join-Path -Path $directoryPath -ChildPath ("$disabledFileNameBase-$counter$extension")
        $counter++
    }

    return $candidatePath
}

function Disable-ConfigFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [Parameter(Mandatory = $true)]
        [string] $Reason
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return $null
    }

    $disabledConfigPath = Get-DisabledConfigPath -ConfigPath $ConfigPath
    $disabledFileName = Split-Path -Path $disabledConfigPath -Leaf
    Rename-Item -LiteralPath $ConfigPath -NewName $disabledFileName
    Write-Host $Reason -ForegroundColor Yellow
    Write-Host "Fichier de configuration désactivé : $disabledConfigPath" -ForegroundColor Yellow

    return $disabledConfigPath
}

function ConvertTo-NormalizedProjectConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RawConfig,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($RawConfig.ProjectsRootPath)) {
        throw "Le fichier de configuration '$ConfigPath' ne contient pas de chemin de dossier projet."
    }

    $syncReasons = [System.Collections.Generic.List[string]]::new()
    $projectsRootPath = Get-NormalizedPath -Path $RawConfig.ProjectsRootPath
    Ensure-DirectoryExists -Path $projectsRootPath -Label 'Dossier projet'
    $configVersion = Get-ConfigVersionValue -RawConfig $RawConfig -ConfigPath $ConfigPath
    $storedScriptVersion = Get-ScriptVersionValue -RawConfig $RawConfig -ConfigPath $ConfigPath

    if (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'DefaultProjectType') {
        try {
            $defaultProjectType = Get-NormalizedProjectType -ProjectType $RawConfig.DefaultProjectType

            if ("$($RawConfig.DefaultProjectType)".Trim() -cne $defaultProjectType) {
                $syncReasons.Add("Le type de projet par défaut de '$ConfigPath' a été normalisé en '$defaultProjectType'.")
            }
        }
        catch {
            $defaultProjectType = $FallbackProjectType
            $syncReasons.Add("Le type de projet par défaut de '$ConfigPath' est invalide. Il a été remplacé par '$FallbackProjectType'.")
        }
    }
    else {
        $defaultProjectType = $FallbackProjectType
        $syncReasons.Add("Le type de projet par défaut de '$ConfigPath' a été ajouté avec la valeur '$FallbackProjectType'.")
    }

    if (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'DefaultCreatePythonVenv') {
        try {
            $defaultCreatePythonVenv = Get-NormalizedBooleanSetting -Value $RawConfig.DefaultCreatePythonVenv -SettingName "Le paramètre DefaultCreatePythonVenv de '$ConfigPath'"

            if (-not ($RawConfig.DefaultCreatePythonVenv -is [bool])) {
                $syncReasons.Add("Le paramètre DefaultCreatePythonVenv de '$ConfigPath' a été normalisé en '$defaultCreatePythonVenv'.")
            }
        }
        catch {
            $defaultCreatePythonVenv = $FallbackCreatePythonVenv
            $syncReasons.Add("Le paramètre DefaultCreatePythonVenv de '$ConfigPath' est invalide. Il a été remplacé par '$FallbackCreatePythonVenv'.")
        }
    }
    else {
        $defaultCreatePythonVenv = $FallbackCreatePythonVenv
        $syncReasons.Add("Le paramètre DefaultCreatePythonVenv de '$ConfigPath' a été ajouté avec la valeur '$FallbackCreatePythonVenv'.")
    }

    $defaultPythonInstallLocation = Get-NormalizedDefaultPythonInstallLocationFromConfig `
        -RawConfig $RawConfig `
        -ConfigPath $ConfigPath `
        -SyncReasons $syncReasons
    $legacyCustomPythonPaths = Get-LegacyCustomPythonPathsFromConfig -RawConfig $RawConfig -ConfigPath $ConfigPath -SyncReasons $syncReasons
    $knownPythonInterpreters = Get-NormalizedKnownPythonInterpretersFromConfig -RawConfig $RawConfig -ConfigPath $ConfigPath -SyncReasons $syncReasons
    $pythonDepotPath = Get-NormalizedPythonDepotPathFromConfig -RawConfig $RawConfig -ConfigPath $ConfigPath -SyncReasons $syncReasons
    $hadLegacyCustomPythonPaths = Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'CustomPythonPaths'

    if ($hadLegacyCustomPythonPaths) {
        $knownPythonInterpreters = Merge-LegacyCustomPythonPathsIntoKnownPythonInterpreters `
            -KnownPythonInterpreters $knownPythonInterpreters `
            -LegacyCustomPythonPaths $legacyCustomPythonPaths `
            -ConfigPath $ConfigPath `
            -SyncReasons $syncReasons

        $syncReasons.Add("La liste CustomPythonPaths de '$ConfigPath' a été remplacée par KnownPythonInterpreters.")
    }

    return [PSCustomObject]@{
        ConfigVersion = $configVersion
        ScriptVersion = $storedScriptVersion
        ProjectsRootPath = $projectsRootPath
        DefaultProjectType = $defaultProjectType
        DefaultCreatePythonVenv = $defaultCreatePythonVenv
        DefaultPythonInstallLocation = $defaultPythonInstallLocation
        PythonDepotPath = $pythonDepotPath
        KnownPythonInterpreters = $knownPythonInterpreters
        SyncReasons = $syncReasons.ToArray()
    }
}

function Get-ProjectConfigStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        return [PSCustomObject]@{
            Status = 'Missing'
            Config = $null
            Message = ''
        }
    }

    try {
        $content = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8)

        if ([string]::IsNullOrWhiteSpace($content)) {
            throw 'Le fichier de configuration est vide.'
        }

        $jsonContent = Get-ConfigContentWithoutComments -Content $content

        if ([string]::IsNullOrWhiteSpace($jsonContent)) {
            throw 'Le fichier de configuration ne contient aucun JSON exploitable.'
        }

        $rawConfig = $jsonContent | ConvertFrom-Json
        $config = ConvertTo-NormalizedProjectConfig -RawConfig $rawConfig -ConfigPath $ConfigPath
    }
    catch {
        return [PSCustomObject]@{
            Status = 'Corrupted'
            Config = $null
            Message = "Le fichier de configuration '$ConfigPath' est corrompu ou illisible : $($_.Exception.Message)"
        }
    }

    if ($config.ConfigVersion -gt $CurrentConfigVersion) {
        return [PSCustomObject]@{
            Status = 'TooNew'
            Config = $config
            Message = "Le fichier de configuration '$ConfigPath' utilise une version de configuration plus récente que ce script."
        }
    }

    if ($null -ne $config.ScriptVersion -and $config.ScriptVersion -gt $ScriptVersion) {
        return [PSCustomObject]@{
            Status = 'TooNew'
            Config = $config
            Message = "Le fichier de configuration '$ConfigPath' provient d'un script plus récent que la version $($ScriptVersion.ToString())."
        }
    }

    if ($config.ConfigVersion -lt $CurrentConfigVersion -or $null -eq $config.ScriptVersion -or $config.ScriptVersion -lt $ScriptVersion -or $config.SyncReasons.Count -gt 0) {
        $messages = [System.Collections.Generic.List[string]]::new()

        if ($config.ConfigVersion -lt $CurrentConfigVersion -or $null -eq $config.ScriptVersion -or $config.ScriptVersion -lt $ScriptVersion) {
            $messages.Add("Le fichier de configuration '$ConfigPath' a été synchronisé avec la version $($ScriptVersion.ToString()).")
        }

        foreach ($syncReason in $config.SyncReasons) {
            $messages.Add($syncReason)
        }

        return [PSCustomObject]@{
            Status = 'Outdated'
            Config = $config
            Message = ($messages -join ' ')
        }
    }

    return [PSCustomObject]@{
        Status = 'Current'
        Config = $config
        Message = ''
    }
}

function Use-ExistingProjectConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath
    )

    $configStatus = Get-ProjectConfigStatus -ConfigPath $ConfigPath

    switch ($configStatus.Status) {
        'Missing' {
            return $null
        }
        'Current' {
            return $configStatus.Config
        }
        'Outdated' {
            return Save-ProjectConfig `
                -ConfigPath $ConfigPath `
                -ProjectsRootPath $configStatus.Config.ProjectsRootPath `
                -DefaultProjectType $configStatus.Config.DefaultProjectType `
                -DefaultCreatePythonVenv $configStatus.Config.DefaultCreatePythonVenv `
                -DefaultPythonInstallLocation $configStatus.Config.DefaultPythonInstallLocation `
                -PythonDepotPath $configStatus.Config.PythonDepotPath `
                -KnownPythonInterpreters $configStatus.Config.KnownPythonInterpreters `
                -Message $configStatus.Message
        }
        'TooNew' {
            Disable-ConfigFile -ConfigPath $ConfigPath -Reason $configStatus.Message | Out-Null
            return $null
        }
        'Corrupted' {
            Disable-ConfigFile -ConfigPath $ConfigPath -Reason $configStatus.Message | Out-Null
            return $null
        }
        default {
            throw "Statut de configuration inattendu : $($configStatus.Status)"
        }
    }
}

function Ensure-ConfigCopy {
    param(
        [Parameter(Mandatory = $true)]
        [string] $SourceProjectsRootPath,

        [Parameter(Mandatory = $true)]
        [string] $DefaultProjectType,

        [Parameter(Mandatory = $true)]
        [bool] $DefaultCreatePythonVenv,

        [Parameter(Mandatory = $true)]
        [string] $DefaultPythonInstallLocation,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $PythonDepotPath,

        [AllowNull()]
        [object[]] $KnownPythonInterpreters,

        [Parameter(Mandatory = $true)]
        [string] $DestinationConfigPath
    )

    return Save-ProjectConfig `
        -ConfigPath $DestinationConfigPath `
        -ProjectsRootPath $SourceProjectsRootPath `
        -DefaultProjectType $DefaultProjectType `
        -DefaultCreatePythonVenv $DefaultCreatePythonVenv `
        -DefaultPythonInstallLocation $DefaultPythonInstallLocation `
        -PythonDepotPath $PythonDepotPath `
        -KnownPythonInterpreters $KnownPythonInterpreters `
        -Message 'Configuration synchronisée'
}

function Initialize-ProjectConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [Parameter(Mandatory = $true)]
        [string] $ConfigFileName
    )

    Write-Host 'Aucun fichier de configuration exploitable trouvé.' -ForegroundColor Yellow
    Write-Host "Version du script : $($ScriptVersion.ToString())"
    Write-Host "Chemin actuel du script : $PSCommandPath"
    Write-Host "Dossier du script : $PSScriptRoot"

    $useScriptDirectory = Read-Confirmation -Prompt 'Est-ce bien le dossier projet actuel ? (O/N)'

    if ($useScriptDirectory) {
        $projectsRootPath = Get-NormalizedPath -Path $PSScriptRoot
        return Save-ProjectConfig `
            -ConfigPath $ConfigPath `
            -ProjectsRootPath $projectsRootPath `
            -DefaultProjectType $FallbackProjectType `
            -DefaultCreatePythonVenv $FallbackCreatePythonVenv `
            -DefaultPythonInstallLocation $FallbackPythonInstallLocation `
            -PythonDepotPath $null
    }

    $projectsRootPath = Read-ProjectsRootPath
    $candidateConfigPath = Join-Path -Path $projectsRootPath -ChildPath $ConfigFileName
    $candidateConfig = Use-ExistingProjectConfig -ConfigPath $candidateConfigPath

    if ($null -eq $candidateConfig) {
        $candidateConfig = Save-ProjectConfig `
            -ConfigPath $candidateConfigPath `
            -ProjectsRootPath $projectsRootPath `
            -DefaultProjectType $FallbackProjectType `
            -DefaultCreatePythonVenv $FallbackCreatePythonVenv `
            -DefaultPythonInstallLocation $FallbackPythonInstallLocation `
            -PythonDepotPath $null `
            -Message 'Nouvelle configuration créée'
    }

    if ($candidateConfigPath -ne $ConfigPath) {
        Ensure-ConfigCopy `
            -SourceProjectsRootPath $candidateConfig.ProjectsRootPath `
            -DefaultProjectType $candidateConfig.DefaultProjectType `
            -DefaultCreatePythonVenv $candidateConfig.DefaultCreatePythonVenv `
            -DefaultPythonInstallLocation $candidateConfig.DefaultPythonInstallLocation `
            -PythonDepotPath $candidateConfig.PythonDepotPath `
            -KnownPythonInterpreters $candidateConfig.KnownPythonInterpreters `
            -DestinationConfigPath $ConfigPath | Out-Null
    }

    return $candidateConfig
}

function Get-ProjectConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [Parameter(Mandatory = $true)]
        [string] $ConfigFileName
    )

    $currentConfig = Use-ExistingProjectConfig -ConfigPath $ConfigPath

    if ($null -ne $currentConfig) {
        return $currentConfig
    }

    return Initialize-ProjectConfig -ConfigPath $ConfigPath -ConfigFileName $ConfigFileName
}

function Ensure-PythonDepotPathConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [Parameter(Mandatory = $true)]
        [object] $ProjectConfig
    )

    if (-not [string]::IsNullOrWhiteSpace("$($ProjectConfig.PythonDepotPath)")) {
        return $ProjectConfig
    }

    $pythonDepotPath = Read-OptionalPythonDepotPath -ProjectsRootPath $ProjectConfig.ProjectsRootPath

    if ([string]::IsNullOrWhiteSpace("$pythonDepotPath")) {
        return $ProjectConfig
    }

    return Save-ProjectConfig `
        -ConfigPath $ConfigPath `
        -ProjectsRootPath $ProjectConfig.ProjectsRootPath `
        -DefaultProjectType $ProjectConfig.DefaultProjectType `
        -DefaultCreatePythonVenv $ProjectConfig.DefaultCreatePythonVenv `
        -DefaultPythonInstallLocation $ProjectConfig.DefaultPythonInstallLocation `
        -PythonDepotPath $pythonDepotPath `
        -KnownPythonInterpreters $ProjectConfig.KnownPythonInterpreters `
        -Message 'Dépôt Python dédié aux venv enregistré'
}

function Resolve-ProjectTypeSelection {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ProjectType,

        [Parameter(Mandatory = $true)]
        [string] $DefaultProjectType,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $CustomProjectType
    )

    if ([string]::IsNullOrWhiteSpace($ProjectType)) {
        $normalizedProjectType = Read-ProjectType -DefaultProjectType $DefaultProjectType
    }
    else {
        $normalizedProjectType = Get-NormalizedProjectType -ProjectType $ProjectType
    }

    if ($normalizedProjectType -eq 'autre') {
        if ([string]::IsNullOrWhiteSpace($CustomProjectType)) {
            $projectTypeLabel = Read-CustomProjectType
        }
        else {
            $projectTypeLabel = Get-NormalizedCustomProjectType -CustomProjectType $CustomProjectType
        }
    }
    else {
        $projectTypeLabel = $normalizedProjectType
    }

    return [PSCustomObject]@{
        NormalizedProjectType = $normalizedProjectType
        ProjectTypeLabel = $projectTypeLabel
    }
}

function Resolve-ProjectTarget {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectsRootPath,

        [Parameter(Mandatory = $true)]
        [string] $ProjectName
    )

    $resolvedProjectName = $ProjectName

    while ($true) {
        $projectPath = Join-Path -Path $ProjectsRootPath -ChildPath $resolvedProjectName

        if (-not (Test-Path -LiteralPath $projectPath)) {
            return [PSCustomObject]@{
                Cancelled = $false
                ProjectName = $resolvedProjectName
                ProjectPath = $projectPath
            }
        }

        $action = Read-ExistingProjectAction -ProjectName $resolvedProjectName -ProjectPath $projectPath

        if ($action -eq 'Cancel') {
            Write-Host 'Aucune modification effectuée.' -ForegroundColor Yellow
            return [PSCustomObject]@{
                Cancelled = $true
                ProjectName = $resolvedProjectName
                ProjectPath = $projectPath
            }
        }

        $resolvedProjectName = Read-ProjectName
    }
}

function New-ProjectDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectsRootPath,

        [Parameter(Mandatory = $true)]
        [string] $ProjectName,

        [Parameter(Mandatory = $true)]
        [string] $ProjectTypeLabel
    )

    $targetPath = Join-Path -Path $ProjectsRootPath -ChildPath $ProjectName
    Write-Host "Type de projet sélectionné : $ProjectTypeLabel" -ForegroundColor Cyan

    New-Item -ItemType Directory -Path $targetPath | Out-Null
    Write-Host "Projet créé : $targetPath" -ForegroundColor Green
    return $targetPath
}

function New-PythonProjectReadme {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $ProjectName,

        [bool] $HasVirtualEnvironment = $false
    )

    $readmePath = Join-Path -Path $ProjectPath -ChildPath 'README.md'

    if (Test-Path -LiteralPath $readmePath) {
        Write-Host "README déjà présent : $readmePath" -ForegroundColor Yellow
        return $readmePath
    }

    $quickStartLines = [System.Collections.Generic.List[string]]::new()

    if ($HasVirtualEnvironment) {
        $quickStartLines.Add('.\.venv\Scripts\Activate.ps1')
        $quickStartLines.Add('python --version')
    }
    else {
        $quickStartLines.Add('python -m venv .venv')
        $quickStartLines.Add('.\.venv\Scripts\Activate.ps1')
        $quickStartLines.Add('python --version')
    }

    $contentLines = @(
        "# $ProjectName",
        '',
        'Projet Python préparé avec `prepare-nouveau-projet.ps1`.',
        '',
        '## Démarrage rapide',
        '',
        '```',
        ($quickStartLines -join [Environment]::NewLine),
        '```',
        '',
        '## Notes',
        '',
        '- Le code du projet peut être ajouté ici.',
        '- Le venv local est prévu dans le dossier `.venv`.'
    )

    $content = ($contentLines -join [Environment]::NewLine) + [Environment]::NewLine
    Write-Utf8TextFile -Path $readmePath -Content $content
    Write-Host "README créé : $readmePath" -ForegroundColor Green
    return $readmePath
}

function Get-PythonRequirementsFileName {
    param(
        [datetime] $Date = (Get-Date)
    )

    return ('{0:yyyy-MM-dd}requirements.txt' -f $Date)
}

function New-PythonProjectRequirementsFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [datetime] $Date = (Get-Date)
    )

    $requirementsFileName = Get-PythonRequirementsFileName -Date $Date
    $requirementsPath = Join-Path -Path $ProjectPath -ChildPath $requirementsFileName

    if (Test-Path -LiteralPath $requirementsPath) {
        Write-Host "Fichier requirements déjà présent : $requirementsPath" -ForegroundColor Yellow
        return $requirementsPath
    }

    $contentLines = @(
        '# Dépendances Python du projet',
        '# Ajoutez une dépendance par ligne, par exemple :',
        '# requests==2.32.3'
    )

    $content = ($contentLines -join [Environment]::NewLine) + [Environment]::NewLine
    Write-Utf8TextFile -Path $requirementsPath -Content $content
    Write-Host "Fichier requirements créé : $requirementsPath" -ForegroundColor Green
    return $requirementsPath
}

function Get-NormalizedPythonDistributionName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectName
    )

    $normalizedText = $ProjectName.Normalize([Text.NormalizationForm]::FormD)
    $builder = [System.Text.StringBuilder]::new()

    foreach ($character in $normalizedText.ToCharArray()) {
        $unicodeCategory = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ($unicodeCategory -eq [Globalization.UnicodeCategory]::NonSpacingMark) {
            continue
        }

        [void] $builder.Append($character)
    }

    $asciiFriendlyName = $builder.ToString().Normalize([Text.NormalizationForm]::FormC).ToLowerInvariant()
    $distributionName = [System.Text.RegularExpressions.Regex]::Replace($asciiFriendlyName, '[^a-z0-9._-]+', '-')
    $distributionName = [System.Text.RegularExpressions.Regex]::Replace($distributionName, '-{2,}', '-').Trim('-')

    if ([string]::IsNullOrWhiteSpace($distributionName)) {
        return 'mon-projet-python'
    }

    return $distributionName
}

function Get-PythonVenvPromptLabel {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectName
    )

    $normalizedText = $ProjectName.Normalize([Text.NormalizationForm]::FormD)
    $builder = [System.Text.StringBuilder]::new()

    foreach ($character in $normalizedText.ToCharArray()) {
        $unicodeCategory = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ($unicodeCategory -eq [Globalization.UnicodeCategory]::NonSpacingMark) {
            continue
        }

        if ([char]::IsLetterOrDigit($character)) {
            [void] $builder.Append($character)
        }
    }

    $projectLabel = $builder.ToString()
    if ([string]::IsNullOrWhiteSpace($projectLabel)) {
        return 'venvProjet'
    }

    return "venv$projectLabel"
}

function New-PythonProjectPyprojectFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $ProjectName
    )

    $pyprojectPath = Join-Path -Path $ProjectPath -ChildPath 'pyproject.toml'

    if (Test-Path -LiteralPath $pyprojectPath) {
        Write-Host "pyproject.toml déjà présent : $pyprojectPath" -ForegroundColor Yellow
        return $pyprojectPath
    }

    $distributionName = Get-NormalizedPythonDistributionName -ProjectName $ProjectName
    $contentLines = @(
        '[project]',
        "name = ""$distributionName""",
        'version = "0.1.0"',
        "description = ""Projet Python $ProjectName""",
        'readme = "README.md"',
        'dependencies = []',
        '',
        '[build-system]',
        'requires = ["setuptools>=61.0"]',
        'build-backend = "setuptools.build_meta"'
    )

    $content = ($contentLines -join [Environment]::NewLine) + [Environment]::NewLine
    Write-Utf8TextFile -Path $pyprojectPath -Content $content
    Write-Host "pyproject.toml créé : $pyprojectPath" -ForegroundColor Green
    return $pyprojectPath
}

function New-ProjectGitIgnoreFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $ProjectType
    )

    $gitIgnorePath = Join-Path -Path $ProjectPath -ChildPath '.gitignore'

    if (Test-Path -LiteralPath $gitIgnorePath) {
        Write-Host ".gitignore déjà présent : $gitIgnorePath" -ForegroundColor Yellow
        return $gitIgnorePath
    }

    $contentLines = [System.Collections.Generic.List[string]]::new()
    $contentLines.Add('# Fichiers système et temporaires')
    $contentLines.Add('Thumbs.db')
    $contentLines.Add('Desktop.ini')
    $contentLines.Add('*.tmp')
    $contentLines.Add('*.temp')
    $contentLines.Add('*.log')
    $contentLines.Add('')
    $contentLines.Add('# Dossiers et fichiers locaux')
    $contentLines.Add('.vscode/')
    $contentLines.Add('.idea/')
    $contentLines.Add('.env')
    $contentLines.Add('.env.*')

    if ($ProjectType -eq 'py') {
        $contentLines.Add('')
        $contentLines.Add('# Python')
        $contentLines.Add('.venv/')
        $contentLines.Add('__pycache__/')
        $contentLines.Add('*.pyc')
        $contentLines.Add('*.pyo')
        $contentLines.Add('*.pyd')
        $contentLines.Add('.pytest_cache/')
        $contentLines.Add('.mypy_cache/')
        $contentLines.Add('.ruff_cache/')
        $contentLines.Add('build/')
        $contentLines.Add('dist/')
        $contentLines.Add('*.egg-info/')
    }

    $content = (($contentLines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine
    Write-Utf8TextFile -Path $gitIgnorePath -Content $content
    Write-Host ".gitignore créé : $gitIgnorePath" -ForegroundColor Green
    return $gitIgnorePath
}

function New-PythonProjectCmdVenvLauncher {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $ProjectName
    )

    $launcherPath = Join-Path -Path $ProjectPath -ChildPath 'cmdVenv.cmd'

    if (Test-Path -LiteralPath $launcherPath) {
        Write-Host "cmdVenv.cmd déjà présent : $launcherPath" -ForegroundColor Yellow
        return $launcherPath
    }

    $promptLabel = Get-PythonVenvPromptLabel -ProjectName $ProjectName
    $contentLines = @(
        '@echo off',
        'setlocal',
        'chcp 65001 >nul',
        'cd /d "%~dp0"',
        '',
        'if not exist ".venv\Scripts\activate.bat" (',
        '    echo Erreur : aucun environnement virtuel Python n''a ete trouve dans ".venv".',
        '    echo Relancez "prepare-nouveau-projet.ps1" ou creez ".venv" manuellement.',
        '    pause',
        '    exit /b 1',
        ')',
        '',
        'call ".venv\Scripts\activate.bat"',
        "set ""PROMPT=($promptLabel) `$P`$G""",
        'cmd.exe'
    )

    $content = ($contentLines -join [Environment]::NewLine) + [Environment]::NewLine
    Write-Utf8TextFile -Path $launcherPath -Content $content -WithoutBom
    Write-Host "cmdVenv.cmd créé : $launcherPath" -ForegroundColor Green
    return $launcherPath
}

function Invoke-ExternalExecutableCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ExecutablePath,

        [string[]] $Arguments = @(),

        [string] $WaitMessage = ''
    )

    $stopwatch = $null

    if (-not [string]::IsNullOrWhiteSpace($WaitMessage)) {
        Write-StepInfo "$WaitMessage..."
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    $previousErrorActionPreference = $ErrorActionPreference
    $hadNativeCommandPreference = $false
    $previousNativeCommandPreference = $null

    try {
        $ErrorActionPreference = 'Continue'

        $nativeCommandPreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
        if ($null -ne $nativeCommandPreferenceVariable) {
            $hadNativeCommandPreference = $true
            $previousNativeCommandPreference = [bool] $nativeCommandPreferenceVariable.Value
            $script:PSNativeCommandUseErrorActionPreference = $false
        }

        $outputLines = @(& $ExecutablePath @Arguments 2>&1 | ForEach-Object { "$_" })
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    }
    catch {
        return [PSCustomObject]@{
            ExecutablePath = $ExecutablePath
            Success = $false
            ExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { $LASTEXITCODE }
            OutputLines = @()
            ErrorMessage = $_.Exception.Message
        }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference

        if ($hadNativeCommandPreference) {
            $script:PSNativeCommandUseErrorActionPreference = $previousNativeCommandPreference
        }

        if ($null -ne $stopwatch) {
            $stopwatch.Stop()
            Write-StepInfo ("Temps écoulé : {0:N1} s" -f $stopwatch.Elapsed.TotalSeconds)
        }
    }

    return [PSCustomObject]@{
        ExecutablePath = $ExecutablePath
        Success = ($exitCode -eq 0)
        ExitCode = $exitCode
        OutputLines = $outputLines
        ErrorMessage = ''
    }
}

function Invoke-ExternalCommandCapture {
    param(
        [Parameter(Mandatory = $true)]
        [string] $CommandName,

        [string[]] $Arguments = @(),

        [string] $WaitMessage = ''
    )

    $command = Get-Command -Name $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($null -eq $command) {
        return $null
    }

    $result = Invoke-ExternalExecutableCapture -ExecutablePath $command.Source -Arguments $Arguments -WaitMessage $WaitMessage

    if ($null -eq $result) {
        return $null
    }

    return [PSCustomObject]@{
        CommandName = $CommandName
        CommandPath = $result.ExecutablePath
        Success = $result.Success
        ExitCode = $result.ExitCode
        OutputLines = $result.OutputLines
        ErrorMessage = $result.ErrorMessage
    }
}

function Get-PreferredPythonManagerCommand {
    foreach ($commandName in @('pymanager', 'py')) {
        $command = Get-Command -Name $commandName -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            return [PSCustomObject]@{
                CommandName = $commandName
                CommandPath = $command.Source
            }
        }
    }

    return $null
}

function Invoke-PythonManagerCommandCapture {
    param(
        [string[]] $Arguments = @(),

        [string] $WaitMessage = ''
    )

    $command = Get-PreferredPythonManagerCommand
    if ($null -eq $command) {
        return $null
    }

    $result = Invoke-ExternalExecutableCapture -ExecutablePath $command.CommandPath -Arguments $Arguments -WaitMessage $WaitMessage

    return [PSCustomObject]@{
        CommandName = $command.CommandName
        CommandPath = $result.ExecutablePath
        Success = $result.Success
        ExitCode = $result.ExitCode
        OutputLines = $result.OutputLines
        ErrorMessage = $result.ErrorMessage
    }
}

function Get-ObjectTextProperty {
    param(
        [AllowNull()]
        [object] $InputObject,

        [Parameter(Mandatory = $true)]
        [string[]] $PropertyNames
    )

    if ($null -eq $InputObject) {
        return ''
    }

    foreach ($propertyName in $PropertyNames) {
        $property = $InputObject.PSObject.Properties.Match($propertyName) | Select-Object -First 1
        if ($null -eq $property -or $null -eq $property.Value) {
            continue
        }

        $propertyText = "$($property.Value)".Trim()
        if (-not [string]::IsNullOrWhiteSpace($propertyText)) {
            return $propertyText
        }
    }

    return ''
}

function Get-VersionSortValue {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Text
    )

    $textValue = if ($null -eq $Text) { '' } else { $Text.Trim() }
    if ([string]::IsNullOrWhiteSpace($textValue)) {
        return [Version] '0.0.0'
    }

    $versionMatch = [System.Text.RegularExpressions.Regex]::Match($textValue, '\d+(?:\.\d+)+')
    if ($versionMatch.Success) {
        try {
            return [Version] $versionMatch.Value
        }
        catch {
            return [Version] '0.0.0'
        }
    }

    return [Version] '0.0.0'
}

function Get-PythonVersionFromExecutablePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PythonExecutablePath
    )

    $normalizedPythonExecutablePath = Get-NormalizedExistingFilePath -Path $PythonExecutablePath -Label 'Python'
    $result = Invoke-ExternalExecutableCapture -ExecutablePath $normalizedPythonExecutablePath -Arguments @('--version')

    if (-not $result.Success) {
        if (-not [string]::IsNullOrWhiteSpace($result.ErrorMessage)) {
            throw "Impossible de lire la version de Python pour '$normalizedPythonExecutablePath' : $($result.ErrorMessage)"
        }

        throw "Impossible de lire la version de Python pour '$normalizedPythonExecutablePath'."
    }

    $versionText = ($result.OutputLines -join ' ')
    $versionMatch = [System.Text.RegularExpressions.Regex]::Match($versionText, 'Python\s+([^\s]+)')

    if (-not $versionMatch.Success) {
        throw "Impossible de déterminer la version du Python '$normalizedPythonExecutablePath'."
    }

    return $versionMatch.Groups[1].Value
}

function New-PythonInterpreterEntry {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ExecutablePath,

        [Parameter(Mandatory = $true)]
        [string] $Source
    )

    $normalizedSource = Get-NormalizedPythonInterpreterSource -Source $Source
    $normalizedExecutablePath = Get-NormalizedExistingFilePath -Path $ExecutablePath -Label 'Python'
    $pythonVersion = Get-PythonVersionFromExecutablePath -PythonExecutablePath $normalizedExecutablePath

    return [PSCustomObject]@{
        Source = $normalizedSource
        Version = $pythonVersion
        ExecutablePath = $normalizedExecutablePath
    }
}

function Convert-LegacyPyListLinesToExecutablePaths {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $OutputLines
    )

    $paths = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $OutputLines) {
        $trimmedLine = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedLine)) {
            continue
        }

        if (Test-Path -LiteralPath $trimmedLine) {
            Add-UniqueCaseInsensitiveString -List $paths -Value $trimmedLine
            continue
        }

        $match = [System.Text.RegularExpressions.Regex]::Match($trimmedLine, '((?:[A-Za-z]:|\\\\)[^:*?"<>|\r\n]+python(?:w)?\.(?:exe|cmd|bat))$')
        if ($match.Success) {
            Add-UniqueCaseInsensitiveString -List $paths -Value $match.Groups[1].Value
        }
    }

    return @($paths)
}

function Get-PythonManagerExecutablePaths {
    $primaryResult = Invoke-PythonManagerCommandCapture -Arguments @('list', '--format=exe')

    if ($null -ne $primaryResult -and $primaryResult.Success) {
        $paths = [System.Collections.Generic.List[string]]::new()
        foreach ($line in $primaryResult.OutputLines) {
            $trimmedLine = $line.Trim().Trim('"')
            if ([string]::IsNullOrWhiteSpace($trimmedLine)) {
                continue
            }

            Add-UniqueCaseInsensitiveString -List $paths -Value $trimmedLine
        }

        return @($paths)
    }

    $legacyResult = Invoke-ExternalCommandCapture -CommandName 'py' -Arguments @('-0p')
    if ($null -ne $legacyResult -and $legacyResult.Success) {
        return Convert-LegacyPyListLinesToExecutablePaths -OutputLines $legacyResult.OutputLines
    }

    return @()
}

function Get-PythonManagerInterpreterEntries {
    $entries = [System.Collections.Generic.List[object]]::new()
    $knownPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($executablePath in Get-PythonManagerExecutablePaths) {
        try {
            $entry = New-PythonInterpreterEntry -ExecutablePath $executablePath -Source 'pymanager'
            $alreadyKnown = $false

            foreach ($knownPath in $knownPaths) {
                if ($knownPath.Equals($entry.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $alreadyKnown = $true
                    break
                }
            }

            if (-not $alreadyKnown) {
                Add-UniqueCaseInsensitiveString -List $knownPaths -Value $entry.ExecutablePath
                $entries.Add($entry)
            }
        }
        catch {
            continue
        }
    }

    return @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $entries)
}

function Get-AvailablePythonInterpreters {
    param(
        [AllowNull()]
        [object[]] $KnownPythonInterpreters
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    $knownPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in Get-PythonManagerInterpreterEntries) {
        Add-UniqueCaseInsensitiveString -List $knownPaths -Value $entry.ExecutablePath
        $entries.Add($entry)
    }

    foreach ($knownInterpreter in @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $KnownPythonInterpreters)) {
        if ($knownInterpreter.Source -notin @('custom', 'depot')) {
            continue
        }

        try {
            $entry = New-PythonInterpreterEntry -ExecutablePath $knownInterpreter.ExecutablePath -Source $knownInterpreter.Source
            $alreadyKnown = $false

            foreach ($knownPath in $knownPaths) {
                if ($knownPath.Equals($entry.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $alreadyKnown = $true
                    break
                }
            }

            if (-not $alreadyKnown) {
                Add-UniqueCaseInsensitiveString -List $knownPaths -Value $entry.ExecutablePath
                $entries.Add($entry)
            }
        }
        catch {
            continue
        }
    }

    return @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $entries)
}

function Get-PythonInterpreterDisplayLabel {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Interpreter
    )

    $sourceLabel = switch ($Interpreter.Source) {
        'pymanager' { 'pymanager' }
        'depot' { 'dépôt venv' }
        'custom' { 'chemin enregistré' }
        default { $Interpreter.Source }
    }

    return "$($Interpreter.Version) - $($Interpreter.ExecutablePath) [$sourceLabel]"
}

function ConvertTo-CanonicalPythonInstallableRuntimeEntries {
    param(
        [AllowNull()]
        [object[]] $Entries
    )

    $runtimeEntries = @($Entries)
    $orderedEntries = $runtimeEntries | Sort-Object `
        @{ Expression = { Get-VersionSortValue -Text "$($_.Version)" }; Descending = $true }, `
        @{ Expression = { $_.InstallTag.ToLowerInvariant() } }

    return @(
        $orderedEntries | ForEach-Object {
            [PSCustomObject] ([ordered]@{
                    Version = $_.Version
                    Architecture = $_.Architecture
                    InstallTag = $_.InstallTag
                    DisplayName = $_.DisplayName
                    ManagerCommandName = $_.ManagerCommandName
                })
        }
    )
}

function ConvertTo-PythonInstallableRuntimeEntries {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $OutputLines,

        [Parameter(Mandatory = $true)]
        [string] $ManagerCommandName
    )

    $runtimeEntries = [System.Collections.Generic.List[object]]::new()
    $knownTags = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $OutputLines) {
        $trimmedLine = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedLine) -or -not $trimmedLine.StartsWith('{')) {
            continue
        }

        try {
            $runtimeObject = $trimmedLine | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }

        $installTag = Get-ObjectTextProperty -InputObject $runtimeObject -PropertyNames @('tag', 'id', 'install_tag', 'install-tag', 'alias')
        if ([string]::IsNullOrWhiteSpace($installTag)) {
            continue
        }

        $alreadyKnown = $false
        foreach ($knownTag in $knownTags) {
            if ($knownTag.Equals($installTag, [System.StringComparison]::OrdinalIgnoreCase)) {
                $alreadyKnown = $true
                break
            }
        }

        if ($alreadyKnown) {
            continue
        }

        Add-UniqueCaseInsensitiveString -List $knownTags -Value $installTag

        $displayName = Get-ObjectTextProperty -InputObject $runtimeObject -PropertyNames @('display-name', 'display_name', 'name', 'short-name', 'short_name')
        $version = Get-ObjectTextProperty -InputObject $runtimeObject -PropertyNames @('sort-version', 'sort_version', 'version', 'display-version', 'display_version')
        $architecture = Get-ObjectTextProperty -InputObject $runtimeObject -PropertyNames @('architecture', 'arch', 'machine', 'platform', 'target')

        if ([string]::IsNullOrWhiteSpace($version)) {
            $version = Get-ObjectTextProperty -InputObject $runtimeObject -PropertyNames @('short-version', 'short_version', 'tag')
        }

        if ([string]::IsNullOrWhiteSpace($version)) {
            $versionMatch = [System.Text.RegularExpressions.Regex]::Match($installTag, '\d+(?:\.\d+)+')
            if ($versionMatch.Success) {
                $version = $versionMatch.Value
            }
            else {
                $version = $installTag
            }
        }

        $runtimeEntries.Add([PSCustomObject]@{
                Version = $version
                Architecture = $architecture
                InstallTag = $installTag
                DisplayName = $displayName
                ManagerCommandName = $ManagerCommandName
            })
    }

    return @(ConvertTo-CanonicalPythonInstallableRuntimeEntries -Entries $runtimeEntries)
}

function Test-PythonManagerNoRuntimesResult {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]] $OutputLines,

        [string] $ErrorMessage = ''
    )

    foreach ($messageText in @(@($OutputLines) + @($ErrorMessage))) {
        $normalizedMessage = "$messageText".Trim()
        if ([string]::IsNullOrWhiteSpace($normalizedMessage)) {
            continue
        }

        if ($normalizedMessage -match '(?i)\bno runtimes\b') {
            return $true
        }
    }

    return $false
}

function Get-PythonInstallableRuntimeEntries {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $VersionRequest
    )

    $normalizedVersionRequest = if ($null -eq $VersionRequest) { '' } else { $VersionRequest.Trim() }
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('list')
    $arguments.Add('--online')
    $arguments.Add('--format=jsonl')
    $waitMessage = 'Recherche des versions Python installables'

    if (-not [string]::IsNullOrWhiteSpace($normalizedVersionRequest)) {
        $normalizedVersionRequest = Get-NormalizedPythonVersionRequest -VersionRequest $normalizedVersionRequest
        $arguments.Add($normalizedVersionRequest)
        $waitMessage = "Recherche des versions Python installables pour '$normalizedVersionRequest'"
    }

    $lookupResult = Invoke-PythonManagerCommandCapture `
        -Arguments $arguments.ToArray() `
        -WaitMessage $waitMessage

    if ($null -eq $lookupResult) {
        return [PSCustomObject]@{
            LookupAvailable = $false
            Success = $false
            NoRuntimes = $false
            Entries = @()
            CommandName = ''
            CommandPath = ''
            OutputLines = @()
            ErrorMessage = "Le gestionnaire Python 'pymanager' ou 'py' est introuvable."
        }
    }

    $entries = @(ConvertTo-PythonInstallableRuntimeEntries -OutputLines $lookupResult.OutputLines -ManagerCommandName $lookupResult.CommandName)
    $noRuntimes = (@($entries).Count -eq 0) -and (Test-PythonManagerNoRuntimesResult -OutputLines $lookupResult.OutputLines -ErrorMessage $lookupResult.ErrorMessage)

    return [PSCustomObject]@{
        LookupAvailable = $true
        Success = $lookupResult.Success
        NoRuntimes = $noRuntimes
        Entries = $entries
        CommandName = $lookupResult.CommandName
        CommandPath = $lookupResult.CommandPath
        OutputLines = $lookupResult.OutputLines
        ErrorMessage = $lookupResult.ErrorMessage
    }
}

function Get-PythonInstallableRuntimeDisplayLabel {
    param(
        [Parameter(Mandatory = $true)]
        [object] $InstallableRuntime
    )

    $managerLabel = if ([string]::IsNullOrWhiteSpace("$($InstallableRuntime.ManagerCommandName)")) {
        'pymanager'
    }
    else {
        $InstallableRuntime.ManagerCommandName
    }

    $installTag = "$($InstallableRuntime.InstallTag)".Trim()
    $version = "$($InstallableRuntime.Version)".Trim()
    $displayName = "$($InstallableRuntime.DisplayName)".Trim()

    if ([string]::IsNullOrWhiteSpace($version)) {
        $version = $installTag
    }

    if (-not [string]::IsNullOrWhiteSpace($displayName)) {
        if ($installTag.Equals($version, [System.StringComparison]::OrdinalIgnoreCase)) {
            return "$displayName [installable via $managerLabel]"
        }

        return "$displayName [$installTag, installable via $managerLabel]"
    }

    if ($version.Equals($installTag, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "$installTag [installable via $managerLabel]"
    }

    return "$version [$installTag, installable via $managerLabel]"
}

function Get-PythonInstallableRuntimeVersionForDepotFolder {
    param(
        [Parameter(Mandatory = $true)]
        [object] $InstallableRuntime
    )

    $versionCandidates = @(
        "$($InstallableRuntime.Version)",
        "$($InstallableRuntime.DisplayName)",
        "$($InstallableRuntime.InstallTag)"
    )

    foreach ($versionCandidate in $versionCandidates) {
        $versionMatch = [System.Text.RegularExpressions.Regex]::Match($versionCandidate, '\d+(?:\.\d+)+')
        if (-not $versionMatch.Success) {
            continue
        }

        $versionParts = @($versionMatch.Value.Split('.'))
        while ($versionParts.Count -lt 3) {
            $versionParts += '0'
        }

        if ($versionParts.Count -gt 3) {
            $versionParts = @($versionParts[0], $versionParts[1], $versionParts[2])
        }

        return ($versionParts -join '.')
    }

    throw "Impossible de déterminer une version exploitable pour la référence Python '$($InstallableRuntime.InstallTag)'."
}

function Get-PythonInstallableRuntimeArchitectureForDepotFolder {
    param(
        [Parameter(Mandatory = $true)]
        [object] $InstallableRuntime
    )

    $architectureCandidates = @(
        "$($InstallableRuntime.Architecture)",
        "$($InstallableRuntime.DisplayName)"
    )

    foreach ($architectureCandidate in $architectureCandidates) {
        $trimmedCandidate = $architectureCandidate.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedCandidate)) {
            continue
        }

        $parenthesizedMatch = [System.Text.RegularExpressions.Regex]::Match($trimmedCandidate, '\(([^)]+)\)')
        if ($parenthesizedMatch.Success) {
            $trimmedCandidate = $parenthesizedMatch.Groups[1].Value.Trim()
        }

        if ($trimmedCandidate -match '(?i)\b(?:32-bit|64-bit|arm64|x64|x86|amd64)\b') {
            return $matches[0]
        }
    }

    $installTag = "$($InstallableRuntime.InstallTag)".Trim()
    $tagMatch = [System.Text.RegularExpressions.Regex]::Match($installTag, '-([A-Za-z0-9][A-Za-z0-9._-]*)$')
    if ($tagMatch.Success) {
        return $tagMatch.Groups[1].Value.Trim()
    }

    return ''
}

function Get-PythonReferenceDisplayLabel {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Reference
    )

    if ($Reference.PSObject.Properties.Match('ExecutablePath').Count -gt 0) {
        return Get-PythonInterpreterDisplayLabel -Interpreter $Reference
    }

    if ($Reference.PSObject.Properties.Match('InstallTag').Count -gt 0) {
        return Get-PythonInstallableRuntimeDisplayLabel -InstallableRuntime $Reference
    }

    return "$Reference"
}

function New-PythonReferenceSelection {
    param(
        [Parameter(Mandatory = $true)]
        [object] $Reference
    )

    if ($Reference.PSObject.Properties.Match('ExecutablePath').Count -gt 0) {
        return [PSCustomObject]@{
            Mode = 'Known'
            Interpreter = $Reference
            InstallableRuntime = $null
            PythonExecutablePath = $null
        }
    }

    if ($Reference.PSObject.Properties.Match('InstallTag').Count -gt 0) {
        return [PSCustomObject]@{
            Mode = 'Installable'
            Interpreter = $null
            InstallableRuntime = $Reference
            PythonExecutablePath = $null
        }
    }

    throw 'La référence Python sélectionnée est invalide.'
}

function Get-CombinedPythonReferenceMatches {
    param(
        [AllowNull()]
        [object[]] $KnownMatches = @(),

        [AllowNull()]
        [object[]] $InstallableMatches = @()
    )

    $combinedMatches = [System.Collections.Generic.List[object]]::new()

    foreach ($knownMatch in @($KnownMatches)) {
        $combinedMatches.Add($knownMatch)
    }

    foreach ($installableMatch in @($InstallableMatches)) {
        $combinedMatches.Add($installableMatch)
    }

    return @($combinedMatches.ToArray())
}

function Get-NormalizedPythonVersionRequest {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $VersionRequest
    )

    $normalizedVersionRequest = if ($null -eq $VersionRequest) { '' } else { $VersionRequest.Trim() }

    if ([string]::IsNullOrWhiteSpace($normalizedVersionRequest)) {
        throw 'La version Python ne peut pas être vide.'
    }

    return $normalizedVersionRequest
}

function Test-PythonVersionMatchesRequest {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $VersionText,

        [Parameter(Mandatory = $true)]
        [string] $VersionRequest
    )

    $normalizedVersionText = if ($null -eq $VersionText) { '' } else { $VersionText.Trim() }
    $normalizedVersionRequest = Get-NormalizedPythonVersionRequest -VersionRequest $VersionRequest

    if ([string]::IsNullOrWhiteSpace($normalizedVersionText)) {
        return $false
    }

    if ($normalizedVersionText.Equals($normalizedVersionRequest, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $normalizedVersionText.StartsWith("$normalizedVersionRequest.", [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-PythonInterpreterMatchesByVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string] $VersionRequest,

        [AllowNull()]
        [object[]] $KnownPythonInterpreters
    )

    $interpreterEntries = @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $KnownPythonInterpreters)
    $exactMatches = [System.Collections.Generic.List[object]]::new()
    $partialMatches = [System.Collections.Generic.List[object]]::new()

    foreach ($interpreterEntry in $interpreterEntries) {
        $interpreterVersion = "$($interpreterEntry.Version)".Trim()

        if ($interpreterVersion.Equals($VersionRequest, [System.StringComparison]::OrdinalIgnoreCase)) {
            $exactMatches.Add($interpreterEntry)
            continue
        }

        if (Test-PythonVersionMatchesRequest -VersionText $interpreterVersion -VersionRequest $VersionRequest) {
            $partialMatches.Add($interpreterEntry)
        }
    }

    return [PSCustomObject]@{
        ExactMatches = @($exactMatches)
        PartialMatches = @($partialMatches)
    }
}

function Get-PythonInstallableRuntimeMatchesByVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string] $VersionRequest,

        [AllowNull()]
        [object[]] $InstallableRuntimes
    )

    $runtimeEntries = @(ConvertTo-CanonicalPythonInstallableRuntimeEntries -Entries $InstallableRuntimes)
    $exactMatches = [System.Collections.Generic.List[object]]::new()
    $partialMatches = [System.Collections.Generic.List[object]]::new()

    foreach ($runtimeEntry in $runtimeEntries) {
        $runtimeVersionsToCheck = @(
            "$($runtimeEntry.Version)".Trim(),
            "$($runtimeEntry.InstallTag)".Trim()
        )

        $hasExactMatch = $false
        foreach ($runtimeVersion in $runtimeVersionsToCheck) {
            if ([string]::IsNullOrWhiteSpace($runtimeVersion)) {
                continue
            }

            if ($runtimeVersion.Equals($VersionRequest, [System.StringComparison]::OrdinalIgnoreCase)) {
                $exactMatches.Add($runtimeEntry)
                $hasExactMatch = $true
                break
            }
        }

        if ($hasExactMatch) {
            continue
        }

        foreach ($runtimeVersion in $runtimeVersionsToCheck) {
            if (Test-PythonVersionMatchesRequest -VersionText $runtimeVersion -VersionRequest $VersionRequest) {
                $partialMatches.Add($runtimeEntry)
                break
            }
        }
    }

    return [PSCustomObject]@{
        ExactMatches = @($exactMatches)
        PartialMatches = @($partialMatches)
    }
}

function Show-PythonReferenceMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Title,

        [Parameter(Mandatory = $true)]
        [object[]] $Matches
    )

    Write-Host $Title
    for ($index = 0; $index -lt $Matches.Count; $index++) {
        Write-Host "$($index + 1). $(Get-PythonReferenceDisplayLabel -Reference $Matches[$index])"
    }
}

function Read-PythonReferenceChoice {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Matches
    )

    while ($true) {
        $answer = Read-Host 'Référence Python à utiliser (Entrée = 1, numéro ou chemin Python)'

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return New-PythonReferenceSelection -Reference $Matches[0]
        }

        $selectionIndex = 0
        if ([int]::TryParse($answer, [ref] $selectionIndex) -and $selectionIndex -ge 1 -and $selectionIndex -le $Matches.Count) {
            return New-PythonReferenceSelection -Reference $Matches[$selectionIndex - 1]
        }

        try {
            return [PSCustomObject]@{
                Mode = 'CustomPath'
                Interpreter = $null
                InstallableRuntime = $null
                PythonExecutablePath = Get-NormalizedExistingFilePath -Path $answer -Label 'Python'
            }
        }
        catch {
            Write-Host 'Saisissez un numéro valide ou le chemin complet d''un Python déjà installé.' -ForegroundColor Yellow
        }
    }
}

function Sync-ProjectPythonInterpreters {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [Parameter(Mandatory = $true)]
        [object] $ProjectConfig
    )

    $freshInterpreters = Get-AvailablePythonInterpreters -KnownPythonInterpreters $ProjectConfig.KnownPythonInterpreters

    if (-not (Test-PythonInterpreterEntryCollectionsEqual -Left $ProjectConfig.KnownPythonInterpreters -Right $freshInterpreters)) {
        return Save-ProjectConfig `
            -ConfigPath $ConfigPath `
            -ProjectsRootPath $ProjectConfig.ProjectsRootPath `
            -DefaultProjectType $ProjectConfig.DefaultProjectType `
            -DefaultCreatePythonVenv $ProjectConfig.DefaultCreatePythonVenv `
            -DefaultPythonInstallLocation $ProjectConfig.DefaultPythonInstallLocation `
            -PythonDepotPath $ProjectConfig.PythonDepotPath `
            -KnownPythonInterpreters $freshInterpreters `
            -Message 'Catalogue Python synchronisé'
    }

    $ProjectConfig.KnownPythonInterpreters = $freshInterpreters
    return $ProjectConfig
}

function Add-PythonInterpreterToProjectConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [Parameter(Mandatory = $true)]
        [object] $ProjectConfig,

        [Parameter(Mandatory = $true)]
        [object] $PythonInterpreter
    )

    $knownPythonInterpreters = [System.Collections.Generic.List[object]]::new()
    $knownPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($existingInterpreter in @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $ProjectConfig.KnownPythonInterpreters)) {
        $alreadyKnown = $false
        foreach ($knownPath in $knownPaths) {
            if ($knownPath.Equals($existingInterpreter.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)) {
                $alreadyKnown = $true
                break
            }
        }

        if (-not $alreadyKnown) {
            Add-UniqueCaseInsensitiveString -List $knownPaths -Value $existingInterpreter.ExecutablePath
            $knownPythonInterpreters.Add($existingInterpreter)
        }
    }

    $normalizedInterpreterSource = Get-NormalizedPythonInterpreterSource -Source $PythonInterpreter.Source -DefaultSource 'custom'
    $normalizedCustomInterpreter = [PSCustomObject]@{
        Source = $normalizedInterpreterSource
        Version = $PythonInterpreter.Version
        ExecutablePath = (Get-NormalizedExistingFilePath -Path $PythonInterpreter.ExecutablePath -Label 'Python')
    }

    $customInterpreterAlreadyKnown = $false
    foreach ($knownPath in $knownPaths) {
        if ($knownPath.Equals($normalizedCustomInterpreter.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            $customInterpreterAlreadyKnown = $true
            break
        }
    }

    if (-not $customInterpreterAlreadyKnown) {
        Add-UniqueCaseInsensitiveString -List $knownPaths -Value $normalizedCustomInterpreter.ExecutablePath
        $knownPythonInterpreters.Add($normalizedCustomInterpreter)
    }

    $updatedConfig = Save-ProjectConfig `
        -ConfigPath $ConfigPath `
        -ProjectsRootPath $ProjectConfig.ProjectsRootPath `
        -DefaultProjectType $ProjectConfig.DefaultProjectType `
        -DefaultCreatePythonVenv $ProjectConfig.DefaultCreatePythonVenv `
        -DefaultPythonInstallLocation $ProjectConfig.DefaultPythonInstallLocation `
        -PythonDepotPath $ProjectConfig.PythonDepotPath `
        -KnownPythonInterpreters $knownPythonInterpreters.ToArray() `
        -Message 'Python enregistré'

    return Sync-ProjectPythonInterpreters -ConfigPath $ConfigPath -ProjectConfig $updatedConfig
}

function Get-KnownPythonInterpreterByExecutablePath {
    param(
        [AllowNull()]
        [object[]] $KnownPythonInterpreters,

        [Parameter(Mandatory = $true)]
        [string] $ExecutablePath
    )

    $normalizedExecutablePath = Get-NormalizedPathCandidate -Path $ExecutablePath

    foreach ($knownInterpreter in @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $KnownPythonInterpreters)) {
        if ($knownInterpreter.ExecutablePath.Equals($normalizedExecutablePath, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $knownInterpreter
        }
    }

    return $null
}

function Show-PythonInstallableLookupFailureMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string] $VersionRequest,

        [Parameter(Mandatory = $true)]
        [bool] $HasKnownInterpreters,

        [Parameter(Mandatory = $true)]
        [object] $LookupResult
    )

    if ($LookupResult.LookupAvailable -and $LookupResult.NoRuntimes) {
        if ($HasKnownInterpreters) {
            Write-Host "Aucune référence Python connue ni installable ne correspond à '$VersionRequest'." -ForegroundColor Yellow
        }
        else {
            Write-Host "Aucune référence Python installable ne correspond à '$VersionRequest'." -ForegroundColor Yellow
        }

        return
    }

    if (-not $LookupResult.LookupAvailable) {
        if ($HasKnownInterpreters) {
            Write-Host "Aucune référence Python connue ne correspond à '$VersionRequest', et la recherche de versions installables n'est pas disponible sans 'pymanager' ou 'py'." -ForegroundColor Yellow
        }
        else {
            Write-Host "La recherche de versions Python installables n'est pas disponible sans 'pymanager' ou 'py'." -ForegroundColor Yellow
        }

        return
    }

    Write-Host "Impossible de vérifier les versions Python installables pour '$VersionRequest'." -ForegroundColor Yellow

    if (-not [string]::IsNullOrWhiteSpace($LookupResult.ErrorMessage)) {
        Write-Host $LookupResult.ErrorMessage -ForegroundColor DarkYellow
        return
    }

    foreach ($outputLine in $LookupResult.OutputLines) {
        if (-not [string]::IsNullOrWhiteSpace("$outputLine")) {
            Write-Host $outputLine -ForegroundColor DarkYellow
        }
    }
}

function Read-PythonInterpreterSelection {
    param(
        [AllowNull()]
        [object[]] $KnownPythonInterpreters
    )

    $interpreterEntries = @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $KnownPythonInterpreters)

    if ($interpreterEntries.Count -eq 0) {
        Write-Host 'Aucune version Python connue n''a été trouvée via pymanager ou la configuration.' -ForegroundColor Yellow
    }

    while ($true) {
        $versionPrompt = if ($interpreterEntries.Count -gt 0) {
            'Version Python pour le venv (exemple 3.14, Entrée = versions connues et installables)'
        }
        else {
            'Version Python pour le venv à installer (exemple 3.14), ou chemin Python'
        }

        $versionRequest = Read-Host $versionPrompt

        if ([string]::IsNullOrWhiteSpace($versionRequest)) {
            $installableLookup = Get-PythonInstallableRuntimeEntries -VersionRequest ''
            $combinedMatches = Get-CombinedPythonReferenceMatches `
                -KnownMatches $interpreterEntries `
                -InstallableMatches @($installableLookup.Entries)

            if ($combinedMatches.Count -gt 0) {
                $title = if ($interpreterEntries.Count -gt 0 -and @($installableLookup.Entries).Count -gt 0) {
                    'Versions Python connues et installables :'
                }
                elseif ($interpreterEntries.Count -gt 0) {
                    'Versions Python connues :'
                }
                else {
                    'Versions Python installables :'
                }

                Show-PythonReferenceMatches -Title $title -Matches $combinedMatches
                return Read-PythonReferenceChoice -Matches $combinedMatches
            }

            if (-not $installableLookup.LookupAvailable) {
                Write-Host "La recherche de versions Python installables n'est pas disponible sans 'pymanager' ou 'py'." -ForegroundColor Yellow
            }
            elseif ($installableLookup.NoRuntimes) {
                Write-Host 'Aucune version Python installable n''a été trouvée.' -ForegroundColor Yellow
            }
            else {
                Write-Host 'Impossible de vérifier les versions Python installables.' -ForegroundColor Yellow
            }

            Write-Host 'Saisissez une version Python à installer ou le chemin complet d''un Python déjà installé.' -ForegroundColor Yellow
            continue
        }

        if ($interpreterEntries.Count -eq 0) {
            try {
                $pythonExecutablePath = Get-NormalizedExistingFilePath -Path $versionRequest -Label 'Python'
                return [PSCustomObject]@{
                    Mode = 'CustomPath'
                    Interpreter = $null
                    InstallableRuntime = $null
                    PythonExecutablePath = $pythonExecutablePath
                }
            }
            catch {
            }
        }

        $normalizedVersionRequest = Get-NormalizedPythonVersionRequest -VersionRequest $versionRequest

        if ($interpreterEntries.Count -gt 0) {
            $matches = Get-PythonInterpreterMatchesByVersion -VersionRequest $normalizedVersionRequest -KnownPythonInterpreters $interpreterEntries

            if ($matches.ExactMatches.Count -gt 0) {
                Show-PythonReferenceMatches -Title "Références Python exactes pour '$normalizedVersionRequest' :" -Matches $matches.ExactMatches
                return Read-PythonReferenceChoice -Matches $matches.ExactMatches
            }

            $installableLookup = Get-PythonInstallableRuntimeEntries -VersionRequest $normalizedVersionRequest
            $installableMatches = Get-PythonInstallableRuntimeMatchesByVersion `
                -VersionRequest $normalizedVersionRequest `
                -InstallableRuntimes @($installableLookup.Entries)

            if ($installableMatches.ExactMatches.Count -gt 0) {
                Show-PythonReferenceMatches -Title "Références Python exactes et installables pour '$normalizedVersionRequest' :" -Matches @($installableMatches.ExactMatches)
                return Read-PythonReferenceChoice -Matches @($installableMatches.ExactMatches)
            }

            if ($matches.PartialMatches.Count -gt 0) {
                $combinedMatches = Get-CombinedPythonReferenceMatches `
                    -KnownMatches $matches.PartialMatches `
                    -InstallableMatches @($installableMatches.PartialMatches)

                if ($combinedMatches.Count -gt $matches.PartialMatches.Count) {
                    Show-PythonReferenceMatches -Title "Références Python compatibles et installables pour '$normalizedVersionRequest' :" -Matches $combinedMatches
                    return Read-PythonReferenceChoice -Matches $combinedMatches
                }

                Show-PythonReferenceMatches -Title "Références Python compatibles pour '$normalizedVersionRequest' :" -Matches $matches.PartialMatches
                return Read-PythonReferenceChoice -Matches $matches.PartialMatches
            }
        }

        $installableLookup = Get-PythonInstallableRuntimeEntries -VersionRequest $normalizedVersionRequest
        $installableMatches = Get-PythonInstallableRuntimeMatchesByVersion `
            -VersionRequest $normalizedVersionRequest `
            -InstallableRuntimes @($installableLookup.Entries)
        $matchingInstallableEntries = @($installableMatches.ExactMatches + $installableMatches.PartialMatches)

        if ($matchingInstallableEntries.Count -gt 0) {
            Show-PythonReferenceMatches -Title "Références Python installables pour '$normalizedVersionRequest' :" -Matches $matchingInstallableEntries
            return Read-PythonReferenceChoice -Matches $matchingInstallableEntries
        }

        Show-PythonInstallableLookupFailureMessage `
            -VersionRequest $normalizedVersionRequest `
            -HasKnownInterpreters ($interpreterEntries.Count -gt 0) `
            -LookupResult $installableLookup

        $answer = Read-Host 'Chemin complet d''un autre Python installé, ou Entrée pour saisir une autre version'

        if ([string]::IsNullOrWhiteSpace($answer)) {
            continue
        }

        try {
            $pythonExecutablePath = Get-NormalizedExistingFilePath -Path $answer -Label 'Python'
            $customSelection = [PSCustomObject]@{
                Mode = 'CustomPath'
                Interpreter = $null
                InstallableRuntime = $null
                PythonExecutablePath = $pythonExecutablePath
            }

            return $customSelection
        }
        catch {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
        }
    }
}

function Get-PythonManagerInterpreterEntryForInstallTag {
    param(
        [Parameter(Mandatory = $true)]
        [string] $InstallTag
    )

    $result = Invoke-PythonManagerCommandCapture -Arguments @('list', '--one', '--format=exe', $InstallTag)

    if ($null -eq $result) {
        throw "Le gestionnaire Python 'pymanager' ou 'py' est introuvable."
    }

    if (-not $result.Success) {
        if (-not [string]::IsNullOrWhiteSpace($result.ErrorMessage)) {
            throw "Impossible de retrouver le Python installé pour '$InstallTag' : $($result.ErrorMessage)"
        }

        throw "Impossible de retrouver le Python installé pour '$InstallTag'."
    }

    $executablePaths = Convert-LegacyPyListLinesToExecutablePaths -OutputLines $result.OutputLines
    foreach ($executablePath in $executablePaths) {
        try {
            return New-PythonInterpreterEntry -ExecutablePath $executablePath -Source 'pymanager'
        }
        catch {
            continue
        }
    }

    throw "Impossible de retrouver le Python installé pour '$InstallTag'."
}

function Get-SanitizedPythonDepotRuntimeFolderName {
    param(
        [Parameter(Mandatory = $true)]
        [object] $InstallableRuntime
    )

    $versionText = Get-PythonInstallableRuntimeVersionForDepotFolder -InstallableRuntime $InstallableRuntime
    $architectureText = Get-PythonInstallableRuntimeArchitectureForDepotFolder -InstallableRuntime $InstallableRuntime
    $folderName = "Python $versionText"

    if (-not [string]::IsNullOrWhiteSpace($architectureText)) {
        $folderName = "$folderName-$architectureText"
    }

    foreach ($invalidCharacter in [System.IO.Path]::GetInvalidFileNameChars()) {
        $folderName = $folderName.Replace([string] $invalidCharacter, '_')
    }

    if ([string]::IsNullOrWhiteSpace($folderName)) {
        throw "La référence Python '$($InstallableRuntime.InstallTag)' ne peut pas être convertie en nom de dossier."
    }

    return $folderName
}

function Get-PythonDepotRuntimePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PythonDepotPath,

        [Parameter(Mandatory = $true)]
        [object] $InstallableRuntime
    )

    $normalizedPythonDepotPath = Get-NormalizedPath -Path $PythonDepotPath
    $runtimeFolderName = Get-SanitizedPythonDepotRuntimeFolderName -InstallableRuntime $InstallableRuntime
    return Join-Path -Path $normalizedPythonDepotPath -ChildPath $runtimeFolderName
}

function Get-PythonExecutablePathFromDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string] $DirectoryPath
    )

    $normalizedDirectoryPath = Get-NormalizedPath -Path $DirectoryPath

    foreach ($candidateFileName in @('python.exe', 'python.cmd', 'python.bat')) {
        $candidatePath = Join-Path -Path $normalizedDirectoryPath -ChildPath $candidateFileName
        if (Test-Path -LiteralPath $candidatePath) {
            return Get-NormalizedExistingFilePath -Path $candidatePath -Label 'Python'
        }
    }

    throw "Aucun exécutable Python n'a été trouvé dans '$normalizedDirectoryPath'."
}

function Install-PythonRuntime {
    param(
        [Parameter(Mandatory = $true)]
        [object] $InstallableRuntime,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $PythonDepotPath = $null
    )

    $installTag = "$($InstallableRuntime.InstallTag)".Trim()
    if ([string]::IsNullOrWhiteSpace($installTag)) {
        throw 'La référence Python installable est invalide.'
    }

    $command = Get-PreferredPythonManagerCommand
    if ($null -eq $command) {
        throw "Le gestionnaire Python 'pymanager' ou 'py' est introuvable."
    }

    $usePythonDepot = -not [string]::IsNullOrWhiteSpace("$PythonDepotPath")
    Write-Host "Python installable sélectionné : $(Get-PythonInstallableRuntimeDisplayLabel -InstallableRuntime $InstallableRuntime)" -ForegroundColor Cyan
    if ($usePythonDepot) {
        $runtimeInstallPath = Get-PythonDepotRuntimePath -PythonDepotPath $PythonDepotPath -InstallableRuntime $InstallableRuntime
        $existingPythonExecutablePath = $null

        try {
            $existingPythonExecutablePath = Get-PythonExecutablePathFromDirectory -DirectoryPath $runtimeInstallPath
        }
        catch {
        }

        if (-not [string]::IsNullOrWhiteSpace("$existingPythonExecutablePath")) {
            Write-Host "Python du dépôt déjà disponible : $runtimeInstallPath" -ForegroundColor Yellow
            return New-PythonInterpreterEntry -ExecutablePath $existingPythonExecutablePath -Source 'depot'
        }

        Ensure-DirectoryExists -Path $PythonDepotPath -Label 'Dépôt Python'
        Write-Host "Dépôt Python dédié aux venv : $PythonDepotPath" -ForegroundColor Cyan
        Write-Host "Commande exécutée : $($command.CommandName) install --target=$runtimeInstallPath $installTag" -ForegroundColor DarkCyan
        $result = Invoke-PythonManagerCommandCapture -Arguments @('install', "--target=$runtimeInstallPath", $installTag) -WaitMessage "Installation de Python $installTag dans le dépôt en cours"
    }
    else {
        Write-Host "Commande exécutée : $($command.CommandName) install $installTag" -ForegroundColor DarkCyan
        $result = Invoke-PythonManagerCommandCapture -Arguments @('install', $installTag) -WaitMessage "Installation de Python $installTag en cours"
    }

    if ($null -eq $result) {
        throw "Le gestionnaire Python 'pymanager' ou 'py' est introuvable."
    }

    foreach ($outputLine in $result.OutputLines) {
        Write-Host $outputLine
    }

    if (-not $result.Success) {
        if (-not [string]::IsNullOrWhiteSpace($result.ErrorMessage)) {
            throw "Impossible d'installer la référence Python '$installTag' : $($result.ErrorMessage)"
        }

        throw "Impossible d'installer la référence Python '$installTag'."
    }

    if ($usePythonDepot) {
        $runtimePythonExecutablePath = Get-PythonExecutablePathFromDirectory -DirectoryPath $runtimeInstallPath
        return New-PythonInterpreterEntry -ExecutablePath $runtimePythonExecutablePath -Source 'depot'
    }

    return Get-PythonManagerInterpreterEntryForInstallTag -InstallTag $installTag
}

function Select-PythonInterpreterForVenv {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [Parameter(Mandatory = $true)]
        [object] $ProjectConfig
    )

    $selection = Read-PythonInterpreterSelection -KnownPythonInterpreters $ProjectConfig.KnownPythonInterpreters

    if ($selection.Mode -eq 'Known') {
        return [PSCustomObject]@{
            ProjectConfig = $ProjectConfig
            Interpreter = $selection.Interpreter
        }
    }

    if ($selection.Mode -eq 'Installable') {
        $installLocation = Read-PythonInstallLocationChoice `
            -PythonDepotPath $ProjectConfig.PythonDepotPath `
            -DefaultPythonInstallLocation $ProjectConfig.DefaultPythonInstallLocation
        $selectedPythonDepotPath = if ($installLocation -eq 'Depot') { $ProjectConfig.PythonDepotPath } else { $null }
        $installedInterpreter = Install-PythonRuntime `
            -InstallableRuntime $selection.InstallableRuntime `
            -PythonDepotPath $selectedPythonDepotPath

        if ($installedInterpreter.Source -eq 'depot') {
            $updatedConfig = Add-PythonInterpreterToProjectConfig -ConfigPath $ConfigPath -ProjectConfig $ProjectConfig -PythonInterpreter $installedInterpreter
        }
        else {
            Write-StepInfo 'Synchronisation du catalogue Python après installation...'
            $updatedConfig = Sync-ProjectPythonInterpreters -ConfigPath $ConfigPath -ProjectConfig $ProjectConfig
        }

        $selectedInterpreter = Get-KnownPythonInterpreterByExecutablePath `
            -KnownPythonInterpreters $updatedConfig.KnownPythonInterpreters `
            -ExecutablePath $installedInterpreter.ExecutablePath

        if ($null -eq $selectedInterpreter) {
            $selectedInterpreter = $installedInterpreter
        }

        return [PSCustomObject]@{
            ProjectConfig = $updatedConfig
            Interpreter = $selectedInterpreter
        }
    }

    Write-StepInfo "Lecture de la version du Python personnalisé : $($selection.PythonExecutablePath)"
    $customInterpreter = New-PythonInterpreterEntry -ExecutablePath $selection.PythonExecutablePath -Source 'custom'
    $updatedConfig = Add-PythonInterpreterToProjectConfig -ConfigPath $ConfigPath -ProjectConfig $ProjectConfig -PythonInterpreter $customInterpreter
    $selectedInterpreter = Get-KnownPythonInterpreterByExecutablePath `
        -KnownPythonInterpreters $updatedConfig.KnownPythonInterpreters `
        -ExecutablePath $customInterpreter.ExecutablePath

    if ($null -eq $selectedInterpreter) {
        $selectedInterpreter = $customInterpreter
    }

    return [PSCustomObject]@{
        ProjectConfig = $updatedConfig
        Interpreter = $selectedInterpreter
    }
}

function New-PythonVirtualEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [object] $PythonInterpreter
    )

    $venvPath = Join-Path -Path $ProjectPath -ChildPath '.venv'

    if (Test-Path -LiteralPath $venvPath) {
        $item = Get-Item -LiteralPath $venvPath

        if (-not $item.PSIsContainer) {
            throw "Le chemin '$venvPath' existe déjà, mais ce n'est pas un dossier."
        }

        Write-Host "L'environnement virtuel existe déjà : $venvPath" -ForegroundColor Yellow
        return $venvPath
    }

    Write-Host "Python sélectionné pour le venv : $(Get-PythonInterpreterDisplayLabel -Interpreter $PythonInterpreter)" -ForegroundColor Cyan
    Write-Host "Création de l'environnement virtuel Python : $venvPath" -ForegroundColor Cyan
    Write-Host "Commande exécutée : $($PythonInterpreter.ExecutablePath) -m venv $venvPath" -ForegroundColor DarkCyan

    $result = Invoke-ExternalExecutableCapture `
        -ExecutablePath $PythonInterpreter.ExecutablePath `
        -Arguments @('-m', 'venv', $venvPath) `
        -WaitMessage 'Création du venv en cours'

    foreach ($outputLine in $result.OutputLines) {
        Write-Host $outputLine
    }

    if (-not $result.Success) {
        if (-not [string]::IsNullOrWhiteSpace($result.ErrorMessage)) {
            throw "Impossible de créer l'environnement virtuel Python dans '$venvPath' : $($result.ErrorMessage)"
        }

        throw "Impossible de créer l'environnement virtuel Python dans '$venvPath'."
    }

    Write-Host "Environnement virtuel créé : $venvPath" -ForegroundColor Green
    return $venvPath
}

$scriptFailure = $null
Set-Utf8ConsoleEncoding

try {
    $projectConfig = Get-ProjectConfig -ConfigPath $ConfigPath -ConfigFileName $ConfigFileName
    $projectConfig = Ensure-PythonDepotPathConfiguration -ConfigPath $ConfigPath -ProjectConfig $projectConfig

    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        $ProjectName = Read-ProjectName
    }

    $projectTarget = Resolve-ProjectTarget -ProjectsRootPath $projectConfig.ProjectsRootPath -ProjectName $ProjectName

    if (-not $projectTarget.Cancelled) {
        $ProjectName = $projectTarget.ProjectName
        $projectTypeSelection = Resolve-ProjectTypeSelection `
            -ProjectType $ProjectType `
            -DefaultProjectType $projectConfig.DefaultProjectType `
            -CustomProjectType $CustomProjectType
        $ProjectType = $projectTypeSelection.NormalizedProjectType

        $projectPath = New-ProjectDirectory `
            -ProjectsRootPath $projectConfig.ProjectsRootPath `
            -ProjectName $ProjectName `
            -ProjectTypeLabel $projectTypeSelection.ProjectTypeLabel

        New-ProjectGitIgnoreFile `
            -ProjectPath $projectPath `
            -ProjectType $ProjectType | Out-Null

        if ($ProjectType -eq 'py') {
            $createPythonVenv = $false
            $createPythonVenv = Read-CreatePythonVenv -DefaultCreatePythonVenv $projectConfig.DefaultCreatePythonVenv

            if ($createPythonVenv) {
                Write-StepInfo 'Recherche des versions Python connues...'
                $projectConfig = Sync-ProjectPythonInterpreters -ConfigPath $ConfigPath -ProjectConfig $projectConfig
                $pythonSelection = Select-PythonInterpreterForVenv -ConfigPath $ConfigPath -ProjectConfig $projectConfig
                $projectConfig = $pythonSelection.ProjectConfig
                New-PythonVirtualEnvironment -ProjectPath $projectPath -PythonInterpreter $pythonSelection.Interpreter | Out-Null
            }

            New-PythonProjectReadme `
                -ProjectPath $projectPath `
                -ProjectName $ProjectName `
                -HasVirtualEnvironment $createPythonVenv | Out-Null

            New-PythonProjectPyprojectFile `
                -ProjectPath $projectPath `
                -ProjectName $ProjectName | Out-Null

            New-PythonProjectRequirementsFile -ProjectPath $projectPath | Out-Null
            New-PythonProjectCmdVenvLauncher `
                -ProjectPath $projectPath `
                -ProjectName $ProjectName | Out-Null
        }
    }
}
catch {
    $scriptFailure = $_
    Write-Host "Erreur : $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if (-not $NoPause) {
        Read-Host 'Appuyez sur Entrée pour fermer la fenêtre' | Out-Null
    }

    Restore-ConsoleEncoding
}

if ($null -ne $scriptFailure) {
    throw $scriptFailure
}
