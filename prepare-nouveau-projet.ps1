[CmdletBinding()]
param(
    [string] $ProjectName,
    [string] $ProjectType,
    [string] $CustomProjectType,
    [switch] $NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = [Version] '1.16.0'
$CurrentConfigVersion = 13
$LegacyConfigVersion = 1
$ConfigFileName = 'prepare-nouveau-projet.config.json'
$ConfigDisabledSuffix = 'desactive'
$KnownProjectTypes = @('cmd', 'bat', 'ps1', 'py', 'django', 'autre')
$KnownProjectTypesDisplay = $KnownProjectTypes -join ', '
$FallbackProjectType = 'django'
$FallbackCreatePythonVenv = $true
$FallbackPythonInstallLocation = 'depot'
$FallbackAskInstallGitHubCliWhenMissing = $true
$FallbackAskInstallPythonManagerWhenMissing = $true
$FallbackGitHubRepositoryVisibility = 'private'
$FallbackDjangoLanguageCode = 'fr-fr'
$FallbackDjangoTimeZone = 'Europe/Paris'
$PythonDepotFolderName = 'Python'
$ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath $ConfigFileName
$script:OriginalConsoleInputEncoding = $null
$script:OriginalConsoleOutputEncoding = $null
$script:OriginalCommandOutputEncoding = $null
$script:OriginalConsoleCodePage = $null
$script:OriginalLocation = $null

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

function Get-TextWithoutDiacritics {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Text
    )

    $normalizedText = $Text.Normalize([Text.NormalizationForm]::FormD)
    $builder = [System.Text.StringBuilder]::new()

    foreach ($character in $normalizedText.ToCharArray()) {
        $unicodeCategory = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ($unicodeCategory -eq [Globalization.UnicodeCategory]::NonSpacingMark) {
            continue
        }

        [void] $builder.Append($character)
    }

    return $builder.ToString().Normalize([Text.NormalizationForm]::FormC)
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

function Test-PythonBasedProjectType {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ProjectType
    )

    $normalizedProjectType = if ($null -eq $ProjectType) { '' } else { $ProjectType.Trim().ToLowerInvariant() }
    return ($normalizedProjectType -in @('py', 'django'))
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

function Get-NormalizedGitHubRepositoryVisibilitySetting {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $Visibility,

        [switch] $AllowDefault,

        [string] $DefaultVisibility = $FallbackGitHubRepositoryVisibility
    )

    $normalizedDefaultVisibility = if ([string]::IsNullOrWhiteSpace($DefaultVisibility)) {
        $FallbackGitHubRepositoryVisibility
    }
    else {
        $DefaultVisibility.Trim().ToLowerInvariant()
    }

    if ($normalizedDefaultVisibility -notin @('private', 'public')) {
        throw "La visibilité GitHub par défaut '$DefaultVisibility' est invalide."
    }

    $visibilityText = if ($null -eq $Visibility) { '' } else { $Visibility.Trim() }

    if ([string]::IsNullOrWhiteSpace($visibilityText)) {
        if ($AllowDefault) {
            return $normalizedDefaultVisibility
        }

        throw 'La visibilité GitHub ne peut pas être vide.'
    }

    switch -Regex ($visibilityText.ToLowerInvariant()) {
        '^(1|prive|privé|private)$' { return 'private' }
        '^(2|public|publique)$' { return 'public' }
        default {
            throw "La visibilité GitHub '$Visibility' est invalide."
        }
    }
}

function Get-NormalizedDjangoLanguageCodeSetting {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $LanguageCode,

        [string] $DefaultLanguageCode = $FallbackDjangoLanguageCode
    )

    $normalizedLanguageCode = if ([string]::IsNullOrWhiteSpace($LanguageCode)) {
        $DefaultLanguageCode
    }
    else {
        $LanguageCode.Trim().ToLowerInvariant()
    }

    if ([string]::IsNullOrWhiteSpace($normalizedLanguageCode)) {
        throw 'Le paramètre DefaultDjangoLanguageCode ne peut pas être vide.'
    }

    return $normalizedLanguageCode
}

function Get-NormalizedDjangoTimeZoneSetting {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $TimeZone,

        [string] $DefaultTimeZone = $FallbackDjangoTimeZone
    )

    $normalizedTimeZone = if ([string]::IsNullOrWhiteSpace($TimeZone)) {
        $DefaultTimeZone
    }
    else {
        $TimeZone.Trim()
    }

    if ([string]::IsNullOrWhiteSpace($normalizedTimeZone)) {
        throw 'Le paramètre DefaultDjangoTimeZone ne peut pas être vide.'
    }

    return $normalizedTimeZone
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

