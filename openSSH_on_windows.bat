<# :
@echo off
setlocal
title Assistant SSH Windows
rem --- Verification des droits administrateur, relance auto si besoin ---
net session >nul 2>&1
if not errorlevel 1 goto :admin
echo Demande des droits administrateur...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b
:admin
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f='%~f0'; iex ([IO.File]::ReadAllText($f))"
exit /b
#>

# =====================================================================
#  Partie PowerShell : assistant interactif pour le serveur OpenSSH
# =====================================================================

$ConfigPath = "$env:ProgramData\ssh\sshd_config"
$SshdExe    = "$env:WINDIR\System32\OpenSSH\sshd.exe"

function Titre($t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }
function OK($t)    { Write-Host "  [OK] $t" -ForegroundColor Green }
function KO($t)    { Write-Host "  [!!] $t" -ForegroundColor Red }
function Info($t)  { Write-Host "  [..] $t" -ForegroundColor Yellow }
function Attendre  { Write-Host ""; Read-Host "Appuyez sur Entree pour revenir au menu" | Out-Null }

function Get-SshPort {
    $port = 22
    if (Test-Path $ConfigPath) {
        $m = Select-String -Path $ConfigPath -Pattern '^\s*Port\s+(\d+)' | Select-Object -First 1
        if ($m) { $port = [int]$m.Matches[0].Groups[1].Value }
    }
    return $port
}

function Test-Port($hote, $port) {
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($hote, $port, $null, $null)
        $fini = $iar.AsyncWaitHandle.WaitOne(2000, $false)
        return ($fini -and $c.Connected)
    } catch { return $false } finally { $c.Close() }
}

# ---------------------------------------------------------------------
function Diagnostic {
    $port = Get-SshPort
    $localOK = $false

    Titre "1. Serveur OpenSSH installe ?"
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc) { OK "Service sshd present" }
    else      { KO "Serveur OpenSSH NON installe -> utilisez l'option 2" }

    Titre "2. Etat du service"
    if ($svc) {
        if ($svc.Status -eq 'Running')       { OK "sshd est demarre" }
        else                                  { KO "sshd est arrete (etat : $($svc.Status))" }
        if ($svc.StartType -eq 'Automatic')   { OK "Demarrage automatique (permanent)" }
        else                                  { KO "Demarrage : $($svc.StartType) -> pas permanent" }
    } else { Info "Ignore (service absent)" }

    Titre "3. Port configure"
    Info "Port SSH : $port"

    Titre "4. Ecoute sur le port $port"
    $ecoute = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($ecoute) { OK "Le port $port est en ecoute" }
    else         { KO "Rien n'ecoute sur le port $port" }

    Titre "5. Test de connexion locale"
    if (Test-Port '127.0.0.1' $port) { OK "Connexion locale reussie"; $localOK = $true }
    else                             { KO "Connexion locale refusee" }

    Titre "6. Regles du pare-feu Windows"
    $regles = @(Get-NetFirewallRule -Direction Inbound -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*ssh*' -or $_.DisplayName -like '*ssh*' })
    $bonnes = @()
    if ($regles.Count -gt 0) {
        $regles | Format-Table Name, Enabled, Action, Profile -AutoSize | Out-String | Write-Host
        $bonnes = @($regles | Where-Object { "$($_.Enabled)" -eq 'True' -and "$($_.Action)" -eq 'Allow' })
        if ($bonnes.Count -gt 0) { OK "Au moins une regle SSH active" }
        else                     { KO "Regles SSH presentes mais desactivees ou en blocage" }
    } else { KO "Aucune regle SSH dans le pare-feu -> utilisez l'option 2" }

    Titre "7. Profil reseau vs pare-feu"
    $profils = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    foreach ($p in $profils) {
        $cat = "$($p.NetworkCategory)"
        $flag = if ($cat -eq 'DomainAuthenticated') { 'Domain' } else { $cat }
        $couvert = @($bonnes | Where-Object { "$($_.Profile)" -eq 'Any' -or "$($_.Profile)" -match $flag })
        if ($couvert.Count -gt 0) { OK "$($p.InterfaceAlias) [$($p.Name)] : profil $cat -> SSH autorise" }
        else                      { KO "$($p.InterfaceAlias) [$($p.Name)] : profil $cat -> SSH BLOQUE (option 2 ou 3)" }
    }

    Titre "8. Pare-feu tiers (antivirus)"
    $tiers = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct -ErrorAction SilentlyContinue)
    if ($tiers.Count -gt 0) {
        foreach ($t in $tiers) { Info "Detecte : $($t.displayName) -> verifiez qu'il autorise le port $port" }
    } else { OK "Aucun pare-feu tiers detecte" }

    Titre "9. Commandes pour se connecter depuis un autre poste"
    $user = $env:USERNAME
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        ForEach-Object {
            $cmd = if ($port -ne 22) { "ssh -p $port $user@$($_.IPAddress)" } else { "ssh $user@$($_.IPAddress)" }
            Write-Host ("  {0,-28} {1}" -f $_.InterfaceAlias, $cmd)
        }
    Info "Ignorez les cartes virtuelles (vEthernet, VirtualBox, VMware, WSL...)"

    Titre "Conclusion"
    if (-not $svc)          { KO "Installez le serveur : option 2" }
    elseif (-not $localOK)  { KO "Le serveur ne repond pas en local : option 2, puis option 4 si ca echoue" }
    else {
        OK "Le serveur fonctionne en local."
        Info "Si l'autre poste obtient un timeout : pare-feu (points 6-8), mauvaise IP,"
        Info "ou les deux appareils ne sont pas sur le meme reseau (reseau invite, 4G...)."
    }
}

