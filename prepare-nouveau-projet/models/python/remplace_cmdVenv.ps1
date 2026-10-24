[CmdletBinding()]
param([switch] $SessionVenv)

$ErrorActionPreference = 'Stop'
$activation = Join-Path $PSScriptRoot '.venv\Scripts\Activate.ps1'
if (-not (Test-Path -LiteralPath $activation -PathType Leaf)) {
    throw "Aucun environnement Python trouvé. Relancez prepare-nouveau-projet.ps1 pour créer le venv. Chemin attendu : $activation"
}

if (-not $SessionVenv) {
    $executable = Join-Path $PSHOME 'powershell.exe'
    if (-not (Test-Path -LiteralPath $executable)) {
        $executable = Join-Path $PSHOME 'pwsh.exe'
    }
    & $executable -NoProfile -NoExit -File $PSCommandPath -SessionVenv
    return
}

Set-Location -LiteralPath $PSScriptRoot
. $activation
function global:prompt {
    "({{PYTHON_VENV_PROMPT_LABEL}}) $($executionContext.SessionState.Path.CurrentLocation)> "
}