function Get-DetectedExistingProjectType {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    if (Test-PythonProjectPath -ProjectPath $ProjectPath) {
        $managePyPath = Join-Path -Path $ProjectPath -ChildPath 'manage.py'
        if (Test-Path -LiteralPath $managePyPath) {
            return 'django'
        }

        $pyprojectPath = Join-Path -Path $ProjectPath -ChildPath 'pyproject.toml'
        if (Test-Path -LiteralPath $pyprojectPath) {
            $pyprojectContent = [System.IO.File]::ReadAllText($pyprojectPath, [System.Text.Encoding]::UTF8)
            if ($pyprojectContent -match '(?im)^\s*dependencies\s*=\s*\[[\s\S]*"django(?:==[^"]+)?"') {
                return 'django'
            }
        }

        foreach ($requirementsFile in @(Get-PythonProjectDatedRequirementsFiles -ProjectPath $ProjectPath)) {
            $requirementsContent = [System.IO.File]::ReadAllText($requirementsFile.FullName, [System.Text.Encoding]::UTF8)
            if ($requirementsContent -match '(?im)^\s*django(?:==[^\s#]+)?\s*$') {
                return 'django'
            }
        }

        return 'py'
    }

    if ((Get-ChildItem -LiteralPath $ProjectPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        return 'ps1'
    }

    if ((Get-ChildItem -LiteralPath $ProjectPath -Filter '*.cmd' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        return 'cmd'
    }

    if ((Get-ChildItem -LiteralPath $ProjectPath -Filter '*.bat' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        return 'bat'
    }

    return $FallbackProjectType
}

function Read-ConfirmedDetectedProjectType {
    param(
        [Parameter(Mandatory = $true)]
        [string] $DetectedProjectType
    )

    Write-Host "Type de projet détecté pour la mise à jour : $DetectedProjectType" -ForegroundColor Cyan
    return Read-ProjectType -DefaultProjectType $DetectedProjectType
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
    Write-Host '1. Mettre à jour le projet existant'
    Write-Host '2. Changer le nom'
    Write-Host '3. Fermer sans rien faire'

    while ($true) {
        $answer = (Read-Host 'Choix (1/2/3)').Trim()

        switch -Regex ($answer) {
            '^(1|m|maj|mettre-a-jour|mettre à jour|update)$' { return 'Update' }
            '^(2|c|changer)$' { return 'Rename' }
            '^(3|f|fermer)$' { return 'Cancel' }
            default {
                Write-Host 'Choisissez 1 pour mettre à jour, 2 pour changer le nom ou 3 pour fermer.' -ForegroundColor Yellow
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

function Read-GitHubRepositoryVisibilityChoice {
    param(
        [Parameter(Mandatory = $true)]
        [string] $DefaultGitHubRepositoryVisibility
    )

    $normalizedDefaultVisibility = Get-NormalizedGitHubRepositoryVisibilitySetting `
        -Visibility $DefaultGitHubRepositoryVisibility `
        -AllowDefault `
        -DefaultVisibility $FallbackGitHubRepositoryVisibility
    $defaultChoiceLabel = if ($normalizedDefaultVisibility -eq 'private') { '1' } else { '2' }

    Write-Host 'Créer le dépôt GitHub :'
    Write-Host '1. Privé'
    Write-Host '2. Public'
    Write-Host '3. Ne pas créer de dépôt GitHub'

    while ($true) {
        $answer = (Read-Host "Visibilité du dépôt GitHub (Entrée = $defaultChoiceLabel)").Trim()

        if ($answer -match '^(3|n|non|skip|ignorer)$') {
            return 'skip'
        }

        try {
            return Get-NormalizedGitHubRepositoryVisibilitySetting `
                -Visibility $answer `
                -AllowDefault `
                -DefaultVisibility $normalizedDefaultVisibility
        }
        catch {
            Write-Host "Choisissez 1 pour privé, 2 pour public ou 3 pour ne pas créer de dépôt GitHub. Entrée = $defaultChoiceLabel." -ForegroundColor Yellow
        }
    }
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

function Get-NormalizedAskInstallGitHubCliWhenMissingFromConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RawConfig,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [AllowNull()]
        [System.Collections.Generic.List[string]] $SyncReasons = [System.Collections.Generic.List[string]]::new()
    )

    if (-not (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'AskInstallGitHubCliWhenMissing')) {
        $SyncReasons.Add("Le paramètre AskInstallGitHubCliWhenMissing de '$ConfigPath' a été ajouté avec la valeur '$FallbackAskInstallGitHubCliWhenMissing'.")
        return $FallbackAskInstallGitHubCliWhenMissing
    }

    try {
        $askInstallGitHubCliWhenMissing = Get-NormalizedBooleanSetting `
            -Value $RawConfig.AskInstallGitHubCliWhenMissing `
            -SettingName "Le paramètre AskInstallGitHubCliWhenMissing de '$ConfigPath'"

        if (-not ($RawConfig.AskInstallGitHubCliWhenMissing -is [bool])) {
            $SyncReasons.Add("Le paramètre AskInstallGitHubCliWhenMissing de '$ConfigPath' a été normalisé en '$askInstallGitHubCliWhenMissing'.")
        }

        return $askInstallGitHubCliWhenMissing
    }
    catch {
        $SyncReasons.Add("Le paramètre AskInstallGitHubCliWhenMissing de '$ConfigPath' est invalide. Il a été remplacé par '$FallbackAskInstallGitHubCliWhenMissing'.")
        return $FallbackAskInstallGitHubCliWhenMissing
    }
}

function Get-NormalizedAskInstallPythonManagerWhenMissingFromConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RawConfig,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [AllowNull()]
        [System.Collections.Generic.List[string]] $SyncReasons = [System.Collections.Generic.List[string]]::new()
    )

    if (-not (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'AskInstallPythonManagerWhenMissing')) {
        $SyncReasons.Add("Le paramètre AskInstallPythonManagerWhenMissing de '$ConfigPath' a été ajouté avec la valeur '$FallbackAskInstallPythonManagerWhenMissing'.")
        return $FallbackAskInstallPythonManagerWhenMissing
    }

    try {
        $askInstallPythonManagerWhenMissing = Get-NormalizedBooleanSetting `
            -Value $RawConfig.AskInstallPythonManagerWhenMissing `
            -SettingName "Le paramètre AskInstallPythonManagerWhenMissing de '$ConfigPath'"

        if (-not ($RawConfig.AskInstallPythonManagerWhenMissing -is [bool])) {
            $SyncReasons.Add("Le paramètre AskInstallPythonManagerWhenMissing de '$ConfigPath' a été normalisé en '$askInstallPythonManagerWhenMissing'.")
        }

        return $askInstallPythonManagerWhenMissing
    }
    catch {
        $SyncReasons.Add("Le paramètre AskInstallPythonManagerWhenMissing de '$ConfigPath' est invalide. Il a été remplacé par '$FallbackAskInstallPythonManagerWhenMissing'.")
        return $FallbackAskInstallPythonManagerWhenMissing
    }
}

function Get-NormalizedDefaultGitHubRepositoryVisibilityFromConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RawConfig,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [AllowNull()]
        [System.Collections.Generic.List[string]] $SyncReasons = [System.Collections.Generic.List[string]]::new()
    )

    if (-not (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'DefaultGitHubRepositoryVisibility')) {
        $SyncReasons.Add("Le paramètre DefaultGitHubRepositoryVisibility de '$ConfigPath' a été ajouté avec la valeur '$FallbackGitHubRepositoryVisibility'.")
        return $FallbackGitHubRepositoryVisibility
    }

    try {
        $defaultGitHubRepositoryVisibility = Get-NormalizedGitHubRepositoryVisibilitySetting `
            -Visibility $RawConfig.DefaultGitHubRepositoryVisibility `
            -AllowDefault `
            -DefaultVisibility $FallbackGitHubRepositoryVisibility

        if ("$($RawConfig.DefaultGitHubRepositoryVisibility)".Trim().ToLowerInvariant() -cne $defaultGitHubRepositoryVisibility) {
            $SyncReasons.Add("Le paramètre DefaultGitHubRepositoryVisibility de '$ConfigPath' a été normalisé en '$defaultGitHubRepositoryVisibility'.")
        }

        return $defaultGitHubRepositoryVisibility
    }
    catch {
        $SyncReasons.Add("Le paramètre DefaultGitHubRepositoryVisibility de '$ConfigPath' est invalide. Il a été remplacé par '$FallbackGitHubRepositoryVisibility'.")
        return $FallbackGitHubRepositoryVisibility
    }
}

function Get-NormalizedGitHubLoginFromConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RawConfig,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [AllowNull()]
        [System.Collections.Generic.List[string]] $SyncReasons = [System.Collections.Generic.List[string]]::new()
    )

    if (-not (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'GitHubLogin')) {
        $SyncReasons.Add("Le paramètre GitHubLogin de '$ConfigPath' a été ajouté.")
        return $null
    }

    $gitHubLoginText = "$($RawConfig.GitHubLogin)".Trim()
    if ([string]::IsNullOrWhiteSpace($gitHubLoginText)) {
        return $null
    }

    $normalizedGitHubLogin = $gitHubLoginText.ToLowerInvariant()
    if ($gitHubLoginText -cne $normalizedGitHubLogin) {
        $SyncReasons.Add("Le paramètre GitHubLogin de '$ConfigPath' a été normalisé en '$normalizedGitHubLogin'.")
    }

    return $normalizedGitHubLogin
}

function Get-NormalizedDefaultDjangoLanguageCodeFromConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RawConfig,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [AllowNull()]
        [System.Collections.Generic.List[string]] $SyncReasons = [System.Collections.Generic.List[string]]::new()
    )

    if (-not (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'DefaultDjangoLanguageCode')) {
        $SyncReasons.Add("Le paramètre DefaultDjangoLanguageCode de '$ConfigPath' a été ajouté avec la valeur '$FallbackDjangoLanguageCode'.")
        return $FallbackDjangoLanguageCode
    }

    try {
        $defaultDjangoLanguageCode = Get-NormalizedDjangoLanguageCodeSetting -LanguageCode $RawConfig.DefaultDjangoLanguageCode -DefaultLanguageCode $FallbackDjangoLanguageCode
        if ("$($RawConfig.DefaultDjangoLanguageCode)".Trim() -cne $defaultDjangoLanguageCode) {
            $SyncReasons.Add("Le paramètre DefaultDjangoLanguageCode de '$ConfigPath' a été normalisé en '$defaultDjangoLanguageCode'.")
        }

        return $defaultDjangoLanguageCode
    }
    catch {
        $SyncReasons.Add("Le paramètre DefaultDjangoLanguageCode de '$ConfigPath' est invalide. Il a été remplacé par '$FallbackDjangoLanguageCode'.")
        return $FallbackDjangoLanguageCode
    }
}

function Get-NormalizedDefaultDjangoTimeZoneFromConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object] $RawConfig,

        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [AllowNull()]
        [System.Collections.Generic.List[string]] $SyncReasons = [System.Collections.Generic.List[string]]::new()
    )

    if (-not (Test-ConfigPropertyExists -Config $RawConfig -PropertyName 'DefaultDjangoTimeZone')) {
        $SyncReasons.Add("Le paramètre DefaultDjangoTimeZone de '$ConfigPath' a été ajouté avec la valeur '$FallbackDjangoTimeZone'.")
        return $FallbackDjangoTimeZone
    }

    try {
        $defaultDjangoTimeZone = Get-NormalizedDjangoTimeZoneSetting -TimeZone $RawConfig.DefaultDjangoTimeZone -DefaultTimeZone $FallbackDjangoTimeZone
        if ("$($RawConfig.DefaultDjangoTimeZone)".Trim() -cne $defaultDjangoTimeZone) {
            $SyncReasons.Add("Le paramètre DefaultDjangoTimeZone de '$ConfigPath' a été normalisé en '$defaultDjangoTimeZone'.")
        }

        return $defaultDjangoTimeZone
    }
    catch {
        $SyncReasons.Add("Le paramètre DefaultDjangoTimeZone de '$ConfigPath' est invalide. Il a été remplacé par '$FallbackDjangoTimeZone'.")
        return $FallbackDjangoTimeZone
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

        [Parameter(Mandatory = $true)]
        [bool] $AskInstallGitHubCliWhenMissing,

        [Parameter(Mandatory = $true)]
        [bool] $AskInstallPythonManagerWhenMissing,

        [Parameter(Mandatory = $true)]
        [string] $DefaultGitHubRepositoryVisibility,

        [Parameter(Mandatory = $true)]
        [string] $DefaultDjangoLanguageCode,

        [Parameter(Mandatory = $true)]
        [string] $DefaultDjangoTimeZone,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $GitHubLogin,

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
        AskInstallGitHubCliWhenMissing = $AskInstallGitHubCliWhenMissing
        AskInstallPythonManagerWhenMissing = $AskInstallPythonManagerWhenMissing
        DefaultGitHubRepositoryVisibility = $DefaultGitHubRepositoryVisibility
        DefaultDjangoLanguageCode = $DefaultDjangoLanguageCode
        DefaultDjangoTimeZone = $DefaultDjangoTimeZone
        GitHubLogin = $GitHubLogin
        PythonDepotPath = $PythonDepotPath
        KnownPythonInterpreters = @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $KnownPythonInterpreters)
    }
}

function Add-JsonPropertyWithComments {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[string]] $Lines,

        [Parameter(Mandatory = $true)]
        [string] $PropertyName,

        [AllowNull()]
        [string[]] $Comments = @(),

        [AllowNull()]
        [object] $Value,

        [Parameter(Mandatory = $true)]
        [bool] $IsLast
    )

    foreach ($comment in @($Comments)) {
        if (-not [string]::IsNullOrWhiteSpace("$comment")) {
            $Lines.Add("  // $comment")
        }
    }

    $jsonText = $Value | ConvertTo-Json -Depth 6
    if ([string]::IsNullOrWhiteSpace("$jsonText")) {
        $jsonText = '[]'
    }

    $jsonValueLines = @($jsonText -split "`r?`n")
    if ($jsonValueLines.Count -le 1) {
        $propertyLine = "  ""$PropertyName"": $($jsonValueLines[0])"
        if (-not $IsLast) {
            $propertyLine += ','
        }

        $Lines.Add($propertyLine)
        return
    }

    $Lines.Add("  ""$PropertyName"": $($jsonValueLines[0])")

    for ($index = 1; $index -lt $jsonValueLines.Count; $index++) {
        $line = "  $($jsonValueLines[$index])"
        if ($index -eq ($jsonValueLines.Count - 1) -and -not $IsLast) {
            $line += ','
        }

        $Lines.Add($line)
    }
}

function Get-ProjectConfigText {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable] $ConfigData
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('{')

    $propertyDefinitions = @(
        [PSCustomObject]@{
            Name = 'ConfigVersion'
            Comments = @('Version du format de configuration utilisée par le script.')
            Value = $ConfigData.ConfigVersion
        },
        [PSCustomObject]@{
            Name = 'ScriptVersion'
            Comments = @('Version du script qui a enregistré cette configuration.')
            Value = $ConfigData.ScriptVersion
        },
        [PSCustomObject]@{
            Name = 'ProjectsRootPath'
            Comments = @('Chemin du dossier racine où créer les projets.')
            Value = $ConfigData.ProjectsRootPath
        },
        [PSCustomObject]@{
            Name = 'DefaultProjectType'
            Comments = @("Types de projet connus : $KnownProjectTypesDisplay", 'Type utilisé quand vous appuyez seulement sur Entrée.')
            Value = $ConfigData.DefaultProjectType
        },
        [PSCustomObject]@{
            Name = 'DefaultCreatePythonVenv'
            Comments = @('true = O par défaut, false = N par défaut pour les projets Python.')
            Value = $ConfigData.DefaultCreatePythonVenv
        },
        [PSCustomObject]@{
            Name = 'DefaultPythonInstallLocation'
            Comments = @('"depot" = installer par défaut dans le dépôt venv, "default" = utiliser l''installation par défaut de pymanager.')
            Value = $ConfigData.DefaultPythonInstallLocation
        },
        [PSCustomObject]@{
            Name = 'AskInstallGitHubCliWhenMissing'
            Comments = @('true = reposer la question d''installation de gh si gh est absent et winget présent, false = ne plus reposer la question.', 'Remettez cette valeur à true si vous voulez être redemandé plus tard.')
            Value = $ConfigData.AskInstallGitHubCliWhenMissing
        },
        [PSCustomObject]@{
            Name = 'AskInstallPythonManagerWhenMissing'
            Comments = @('true = reposer la question d''installation de pymanager si pymanager est absent et winget présent, false = ne plus reposer la question.', 'Remettez cette valeur à true si vous voulez être redemandé plus tard.')
            Value = $ConfigData.AskInstallPythonManagerWhenMissing
        },
        [PSCustomObject]@{
            Name = 'DefaultGitHubRepositoryVisibility'
            Comments = @('"private" = dépôt GitHub privé par défaut, "public" = dépôt GitHub public par défaut.')
            Value = $ConfigData.DefaultGitHubRepositoryVisibility
        },
        [PSCustomObject]@{
            Name = 'DefaultDjangoLanguageCode'
            Comments = @('Valeur appliquée à LANGUAGE_CODE dans settings.py pour les nouveaux projets Django.')
            Value = $ConfigData.DefaultDjangoLanguageCode
        },
        [PSCustomObject]@{
            Name = 'DefaultDjangoTimeZone'
            Comments = @('Valeur appliquée à TIME_ZONE dans settings.py pour les nouveaux projets Django.')
            Value = $ConfigData.DefaultDjangoTimeZone
        },
        [PSCustomObject]@{
            Name = 'GitHubLogin'
            Comments = @('Login GitHub mémorisé pour détecter un changement de compte gh.')
            Value = $ConfigData.GitHubLogin
        },
        [PSCustomObject]@{
            Name = 'PythonDepotPath'
            Comments = @('Dépôt dédié aux versions Python installées pour créer des venv.', 'Laissez vide si vous ne voulez pas de dépôt Python dédié.')
            Value = $ConfigData.PythonDepotPath
        },
        [PSCustomObject]@{
            Name = 'KnownPythonInterpreters'
            Comments = @('Catalogue synchronisé des versions Python détectées avec leur source, leur version et leur chemin.', 'Synchronisé automatiquement depuis "pymanager list --format=exe" ou "py list --format=exe", plus les chemins Python personnalisés déjà saisis.')
            Value = $ConfigData.KnownPythonInterpreters
        }
    )

    for ($index = 0; $index -lt $propertyDefinitions.Count; $index++) {
        $propertyDefinition = $propertyDefinitions[$index]
        Add-JsonPropertyWithComments `
            -Lines $lines `
            -PropertyName $propertyDefinition.Name `
            -Comments $propertyDefinition.Comments `
            -Value $propertyDefinition.Value `
            -IsLast ($index -eq ($propertyDefinitions.Count - 1))
    }

    $lines.Add('}')
    return (($lines.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine)
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

        [Parameter(Mandatory = $true)]
        [bool] $AskInstallGitHubCliWhenMissing,

        [Parameter(Mandatory = $true)]
        [bool] $AskInstallPythonManagerWhenMissing,

        [Parameter(Mandatory = $true)]
        [string] $DefaultGitHubRepositoryVisibility,

        [Parameter(Mandatory = $true)]
        [string] $DefaultDjangoLanguageCode,

        [Parameter(Mandatory = $true)]
        [string] $DefaultDjangoTimeZone,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $GitHubLogin = $null,

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
    $normalizedAskInstallGitHubCliWhenMissing = Get-NormalizedBooleanSetting `
        -Value $AskInstallGitHubCliWhenMissing `
        -SettingName 'Le paramètre AskInstallGitHubCliWhenMissing'
    $normalizedAskInstallPythonManagerWhenMissing = Get-NormalizedBooleanSetting `
        -Value $AskInstallPythonManagerWhenMissing `
        -SettingName 'Le paramètre AskInstallPythonManagerWhenMissing'
    $normalizedDefaultGitHubRepositoryVisibility = Get-NormalizedGitHubRepositoryVisibilitySetting `
        -Visibility $DefaultGitHubRepositoryVisibility `
        -AllowDefault `
        -DefaultVisibility $FallbackGitHubRepositoryVisibility
    $normalizedDefaultDjangoLanguageCode = Get-NormalizedDjangoLanguageCodeSetting `
        -LanguageCode $DefaultDjangoLanguageCode `
        -DefaultLanguageCode $FallbackDjangoLanguageCode
    $normalizedDefaultDjangoTimeZone = Get-NormalizedDjangoTimeZoneSetting `
        -TimeZone $DefaultDjangoTimeZone `
        -DefaultTimeZone $FallbackDjangoTimeZone
    $normalizedGitHubLogin = if ([string]::IsNullOrWhiteSpace("$GitHubLogin")) {
        $null
    }
    else {
        "$GitHubLogin".Trim().ToLowerInvariant()
    }
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
        -AskInstallGitHubCliWhenMissing $normalizedAskInstallGitHubCliWhenMissing `
        -AskInstallPythonManagerWhenMissing $normalizedAskInstallPythonManagerWhenMissing `
        -DefaultGitHubRepositoryVisibility $normalizedDefaultGitHubRepositoryVisibility `
        -DefaultDjangoLanguageCode $normalizedDefaultDjangoLanguageCode `
        -DefaultDjangoTimeZone $normalizedDefaultDjangoTimeZone `
        -GitHubLogin $normalizedGitHubLogin `
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
        AskInstallGitHubCliWhenMissing = $normalizedAskInstallGitHubCliWhenMissing
        AskInstallPythonManagerWhenMissing = $normalizedAskInstallPythonManagerWhenMissing
        DefaultGitHubRepositoryVisibility = $normalizedDefaultGitHubRepositoryVisibility
        DefaultDjangoLanguageCode = $normalizedDefaultDjangoLanguageCode
        DefaultDjangoTimeZone = $normalizedDefaultDjangoTimeZone
        GitHubLogin = $normalizedGitHubLogin
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

    if ($configVersion -lt 12 -and $defaultProjectType -eq 'py') {
        $defaultProjectType = $FallbackProjectType
        $syncReasons.Add("Le type de projet par défaut de '$ConfigPath' a été mis à jour de 'py' vers '$FallbackProjectType'.")
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
    $askInstallGitHubCliWhenMissing = Get-NormalizedAskInstallGitHubCliWhenMissingFromConfig `
        -RawConfig $RawConfig `
        -ConfigPath $ConfigPath `
        -SyncReasons $syncReasons
    $askInstallPythonManagerWhenMissing = Get-NormalizedAskInstallPythonManagerWhenMissingFromConfig `
        -RawConfig $RawConfig `
        -ConfigPath $ConfigPath `
        -SyncReasons $syncReasons
    $defaultGitHubRepositoryVisibility = Get-NormalizedDefaultGitHubRepositoryVisibilityFromConfig `
        -RawConfig $RawConfig `
        -ConfigPath $ConfigPath `
        -SyncReasons $syncReasons
    $defaultDjangoLanguageCode = Get-NormalizedDefaultDjangoLanguageCodeFromConfig `
        -RawConfig $RawConfig `
        -ConfigPath $ConfigPath `
        -SyncReasons $syncReasons
    $defaultDjangoTimeZone = Get-NormalizedDefaultDjangoTimeZoneFromConfig `
        -RawConfig $RawConfig `
        -ConfigPath $ConfigPath `
        -SyncReasons $syncReasons
    $gitHubLogin = Get-NormalizedGitHubLoginFromConfig `
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
        AskInstallGitHubCliWhenMissing = $askInstallGitHubCliWhenMissing
        AskInstallPythonManagerWhenMissing = $askInstallPythonManagerWhenMissing
        DefaultGitHubRepositoryVisibility = $defaultGitHubRepositoryVisibility
        DefaultDjangoLanguageCode = $defaultDjangoLanguageCode
        DefaultDjangoTimeZone = $defaultDjangoTimeZone
        GitHubLogin = $gitHubLogin
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
                -AskInstallGitHubCliWhenMissing $configStatus.Config.AskInstallGitHubCliWhenMissing `
                -AskInstallPythonManagerWhenMissing $configStatus.Config.AskInstallPythonManagerWhenMissing `
                -DefaultGitHubRepositoryVisibility $configStatus.Config.DefaultGitHubRepositoryVisibility `
                -DefaultDjangoLanguageCode $configStatus.Config.DefaultDjangoLanguageCode `
                -DefaultDjangoTimeZone $configStatus.Config.DefaultDjangoTimeZone `
                -GitHubLogin $configStatus.Config.GitHubLogin `
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

        [Parameter(Mandatory = $true)]
        [bool] $AskInstallGitHubCliWhenMissing,

        [Parameter(Mandatory = $true)]
        [bool] $AskInstallPythonManagerWhenMissing,

        [Parameter(Mandatory = $true)]
        [string] $DefaultGitHubRepositoryVisibility,

        [Parameter(Mandatory = $true)]
        [string] $DefaultDjangoLanguageCode,

        [Parameter(Mandatory = $true)]
        [string] $DefaultDjangoTimeZone,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $GitHubLogin,

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
        -AskInstallGitHubCliWhenMissing $AskInstallGitHubCliWhenMissing `
        -AskInstallPythonManagerWhenMissing $AskInstallPythonManagerWhenMissing `
        -DefaultGitHubRepositoryVisibility $DefaultGitHubRepositoryVisibility `
        -DefaultDjangoLanguageCode $DefaultDjangoLanguageCode `
        -DefaultDjangoTimeZone $DefaultDjangoTimeZone `
        -GitHubLogin $GitHubLogin `
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
            -AskInstallGitHubCliWhenMissing $FallbackAskInstallGitHubCliWhenMissing `
            -AskInstallPythonManagerWhenMissing $FallbackAskInstallPythonManagerWhenMissing `
            -DefaultGitHubRepositoryVisibility $FallbackGitHubRepositoryVisibility `
            -DefaultDjangoLanguageCode $FallbackDjangoLanguageCode `
            -DefaultDjangoTimeZone $FallbackDjangoTimeZone `
            -GitHubLogin $null `
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
            -AskInstallGitHubCliWhenMissing $FallbackAskInstallGitHubCliWhenMissing `
            -AskInstallPythonManagerWhenMissing $FallbackAskInstallPythonManagerWhenMissing `
            -DefaultGitHubRepositoryVisibility $FallbackGitHubRepositoryVisibility `
            -DefaultDjangoLanguageCode $FallbackDjangoLanguageCode `
            -DefaultDjangoTimeZone $FallbackDjangoTimeZone `
            -GitHubLogin $null `
            -PythonDepotPath $null `
            -Message 'Nouvelle configuration créée'
    }

    if ($candidateConfigPath -ne $ConfigPath) {
        Ensure-ConfigCopy `
            -SourceProjectsRootPath $candidateConfig.ProjectsRootPath `
            -DefaultProjectType $candidateConfig.DefaultProjectType `
            -DefaultCreatePythonVenv $candidateConfig.DefaultCreatePythonVenv `
            -DefaultPythonInstallLocation $candidateConfig.DefaultPythonInstallLocation `
            -AskInstallGitHubCliWhenMissing $candidateConfig.AskInstallGitHubCliWhenMissing `
            -AskInstallPythonManagerWhenMissing $candidateConfig.AskInstallPythonManagerWhenMissing `
            -DefaultGitHubRepositoryVisibility $candidateConfig.DefaultGitHubRepositoryVisibility `
            -DefaultDjangoLanguageCode $candidateConfig.DefaultDjangoLanguageCode `
            -DefaultDjangoTimeZone $candidateConfig.DefaultDjangoTimeZone `
            -GitHubLogin $candidateConfig.GitHubLogin `
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
        -AskInstallGitHubCliWhenMissing $ProjectConfig.AskInstallGitHubCliWhenMissing `
        -AskInstallPythonManagerWhenMissing $ProjectConfig.AskInstallPythonManagerWhenMissing `
        -DefaultGitHubRepositoryVisibility $ProjectConfig.DefaultGitHubRepositoryVisibility `
        -DefaultDjangoLanguageCode $ProjectConfig.DefaultDjangoLanguageCode `
        -DefaultDjangoTimeZone $ProjectConfig.DefaultDjangoTimeZone `
        -GitHubLogin $ProjectConfig.GitHubLogin `
        -PythonDepotPath $pythonDepotPath `
        -KnownPythonInterpreters $ProjectConfig.KnownPythonInterpreters `
        -Message 'Dépôt Python dédié aux venv enregistré'
}

function Install-GitHubCliWithWinget {
    $command = Get-WingetCommand
    if ($null -eq $command) {
        return $null
    }

    Write-Host "Commande exécutée : $($command.CommandName) install --id GitHub.cli --accept-package-agreements --accept-source-agreements" -ForegroundColor DarkCyan
    return Invoke-ExternalExecutableCapture `
        -ExecutablePath $command.CommandPath `
        -Arguments @('install', '--id', 'GitHub.cli', '--accept-package-agreements', '--accept-source-agreements') `
        -WaitMessage 'Installation de GitHub CLI en cours'
}

function Install-PythonManagerWithWinget {
    $command = Get-WingetCommand
    if ($null -eq $command) {
        return $null
    }

    Write-Host "Commande exécutée : $($command.CommandName) install 9NQ7512CXL7T -e --accept-package-agreements --disable-interactivity" -ForegroundColor DarkCyan
    return Invoke-ExternalExecutableCapture `
        -ExecutablePath $command.CommandPath `
        -Arguments @('install', '9NQ7512CXL7T', '-e', '--accept-package-agreements', '--disable-interactivity') `
        -WaitMessage 'Installation de Python Install Manager en cours'
}

function Ensure-PythonManagerAvailability {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [Parameter(Mandatory = $true)]
        [object] $ProjectConfig
    )

    $pymanagerCommand = Get-PymanagerCommand
    $preferredPythonManagerCommand = Get-PreferredPythonManagerCommand
    if ($null -ne $pymanagerCommand) {
        return [PSCustomObject]@{
            ProjectConfig = $ProjectConfig
            PythonManagerCommand = $preferredPythonManagerCommand
        }
    }

    $wingetCommand = Get-WingetCommand
    if ($null -eq $wingetCommand) {
        return [PSCustomObject]@{
            ProjectConfig = $ProjectConfig
            PythonManagerCommand = $preferredPythonManagerCommand
        }
    }

    if (-not $ProjectConfig.AskInstallPythonManagerWhenMissing) {
        return [PSCustomObject]@{
            ProjectConfig = $ProjectConfig
            PythonManagerCommand = $preferredPythonManagerCommand
        }
    }

    $installPythonManager = Read-ConfirmationWithDefault `
        -Prompt 'Python Install Manager "pymanager" est absent. Voulez-vous l''installer maintenant avec winget ?' `
        -DefaultValue $true

    if (-not $installPythonManager) {
        $updatedConfig = Save-ProjectConfig `
            -ConfigPath $ConfigPath `
            -ProjectsRootPath $ProjectConfig.ProjectsRootPath `
            -DefaultProjectType $ProjectConfig.DefaultProjectType `
            -DefaultCreatePythonVenv $ProjectConfig.DefaultCreatePythonVenv `
            -DefaultPythonInstallLocation $ProjectConfig.DefaultPythonInstallLocation `
            -AskInstallGitHubCliWhenMissing $ProjectConfig.AskInstallGitHubCliWhenMissing `
            -AskInstallPythonManagerWhenMissing $false `
            -DefaultGitHubRepositoryVisibility $ProjectConfig.DefaultGitHubRepositoryVisibility `
            -DefaultDjangoLanguageCode $ProjectConfig.DefaultDjangoLanguageCode `
            -DefaultDjangoTimeZone $ProjectConfig.DefaultDjangoTimeZone `
            -GitHubLogin $ProjectConfig.GitHubLogin `
            -PythonDepotPath $ProjectConfig.PythonDepotPath `
            -KnownPythonInterpreters $ProjectConfig.KnownPythonInterpreters `
            -Message 'Configuration Python Manager enregistrée'
        Write-Host 'La question d''installation de pymanager ne sera plus reposée tant que AskInstallPythonManagerWhenMissing reste à false dans la configuration.' -ForegroundColor Yellow

        return [PSCustomObject]@{
            ProjectConfig = $updatedConfig
            PythonManagerCommand = $preferredPythonManagerCommand
        }
    }

    $installResult = Install-PythonManagerWithWinget
    if ($null -eq $installResult) {
        return [PSCustomObject]@{
            ProjectConfig = $ProjectConfig
            PythonManagerCommand = $preferredPythonManagerCommand
        }
    }

    foreach ($outputLine in $installResult.OutputLines) {
        if (-not [string]::IsNullOrWhiteSpace("$outputLine")) {
            Write-Host $outputLine
        }
    }

    if (-not $installResult.Success) {
        if (-not [string]::IsNullOrWhiteSpace($installResult.ErrorMessage)) {
            Write-Host "Impossible d'installer Python Install Manager automatiquement : $($installResult.ErrorMessage)" -ForegroundColor Yellow
        }
        else {
            Write-Host 'Impossible d''installer Python Install Manager automatiquement.' -ForegroundColor Yellow
        }

        return [PSCustomObject]@{
            ProjectConfig = $ProjectConfig
            PythonManagerCommand = $preferredPythonManagerCommand
        }
    }

    $preferredPythonManagerCommand = Get-PreferredPythonManagerCommand
    if ($null -eq (Get-PymanagerCommand)) {
        Write-Host 'Python Install Manager semble installé, mais la commande "pymanager" n''est pas encore disponible dans cette session. Relancez le script pour l''utiliser.' -ForegroundColor Yellow
    }

    return [PSCustomObject]@{
        ProjectConfig = $ProjectConfig
        PythonManagerCommand = $preferredPythonManagerCommand
    }
}

function Ensure-GitHubCliAvailability {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [Parameter(Mandatory = $true)]
        [object] $ProjectConfig
    )

    $gitHubCliCommand = Get-GitHubCliCommand
    if ($null -ne $gitHubCliCommand) {
        return [PSCustomObject]@{
            ProjectConfig = $ProjectConfig
            GitHubCliCommand = $gitHubCliCommand
        }
    }

    $wingetCommand = Get-WingetCommand
    if ($null -eq $wingetCommand) {
        return [PSCustomObject]@{
            ProjectConfig = $ProjectConfig
            GitHubCliCommand = $null
        }
    }

    if (-not $ProjectConfig.AskInstallGitHubCliWhenMissing) {
        return [PSCustomObject]@{
            ProjectConfig = $ProjectConfig
            GitHubCliCommand = $null
        }
    }

    $installGitHubCli = Read-ConfirmationWithDefault `
        -Prompt 'GitHub CLI "gh" est absent. Voulez-vous l''installer maintenant avec winget ?' `
        -DefaultValue $true

    if (-not $installGitHubCli) {
        $updatedConfig = Save-ProjectConfig `
            -ConfigPath $ConfigPath `
            -ProjectsRootPath $ProjectConfig.ProjectsRootPath `
            -DefaultProjectType $ProjectConfig.DefaultProjectType `
            -DefaultCreatePythonVenv $ProjectConfig.DefaultCreatePythonVenv `
            -DefaultPythonInstallLocation $ProjectConfig.DefaultPythonInstallLocation `
            -AskInstallGitHubCliWhenMissing $false `
            -AskInstallPythonManagerWhenMissing $ProjectConfig.AskInstallPythonManagerWhenMissing `
            -DefaultGitHubRepositoryVisibility $ProjectConfig.DefaultGitHubRepositoryVisibility `
            -DefaultDjangoLanguageCode $ProjectConfig.DefaultDjangoLanguageCode `
            -DefaultDjangoTimeZone $ProjectConfig.DefaultDjangoTimeZone `
            -GitHubLogin $ProjectConfig.GitHubLogin `
            -PythonDepotPath $ProjectConfig.PythonDepotPath `
            -KnownPythonInterpreters $ProjectConfig.KnownPythonInterpreters `
            -Message 'Configuration GitHub CLI enregistrée'
        Write-Host 'La question d''installation de gh ne sera plus reposée tant que AskInstallGitHubCliWhenMissing reste à false dans la configuration.' -ForegroundColor Yellow

        return [PSCustomObject]@{
            ProjectConfig = $updatedConfig
            GitHubCliCommand = $null
        }
    }

    $installResult = Install-GitHubCliWithWinget
    if ($null -eq $installResult) {
        return [PSCustomObject]@{
            ProjectConfig = $ProjectConfig
            GitHubCliCommand = $null
        }
    }

    foreach ($outputLine in $installResult.OutputLines) {
        if (-not [string]::IsNullOrWhiteSpace("$outputLine")) {
            Write-Host $outputLine
        }
    }

    if (-not $installResult.Success) {
        if (-not [string]::IsNullOrWhiteSpace($installResult.ErrorMessage)) {
            Write-Host "Impossible d'installer GitHub CLI automatiquement : $($installResult.ErrorMessage)" -ForegroundColor Yellow
        }
        else {
            Write-Host 'Impossible d''installer GitHub CLI automatiquement.' -ForegroundColor Yellow
        }

        return [PSCustomObject]@{
            ProjectConfig = $ProjectConfig
            GitHubCliCommand = $null
        }
    }

    $gitHubCliCommand = Get-GitHubCliCommand
    if ($null -eq $gitHubCliCommand) {
        Write-Host 'GitHub CLI semble installé, mais la commande "gh" n''est pas encore disponible dans cette session. Relancez le script pour l''utiliser.' -ForegroundColor Yellow
    }

    return [PSCustomObject]@{
        ProjectConfig = $ProjectConfig
        GitHubCliCommand = $gitHubCliCommand
    }
}

function Test-GitRepositoryHasOriginRemote {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    $result = Invoke-GitCommandCapture -Arguments @('-C', $ProjectPath, 'remote', 'get-url', 'origin')
    return ($null -ne $result -and $result.Success)
}

function Test-GitHubCliAuthentication {
    $result = Invoke-GitHubCliCommandCapture -Arguments @('auth', 'status')

    if ($null -eq $result) {
        return $false
    }

    return $result.Success
}

function Ensure-GitHubCliAuthentication {
    if (Test-GitHubCliAuthentication) {
        return $true
    }

    Write-Host 'GitHub CLI est installé mais pas encore connecté à votre compte GitHub.' -ForegroundColor Yellow
    $loginSucceeded = Invoke-GitHubCliCommandPassthrough `
        -Arguments @('auth', 'login') `
        -StartMessage 'Lancement de la connexion GitHub CLI...'

    if (-not $loginSucceeded) {
        Write-Host 'La connexion GitHub CLI n''a pas été terminée.' -ForegroundColor Yellow
    }

    if (Test-GitHubCliAuthentication) {
        Write-Host 'Connexion GitHub CLI détectée.' -ForegroundColor Green
        return $true
    }

    Write-Host 'Impossible de confirmer la connexion GitHub CLI dans cette session.' -ForegroundColor Yellow
    Write-Host 'Vous pouvez relancer plus tard : gh auth login' -ForegroundColor Cyan
    return $false
}

function Sync-GitHubLoginConfiguration {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [Parameter(Mandatory = $true)]
        [object] $ProjectConfig
    )

    if ($null -eq (Get-GitHubCliCommand)) {
        return $ProjectConfig
    }

    if (-not (Test-GitHubCliAuthentication)) {
        return $ProjectConfig
    }

    $currentGitHubLogin = (Get-GitHubAuthenticatedLogin).ToLowerInvariant()
    $storedGitHubLogin = if ([string]::IsNullOrWhiteSpace("$($ProjectConfig.GitHubLogin)")) {
        ''
    }
    else {
        "$($ProjectConfig.GitHubLogin)".Trim().ToLowerInvariant()
    }

    if (-not [string]::IsNullOrWhiteSpace($storedGitHubLogin) -and $storedGitHubLogin -cne $currentGitHubLogin) {
        $shouldRelogin = Read-ConfirmationWithDefault `
            -Prompt "Le login GitHub enregistré est '$storedGitHubLogin' mais gh est connecté avec '$currentGitHubLogin'. Voulez-vous vous déconnecter de gh puis vous reconnecter ?" `
            -DefaultValue $true

        if ($shouldRelogin) {
            $logoutSucceeded = Invoke-GitHubCliCommandPassthrough `
                -Arguments @('auth', 'logout', '--hostname', 'github.com') `
                -StartMessage 'Déconnexion de GitHub CLI...'

            if (-not $logoutSucceeded) {
                Write-Host 'La déconnexion GitHub CLI n''a pas été terminée.' -ForegroundColor Yellow
            }

            if (Ensure-GitHubCliAuthentication) {
                $currentGitHubLogin = (Get-GitHubAuthenticatedLogin).ToLowerInvariant()
            }
        }
    }

    if ($storedGitHubLogin -ceq $currentGitHubLogin) {
        return $ProjectConfig
    }

    return Save-ProjectConfig `
        -ConfigPath $ConfigPath `
        -ProjectsRootPath $ProjectConfig.ProjectsRootPath `
        -DefaultProjectType $ProjectConfig.DefaultProjectType `
        -DefaultCreatePythonVenv $ProjectConfig.DefaultCreatePythonVenv `
        -DefaultPythonInstallLocation $ProjectConfig.DefaultPythonInstallLocation `
        -AskInstallGitHubCliWhenMissing $ProjectConfig.AskInstallGitHubCliWhenMissing `
        -AskInstallPythonManagerWhenMissing $ProjectConfig.AskInstallPythonManagerWhenMissing `
        -DefaultGitHubRepositoryVisibility $ProjectConfig.DefaultGitHubRepositoryVisibility `
        -DefaultDjangoLanguageCode $ProjectConfig.DefaultDjangoLanguageCode `
        -DefaultDjangoTimeZone $ProjectConfig.DefaultDjangoTimeZone `
        -GitHubLogin $currentGitHubLogin `
        -PythonDepotPath $ProjectConfig.PythonDepotPath `
        -KnownPythonInterpreters $ProjectConfig.KnownPythonInterpreters `
        -Message 'Compte GitHub enregistré'
}

function Get-GitHubAuthenticatedLogin {
    $result = Invoke-GitHubCliCommandCapture -Arguments @('api', 'user')

    if ($null -eq $result -or -not $result.Success) {
        throw "Impossible de déterminer le compte GitHub connecté."
    }

    $jsonText = ($result.OutputLines -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        throw "Impossible de déterminer le compte GitHub connecté."
    }

    $user = $jsonText | ConvertFrom-Json -ErrorAction Stop
    $login = "$($user.login)".Trim()

    if ([string]::IsNullOrWhiteSpace($login)) {
        throw "Impossible de déterminer le compte GitHub connecté."
    }

    return $login
}

function Get-GitHubRepositoryInfoForProjectName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectName
    )

    $repositoryName = Get-NormalizedGitHubRepositoryName -ProjectName $ProjectName
    $ownerLogin = Get-GitHubAuthenticatedLogin
    $repositoryFullName = "$ownerLogin/$repositoryName"
    $result = Invoke-GitHubCliCommandCapture -Arguments @('repo', 'view', $repositoryFullName, '--json', 'name,url,nameWithOwner')

    if ($null -eq $result) {
        throw "GitHub CLI 'gh' est introuvable."
    }

    if ($result.Success) {
        $jsonText = ($result.OutputLines -join [Environment]::NewLine).Trim()
        $repositoryData = $jsonText | ConvertFrom-Json -ErrorAction Stop

        return [PSCustomObject]@{
            Exists = $true
            RepositoryName = $repositoryName
            RepositoryFullName = "$($repositoryData.nameWithOwner)".Trim()
            RepositoryUrl = "$($repositoryData.url)".Trim()
        }
    }

    $combinedOutput = ((@($result.OutputLines) + @($result.ErrorMessage)) -join ' ')
    if ($combinedOutput -match '(?i)(could not resolve to a repository|not found|404)') {
        return [PSCustomObject]@{
            Exists = $false
            RepositoryName = $repositoryName
            RepositoryFullName = $repositoryFullName
            RepositoryUrl = ''
        }
    }

    throw "Impossible de vérifier le dépôt GitHub '$repositoryFullName'."
}

function Read-ExistingGitHubRepositoryAction {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryFullName,

        [Parameter(Mandatory = $true)]
        [string] $RepositoryUrl
    )

    Write-Host "Le dépôt GitHub '$RepositoryFullName' existe déjà : $RepositoryUrl" -ForegroundColor Yellow
    Write-Host '1. Importer le dépôt GitHub existant'
    Write-Host '2. Changer le nom du projet'
    Write-Host '3. Arrêter sans rien créer'

    while ($true) {
        $answer = (Read-Host 'Choix (1/2/3)').Trim()

        switch -Regex ($answer) {
            '^(1|i|import|importer)$' { return 'Import' }
            '^(2|c|changer)$' { return 'Rename' }
            '^(3|a|arreter|arrêter|stop)$' { return 'Cancel' }
            default {
                Write-Host 'Choisissez 1 pour importer, 2 pour changer le nom ou 3 pour arrêter.' -ForegroundColor Yellow
            }
        }
    }
}

function Remove-ProjectDirectoryIfExists {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    if (-not (Test-Path -LiteralPath $ProjectPath)) {
        return
    }

    $item = Get-Item -LiteralPath $ProjectPath -ErrorAction Stop
    if (-not $item.PSIsContainer) {
        return
    }

    Remove-Item -LiteralPath $ProjectPath -Recurse -Force
    Write-Host "Dossier supprimé : $ProjectPath" -ForegroundColor Yellow
}

function Import-GitHubRepositoryToProjectPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $RepositoryFullName,

        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    $gitHubCliCommand = Get-GitHubCliCommand
    if ($null -eq $gitHubCliCommand) {
        throw "GitHub CLI 'gh' est introuvable."
    }

    Write-Host "Commande exécutée : $($gitHubCliCommand.CommandName) repo clone $RepositoryFullName $ProjectPath" -ForegroundColor DarkCyan
    $result = Invoke-GitHubCliCommandCapture `
        -Arguments @('repo', 'clone', $RepositoryFullName, $ProjectPath) `
        -WaitMessage 'Import du dépôt GitHub en cours'

    if ($null -eq $result) {
        throw "GitHub CLI 'gh' est introuvable."
    }

    foreach ($outputLine in $result.OutputLines) {
        if (-not [string]::IsNullOrWhiteSpace("$outputLine")) {
            Write-Host $outputLine
        }
    }

    if (-not $result.Success) {
        Remove-ProjectDirectoryIfExists -ProjectPath $ProjectPath

        if (-not [string]::IsNullOrWhiteSpace($result.ErrorMessage)) {
            throw "Impossible d'importer le dépôt GitHub '$RepositoryFullName' : $($result.ErrorMessage)"
        }

        throw "Impossible d'importer le dépôt GitHub '$RepositoryFullName'."
    }

    Write-Host "Dépôt GitHub importé : $ProjectPath" -ForegroundColor Green
}

function Test-TextFileContentMatches {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Path,

        [Parameter(Mandatory = $true)]
        [string] $ExpectedContent
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $currentContent = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return $currentContent -eq $ExpectedContent
}

function Get-PythonProjectDatedRequirementsFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    return @(Get-ChildItem -LiteralPath $ProjectPath -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}requirements\.txt$' })
}

function Get-PythonProjectReadmeSupplementContent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectName,

        [bool] $HasVirtualEnvironment = $false
    )

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
        '',
        '## Préparation locale',
        '',
        'Informations ajoutées par `prepare-nouveau-projet.ps1`.',
        '',
        '```',
        ($quickStartLines -join [Environment]::NewLine),
        '```',
        '',
        '- Le venv local est prévu dans le dossier `.venv`.'
    )

    return (($contentLines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function Get-MissingPythonProjectReadmeMarkers {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Content,

        [bool] $HasVirtualEnvironment = $false
    )

    $expectedMarkers = [System.Collections.Generic.List[string]]::new()
    $expectedMarkers.Add('Informations ajoutées par `prepare-nouveau-projet.ps1`.')
    $expectedMarkers.Add('## Préparation locale')
    $expectedMarkers.Add('.\.venv\Scripts\Activate.ps1')
    $expectedMarkers.Add('- Le venv local est prévu dans le dossier `.venv`.')

    if (-not $HasVirtualEnvironment) {
        $expectedMarkers.Add('python -m venv .venv')
    }

    return @($expectedMarkers | Where-Object { $Content -notmatch [regex]::Escape($_) })
}

function Ensure-TomlSectionContainsLines {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Content,

        [Parameter(Mandatory = $true)]
        [string] $SectionHeader,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]] $RequiredLines
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @(($Content -replace "`r`n", "`n") -split "`n")) {
        $lines.Add($line)
    }

    while ($lines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($lines[$lines.Count - 1])) {
        $lines.RemoveAt($lines.Count - 1)
    }

    $sectionIndex = -1
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index].Trim() -eq $SectionHeader) {
            $sectionIndex = $index
            break
        }
    }

    $missingLines = [System.Collections.Generic.List[string]]::new()

    if ($sectionIndex -ge 0) {
        $sectionEndIndex = $lines.Count
        for ($index = $sectionIndex + 1; $index -lt $lines.Count; $index++) {
            if ($lines[$index].Trim().StartsWith('[')) {
                $sectionEndIndex = $index
                break
            }
        }

        $sectionLines = @()
        if ($sectionEndIndex -gt ($sectionIndex + 1)) {
            $sectionLines = @($lines[($sectionIndex + 1)..($sectionEndIndex - 1)])
        }

        foreach ($requiredLine in @($RequiredLines)) {
            if ($sectionLines -notcontains $requiredLine) {
                $missingLines.Add($requiredLine)
            }
        }

        if ($missingLines.Count -gt 0) {
            $insertIndex = $sectionEndIndex
            foreach ($missingLine in @($missingLines)) {
                $lines.Insert($insertIndex, $missingLine)
                $insertIndex++
            }
        }
    }
    else {
        foreach ($requiredLine in @($RequiredLines)) {
            $missingLines.Add($requiredLine)
        }

        if ($missingLines.Count -gt 0) {
            if ($lines.Count -gt 0) {
                $lines.Add('')
            }

            $lines.Add($SectionHeader)
            foreach ($missingLine in @($missingLines)) {
                $lines.Add($missingLine)
            }
        }
    }

    return [PSCustomObject]@{
        Content = (($lines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine
        MissingLines = @($missingLines)
    }
}

function Get-PythonProjectPyprojectUpdateResult {
    param(
        [Parameter(Mandatory = $true)]
        [string] $Content,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $RecommendedPythonVersionRequest = $null
    )

    $updatedProjectContent = $Content
    $projectRequiredLines = [System.Collections.Generic.List[string]]::new()
    $projectChangedEntries = [System.Collections.Generic.List[string]]::new()

    if ($updatedProjectContent -notmatch '(?m)^\s*readme\s*=\s*["'']README\.md["'']\s*$') {
        $projectRequiredLines.Add('readme = "README.md"')
        $projectChangedEntries.Add('readme = "README.md"')
    }

    $requiresPythonConstraint = Get-PythonRequiresVersionConstraint -RecommendedVersionRequest $RecommendedPythonVersionRequest
    if (-not [string]::IsNullOrWhiteSpace("$requiresPythonConstraint")) {
        $expectedRequiresPythonLine = "requires-python = ""$requiresPythonConstraint"""
        $requiresPythonMatch = [System.Text.RegularExpressions.Regex]::Match($updatedProjectContent, '(?m)^\s*requires-python\s*=\s*["'']([^"'']+)["'']\s*$')
        if (-not $requiresPythonMatch.Success) {
            $projectRequiredLines.Add($expectedRequiresPythonLine)
            $projectChangedEntries.Add($expectedRequiresPythonLine)
        }
        elseif ($requiresPythonMatch.Groups[1].Value.Trim() -ne $requiresPythonConstraint) {
            $updatedProjectContent = [System.Text.RegularExpressions.Regex]::Replace(
                $updatedProjectContent,
                '(?m)^\s*requires-python\s*=\s*["''][^"'']+["'']\s*$',
                [System.Text.RegularExpressions.MatchEvaluator]{
                    param($match)
                    return $expectedRequiresPythonLine
                },
                1
            )
            $projectChangedEntries.Add($expectedRequiresPythonLine)
        }
    }

    $projectResult = Ensure-TomlSectionContainsLines `
        -Content $updatedProjectContent `
        -SectionHeader '[project]' `
        -RequiredLines $projectRequiredLines.ToArray()

    $buildSystemResult = Ensure-TomlSectionContainsLines `
        -Content $projectResult.Content `
        -SectionHeader '[build-system]' `
        -RequiredLines @(
            @(
                if ($Content -notmatch '(?m)^\s*requires\s*=\s*\[[^\]]*setuptools>=61\.0[^\]]*\]\s*$') { 'requires = ["setuptools>=61.0"]' }
                if ($Content -notmatch '(?m)^\s*build-backend\s*=\s*["'']setuptools\.build_meta["'']\s*$') { 'build-backend = "setuptools.build_meta"' }
            ) | Where-Object { $_ -ne $null }
        )

    return [PSCustomObject]@{
        Content = $buildSystemResult.Content
        MissingProjectLines = @($projectChangedEntries + $projectResult.MissingLines | Select-Object -Unique)
        MissingBuildSystemLines = @($buildSystemResult.MissingLines)
        HasChanges = (
            $buildSystemResult.Content -ne $Content -or
            @($projectChangedEntries).Count -gt 0 -or
            @($projectResult.MissingLines).Count -gt 0 -or
            @($buildSystemResult.MissingLines).Count -gt 0
        )
    }
}

function Get-PythonRequirementsHeaderUpdateResult {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string] $Content
    )

    $headerContent = Get-PythonProjectRequirementsContent
    $requiredLines = @(
        '# Dépendances Python du projet',
        '# Ajoutez une dépendance par ligne, par exemple :',
        '# requests==2.32.3'
    )

    $missingLines = @($requiredLines | Where-Object { $Content -notmatch [regex]::Escape($_) })
    if ($missingLines.Count -eq 0) {
        return [PSCustomObject]@{
            Content = $Content
            MissingLines = @()
            HasChanges = $false
        }
    }

    $normalizedContent = $Content
    if (-not $normalizedContent.EndsWith([Environment]::NewLine) -and -not [string]::IsNullOrEmpty($normalizedContent)) {
        $normalizedContent += [Environment]::NewLine
    }

    return [PSCustomObject]@{
        Content = $headerContent + $normalizedContent
        MissingLines = $missingLines
        HasChanges = $true
    }
}

