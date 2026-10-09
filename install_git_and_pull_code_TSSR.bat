@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Installation Git + depot codeTSSR
chcp 65001 >nul

set "REPO_URL=https://github.com/antares667367/codeTSSR.git"
set "DEFAULT_DIR=%USERPROFILE%\codeTSSR"

echo ============================================================
echo    Installation de Git et recuperation du depot codeTSSR
echo ============================================================
echo.

:: ---------------------------------------------------------------
:: 1. Verification de Git
:: ---------------------------------------------------------------
where git >nul 2>&1
if %errorlevel%==0 (
    for /f "delims=" %%v in ('git --version') do echo [OK] Git est deja installe : %%v
    goto :choix_dossier
)

echo [!] Git n'est pas installe sur cette machine.
echo.
choice /C ON /M "Voulez-vous installer Git maintenant (O = oui, N = non)"
if errorlevel 2 (
    echo Installation annulee. Fin du script.
    goto :fin
)

:: --- Tentative 1 : winget ---
where winget >nul 2>&1
if %errorlevel%==0 (
    echo.
    echo [..] Installation de Git via winget...
    winget install --id Git.Git -e --source winget --accept-package-agreements --accept-source-agreements
    goto :verif_install
)

:: --- Tentative 2 : telechargement direct depuis GitHub ---
echo.
echo [..] winget indisponible, telechargement de l'installeur officiel...
set "INSTALLER=%TEMP%\git-installer.exe"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol='Tls12';" ^
  "$r=Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest';" ^
  "$a=$r.assets | Where-Object { $_.name -match '^Git-.*-64-bit\.exe$' } | Select-Object -First 1;" ^
  "Invoke-WebRequest $a.browser_download_url -OutFile '%INSTALLER%'"
if not exist "%INSTALLER%" (
    echo [ERREUR] Le telechargement a echoue.
    echo Installez Git manuellement depuis https://git-scm.com/download/win
    start "" "https://git-scm.com/download/win"
    goto :fin
)
echo [..] Lancement de l'installation (acceptez la demande d'administrateur)...
"%INSTALLER%" /VERYSILENT /NORESTART /NOCANCEL /SP- /COMPONENTS="icons,ext\reg\shellhere,assoc,assoc_sh"
del "%INSTALLER%" >nul 2>&1

:verif_install
:: Ajoute Git au PATH de cette session (le PATH systeme n'est pas recharge)
if exist "%ProgramFiles%\Git\cmd\git.exe" set "PATH=%ProgramFiles%\Git\cmd;%PATH%"
if exist "%LocalAppData%\Programs\Git\cmd\git.exe" set "PATH=%LocalAppData%\Programs\Git\cmd;%PATH%"

where git >nul 2>&1
if not %errorlevel%==0 (
    echo [ERREUR] Git ne semble pas installe correctement.
    echo Fermez cette fenetre, ouvrez-en une nouvelle et relancez le script.
    goto :fin
)
for /f "delims=" %%v in ('git --version') do echo [OK] Installation reussie : %%v

:: ---------------------------------------------------------------
:: 2. Choix du dossier
:: ---------------------------------------------------------------
:choix_dossier
echo.
echo Dossier de destination par defaut : %DEFAULT_DIR%
set "TARGET_DIR="
set /p "TARGET_DIR=Appuyez sur Entree pour garder ce dossier, ou tapez un autre chemin : "
if "!TARGET_DIR!"=="" set "TARGET_DIR=%DEFAULT_DIR%"
echo.

:: ---------------------------------------------------------------
:: 3. Clone ou pull
:: ---------------------------------------------------------------
if exist "!TARGET_DIR!\.git" (
    echo [..] Le depot existe deja : mise a jour ^(git pull^)...
    git -C "!TARGET_DIR!" pull
    if errorlevel 1 (
        echo.
        echo [!] Le pull a echoue ^(modifications locales en conflit ?^).
        choice /C ON /M "Ecraser les modifications locales et forcer la mise a jour"
        if not errorlevel 2 (
            git -C "!TARGET_DIR!" fetch --all
            for /f "delims=" %%b in ('git -C "!TARGET_DIR!" rev-parse --abbrev-ref HEAD') do git -C "!TARGET_DIR!" reset --hard origin/%%b
        )
    )
) else (
    if exist "!TARGET_DIR!\*" (
        dir /b "!TARGET_DIR!" | findstr "^" >nul && (
            echo [ERREUR] Le dossier "!TARGET_DIR!" existe et n'est pas vide, ce n'est pas un depot Git.
            echo Choisissez un autre dossier.
            goto :choix_dossier
        )
    )
    echo [..] Clonage du depot dans "!TARGET_DIR!"...
    git clone "%REPO_URL%" "!TARGET_DIR!"
)

if errorlevel 1 (
    echo.
    echo [ERREUR] L'operation Git a echoue. Verifiez votre connexion internet.
    goto :fin
)

echo.
echo [OK] Depot a jour dans : !TARGET_DIR!
echo.
choice /C ON /M "Ouvrir le dossier dans l'explorateur"
if not errorlevel 2 start "" explorer "!TARGET_DIR!"

:fin
echo.
pause
endlocal