# ---------------------------------------------------------------------
function Reparation {
    $port = Get-SshPort

    Titre "Installation du serveur OpenSSH"
    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        Info "Installation en cours (peut prendre plusieurs minutes)..."
        try {
            Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*' |
                Add-WindowsCapability -Online -ErrorAction Stop | Out-Null
            OK "Serveur OpenSSH installe"
        } catch {
            KO "Echec de l'installation : $($_.Exception.Message)"
            Info "Alternative : Parametres > Applications > Fonctionnalites facultatives > Serveur OpenSSH"
            return
        }
    } else { OK "Deja installe" }

    Titre "Demarrage permanent du service"
    try { Set-Service sshd -StartupType Automatic -ErrorAction Stop; OK "Demarrage automatique active" }
    catch { KO "Impossible de passer en automatique : $($_.Exception.Message)" }
    try { Start-Service sshd -ErrorAction Stop; OK "Service sshd demarre" }
    catch { KO "Le service refuse de demarrer : $($_.Exception.Message)"; Info "Utilisez l'option 4 pour voir la cause" }

    Titre "Ouverture du pare-feu (tous profils reseau)"
    try {
        if ($port -eq 22 -and (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
            Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Enabled True -Action Allow -Profile Any -ErrorAction Stop
            OK "Regle OpenSSH-Server-In-TCP activee pour tous les profils"
        } else {
            $nom = "SSH-Port-$port"
            if (Get-NetFirewallRule -Name $nom -ErrorAction SilentlyContinue) {
                Set-NetFirewallRule -Name $nom -Enabled True -Action Allow -Profile Any -ErrorAction Stop
            } else {
                New-NetFirewallRule -Name $nom -DisplayName "OpenSSH Server (port $port)" -Direction Inbound `
                    -Protocol TCP -LocalPort $port -Action Allow -Profile Any -Enabled True -ErrorAction Stop | Out-Null
            }
            OK "Regle $nom ouverte sur le port $port pour tous les profils"
        }
    } catch { KO "Erreur pare-feu : $($_.Exception.Message)" }

    Titre "Verification"
    Start-Sleep -Seconds 2
    if (Test-Port '127.0.0.1' $port) { OK "SSH repond en local sur le port $port" }
    else                             { KO "SSH ne repond toujours pas -> option 4" }
}

# ---------------------------------------------------------------------
function Reseau-Prive {
    Titre "Profils reseau actuels"
    $profils = @(Get-NetConnectionProfile)
    for ($i = 0; $i -lt $profils.Count; $i++) {
        Write-Host ("  {0}) {1} [{2}] : {3}" -f ($i + 1), $profils[$i].InterfaceAlias, $profils[$i].Name, $profils[$i].NetworkCategory)
    }
    Info "A faire uniquement pour votre reseau domestique, pas un Wi-Fi public."
    $c = Read-Host "Numero du reseau a passer en Prive (Entree pour annuler)"
    if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $profils.Count) {
        $p = $profils[[int]$c - 1]
        try {
            Set-NetConnectionProfile -InterfaceIndex $p.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
            OK "$($p.InterfaceAlias) est maintenant en profil Prive"
        } catch { KO "Echec : $($_.Exception.Message)" }
    } else { Info "Annule" }
}

# ---------------------------------------------------------------------
function Debug-Sshd {
    if (-not (Test-Path $SshdExe)) { KO "sshd.exe introuvable : serveur non installe (option 2)"; return }

    Titre "Test de la configuration (sshd -t)"
    $sortie = & $SshdExe -t 2>&1
    if ($LASTEXITCODE -eq 0) { OK "Configuration valide" }
    else { KO "Probleme detecte :"; $sortie | ForEach-Object { Write-Host "     $_" -ForegroundColor Red } }

    Write-Host ""
    $r = Read-Host "Lancer sshd en mode debug detaille ? (o/N)"
    if ($r -match '^[oOyY]') {
        Info "Arret temporaire du service. Si le serveur reste en attente, c'est qu'il demarre bien :"
        Info "connectez-vous une fois depuis un autre poste pour voir le detail, il s'arretera ensuite."
        Stop-Service sshd -ErrorAction SilentlyContinue
        & $SshdExe -d -p (Get-SshPort)
        Start-Service sshd -ErrorAction SilentlyContinue
        Info "Service sshd relance"
    }
}

# ---------------------------------------------------------------------
function Agent-Ssh {
    Titre "ssh-agent au demarrage"
    try {
        Set-Service ssh-agent -StartupType Automatic -ErrorAction Stop
        Start-Service ssh-agent -ErrorAction Stop
        OK "ssh-agent demarre et automatique"
    } catch { KO "Erreur : $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------
do {
    Clear-Host
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "        ASSISTANT SERVEUR SSH WINDOWS"           -ForegroundColor Cyan
    Write-Host "==============================================" -ForegroundColor Cyan
    Write-Host "  Utilisateur : $env:USERNAME   PC : $env:COMPUTERNAME"
    Write-Host ""
    Write-Host "  1) Diagnostic complet (aucune modification)"
    Write-Host "  2) Reparation auto : installer, demarrer, rendre permanent, ouvrir le pare-feu"
    Write-Host "  3) Passer un reseau en profil Prive"
    Write-Host "  4) Verifier la configuration de sshd (test / debug)"
    Write-Host "  5) Activer ssh-agent au demarrage (pour les cles SSH)"
    Write-Host "  Q) Quitter"
    Write-Host ""
    $choix = Read-Host "Votre choix"
    switch ($choix) {
        '1' { Diagnostic;   Attendre }
        '2' { Reparation;   Attendre }
        '3' { Reseau-Prive; Attendre }
        '4' { Debug-Sshd;   Attendre }
        '5' { Agent-Ssh;    Attendre }
    }
} while ($choix -notin @('q', 'Q'))