function Get-MissingGitIgnoreEntries {
    param(
        [AllowNull()]
        [string[]] $CurrentLines = @(),

        [Parameter(Mandatory = $true)]
        [string] $ProjectType
    )

    $missingSections = [System.Collections.Generic.List[object]]::new()
    $sections = @(Get-ProjectGitIgnoreSections -ProjectType $ProjectType)

    foreach ($section in $sections) {
        $missingLines = @($section.Lines | Where-Object { $CurrentLines -notcontains $_ })
        if ($missingLines.Count -gt 0) {
            $missingSections.Add([PSCustomObject]@{
                    Title = $section.Title
                    Lines = $missingLines
                })
        }
    }

    return @($missingSections)
}

function Update-ProjectGitIgnoreFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $ProjectType
    )

    $gitIgnorePath = Join-Path -Path $ProjectPath -ChildPath '.gitignore'
    if (-not (Test-Path -LiteralPath $gitIgnorePath)) {
        return New-ProjectGitIgnoreFile -ProjectPath $ProjectPath -ProjectType $ProjectType
    }

    $currentContent = [System.IO.File]::ReadAllText($gitIgnorePath, [System.Text.Encoding]::UTF8)
    $normalizedCurrentContent = $currentContent -replace "`r`n", "`n"
    $currentLines = @($normalizedCurrentContent -split "`n")
    $missingSections = @(Get-MissingGitIgnoreEntries -CurrentLines $currentLines -ProjectType $ProjectType)

    if ($missingSections.Count -eq 0) {
        Write-Host ".gitignore déjà à jour : $gitIgnorePath" -ForegroundColor Yellow
        return $gitIgnorePath
    }

    $updatedLines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in @($currentLines)) {
        $updatedLines.Add($line)
    }

    while ($updatedLines.Count -gt 0 -and [string]::IsNullOrWhiteSpace($updatedLines[$updatedLines.Count - 1])) {
        $updatedLines.RemoveAt($updatedLines.Count - 1)
    }

    foreach ($section in $missingSections) {
        if ($updatedLines.Count -gt 0) {
            $updatedLines.Add('')
        }

        $updatedLines.Add($section.Title)
        foreach ($line in @($section.Lines)) {
            $updatedLines.Add($line)
        }
    }

    $updatedContent = (($updatedLines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine
    Write-Utf8TextFile -Path $gitIgnorePath -Content $updatedContent
    Write-Host ".gitignore mis à jour : $gitIgnorePath" -ForegroundColor Green
    return $gitIgnorePath
}

function Get-ImportedPythonProjectSetupPlan {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $ProjectName,

        [bool] $WillCreateVirtualEnvironment = $false,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $RecommendedPythonVersionRequest = $null
    )

    $finalHasVirtualEnvironment = $WillCreateVirtualEnvironment -or (Test-Path -LiteralPath (Join-Path -Path $ProjectPath -ChildPath '.venv'))
    $changes = [System.Collections.Generic.List[object]]::new()

    $readmePath = Join-Path -Path $ProjectPath -ChildPath 'README.md'
    if (-not (Test-Path -LiteralPath $readmePath)) {
        $changes.Add([PSCustomObject]@{
                Type = 'WriteFile'
                Path = $readmePath
                Description = 'Créer README.md'
                Content = (Get-PythonProjectReadmeContent -ProjectName $ProjectName -HasVirtualEnvironment $finalHasVirtualEnvironment)
                WithoutBom = $false
            })
    }
    else {
        $readmeContent = [System.IO.File]::ReadAllText($readmePath, [System.Text.Encoding]::UTF8)
        $missingReadmeMarkers = @(Get-MissingPythonProjectReadmeMarkers -Content $readmeContent -HasVirtualEnvironment $finalHasVirtualEnvironment)
        if ($missingReadmeMarkers.Count -gt 0) {
            $changes.Add([PSCustomObject]@{
                    Type = 'WriteFile'
                    Path = $readmePath
                    Description = 'Compléter README.md'
                    Content = ($readmeContent.TrimEnd("`r", "`n") + (Get-PythonProjectReadmeSupplementContent -ProjectName $ProjectName -HasVirtualEnvironment $finalHasVirtualEnvironment))
                    WithoutBom = $false
                    MissingEntries = $missingReadmeMarkers
                })
        }
    }

    $pyprojectPath = Join-Path -Path $ProjectPath -ChildPath 'pyproject.toml'
    if (-not (Test-Path -LiteralPath $pyprojectPath)) {
        $changes.Add([PSCustomObject]@{
                Type = 'WriteFile'
                Path = $pyprojectPath
                Description = 'Créer pyproject.toml'
                Content = (Get-PythonProjectPyprojectContent -ProjectName $ProjectName -RecommendedPythonVersionRequest $RecommendedPythonVersionRequest)
                WithoutBom = $false
            })
    }
    else {
        $pyprojectContent = [System.IO.File]::ReadAllText($pyprojectPath, [System.Text.Encoding]::UTF8)
        $pyprojectUpdateResult = Get-PythonProjectPyprojectUpdateResult `
            -Content $pyprojectContent `
            -RecommendedPythonVersionRequest $RecommendedPythonVersionRequest
        if ($pyprojectUpdateResult.HasChanges) {
            $changes.Add([PSCustomObject]@{
                    Type = 'WriteFile'
                    Path = $pyprojectPath
                    Description = 'Compléter pyproject.toml'
                    Content = $pyprojectUpdateResult.Content
                    WithoutBom = $false
                    MissingEntries = @($pyprojectUpdateResult.MissingProjectLines + $pyprojectUpdateResult.MissingBuildSystemLines)
                })
        }
    }

    $datedRequirementsFiles = @(Get-PythonProjectDatedRequirementsFiles -ProjectPath $ProjectPath)
    if ($datedRequirementsFiles.Count -eq 0) {
        $requirementsPath = Join-Path -Path $ProjectPath -ChildPath (Get-PythonRequirementsFileName)
        $changes.Add([PSCustomObject]@{
                Type = 'WriteFile'
                Path = $requirementsPath
                Description = "Créer $(Split-Path -Leaf $requirementsPath)"
                Content = (Get-PythonProjectRequirementsContent)
                WithoutBom = $false
            })
    }
    else {
        $requirementsFile = $datedRequirementsFiles | Sort-Object Name -Descending | Select-Object -First 1
        $requirementsContent = [System.IO.File]::ReadAllText($requirementsFile.FullName, [System.Text.Encoding]::UTF8)
        $requirementsUpdateResult = Get-PythonRequirementsHeaderUpdateResult -Content $requirementsContent
        if ($requirementsUpdateResult.HasChanges) {
            $changes.Add([PSCustomObject]@{
                    Type = 'WriteFile'
                    Path = $requirementsFile.FullName
                    Description = "Compléter $($requirementsFile.Name)"
                    Content = $requirementsUpdateResult.Content
                    WithoutBom = $false
                    MissingEntries = @($requirementsUpdateResult.MissingLines)
                })
        }
    }

    $gitIgnorePath = Join-Path -Path $ProjectPath -ChildPath '.gitignore'
    if (-not (Test-Path -LiteralPath $gitIgnorePath)) {
        $changes.Add([PSCustomObject]@{
                Type = 'WriteFile'
                Path = $gitIgnorePath
                Description = 'Créer .gitignore'
                Content = (Get-ProjectGitIgnoreContent -ProjectType 'py')
                WithoutBom = $false
            })
    }
    else {
        $currentGitIgnoreContent = [System.IO.File]::ReadAllText($gitIgnorePath, [System.Text.Encoding]::UTF8)
        $currentGitIgnoreLines = @(($currentGitIgnoreContent -replace "`r`n", "`n") -split "`n")
        $missingGitIgnoreSections = @(Get-MissingGitIgnoreEntries -CurrentLines $currentGitIgnoreLines -ProjectType 'py')
        if ($missingGitIgnoreSections.Count -gt 0) {
            $missingEntries = @()
            foreach ($section in $missingGitIgnoreSections) {
                $missingEntries += @($section.Lines)
            }

            $changes.Add([PSCustomObject]@{
                    Type = 'UpdateGitIgnore'
                    Path = $gitIgnorePath
                    Description = 'Compléter .gitignore'
                    MissingEntries = @($missingEntries)
                })
        }
    }

    if ($finalHasVirtualEnvironment) {
        $cmdVenvPath = Join-Path -Path $ProjectPath -ChildPath 'cmdVenv.cmd'
        $expectedCmdVenvContent = Get-PythonProjectCmdVenvLauncherContent -ProjectName $ProjectName
        if (-not (Test-Path -LiteralPath $cmdVenvPath)) {
            $changes.Add([PSCustomObject]@{
                    Type = 'WriteFile'
                    Path = $cmdVenvPath
                    Description = 'Créer cmdVenv.cmd'
                    Content = $expectedCmdVenvContent
                    WithoutBom = $true
                    Category = 'Venv'
                })
        }
        elseif (-not (Test-TextFileContentMatches -Path $cmdVenvPath -ExpectedContent $expectedCmdVenvContent)) {
            $changes.Add([PSCustomObject]@{
                    Type = 'WriteFile'
                    Path = $cmdVenvPath
                    Description = 'Mettre à jour cmdVenv.cmd'
                    Content = $expectedCmdVenvContent
                    WithoutBom = $true
                    Category = 'Venv'
                })
        }
    }

    if ($WillCreateVirtualEnvironment) {
        $changes.Add([PSCustomObject]@{
                Type = 'CreateVenv'
                Path = (Join-Path -Path $ProjectPath -ChildPath '.venv')
                Description = 'Créer le venv Python ".venv"'
                Category = 'Venv'
            })
    }

    return [PSCustomObject]@{
        FinalHasVirtualEnvironment = $finalHasVirtualEnvironment
        Changes = @($changes)
    }
}

