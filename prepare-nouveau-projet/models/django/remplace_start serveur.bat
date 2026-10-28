@echo off
setlocal
chcp 65001 >nul

if /I not "%MACHINE%"=="dev" (
    echo Erreur : MACHINE doit valoir dev pour démarrer le serveur local.
    exit /b 1
)

set "PYTHON=%~dp0.venv\Scripts\python.exe"
set "DJANGO_DEBUG=true"
set "DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1"

if not exist "%PYTHON%" (
    echo Erreur : le venv est introuvable. Relancez prepare-nouveau-projet.ps1 pour le créer.
    exit /b 1
)

cd /d "%~dp0{{DJANGO_SITE_PATH}}"
if errorlevel 1 exit /b 1
if not exist "manage.py" (
    echo Erreur : manage.py est introuvable dans le dossier du site Django.
    exit /b 1
)

if "%~1"=="--verifier" goto verifier

echo Préparation de la base de données locale...
"%PYTHON%" manage.py migrate --noinput
if errorlevel 1 (
    echo Impossible de préparer la base de données. Démarrage annulé.
    exit /b 1
)

echo Démarrage du serveur local Django : http://127.0.0.1:8000/
echo Administration : http://127.0.0.1:8000/admin/
echo Pour arrêter le serveur, appuyez sur Ctrl+C.
"%PYTHON%" manage.py runserver 127.0.0.1:8000
exit /b %errorlevel%

:verifier
"%PYTHON%" manage.py check
exit /b %errorlevel%
