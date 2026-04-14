@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

if not exist ".venv\Scripts\activate.bat" (
    echo Erreur : aucun environnement virtuel Python n'a ete trouve dans ".venv".
    echo Relancez "prepare-nouveau-projet.ps1" ou creez ".venv" manuellement.
    pause
    exit /b 1
)

call ".venv\Scripts\activate.bat"
set "PROMPT=({{PYTHON_VENV_PROMPT_LABEL}}) $P$G"
cmd.exe