function Show-ImportedPythonProjectSetupPlan {
    param(
        [AllowEmptyCollection()]
        [object[]] $Changes = @()
    )

    Write-Host 'Changements proposés :' -ForegroundColor Cyan
    foreach ($change in @($Changes)) {
        Write-Host "- $($change.Description)" -ForegroundColor Cyan
        $missingEntries = @()
        if ($change.PSObject.Properties.Match('MissingEntries').Count -gt 0 -and $null -ne $change.MissingEntries) {
            $missingEntries = @($change.MissingEntries)
        }

        if ($missingEntries.Count -gt 0) {
            Write-Host "  Informations manquantes : $($missingEntries -join ', ')" -ForegroundColor DarkCyan
        }
    }
}

function Get-ImportedPythonProjectSetupChangesByCategory {
    param(
        [AllowEmptyCollection()]
        [object[]] $Changes = @()
    )

    $venvChanges = [System.Collections.Generic.List[object]]::new()
    $supplementalChanges = [System.Collections.Generic.List[object]]::new()

    foreach ($change in @($Changes)) {
        $category = if ($change.PSObject.Properties.Match('Category').Count -gt 0) {
            "$($change.Category)"
        }
        else {
            ''
        }

        if ($category -eq 'Venv') {
            $venvChanges.Add($change)
        }
        else {
            $supplementalChanges.Add($change)
        }
    }

    return [PSCustomObject]@{
        VenvChanges = @($venvChanges)
        SupplementalChanges = @($supplementalChanges)
    }
}

function Read-ConfirmedPythonProjectSupplementalChanges {
    param(
        [AllowEmptyCollection()]
        [object[]] $Changes = @()
    )

    $confirmedChanges = [System.Collections.Generic.List[object]]::new()

    foreach ($change in @($Changes)) {
        Show-ImportedPythonProjectSetupPlan -Changes @($change)
        $confirmChange = Read-ConfirmationWithDefault -Prompt 'Confirmer ce changement pour ce projet Python ?' -DefaultValue $true
        if ($confirmChange) {
            $confirmedChanges.Add($change)
        }
        else {
            Write-Host "Changement ignoré à votre demande : $($change.Description)" -ForegroundColor Yellow
        }
    }

    return @($confirmedChanges.ToArray())
}

function Apply-ConfirmedPythonProjectSupplementalChanges {
    param(
        [AllowEmptyCollection()]
        [object[]] $Changes = @(),

        [AllowNull()]
        [System.Collections.Generic.List[string]] $AppliedChangedPaths
    )

    if (@($Changes).Count -eq 0) {
        return
    }

    $confirmedSupplementalChanges = @(Read-ConfirmedPythonProjectSupplementalChanges -Changes $Changes)
    if ($confirmedSupplementalChanges.Count -eq 0) {
        Write-Host 'Les compléments de fichiers ont été ignorés à votre demande.' -ForegroundColor Yellow
        return
    }

    if ($null -eq $AppliedChangedPaths) {
        $AppliedChangedPaths = [System.Collections.Generic.List[string]]::new()
    }

    Invoke-ImportedPythonProjectSetupPlan -Changes $confirmedSupplementalChanges
    foreach ($changedPath in @(Get-ChangedPathsFromSetupChanges -Changes $confirmedSupplementalChanges)) {
        if ($AppliedChangedPaths -notcontains $changedPath) {
            $AppliedChangedPaths.Add($changedPath)
        }
    }
}

function Invoke-ImportedPythonProjectSetupPlan {
    param(
        [AllowEmptyCollection()]
        [object[]] $Changes = @()
    )

    foreach ($change in @($Changes)) {
        switch ($change.Type) {
            'WriteFile' {
                Write-Utf8TextFile -Path $change.Path -Content $change.Content -WithoutBom:([bool] $change.WithoutBom)
                Write-Host "$($change.Description) : $($change.Path)" -ForegroundColor Green
            }
            'UpdateGitIgnore' {
                Update-ProjectGitIgnoreFile -ProjectPath (Split-Path -Path $change.Path -Parent) -ProjectType 'py' | Out-Null
            }
        }
    }
}

function ConvertTo-NormalizedPathList {
    param(
        [AllowNull()]
        [object[]] $Paths = @()
    )

    $normalizedPaths = [System.Collections.Generic.List[string]]::new()
    $pendingValues = [System.Collections.Generic.Queue[object]]::new()

    foreach ($pathValue in @($Paths)) {
        $pendingValues.Enqueue($pathValue)
    }

    while ($pendingValues.Count -gt 0) {
        $currentValue = $pendingValues.Dequeue()
        if ($null -eq $currentValue) {
            continue
        }

        if ($currentValue -is [string]) {
            $currentPath = $currentValue.Trim()
            if ([string]::IsNullOrWhiteSpace($currentPath)) {
                continue
            }

            $normalizedPath = Get-NormalizedPath -Path $currentPath
            if ($normalizedPaths -notcontains $normalizedPath) {
                $normalizedPaths.Add($normalizedPath)
            }

            continue
        }

        if ($currentValue -is [System.Collections.IEnumerable]) {
            foreach ($nestedValue in @($currentValue)) {
                $pendingValues.Enqueue($nestedValue)
            }

            continue
        }

        $currentPath = "$currentValue".Trim()
        if ([string]::IsNullOrWhiteSpace($currentPath)) {
            continue
        }

        $normalizedPath = Get-NormalizedPath -Path $currentPath
        if ($normalizedPaths -notcontains $normalizedPath) {
            $normalizedPaths.Add($normalizedPath)
        }
    }

    return @($normalizedPaths.ToArray())
}

function New-ProjectSetupResult {
    param(
        [Parameter(Mandatory = $true)]
        [object] $ProjectConfig,

        [AllowEmptyCollection()]
        [string[]] $ChangedPaths = @()
    )

    $normalizedChangedPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($normalizedPath in @(ConvertTo-NormalizedPathList -Paths $ChangedPaths)) {
        if ($normalizedChangedPaths -notcontains $normalizedPath) {
            $normalizedChangedPaths.Add($normalizedPath)
        }
    }

    return [PSCustomObject]@{
        ProjectConfig = $ProjectConfig
        ChangedPaths = @($normalizedChangedPaths.ToArray())
    }
}

function Get-ChangedPathsFromSetupChanges {
    param(
        [AllowEmptyCollection()]
        [object[]] $Changes = @()
    )

    $changedPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($change in @($Changes)) {
        if ($change.PSObject.Properties.Match('Path').Count -eq 0) {
            continue
        }

        foreach ($normalizedPath in @(ConvertTo-NormalizedPathList -Paths $change.Path)) {
            if ($changedPaths -notcontains $normalizedPath) {
                $changedPaths.Add($normalizedPath)
            }
        }
    }

    return @($changedPaths.ToArray())
}

function Update-ExistingProjectSetup {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [Parameter(Mandatory = $true)]
        [object] $ProjectConfig,

        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $ProjectName,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $ProjectType,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $CustomProjectType
    )

    $resolvedProjectType = if ([string]::IsNullOrWhiteSpace($ProjectType)) {
        Read-ConfirmedDetectedProjectType -DetectedProjectType (Get-DetectedExistingProjectType -ProjectPath $ProjectPath)
    }
    else {
        Get-NormalizedProjectType -ProjectType $ProjectType
    }

    if (Test-PythonBasedProjectType -ProjectType $resolvedProjectType -and (Test-PythonProjectPath -ProjectPath $ProjectPath)) {
        return Initialize-ImportedPythonProjectEnvironment `
            -ConfigPath $ConfigPath `
            -ProjectConfig $ProjectConfig `
            -ProjectPath $ProjectPath `
            -ProjectName $ProjectName
    }

    $projectTypeSelection = Resolve-ProjectTypeSelection `
        -ProjectType $resolvedProjectType `
        -DefaultProjectType $ProjectConfig.DefaultProjectType `
        -CustomProjectType $CustomProjectType
    $projectTypeToUpdate = $projectTypeSelection.NormalizedProjectType
    $gitIgnorePath = Join-Path -Path $ProjectPath -ChildPath '.gitignore'
    $changes = [System.Collections.Generic.List[object]]::new()

    if (-not (Test-Path -LiteralPath $gitIgnorePath)) {
        $changes.Add([PSCustomObject]@{
                Type = 'WriteFile'
                Path = $gitIgnorePath
                Description = 'Créer .gitignore'
                Content = (Get-ProjectGitIgnoreContent -ProjectType $projectTypeToUpdate)
                WithoutBom = $false
            })
    }
    else {
        $currentGitIgnoreContent = [System.IO.File]::ReadAllText($gitIgnorePath, [System.Text.Encoding]::UTF8)
        $currentGitIgnoreLines = @(($currentGitIgnoreContent -replace "`r`n", "`n") -split "`n")
        $missingGitIgnoreSections = @(Get-MissingGitIgnoreEntries -CurrentLines $currentGitIgnoreLines -ProjectType $projectTypeToUpdate)
        if ($missingGitIgnoreSections.Count -gt 0) {
            $missingEntries = @()
            foreach ($section in $missingGitIgnoreSections) {
                $missingEntries += @($section.Lines)
            }

            $changes.Add([PSCustomObject]@{
                    Type = 'UpdateGitIgnore'
                    Path = $gitIgnorePath
                    Description = 'Compléter .gitignore'
                    MissingEntries = @($missingEntries)
                })
        }
    }

    if ($changes.Count -eq 0) {
        Write-Host 'Le projet existant est déjà à jour pour ce type.' -ForegroundColor Green
        return New-ProjectSetupResult -ProjectConfig $ProjectConfig
    }

    Show-ImportedPythonProjectSetupPlan -Changes @($changes)
    $confirmChanges = Read-ConfirmationWithDefault -Prompt 'Confirmer ces changements pour le projet existant ?' -DefaultValue $true
    if (-not $confirmChanges) {
        Write-Host 'Aucune modification automatique appliquée au projet existant.' -ForegroundColor Yellow
        return New-ProjectSetupResult -ProjectConfig $ProjectConfig
    }

    Invoke-ImportedPythonProjectSetupPlan -Changes @($changes)
    return New-ProjectSetupResult `
        -ProjectConfig $ProjectConfig `
        -ChangedPaths (Get-ChangedPathsFromSetupChanges -Changes @($changes))
}

function Initialize-ImportedPythonProjectEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ConfigPath,

        [Parameter(Mandatory = $true)]
        [object] $ProjectConfig,

        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $ProjectName
    )

    if (-not (Test-PythonProjectPath -ProjectPath $ProjectPath)) {
        return New-ProjectSetupResult -ProjectConfig $ProjectConfig
    }

    $recommendedPythonVersionInfo = Get-RecommendedPythonVersionInfoFromProjectPath -ProjectPath $ProjectPath
    $recommendedPythonVersionRequest = $recommendedPythonVersionInfo.VersionRequest

    if (-not [string]::IsNullOrWhiteSpace("$recommendedPythonVersionRequest")) {
        if ($recommendedPythonVersionInfo.Source -eq 'venv') {
            Write-Host "Version Python recommandée déduite du venv local : $recommendedPythonVersionRequest" -ForegroundColor Cyan
        }
        else {
            Write-Host "Version Python recommandée détectée dans pyproject.toml : $recommendedPythonVersionRequest" -ForegroundColor Cyan
        }
    }

    $venvPath = Join-Path -Path $ProjectPath -ChildPath '.venv'
    $hasExistingVirtualEnvironment = Test-Path -LiteralPath $venvPath
    $shouldCreatePythonVenv = $false
    if (-not $hasExistingVirtualEnvironment) {
        $shouldCreatePythonVenv = Read-CreatePythonVenv -DefaultCreatePythonVenv $ProjectConfig.DefaultCreatePythonVenv
    }

    $setupPlan = Get-ImportedPythonProjectSetupPlan `
        -ProjectPath $ProjectPath `
        -ProjectName $ProjectName `
        -WillCreateVirtualEnvironment $shouldCreatePythonVenv `
        -RecommendedPythonVersionRequest $recommendedPythonVersionRequest

    $categorizedChanges = Get-ImportedPythonProjectSetupChangesByCategory -Changes $setupPlan.Changes
    $venvChanges = @($categorizedChanges.VenvChanges)
    $supplementalChanges = @($categorizedChanges.SupplementalChanges)

    if ($venvChanges.Count -gt 0) {
        Write-Host 'Préparation du venv :' -ForegroundColor Cyan
        foreach ($venvChange in $venvChanges) {
            Write-Host "- $($venvChange.Description)" -ForegroundColor Cyan
        }
    }

    if ($supplementalChanges.Count -eq 0 -and $venvChanges.Count -eq 0) {
        Write-Host 'Le projet Python est déjà à jour.' -ForegroundColor Green
        return New-ProjectSetupResult -ProjectConfig $ProjectConfig
    }

    $appliedChangedPaths = [System.Collections.Generic.List[string]]::new()

    if ($venvChanges.Count -gt 0) {
        Invoke-ImportedPythonProjectSetupPlan -Changes $venvChanges
        foreach ($changedPath in @(Get-ChangedPathsFromSetupChanges -Changes $venvChanges)) {
            if ($appliedChangedPaths -notcontains $changedPath) {
                $appliedChangedPaths.Add($changedPath)
            }
        }
    }

    if (-not $shouldCreatePythonVenv) {
        Apply-ConfirmedPythonProjectSupplementalChanges `
            -Changes $supplementalChanges `
            -AppliedChangedPaths $appliedChangedPaths
        return New-ProjectSetupResult -ProjectConfig $ProjectConfig -ChangedPaths @($appliedChangedPaths)
    }

    Write-StepInfo 'Recherche des versions Python connues...'
    $updatedConfig = Sync-ProjectPythonInterpreters -ConfigPath $ConfigPath -ProjectConfig $ProjectConfig
    $pythonSelection = Select-PythonInterpreterForVenv `
        -ConfigPath $ConfigPath `
        -ProjectConfig $updatedConfig `
        -PreferredVersionRequest $recommendedPythonVersionRequest
    $updatedConfig = $pythonSelection.ProjectConfig
    New-PythonVirtualEnvironment -ProjectPath $ProjectPath -PythonInterpreter $pythonSelection.Interpreter | Out-Null

    $selectedPythonVersionRequest = Get-RecommendedPythonVersionRequestFromVersionText -VersionText $pythonSelection.Interpreter.Version
    $postVenvSetupPlan = Get-ImportedPythonProjectSetupPlan `
        -ProjectPath $ProjectPath `
        -ProjectName $ProjectName `
        -WillCreateVirtualEnvironment $true `
        -RecommendedPythonVersionRequest $selectedPythonVersionRequest
    $postVenvCategorizedChanges = Get-ImportedPythonProjectSetupChangesByCategory -Changes $postVenvSetupPlan.Changes
    Apply-ConfirmedPythonProjectSupplementalChanges `
        -Changes $postVenvCategorizedChanges.SupplementalChanges `
        -AppliedChangedPaths $appliedChangedPaths

    return New-ProjectSetupResult -ProjectConfig $updatedConfig -ChangedPaths @($appliedChangedPaths)
}

function Ensure-LocalGitRepositoryReady {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    $gitCommand = Get-GitCommand
    if ($null -eq $gitCommand) {
        throw "Git n'est pas installé. Impossible de créer automatiquement le dépôt GitHub."
    }

    if (-not (Test-Path -LiteralPath (Join-Path -Path $ProjectPath -ChildPath '.git'))) {
        $initResult = Invoke-GitCommandCapture -Arguments @('-C', $ProjectPath, 'init') -WaitMessage 'Initialisation du dépôt Git local'
        foreach ($outputLine in $initResult.OutputLines) {
            if (-not [string]::IsNullOrWhiteSpace("$outputLine")) {
                Write-Host $outputLine
            }
        }

        if (-not $initResult.Success) {
            throw "Impossible d'initialiser le dépôt Git local dans '$ProjectPath'."
        }
    }

    $branchResult = Invoke-GitCommandCapture -Arguments @('-C', $ProjectPath, 'branch', '-M', 'main')
    if ($null -eq $branchResult -or -not $branchResult.Success) {
        throw "Impossible de positionner la branche Git principale sur 'main'."
    }

    $headResult = Invoke-GitCommandCapture -Arguments @('-C', $ProjectPath, 'rev-parse', '--verify', 'HEAD')
    if ($null -ne $headResult -and $headResult.Success) {
        return
    }

    $addResult = Invoke-GitCommandCapture -Arguments @('-C', $ProjectPath, 'add', '.')
    if ($null -eq $addResult -or -not $addResult.Success) {
        throw "Impossible d'ajouter les fichiers du projet au dépôt Git local."
    }

    $commitResult = Invoke-GitCommandCapture -Arguments @('-C', $ProjectPath, 'commit', '-m', 'Initialisation du projet')
    foreach ($outputLine in $commitResult.OutputLines) {
        if (-not [string]::IsNullOrWhiteSpace("$outputLine")) {
            Write-Host $outputLine
        }
    }

    if (-not $commitResult.Success) {
        if (($commitResult.OutputLines -join ' ') -match '(?i)(user\.name|user\.email|unable to auto-detect email address|author identity unknown)') {
            throw 'Git n''est pas encore configuré avec user.name et user.email. Configurez Git puis relancez le script pour créer automatiquement le dépôt GitHub.'
        }

        if (-not [string]::IsNullOrWhiteSpace($commitResult.ErrorMessage)) {
            throw "Impossible de créer le commit Git initial : $($commitResult.ErrorMessage)"
        }

        throw 'Impossible de créer le commit Git initial.'
    }
}

function Test-GitRepositoryExists {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    return (Test-Path -LiteralPath (Join-Path -Path $ProjectPath -ChildPath '.git'))
}

function Get-GitWorkingTreeStatusLines {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    $result = Invoke-GitCommandCapture -Arguments @('-C', $ProjectPath, 'status', '--porcelain')
    if ($null -eq $result -or -not $result.Success) {
        return @()
    }

    return @($result.OutputLines | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
}

function Get-GitWorkingTreeChangedPaths {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    $changedPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($statusLine in @(Get-GitWorkingTreeStatusLines -ProjectPath $ProjectPath)) {
        $statusText = "$statusLine"
        if ([string]::IsNullOrWhiteSpace($statusText) -or $statusText.Length -lt 4) {
            continue
        }

        $relativePath = $statusText.Substring(3).Trim()
        if ($relativePath.Contains(' -> ')) {
            $relativePath = ($relativePath -split ' -> ' | Select-Object -Last 1).Trim()
        }

        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }

        $absolutePath = Join-Path -Path $ProjectPath -ChildPath $relativePath
        $normalizedPath = Get-NormalizedPathCandidate -Path $absolutePath
        if ($changedPaths -notcontains $normalizedPath) {
            $changedPaths.Add($normalizedPath)
        }
    }

    return ,@($changedPaths)
}

function Test-GitWorkingTreeHasChanges {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    return (@(Get-GitWorkingTreeStatusLines -ProjectPath $ProjectPath).Count -gt 0)
}

function Get-GitOriginRemoteUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    $result = Invoke-GitCommandCapture -Arguments @('-C', $ProjectPath, 'remote', 'get-url', 'origin')
    if ($null -eq $result -or -not $result.Success) {
        return ''
    }

    foreach ($outputLine in @($result.OutputLines)) {
        $outputText = "$outputLine".Trim()
        if (-not [string]::IsNullOrWhiteSpace($outputText)) {
            return $outputText
        }
    }

    return ''
}

function Test-GitHubOriginRemote {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    $originRemoteUrl = Get-GitOriginRemoteUrl -ProjectPath $ProjectPath
    if ([string]::IsNullOrWhiteSpace($originRemoteUrl)) {
        return $false
    }

    return ($originRemoteUrl -match '(?i)github\.com[:/]')
}

function Get-ProjectRelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $TargetPath
    )

    $normalizedProjectPath = [System.IO.Path]::GetFullPath((Get-NormalizedPath -Path $ProjectPath))
    $normalizedTargetPath = [System.IO.Path]::GetFullPath((Get-NormalizedPath -Path $TargetPath))

    if (-not $normalizedTargetPath.StartsWith($normalizedProjectPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Le chemin '$normalizedTargetPath' n'appartient pas au projet '$normalizedProjectPath'."
    }

    $relativePath = $normalizedTargetPath.Substring($normalizedProjectPath.Length).TrimStart('\', '/')
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        return '.'
    }

    return $relativePath
}

function Get-GitCurrentBranchName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    $result = Invoke-GitCommandCapture -Arguments @('-C', $ProjectPath, 'branch', '--show-current')
    if ($null -eq $result -or -not $result.Success) {
        return ''
    }

    foreach ($outputLine in @($result.OutputLines)) {
        $branchName = "$outputLine".Trim()
        if (-not [string]::IsNullOrWhiteSpace($branchName)) {
            return $branchName
        }
    }

    return ''
}

function Sync-UpdatedProjectToGitHub {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [AllowEmptyCollection()]
        [string[]] $ChangedPaths = @()
    )

    if (-not (Test-GitRepositoryExists -ProjectPath $ProjectPath)) {
        Write-Host 'Aucun dépôt Git local détecté. Synchronisation GitHub ignorée.' -ForegroundColor Yellow
        return
    }

    Write-StepInfo 'Préparation de la synchronisation GitHub de la mise à jour...'

    $normalizedChangedPaths = @(Get-ChangedPathsFromSetupChanges -Changes @(
            foreach ($changedPath in @($ChangedPaths)) {
                [PSCustomObject]@{ Path = $changedPath }
            }
        ))
    if ($normalizedChangedPaths.Count -eq 0) {
        Write-Host 'Aucun fichier modifié à synchroniser vers GitHub.' -ForegroundColor Yellow
        return
    }

    if (-not (Test-GitRepositoryHasOriginRemote -ProjectPath $ProjectPath)) {
        Write-Host "Dépôt Git local détecté, mais aucun remote 'origin' n'est configuré. Mise à jour GitHub ignorée." -ForegroundColor Yellow
        return
    }

    if (-not (Test-GitHubOriginRemote -ProjectPath $ProjectPath)) {
        Write-Host "Le remote 'origin' n'est pas un dépôt GitHub. Push GitHub ignoré." -ForegroundColor Yellow
        return
    }

    $relativeChangedPaths = [System.Collections.Generic.List[string]]::new()
    foreach ($changedPath in @($normalizedChangedPaths)) {
        try {
            $relativeChangedPath = Get-ProjectRelativePath -ProjectPath $ProjectPath -TargetPath $changedPath
            if ($relativeChangedPaths -notcontains $relativeChangedPath) {
                $relativeChangedPaths.Add($relativeChangedPath)
            }
        }
        catch {
            continue
        }
    }

    if ($relativeChangedPaths.Count -eq 0) {
        Write-Host 'Aucun fichier du script n''a pu être relié au dépôt Git pour la synchronisation GitHub.' -ForegroundColor Yellow
        return
    }

    $stagedCandidatePaths = [System.Collections.Generic.List[string]]::new()
    foreach ($relativeChangedPath in @($relativeChangedPaths.ToArray())) {
        $addResult = Invoke-GitCommandCapture `
            -Arguments @('-C', $ProjectPath, 'add', '--', $relativeChangedPath) `
            -WaitMessage "Préparation Git du fichier $relativeChangedPath"
        if ($null -ne $addResult -and $addResult.Success) {
            if ($stagedCandidatePaths -notcontains $relativeChangedPath) {
                $stagedCandidatePaths.Add($relativeChangedPath)
            }

            continue
        }

        $addOutputText = ''
        if ($null -ne $addResult) {
            $addOutputText = (@($addResult.OutputLines) -join ' ').Trim()
        }

        if ($addOutputText -match '(?i)ignored by one of your \.gitignore files') {
            Write-Host "Fichier ignoré par Git, non synchronisé : $relativeChangedPath" -ForegroundColor Yellow
            continue
        }

        Write-Host "Impossible de préparer le fichier Git '$relativeChangedPath'. Il sera ignoré pour le push." -ForegroundColor Yellow
    }

    if ($stagedCandidatePaths.Count -eq 0) {
        Write-Host 'Aucun fichier modifié du script n''a pu être préparé pour Git.' -ForegroundColor Yellow
        return
    }

    $stagedResult = Invoke-GitCommandCapture -Arguments (@('-C', $ProjectPath, 'diff', '--cached', '--name-only', '--') + $stagedCandidatePaths.ToArray())
    $stagedFiles = @(
        if ($null -eq $stagedResult -or -not $stagedResult.Success) {
            @()
        }
        else {
            @($stagedResult.OutputLines | Where-Object { -not [string]::IsNullOrWhiteSpace("$_") })
        }
    )

    if ($stagedFiles.Count -eq 0) {
        Write-Host 'Aucun changement de mise à jour à envoyer vers GitHub.' -ForegroundColor Yellow
        return
    }

    $commitResult = Invoke-GitCommandCapture -Arguments @('-C', $ProjectPath, 'commit', '-m', 'Mise à jour du projet via prepare-nouveau-projet.ps1') -WaitMessage 'Création du commit Git de mise à jour'
    foreach ($outputLine in @($commitResult.OutputLines)) {
        if (-not [string]::IsNullOrWhiteSpace("$outputLine")) {
            Write-Host $outputLine
        }
    }

    if ($null -eq $commitResult -or -not $commitResult.Success) {
        if (($commitResult.OutputLines -join ' ') -match '(?i)(user\.name|user\.email|unable to auto-detect email address|author identity unknown)') {
            Write-Host 'Git n''est pas encore configuré avec user.name et user.email. Push GitHub ignoré.' -ForegroundColor Yellow
            return
        }

        Write-Host 'Impossible de créer le commit Git de mise à jour. Push GitHub ignoré.' -ForegroundColor Yellow
        return
    }

    $pushResult = Invoke-GitCommandCapture -Arguments @('-C', $ProjectPath, 'push') -WaitMessage 'Push GitHub en cours'
    foreach ($outputLine in @($pushResult.OutputLines)) {
        if (-not [string]::IsNullOrWhiteSpace("$outputLine")) {
            Write-Host $outputLine
        }
    }

    if ($null -ne $pushResult -and $pushResult.Success) {
        Write-Host 'Mise à jour GitHub effectuée.' -ForegroundColor Green
        return
    }

    $currentBranchName = Get-GitCurrentBranchName -ProjectPath $ProjectPath
    if ([string]::IsNullOrWhiteSpace($currentBranchName)) {
        Write-Host 'Impossible de déterminer la branche Git courante. Push GitHub ignoré.' -ForegroundColor Yellow
        return
    }

    $pushResult = Invoke-GitCommandCapture -Arguments @('-C', $ProjectPath, 'push', '-u', 'origin', $currentBranchName) -WaitMessage 'Push GitHub en cours'
    foreach ($outputLine in @($pushResult.OutputLines)) {
        if (-not [string]::IsNullOrWhiteSpace("$outputLine")) {
            Write-Host $outputLine
        }
    }

    if ($null -eq $pushResult -or -not $pushResult.Success) {
        Write-Host 'Impossible d''envoyer la mise à jour vers GitHub.' -ForegroundColor Yellow
        return
    }

    Write-Host 'Mise à jour GitHub effectuée.' -ForegroundColor Green
}

function Sync-ProjectSetupResultToGitHubIfNeeded {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [AllowNull()]
        [object] $ProjectSetupResult
    )

    if (-not (Test-GitRepositoryExists -ProjectPath $ProjectPath)) {
        return
    }

    if (Test-GitWorkingTreeHasChanges -ProjectPath $ProjectPath) {
        Write-Host 'Le dépôt Git local contient déjà des modifications non validées. Le script ne synchronisera que les fichiers qu''il a lui-même mis à jour.' -ForegroundColor Yellow
    }

    $changedPathsToSync = @()
    if ($null -ne $ProjectSetupResult -and $ProjectSetupResult.PSObject.Properties.Match('ChangedPaths').Count -gt 0) {
        $changedPathsToSync = @($ProjectSetupResult.ChangedPaths)
    }

    if ($changedPathsToSync.Count -eq 0) {
        $changedPathsToSync = @(Get-GitWorkingTreeChangedPaths -ProjectPath $ProjectPath)
    }

    Sync-UpdatedProjectToGitHub `
        -ProjectPath $ProjectPath `
        -ChangedPaths $changedPathsToSync
}

function New-GitHubRepositoryForProject {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $ProjectName,

        [Parameter(Mandatory = $true)]
        [string] $Visibility
    )

    $gitHubCliCommand = Get-GitHubCliCommand
    if ($null -eq $gitHubCliCommand) {
        return
    }

    if (Test-GitRepositoryHasOriginRemote -ProjectPath $ProjectPath) {
        Write-Host "Un remote Git 'origin' existe déjà pour '$ProjectPath'. Création GitHub ignorée." -ForegroundColor Yellow
        return
    }

    $normalizedVisibility = Get-NormalizedGitHubRepositoryVisibilitySetting `
        -Visibility $Visibility `
        -AllowDefault `
        -DefaultVisibility $FallbackGitHubRepositoryVisibility
    $repositoryName = Get-NormalizedGitHubRepositoryName -ProjectName $ProjectName

    if (-not (Ensure-GitHubCliAuthentication)) {
        return
    }

    Ensure-LocalGitRepositoryReady -ProjectPath $ProjectPath

    $ghArguments = @('repo', 'create', $repositoryName, "--$normalizedVisibility", '--source', $ProjectPath, '--remote', 'origin', '--push')
    Write-Host "Dépôt GitHub demandé : $repositoryName ($normalizedVisibility)" -ForegroundColor Cyan
    Write-Host "Commande exécutée : $($gitHubCliCommand.CommandName) $($ghArguments -join ' ')" -ForegroundColor DarkCyan
    $result = Invoke-GitHubCliCommandCapture -Arguments $ghArguments -WaitMessage 'Création du dépôt GitHub en cours'

    if ($null -eq $result) {
        throw "GitHub CLI 'gh' est introuvable."
    }

    foreach ($outputLine in $result.OutputLines) {
        if (-not [string]::IsNullOrWhiteSpace("$outputLine")) {
            Write-Host $outputLine
        }
    }

    if (-not $result.Success) {
        if (-not [string]::IsNullOrWhiteSpace($result.ErrorMessage)) {
            throw "Impossible de créer le dépôt GitHub '$repositoryName' : $($result.ErrorMessage)"
        }

        throw "Impossible de créer le dépôt GitHub '$repositoryName'."
    }

    Write-Host "Dépôt GitHub créé : $repositoryName" -ForegroundColor Green
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
                UseExistingProject = $false
                ProjectName = $resolvedProjectName
                ProjectPath = $projectPath
            }
        }

        $action = Read-ExistingProjectAction -ProjectName $resolvedProjectName -ProjectPath $projectPath

        if ($action -eq 'Cancel') {
            Write-Host 'Aucune modification effectuée.' -ForegroundColor Yellow
            return [PSCustomObject]@{
                Cancelled = $true
                UseExistingProject = $false
                ProjectName = $resolvedProjectName
                ProjectPath = $projectPath
            }
        }

        if ($action -eq 'Update') {
            return [PSCustomObject]@{
                Cancelled = $false
                UseExistingProject = $true
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

function Get-PythonRequirementsFileName {
    param(
        [datetime] $Date = (Get-Date)
    )

    return ('{0:yyyy-MM-dd}requirements.txt' -f $Date)
}

function Get-NormalizedPythonDistributionName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectName
    )

    $asciiFriendlyName = (Get-TextWithoutDiacritics -Text $ProjectName).ToLowerInvariant()
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

    $projectLabel = [System.Text.RegularExpressions.Regex]::Replace((Get-TextWithoutDiacritics -Text $ProjectName), '[^A-Za-z0-9]+', '')
    if ([string]::IsNullOrWhiteSpace($projectLabel)) {
        return 'venvProjet'
    }

    return "venv$projectLabel"
}

function Get-NormalizedDjangoProjectName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectName
    )

    $distributionName = Get-NormalizedPythonDistributionName -ProjectName $ProjectName
    $djangoProjectName = $distributionName.Replace('-', '_').Replace('.', '_')
    $djangoProjectName = [System.Text.RegularExpressions.Regex]::Replace($djangoProjectName, '[^a-zA-Z0-9_]', '_')
    $djangoProjectName = [System.Text.RegularExpressions.Regex]::Replace($djangoProjectName, '_{2,}', '_').Trim('_')

    if ([string]::IsNullOrWhiteSpace($djangoProjectName)) {
        return 'mon_projet_django'
    }

    if ($djangoProjectName -notmatch '^[A-Za-z_]') {
        $djangoProjectName = "projet_$djangoProjectName"
    }

    return $djangoProjectName.ToLowerInvariant()
}

function Test-DjangoProjectNameValidity {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $ProjectName
    )

    $normalizedProjectName = if ($null -eq $ProjectName) { '' } else { $ProjectName.Trim() }
    if ([string]::IsNullOrWhiteSpace($normalizedProjectName)) {
        return $false
    }

    return ($normalizedProjectName -match '^[A-Za-z_][A-Za-z0-9_]*$')
}

function Read-DjangoProjectName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $DefaultProjectName
    )

    while ($true) {
        $projectName = Read-Host "Nom du projet Django interne (Entrée = $DefaultProjectName)"
        if ([string]::IsNullOrWhiteSpace($projectName)) {
            return $DefaultProjectName
        }

        $normalizedProjectName = $projectName.Trim()
        if (Test-DjangoProjectNameValidity -ProjectName $normalizedProjectName) {
            return $normalizedProjectName
        }

        Write-Host 'Le nom du projet Django doit commencer par une lettre ou "_" et ne contenir que des lettres, chiffres ou "_".' -ForegroundColor Yellow
    }
}

function Get-PythonProjectReadmeContent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectName,

        [bool] $HasVirtualEnvironment = $false
    )

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
        ''
    )

    $supplementContent = Get-PythonProjectReadmeSupplementContent -ProjectName $ProjectName -HasVirtualEnvironment $HasVirtualEnvironment
    $supplementLines = @(($supplementContent -replace "`r`n", "`n").TrimEnd("`n").Split("`n"))
    foreach ($supplementLine in $supplementLines) {
        $contentLines += $supplementLine
    }

    $contentLines += @(
        '',
        '## Notes',
        '',
        '- Le code du projet peut être ajouté ici.'
    )

    return (($contentLines -join [Environment]::NewLine) + [Environment]::NewLine)
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

    $content = Get-PythonProjectReadmeContent -ProjectName $ProjectName -HasVirtualEnvironment $HasVirtualEnvironment
    Write-Utf8TextFile -Path $readmePath -Content $content
    Write-Host "README créé : $readmePath" -ForegroundColor Green
    return $readmePath
}

function Get-PythonProjectRequirementsContent {
    $contentLines = @(
        '# Dépendances Python du projet',
        '# Ajoutez une dépendance par ligne, par exemple :',
        '# requests==2.32.3'
    )

    return (($contentLines -join [Environment]::NewLine) + [Environment]::NewLine)
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

    $content = Get-PythonProjectRequirementsContent
    Write-Utf8TextFile -Path $requirementsPath -Content $content
    Write-Host "Fichier requirements créé : $requirementsPath" -ForegroundColor Green
    return $requirementsPath
}

function Get-LatestPythonProjectRequirementsFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    $datedRequirementsFiles = @(Get-PythonProjectDatedRequirementsFiles -ProjectPath $ProjectPath)
    if ($datedRequirementsFiles.Count -eq 0) {
        return New-PythonProjectRequirementsFile -ProjectPath $ProjectPath
    }

    return ($datedRequirementsFiles | Sort-Object Name -Descending | Select-Object -First 1).FullName
}

function Update-PythonRequirementsWithPinnedPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $PackageName,

        [Parameter(Mandatory = $true)]
        [string] $Version
    )

    $requirementsPath = Get-LatestPythonProjectRequirementsFilePath -ProjectPath $ProjectPath
    $normalizedPackageName = $PackageName.Trim()
    $normalizedVersion = $Version.Trim()
    $packagePattern = '(?im)^\s*' + [regex]::Escape($normalizedPackageName) + '\s*==\s*([^\s#]+)\s*$'
    $expectedLine = "$normalizedPackageName==$normalizedVersion"
    $content = [System.IO.File]::ReadAllText($requirementsPath, [System.Text.Encoding]::UTF8)

    if ($content -match $packagePattern) {
        $updatedContent = [regex]::Replace($content, $packagePattern, $expectedLine)
    }
    else {
        $trimmedContent = $content.TrimEnd("`r", "`n")
        if (-not [string]::IsNullOrWhiteSpace($trimmedContent)) {
            $updatedContent = $trimmedContent + [Environment]::NewLine + $expectedLine + [Environment]::NewLine
        }
        else {
            $updatedContent = $expectedLine + [Environment]::NewLine
        }
    }

    if ($updatedContent -ne $content) {
        Write-Utf8TextFile -Path $requirementsPath -Content $updatedContent
        Write-Host "requirements mis à jour : $requirementsPath" -ForegroundColor Green
    }
    else {
        Write-Host "requirements déjà à jour : $requirementsPath" -ForegroundColor Yellow
    }

    return $requirementsPath
}

function Update-PythonProjectPyprojectDependencies {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $PackageName,

        [Parameter(Mandatory = $true)]
        [string] $Version
    )

    $pyprojectPath = Join-Path -Path $ProjectPath -ChildPath 'pyproject.toml'
    if (-not (Test-Path -LiteralPath $pyprojectPath)) {
        return $null
    }

    $normalizedPackageName = $PackageName.Trim()
    $normalizedVersion = $Version.Trim()
    $expectedDependency = '"' + $normalizedPackageName + '==' + $normalizedVersion + '"'
    $content = [System.IO.File]::ReadAllText($pyprojectPath, [System.Text.Encoding]::UTF8)
    $dependencyArrayMatch = [regex]::Match($content, '(?ms)^\s*dependencies\s*=\s*\[(.*?)\]\s*$')
    if (-not $dependencyArrayMatch.Success) {
        return $pyprojectPath
    }

    $currentBlock = $dependencyArrayMatch.Groups[1].Value
    if ($currentBlock -match ('(?i)"' + [regex]::Escape($normalizedPackageName) + '==[^"]+"')) {
        $updatedBlock = [regex]::Replace($currentBlock, '(?i)"' + [regex]::Escape($normalizedPackageName) + '==[^"]+"', $expectedDependency)
    }
    elseif ([string]::IsNullOrWhiteSpace($currentBlock.Trim())) {
        $updatedBlock = $expectedDependency
    }
    else {
        $trimmedBlock = $currentBlock.Trim()
        $updatedBlock = $trimmedBlock.TrimEnd() + ', ' + $expectedDependency
    }

    $updatedContent = $content.Substring(0, $dependencyArrayMatch.Groups[1].Index) + $updatedBlock + $content.Substring($dependencyArrayMatch.Groups[1].Index + $dependencyArrayMatch.Groups[1].Length)
    if ($updatedContent -ne $content) {
        Write-Utf8TextFile -Path $pyprojectPath -Content $updatedContent
        Write-Host "pyproject.toml dépendances mises à jour : $pyprojectPath" -ForegroundColor Green
    }
    else {
        Write-Host "pyproject.toml dépendances déjà à jour : $pyprojectPath" -ForegroundColor Yellow
    }

    return $pyprojectPath
}

function Get-AvailableDjangoPackageVersions {
    $packageInfoUrl = 'https://pypi.org/pypi/Django/json'

    try {
        Write-StepInfo 'Recherche des versions Django téléchargeables...'
        $response = Invoke-RestMethod -Uri $packageInfoUrl -Method Get -TimeoutSec 20
    }
    catch {
        throw "Impossible de récupérer la liste des versions Django téléchargeables : $($_.Exception.Message)"
    }

    $versions = [System.Collections.Generic.List[string]]::new()
    foreach ($releaseProperty in $response.releases.PSObject.Properties) {
        $versionText = "$($releaseProperty.Name)".Trim()
        if ($versionText -notmatch '^\d+(?:\.\d+){1,2}$') {
            continue
        }

        $releaseFiles = @($releaseProperty.Value)
        if ($releaseFiles.Count -eq 0) {
            continue
        }

        if ($versions -notcontains $versionText) {
            $versions.Add($versionText)
        }
    }

    return @(
        $versions.ToArray() |
            Sort-Object -Descending -Property @{ Expression = { Get-VersionSortValue -Text $_ } }
    )
}

function Read-DjangoVersionSelection {
    param(
        [string[]] $AvailableVersions = @()
    )

    $versionEntries = @($AvailableVersions | Select-Object -First 15)
    if ($versionEntries.Count -eq 0) {
        throw "Aucune version Django téléchargeable n'a été trouvée."
    }

    Write-Host 'Versions Django téléchargeables :' -ForegroundColor Cyan
    for ($index = 0; $index -lt $versionEntries.Count; $index++) {
        $versionText = "$($versionEntries[$index])"
        $ltsLabel = if ($versionText -match '^\d+\.2(?:\.|$)') { ' [LTS]' } else { '' }
        Write-Host "$($index + 1). Django $versionText$ltsLabel"
    }

    while ($true) {
        $selectionText = Read-Host 'Version Django à installer (Entrée = 1 ou numéro)'
        if ([string]::IsNullOrWhiteSpace($selectionText)) {
            return $versionEntries[0]
        }

        $selectionNumber = 0
        if ([int]::TryParse($selectionText.Trim(), [ref] $selectionNumber) -and $selectionNumber -ge 1 -and $selectionNumber -le $versionEntries.Count) {
            return $versionEntries[$selectionNumber - 1]
        }

        Write-Host "Choix invalide. Saisissez un numéro entre 1 et $($versionEntries.Count)." -ForegroundColor Yellow
    }
}

function Install-DjangoInVirtualEnvironment {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $DjangoVersion
    )

    $venvPythonPath = Join-Path -Path $ProjectPath -ChildPath '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPythonPath)) {
        throw "Le Python du venv est introuvable : $venvPythonPath"
    }

    Write-Host "Installation de Django $DjangoVersion dans le venv..." -ForegroundColor Cyan
    Write-Host "Commande exécutée : $venvPythonPath -m pip install Django==$DjangoVersion" -ForegroundColor DarkCyan
    $installResult = Invoke-ExternalExecutableCapture `
        -ExecutablePath $venvPythonPath `
        -Arguments @('-m', 'pip', 'install', "Django==$DjangoVersion") `
        -WaitMessage "Installation de Django $DjangoVersion en cours"

    foreach ($outputLine in @($installResult.OutputLines)) {
        if (-not [string]::IsNullOrWhiteSpace("$outputLine")) {
            Write-Host $outputLine
        }
    }

    if (-not $installResult.Success) {
        if (-not [string]::IsNullOrWhiteSpace($installResult.ErrorMessage)) {
            throw "Impossible d'installer Django $DjangoVersion dans le venv : $($installResult.ErrorMessage)"
        }

        throw "Impossible d'installer Django $DjangoVersion dans le venv."
    }

    Update-PythonRequirementsWithPinnedPackage -ProjectPath $ProjectPath -PackageName 'Django' -Version $DjangoVersion | Out-Null
    Update-PythonProjectPyprojectDependencies -ProjectPath $ProjectPath -PackageName 'Django' -Version $DjangoVersion | Out-Null
    Write-Host "Django $DjangoVersion installé dans le venv." -ForegroundColor Green
}

function New-DjangoProjectStructure {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $DjangoProjectName
    )

    $managePyPath = Join-Path -Path $ProjectPath -ChildPath 'manage.py'
    $djangoModulePath = Join-Path -Path $ProjectPath -ChildPath $DjangoProjectName
    if ((Test-Path -LiteralPath $managePyPath) -or (Test-Path -LiteralPath $djangoModulePath)) {
        Write-Host 'Structure Django déjà présente : startproject ignoré.' -ForegroundColor Yellow
        return [PSCustomObject]@{
            Success = $true
            RequiresAnotherName = $false
            ErrorMessage = ''
        }
    }

    $venvPythonPath = Join-Path -Path $ProjectPath -ChildPath '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPythonPath)) {
        throw "Le Python du venv est introuvable : $venvPythonPath"
    }

    Write-Host "Création de la structure Django : $DjangoProjectName" -ForegroundColor Cyan
    Write-Host "Commande exécutée : $venvPythonPath -m django startproject $DjangoProjectName ." -ForegroundColor DarkCyan
    $previousLocation = $null
    try {
        $previousLocation = Get-Location
    }
    catch {
        $previousLocation = $null
    }

    try {
        Set-Location -LiteralPath $ProjectPath
        $startProjectResult = Invoke-ExternalExecutableCapture `
            -ExecutablePath $venvPythonPath `
            -Arguments @('-m', 'django', 'startproject', $DjangoProjectName, '.') `
            -WaitMessage "Création du projet Django $DjangoProjectName en cours"
    }
    finally {
        if ($null -ne $previousLocation) {
            Set-Location -LiteralPath $previousLocation.Path
        }
    }

    foreach ($outputLine in @($startProjectResult.OutputLines)) {
        if (-not [string]::IsNullOrWhiteSpace("$outputLine")) {
            Write-Host $outputLine
        }
    }

    if (-not $startProjectResult.Success) {
        $errorDetails = ''
        if (-not [string]::IsNullOrWhiteSpace($startProjectResult.ErrorMessage)) {
            $errorDetails = $startProjectResult.ErrorMessage
        }
        else {
            $errorDetails = (@($startProjectResult.OutputLines) -join ' ').Trim()
        }

        $requiresAnotherName = ($errorDetails -match '(?i)cannot be used as a project name|conflicts with the name of an existing Python module')
        return [PSCustomObject]@{
            Success = $false
            RequiresAnotherName = $requiresAnotherName
            ErrorMessage = $errorDetails
        }
    }

    Write-Host "Structure Django créée : $ProjectPath" -ForegroundColor Green
    return [PSCustomObject]@{
        Success = $true
        RequiresAnotherName = $false
        ErrorMessage = ''
    }
}

function Ensure-DjangoProjectStructure {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $DefaultDjangoProjectName
    )

    $currentDefaultProjectName = $DefaultDjangoProjectName
    while ($true) {
        $selectedDjangoProjectName = Read-DjangoProjectName -DefaultProjectName $currentDefaultProjectName
        $creationResult = New-DjangoProjectStructure -ProjectPath $ProjectPath -DjangoProjectName $selectedDjangoProjectName
        if ($creationResult.Success) {
            return $selectedDjangoProjectName
        }

        if ($creationResult.RequiresAnotherName) {
            Write-Host "Le nom Django '$selectedDjangoProjectName' ne peut pas être utilisé ici. Choisissez un autre nom." -ForegroundColor Yellow
            if (-not [string]::IsNullOrWhiteSpace($creationResult.ErrorMessage)) {
                Write-Host $creationResult.ErrorMessage -ForegroundColor DarkYellow
            }

            $currentDefaultProjectName = "${selectedDjangoProjectName}_project"
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace($creationResult.ErrorMessage)) {
            throw "Impossible de créer la structure Django '$selectedDjangoProjectName' : $($creationResult.ErrorMessage)"
        }

        throw "Impossible de créer la structure Django '$selectedDjangoProjectName'."
    }
}

function Update-DjangoProjectSettingsFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $DjangoProjectName,

        [Parameter(Mandatory = $true)]
        [string] $LanguageCode,

        [Parameter(Mandatory = $true)]
        [string] $TimeZone
    )

    $settingsPath = Join-Path -Path (Join-Path -Path $ProjectPath -ChildPath $DjangoProjectName) -ChildPath 'settings.py'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        Write-Host "settings.py introuvable : $settingsPath" -ForegroundColor Yellow
        return $null
    }

    $settingsContent = [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8)
    $updatedSettingsContent = $settingsContent
    $updatedSettingsContent = [regex]::Replace($updatedSettingsContent, '(?m)^\s*LANGUAGE_CODE\s*=\s*["''][^"'']+["'']\s*$', "LANGUAGE_CODE = '$LanguageCode'")
    $updatedSettingsContent = [regex]::Replace($updatedSettingsContent, '(?m)^\s*TIME_ZONE\s*=\s*["''][^"'']+["'']\s*$', "TIME_ZONE = '$TimeZone'")

    if ($updatedSettingsContent -ne $settingsContent) {
        Write-Utf8TextFile -Path $settingsPath -Content $updatedSettingsContent
        Write-Host "settings.py mis à jour : $settingsPath" -ForegroundColor Green
    }
    else {
        Write-Host "settings.py déjà à jour : $settingsPath" -ForegroundColor Yellow
    }

    return $settingsPath
}

function Get-NormalizedGitHubRepositoryName {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectName
    )

    $asciiFriendlyName = (Get-TextWithoutDiacritics -Text $ProjectName).ToLowerInvariant()
    $repositoryName = [System.Text.RegularExpressions.Regex]::Replace($asciiFriendlyName, '[^a-z0-9._-]+', '-')
    $repositoryName = [System.Text.RegularExpressions.Regex]::Replace($repositoryName, '-{2,}', '-').Trim('-')

    if ([string]::IsNullOrWhiteSpace($repositoryName)) {
        return 'nouveau-projet'
    }

    return $repositoryName
}

function Get-RecommendedPythonVersionRequestFromVersionText {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $VersionText
    )

    $normalizedVersionText = if ($null -eq $VersionText) { '' } else { $VersionText.Trim() }
    if ([string]::IsNullOrWhiteSpace($normalizedVersionText)) {
        return $null
    }

    $versionMatch = [System.Text.RegularExpressions.Regex]::Match($normalizedVersionText, '\d+(?:\.\d+)+')
    if (-not $versionMatch.Success) {
        return $null
    }

    $versionParts = @($versionMatch.Value.Split('.'))
    if ($versionParts.Count -ge 2) {
        return "$($versionParts[0]).$($versionParts[1])"
    }

    return $versionParts[0]
}

function Get-PythonRequiresVersionConstraint {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $RecommendedVersionRequest
    )

    $normalizedRecommendedVersionRequest = Get-RecommendedPythonVersionRequestFromVersionText -VersionText $RecommendedVersionRequest
    if ([string]::IsNullOrWhiteSpace("$normalizedRecommendedVersionRequest")) {
        return $null
    }

    $versionParts = @($normalizedRecommendedVersionRequest.Split('.'))
    if ($versionParts.Count -lt 2) {
        return ">=${normalizedRecommendedVersionRequest}"
    }

    $majorVersion = [int] $versionParts[0]
    $minorVersion = [int] $versionParts[1]
    $nextMinorVersion = $minorVersion + 1
    return ">=${majorVersion}.${minorVersion},<${majorVersion}.${nextMinorVersion}"
}

function Get-RecommendedPythonVersionRequestFromPyprojectPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $PyprojectPath
    )

    if (-not (Test-Path -LiteralPath $PyprojectPath)) {
        return $null
    }

    $content = [System.IO.File]::ReadAllText($PyprojectPath, [System.Text.Encoding]::UTF8)
    $requiresPythonMatch = [System.Text.RegularExpressions.Regex]::Match($content, '(?m)^\s*requires-python\s*=\s*["'']([^"'']+)["'']')
    if (-not $requiresPythonMatch.Success) {
        return $null
    }

    return Get-RecommendedPythonVersionRequestFromVersionText -VersionText $requiresPythonMatch.Groups[1].Value
}

function Get-RecommendedPythonVersionInfoFromProjectPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    $pyprojectPath = Join-Path -Path $ProjectPath -ChildPath 'pyproject.toml'
    $recommendedFromPyproject = Get-RecommendedPythonVersionRequestFromPyprojectPath -PyprojectPath $pyprojectPath
    if (-not [string]::IsNullOrWhiteSpace("$recommendedFromPyproject")) {
        return [PSCustomObject]@{
            VersionRequest = $recommendedFromPyproject
            Source = 'pyproject'
        }
    }

    $venvScriptsPath = Join-Path -Path $ProjectPath -ChildPath '.venv\Scripts'
    if (-not (Test-Path -LiteralPath $venvScriptsPath)) {
        return [PSCustomObject]@{
            VersionRequest = $null
            Source = $null
        }
    }

    try {
        $venvPythonExecutablePath = Get-PythonExecutablePathFromDirectory -DirectoryPath $venvScriptsPath
        $venvPythonVersion = Get-PythonVersionFromExecutablePath -PythonExecutablePath $venvPythonExecutablePath
        $recommendedFromVenv = Get-RecommendedPythonVersionRequestFromVersionText -VersionText $venvPythonVersion
        if (-not [string]::IsNullOrWhiteSpace("$recommendedFromVenv")) {
            return [PSCustomObject]@{
                VersionRequest = $recommendedFromVenv
                Source = 'venv'
            }
        }
    }
    catch {
    }

    return [PSCustomObject]@{
        VersionRequest = $null
        Source = $null
    }
}

function Test-PythonProjectPath {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath
    )

    if (Test-Path -LiteralPath (Join-Path -Path $ProjectPath -ChildPath 'pyproject.toml')) {
        return $true
    }

    if ((Get-ChildItem -LiteralPath $ProjectPath -Filter '*.py' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        return $true
    }

    if ((Get-ChildItem -LiteralPath $ProjectPath -Filter '*requirements.txt' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) {
        return $true
    }

    return $false
}

function Get-PythonProjectPyprojectContent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectName,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $RecommendedPythonVersionRequest = $null
    )

    $distributionName = Get-NormalizedPythonDistributionName -ProjectName $ProjectName
    $requiresPythonConstraint = Get-PythonRequiresVersionConstraint -RecommendedVersionRequest $RecommendedPythonVersionRequest
    $contentLines = @(
        '[project]',
        "name = ""$distributionName""",
        'version = "0.1.0"',
        "description = ""Projet Python $ProjectName""",
        'readme = "README.md"',
        $(if (-not [string]::IsNullOrWhiteSpace("$requiresPythonConstraint")) { "requires-python = ""$requiresPythonConstraint""" }),
        'dependencies = []',
        '',
        '[build-system]',
        'requires = ["setuptools>=61.0"]',
        'build-backend = "setuptools.build_meta"'
    ) | Where-Object { $_ -ne $null }

    return (($contentLines -join [Environment]::NewLine) + [Environment]::NewLine)
}

function New-PythonProjectPyprojectFile {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectPath,

        [Parameter(Mandatory = $true)]
        [string] $ProjectName,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $RecommendedPythonVersionRequest = $null
    )

    $pyprojectPath = Join-Path -Path $ProjectPath -ChildPath 'pyproject.toml'

    if (Test-Path -LiteralPath $pyprojectPath) {
        Write-Host "pyproject.toml déjà présent : $pyprojectPath" -ForegroundColor Yellow
        return $pyprojectPath
    }

    $content = Get-PythonProjectPyprojectContent `
        -ProjectName $ProjectName `
        -RecommendedPythonVersionRequest $RecommendedPythonVersionRequest
    Write-Utf8TextFile -Path $pyprojectPath -Content $content
    Write-Host "pyproject.toml créé : $pyprojectPath" -ForegroundColor Green
    return $pyprojectPath
}

function Get-ProjectGitIgnoreSections {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectType
    )

    $sections = [System.Collections.Generic.List[object]]::new()
    $sections.Add([PSCustomObject]@{
            Title = '# Fichiers système et temporaires'
            Lines = @('Thumbs.db', 'Desktop.ini', '*.tmp', '*.temp', '*.log')
        })
    $sections.Add([PSCustomObject]@{
            Title = '# Dossiers et fichiers locaux'
            Lines = @('.vscode/', '.idea/', '.env', '.env.*')
        })

    if (Test-PythonBasedProjectType -ProjectType $ProjectType) {
        $sections.Add([PSCustomObject]@{
                Title = '# Python'
                Lines = @('.venv/', 'cmdVenv.cmd', '__pycache__/', '*.pyc', '*.pyo', '*.pyd', '.pytest_cache/', '.mypy_cache/', '.ruff_cache/', 'build/', 'dist/', '*.egg-info/')
            })
    }

    return @($sections)
}

function Get-ProjectGitIgnoreContent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectType
    )

    $contentLines = [System.Collections.Generic.List[string]]::new()
    $sections = @(Get-ProjectGitIgnoreSections -ProjectType $ProjectType)

    for ($sectionIndex = 0; $sectionIndex -lt $sections.Count; $sectionIndex++) {
        $section = $sections[$sectionIndex]
        if ($sectionIndex -gt 0) {
            $contentLines.Add('')
        }

        $contentLines.Add($section.Title)
        foreach ($line in @($section.Lines)) {
            $contentLines.Add($line)
        }
    }

    return ((($contentLines.ToArray()) -join [Environment]::NewLine) + [Environment]::NewLine)
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

    $content = Get-ProjectGitIgnoreContent -ProjectType $ProjectType
    Write-Utf8TextFile -Path $gitIgnorePath -Content $content
    Write-Host ".gitignore créé : $gitIgnorePath" -ForegroundColor Green
    return $gitIgnorePath
}

function Get-PythonProjectCmdVenvLauncherContent {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ProjectName
    )

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

    return (($contentLines -join [Environment]::NewLine) + [Environment]::NewLine)
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

    $content = Get-PythonProjectCmdVenvLauncherContent -ProjectName $ProjectName
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

function Invoke-ExternalExecutablePassthrough {
    param(
        [Parameter(Mandatory = $true)]
        [string] $ExecutablePath,

        [string[]] $Arguments = @(),

        [string] $StartMessage = ''
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $hadNativeCommandPreference = $false
    $previousNativeCommandPreference = $null

    if (-not [string]::IsNullOrWhiteSpace($StartMessage)) {
        Write-StepInfo $StartMessage
    }

    try {
        $ErrorActionPreference = 'Continue'

        $nativeCommandPreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
        if ($null -ne $nativeCommandPreferenceVariable) {
            $hadNativeCommandPreference = $true
            $previousNativeCommandPreference = [bool] $nativeCommandPreferenceVariable.Value
            $script:PSNativeCommandUseErrorActionPreference = $false
        }

        & $ExecutablePath @Arguments
        $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference

        if ($hadNativeCommandPreference) {
            $script:PSNativeCommandUseErrorActionPreference = $previousNativeCommandPreference
        }
    }

    return ($exitCode -eq 0)
}

function Get-PreferredAvailableCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $CommandNames
    )

    foreach ($commandName in $CommandNames) {
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

function Get-PreferredPythonManagerCommand {
    return Get-PreferredAvailableCommand -CommandNames @('pymanager', 'py')
}

function Get-PymanagerCommand {
    return Get-PreferredAvailableCommand -CommandNames @('pymanager')
}

function Get-GitHubCliCommand {
    return Get-PreferredAvailableCommand -CommandNames @('gh')
}

function Get-WingetCommand {
    return Get-PreferredAvailableCommand -CommandNames @('winget')
}

function Get-GitCommand {
    return Get-PreferredAvailableCommand -CommandNames @('git')
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

function Invoke-GitHubCliCommandCapture {
    param(
        [string[]] $Arguments = @(),

        [string] $WaitMessage = ''
    )

    $command = Get-GitHubCliCommand
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

function Invoke-GitHubCliCommandPassthrough {
    param(
        [string[]] $Arguments = @(),

        [string] $StartMessage = ''
    )

    $command = Get-GitHubCliCommand
    if ($null -eq $command) {
        return $false
    }

    return Invoke-ExternalExecutablePassthrough `
        -ExecutablePath $command.CommandPath `
        -Arguments $Arguments `
        -StartMessage $StartMessage
}

function Invoke-GitCommandCapture {
    param(
        [string[]] $Arguments = @(),

        [string] $WaitMessage = ''
    )

    $command = Get-GitCommand
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

function Get-PythonVersionLabelText {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string] $VersionText
    )

    $normalizedVersionText = if ($null -eq $VersionText) { '' } else { $VersionText.Trim() }
    if ([string]::IsNullOrWhiteSpace($normalizedVersionText)) {
        return ''
    }

    $versionMatch = [System.Text.RegularExpressions.Regex]::Match($normalizedVersionText, '\d+(?:\.\d+)+')
    if ($versionMatch.Success) {
        return $versionMatch.Value
    }

    return $normalizedVersionText
}

function Get-LatestStablePythonVersionHint {
    param(
        [AllowNull()]
        [object[]] $KnownPythonInterpreters = @(),

        [AllowNull()]
        [object[]] $InstallableRuntimes = @()
    )

    $versionCandidates = [System.Collections.Generic.List[string]]::new()

    foreach ($knownInterpreter in @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $KnownPythonInterpreters)) {
        $versionLabel = Get-PythonVersionLabelText -VersionText "$($knownInterpreter.Version)"
        if (-not [string]::IsNullOrWhiteSpace($versionLabel) -and $versionCandidates -notcontains $versionLabel) {
            $versionCandidates.Add($versionLabel)
        }
    }

    foreach ($installableRuntime in @(ConvertTo-CanonicalPythonInstallableRuntimeEntries -Entries $InstallableRuntimes)) {
        $versionLabel = Get-PythonVersionLabelText -VersionText "$($installableRuntime.Version)"
        if (-not [string]::IsNullOrWhiteSpace($versionLabel) -and $versionCandidates -notcontains $versionLabel) {
            $versionCandidates.Add($versionLabel)
        }
    }

    if ($versionCandidates.Count -eq 0) {
        return $null
    }

    return @(
        $versionCandidates.ToArray() |
            Sort-Object -Descending -Property @{ Expression = { Get-VersionSortValue -Text $_ } }
    ) | Select-Object -First 1
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

    return ,@(
        $combinedMatches.ToArray() |
            Sort-Object `
                @{ Expression = {
                        if ($_.PSObject.Properties.Match('ExecutablePath').Count -gt 0) { 0 } else { 1 }
                    }
                }, `
                @{ Expression = {
                        if ($_.PSObject.Properties.Match('ExecutablePath').Count -gt 0) {
                            Get-VersionSortValue -Text "$($_.Version)"
                        }
                        else {
                            Get-VersionSortValue -Text "$($_.Version)"
                        }
                    }; Descending = $true
                }, `
                @{ Expression = {
                        if ($_.PSObject.Properties.Match('ExecutablePath').Count -gt 0) {
                            "$($_.ExecutablePath)".ToLowerInvariant()
                        }
                        else {
                            "$($_.InstallTag)".ToLowerInvariant()
                        }
                    }
                }
    )
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

function Resolve-PythonReferenceChoiceForVersionRequest {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Matches
    )

    $selection = Read-PythonReferenceChoice -Matches $Matches

    if ($selection.Mode -eq 'RetryVersionRequest') {
        return [PSCustomObject]@{
            Selection = $null
            NextVersionRequest = $null
            ReturnToPreviousStep = $true
        }
    }

    return [PSCustomObject]@{
        Selection = $selection
        NextVersionRequest = $null
        ReturnToPreviousStep = $false
    }
}

function Read-PythonReferenceChoice {
    param(
        [Parameter(Mandatory = $true)]
        [object[]] $Matches
    )

    while ($true) {
        $answer = Read-Host 'Référence Python à utiliser (Entrée = 1, numéro, r = retour ou chemin Python)'

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return New-PythonReferenceSelection -Reference $Matches[0]
        }

        if ($answer.Trim() -match '^(r|retour|back|precedent|précédent)$') {
            return [PSCustomObject]@{
                Mode = 'RetryVersionRequest'
                Interpreter = $null
                InstallableRuntime = $null
                PythonExecutablePath = $null
                VersionRequest = $null
            }
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
            Write-Host 'Saisissez un numéro valide, r pour revenir ou le chemin complet d''un Python déjà installé.' -ForegroundColor Yellow
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
            -AskInstallGitHubCliWhenMissing $ProjectConfig.AskInstallGitHubCliWhenMissing `
            -AskInstallPythonManagerWhenMissing $ProjectConfig.AskInstallPythonManagerWhenMissing `
            -DefaultGitHubRepositoryVisibility $ProjectConfig.DefaultGitHubRepositoryVisibility `
            -DefaultDjangoLanguageCode $ProjectConfig.DefaultDjangoLanguageCode `
            -DefaultDjangoTimeZone $ProjectConfig.DefaultDjangoTimeZone `
            -GitHubLogin $ProjectConfig.GitHubLogin `
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
        -AskInstallGitHubCliWhenMissing $ProjectConfig.AskInstallGitHubCliWhenMissing `
        -AskInstallPythonManagerWhenMissing $ProjectConfig.AskInstallPythonManagerWhenMissing `
        -DefaultGitHubRepositoryVisibility $ProjectConfig.DefaultGitHubRepositoryVisibility `
        -DefaultDjangoLanguageCode $ProjectConfig.DefaultDjangoLanguageCode `
        -DefaultDjangoTimeZone $ProjectConfig.DefaultDjangoTimeZone `
        -GitHubLogin $ProjectConfig.GitHubLogin `
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
        [object[]] $KnownPythonInterpreters,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $PreferredVersionRequest = $null
    )

    $interpreterEntries = @(ConvertTo-CanonicalPythonInterpreterEntries -Entries $KnownPythonInterpreters)
    $normalizedPreferredVersionRequest = if ([string]::IsNullOrWhiteSpace("$PreferredVersionRequest")) {
        $null
    }
    else {
        Get-RecommendedPythonVersionRequestFromVersionText -VersionText $PreferredVersionRequest
    }

    if ($interpreterEntries.Count -eq 0) {
        Write-Host 'Aucune version Python connue n''a été trouvée via pymanager ou la configuration.' -ForegroundColor Yellow
    }

    $latestStablePythonVersionHint = Get-LatestStablePythonVersionHint -KnownPythonInterpreters $interpreterEntries
    $initialInstallableLookup = $null
    if ([string]::IsNullOrWhiteSpace("$latestStablePythonVersionHint")) {
        $initialInstallableLookup = Get-PythonInstallableRuntimeEntries -VersionRequest ''
        $latestStablePythonVersionHint = Get-LatestStablePythonVersionHint `
            -KnownPythonInterpreters $interpreterEntries `
            -InstallableRuntimes @($initialInstallableLookup.Entries)
    }

    while ($true) {
        $versionPrompt = if (-not [string]::IsNullOrWhiteSpace("$normalizedPreferredVersionRequest")) {
            if ($interpreterEntries.Count -gt 0) {
                if (-not [string]::IsNullOrWhiteSpace("$latestStablePythonVersionHint")) {
                    "Version Python pour le venv (exemple 3.14, Entrée = $normalizedPreferredVersionRequest recommandé, dernière stable : $latestStablePythonVersionHint)"
                }
                else {
                    "Version Python pour le venv (exemple 3.14, Entrée = $normalizedPreferredVersionRequest recommandé)"
                }
            }
            else {
                if (-not [string]::IsNullOrWhiteSpace("$latestStablePythonVersionHint")) {
                    "Version Python pour le venv à installer (exemple 3.14, Entrée = $normalizedPreferredVersionRequest recommandé, dernière stable : $latestStablePythonVersionHint), ou chemin Python"
                }
                else {
                    "Version Python pour le venv à installer (exemple 3.14, Entrée = $normalizedPreferredVersionRequest recommandé), ou chemin Python"
                }
            }
        }
        elseif ($interpreterEntries.Count -gt 0) {
            if (-not [string]::IsNullOrWhiteSpace("$latestStablePythonVersionHint")) {
                "Version Python pour le venv (exemple 3.14, Entrée = versions connues et installables, dernière stable : $latestStablePythonVersionHint)"
            }
            else {
                'Version Python pour le venv (exemple 3.14, Entrée = versions connues et installables)'
            }
        }
        else {
            if (-not [string]::IsNullOrWhiteSpace("$latestStablePythonVersionHint")) {
                "Version Python pour le venv à installer (exemple 3.14, dernière stable : $latestStablePythonVersionHint), ou chemin Python"
            }
            else {
                'Version Python pour le venv à installer (exemple 3.14), ou chemin Python'
            }
        }

        $versionRequest = Read-Host $versionPrompt

        if ([string]::IsNullOrWhiteSpace($versionRequest)) {
            if (-not [string]::IsNullOrWhiteSpace("$normalizedPreferredVersionRequest")) {
                $versionRequest = $normalizedPreferredVersionRequest
            }
            else {
                $installableLookup = if ($null -ne $initialInstallableLookup) { $initialInstallableLookup } else { Get-PythonInstallableRuntimeEntries -VersionRequest '' }
                $initialInstallableLookup = $null
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
                    $choiceResolution = Resolve-PythonReferenceChoiceForVersionRequest -Matches $combinedMatches
                    if ($null -ne $choiceResolution.Selection) {
                        return $choiceResolution.Selection
                    }

                    if ($choiceResolution.ReturnToPreviousStep) {
                        continue
                    }
                    continue
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
            $installableLookup = Get-PythonInstallableRuntimeEntries -VersionRequest $normalizedVersionRequest
            $installableMatches = Get-PythonInstallableRuntimeMatchesByVersion `
                -VersionRequest $normalizedVersionRequest `
                -InstallableRuntimes @($installableLookup.Entries)

            if ($matches.ExactMatches.Count -gt 0 -or $installableMatches.ExactMatches.Count -gt 0) {
                $exactMatches = Get-CombinedPythonReferenceMatches `
                    -KnownMatches $matches.ExactMatches `
                    -InstallableMatches @($installableMatches.ExactMatches)

                if ($installableMatches.ExactMatches.Count -gt 0) {
                    Show-PythonReferenceMatches -Title "Références Python exactes et installables pour '$normalizedVersionRequest' :" -Matches $exactMatches
                }
                else {
                    Show-PythonReferenceMatches -Title "Références Python exactes pour '$normalizedVersionRequest' :" -Matches $exactMatches
                }

                $choiceResolution = Resolve-PythonReferenceChoiceForVersionRequest -Matches $exactMatches
                if ($null -ne $choiceResolution.Selection) {
                    return $choiceResolution.Selection
                }

                if ($choiceResolution.ReturnToPreviousStep) {
                    continue
                }
                continue
            }

            if ($matches.PartialMatches.Count -gt 0) {
                $combinedMatches = Get-CombinedPythonReferenceMatches `
                    -KnownMatches $matches.PartialMatches `
                    -InstallableMatches @($installableMatches.PartialMatches)

                if ($combinedMatches.Count -gt $matches.PartialMatches.Count) {
                    Show-PythonReferenceMatches -Title "Références Python compatibles et installables pour '$normalizedVersionRequest' :" -Matches $combinedMatches
                    $choiceResolution = Resolve-PythonReferenceChoiceForVersionRequest -Matches $combinedMatches
                    if ($null -ne $choiceResolution.Selection) {
                        return $choiceResolution.Selection
                    }

                    if ($choiceResolution.ReturnToPreviousStep) {
                        continue
                    }
                    continue
                }

                Show-PythonReferenceMatches -Title "Références Python compatibles pour '$normalizedVersionRequest' :" -Matches $matches.PartialMatches
                $choiceResolution = Resolve-PythonReferenceChoiceForVersionRequest -Matches $matches.PartialMatches
                if ($null -ne $choiceResolution.Selection) {
                    return $choiceResolution.Selection
                }

                if ($choiceResolution.ReturnToPreviousStep) {
                    continue
                }
                continue
            }
        }

        $installableLookup = Get-PythonInstallableRuntimeEntries -VersionRequest $normalizedVersionRequest
        $installableMatches = Get-PythonInstallableRuntimeMatchesByVersion `
            -VersionRequest $normalizedVersionRequest `
            -InstallableRuntimes @($installableLookup.Entries)
        $matchingInstallableEntries = @($installableMatches.ExactMatches + $installableMatches.PartialMatches)

        if ($matchingInstallableEntries.Count -gt 0) {
            Show-PythonReferenceMatches -Title "Références Python installables pour '$normalizedVersionRequest' :" -Matches $matchingInstallableEntries
            $choiceResolution = Resolve-PythonReferenceChoiceForVersionRequest -Matches $matchingInstallableEntries
            if ($null -ne $choiceResolution.Selection) {
                return $choiceResolution.Selection
            }

            if ($choiceResolution.ReturnToPreviousStep) {
                continue
            }
            continue
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
        [object] $ProjectConfig,

        [AllowNull()]
        [AllowEmptyString()]
        [string] $PreferredVersionRequest = $null
    )

    $selection = Read-PythonInterpreterSelection `
        -KnownPythonInterpreters $ProjectConfig.KnownPythonInterpreters `
        -PreferredVersionRequest $PreferredVersionRequest

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
    if (-not [string]::IsNullOrWhiteSpace("$PSScriptRoot")) {
        try {
            $script:OriginalLocation = Get-Location
        }
        catch {
            $script:OriginalLocation = $null
        }

        Set-Location -LiteralPath $PSScriptRoot
    }

    $projectConfig = Get-ProjectConfig -ConfigPath $ConfigPath -ConfigFileName $ConfigFileName
    $projectConfig = Ensure-PythonDepotPathConfiguration -ConfigPath $ConfigPath -ProjectConfig $projectConfig
    $pythonManagerAvailability = Ensure-PythonManagerAvailability -ConfigPath $ConfigPath -ProjectConfig $projectConfig
    $projectConfig = $pythonManagerAvailability.ProjectConfig
    $gitHubCliAvailability = Ensure-GitHubCliAvailability -ConfigPath $ConfigPath -ProjectConfig $projectConfig
    $projectConfig = $gitHubCliAvailability.ProjectConfig
    $projectConfig = Sync-GitHubLoginConfiguration -ConfigPath $ConfigPath -ProjectConfig $projectConfig

    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        $ProjectName = Read-ProjectName
    }

    $projectWasImportedFromGitHub = $false
    $projectWillUpdateExistingDirectory = $false
    $canCreateGitHubRepository = ($null -ne $gitHubCliAvailability.GitHubCliCommand)
    $projectPath = $null

    while ($true) {
        $projectTarget = Resolve-ProjectTarget -ProjectsRootPath $projectConfig.ProjectsRootPath -ProjectName $ProjectName

        if ($projectTarget.Cancelled) {
            break
        }

        $ProjectName = $projectTarget.ProjectName
        $projectPath = $projectTarget.ProjectPath
        $projectWillUpdateExistingDirectory = [bool] $projectTarget.UseExistingProject

        if ($projectWillUpdateExistingDirectory) {
            break
        }

        if (-not $canCreateGitHubRepository) {
            break
        }

        if (-not (Ensure-GitHubCliAuthentication)) {
            $canCreateGitHubRepository = $false
            break
        }

        $existingRepositoryInfo = Get-GitHubRepositoryInfoForProjectName -ProjectName $ProjectName
        if (-not $existingRepositoryInfo.Exists) {
            break
        }

        $gitHubExistingRepositoryAction = Read-ExistingGitHubRepositoryAction `
            -RepositoryFullName $existingRepositoryInfo.RepositoryFullName `
            -RepositoryUrl $existingRepositoryInfo.RepositoryUrl

        switch ($gitHubExistingRepositoryAction) {
            'Import' {
                Import-GitHubRepositoryToProjectPath `
                    -RepositoryFullName $existingRepositoryInfo.RepositoryFullName `
                    -ProjectPath $projectPath
                $projectWasImportedFromGitHub = $true
                $canCreateGitHubRepository = $false
                break
            }
            'Rename' {
                $ProjectName = Read-ProjectName
                continue
            }
            'Cancel' {
                Write-Host 'Aucune modification effectuée.' -ForegroundColor Yellow
                $projectPath = $null
                break
            }
        }

        if ($projectWasImportedFromGitHub -or $null -eq $projectPath) {
            break
        }
    }

    if ($projectWasImportedFromGitHub -and $null -ne $projectPath) {
        $importedProjectSetupResult = Initialize-ImportedPythonProjectEnvironment `
            -ConfigPath $ConfigPath `
            -ProjectConfig $projectConfig `
            -ProjectPath $projectPath `
            -ProjectName $ProjectName
        $projectConfig = $importedProjectSetupResult.ProjectConfig
        Sync-ProjectSetupResultToGitHubIfNeeded `
            -ProjectPath $projectPath `
            -ProjectSetupResult $importedProjectSetupResult
    }

    if ($projectWillUpdateExistingDirectory -and $null -ne $projectPath -and -not $projectWasImportedFromGitHub) {
        $existingProjectUpdateResult = Update-ExistingProjectSetup `
            -ConfigPath $ConfigPath `
            -ProjectConfig $projectConfig `
            -ProjectPath $projectPath `
            -ProjectName $ProjectName `
            -ProjectType $ProjectType `
            -CustomProjectType $CustomProjectType
        $projectConfig = $existingProjectUpdateResult.ProjectConfig
        Sync-ProjectSetupResultToGitHubIfNeeded `
            -ProjectPath $projectPath `
            -ProjectSetupResult $existingProjectUpdateResult
    }

    if ($null -ne $projectPath -and -not $projectWasImportedFromGitHub -and -not $projectWillUpdateExistingDirectory) {
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

        if (Test-PythonBasedProjectType -ProjectType $ProjectType) {
            $createPythonVenv = $false
            $selectedPythonVersionRequest = $null
            $selectedDjangoVersion = $null
            $createPythonVenv = Read-CreatePythonVenv -DefaultCreatePythonVenv $projectConfig.DefaultCreatePythonVenv

            if ($createPythonVenv) {
                Write-StepInfo 'Recherche des versions Python connues...'
                $projectConfig = Sync-ProjectPythonInterpreters -ConfigPath $ConfigPath -ProjectConfig $projectConfig
                $pythonSelection = Select-PythonInterpreterForVenv -ConfigPath $ConfigPath -ProjectConfig $projectConfig
                $projectConfig = $pythonSelection.ProjectConfig
                $selectedPythonVersionRequest = Get-RecommendedPythonVersionRequestFromVersionText -VersionText $pythonSelection.Interpreter.Version
                New-PythonVirtualEnvironment -ProjectPath $projectPath -PythonInterpreter $pythonSelection.Interpreter | Out-Null
            }

            New-PythonProjectReadme `
                -ProjectPath $projectPath `
                -ProjectName $ProjectName `
                -HasVirtualEnvironment $createPythonVenv | Out-Null

            New-PythonProjectPyprojectFile `
                -ProjectPath $projectPath `
                -ProjectName $ProjectName `
                -RecommendedPythonVersionRequest $selectedPythonVersionRequest | Out-Null

            New-PythonProjectRequirementsFile -ProjectPath $projectPath | Out-Null
            New-PythonProjectCmdVenvLauncher `
                -ProjectPath $projectPath `
                -ProjectName $ProjectName | Out-Null

            if ($ProjectType -eq 'django') {
                if ($createPythonVenv) {
                    $availableDjangoVersions = @(Get-AvailableDjangoPackageVersions)
                    $selectedDjangoVersion = Read-DjangoVersionSelection -AvailableVersions $availableDjangoVersions
                    Install-DjangoInVirtualEnvironment -ProjectPath $projectPath -DjangoVersion $selectedDjangoVersion | Out-Null
                    $defaultDjangoProjectName = Get-NormalizedDjangoProjectName -ProjectName $ProjectName
                    $selectedDjangoProjectName = Ensure-DjangoProjectStructure -ProjectPath $projectPath -DefaultDjangoProjectName $defaultDjangoProjectName
                    Update-DjangoProjectSettingsFile `
                        -ProjectPath $projectPath `
                        -DjangoProjectName $selectedDjangoProjectName `
                        -LanguageCode $projectConfig.DefaultDjangoLanguageCode `
                        -TimeZone $projectConfig.DefaultDjangoTimeZone | Out-Null
                }
                else {
                    Write-Host 'Aucun venv créé : l''installation automatique de Django est ignorée.' -ForegroundColor Yellow
                }
            }
        }

        if ($canCreateGitHubRepository) {
            $gitHubRepositoryVisibility = Read-GitHubRepositoryVisibilityChoice `
                -DefaultGitHubRepositoryVisibility $projectConfig.DefaultGitHubRepositoryVisibility

            if ($gitHubRepositoryVisibility -ne 'skip') {
                try {
                    New-GitHubRepositoryForProject `
                        -ProjectPath $projectPath `
                        -ProjectName $ProjectName `
                        -Visibility $gitHubRepositoryVisibility
                }
                catch {
                    Write-Host "Création GitHub ignorée : $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }
    }
}
catch {
    $scriptFailure = $_
    Write-Host "Erreur : $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    if ($null -ne $script:OriginalLocation) {
        try {
            Set-Location -LiteralPath $script:OriginalLocation.Path
        }
        catch {
            Write-Verbose "Impossible de restaurer le dossier courant : $($_.Exception.Message)"
        }
    }

    if (-not $NoPause) {
        Read-Host 'Appuyez sur Entrée pour fermer la fenêtre' | Out-Null
    }

    Restore-ConsoleEncoding
}

if ($null -ne $scriptFailure) {
    throw $scriptFailure
}
