# Sartor : installer un poste de travail Windows
# Source : https://github.com/sartor-studio/poste
#
# Compatible Windows PowerShell 5.1 et PowerShell 7. Relançable autant de fois
# que nécessaire : ce qui est déjà en place est laissé tel quel.
#
# Ce script ne contient aucun secret. Il demande un code à usage unique affiché
# sur https://backlog.sartorstudio.ai/admin/moi, l'échange contre un jeton
# personnel, installe les outils, relie GitHub, installe les skills Sartor et
# clone les dépôts des dossiers ouverts au compte.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072

$SartorApi = 'https://backlog.sartorstudio.ai'
$Marketplace = 'git@github.com:sartor-studio/sartor-skills.git'
$Racine = Join-Path $env:USERPROFILE 'Sartor'

$script:Prets = New-Object System.Collections.Generic.List[string]
$script:Manques = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------
# Affichage
# ---------------------------------------------------------------------------
function Write-Etape([int]$Numero, [string]$Titre) {
    Write-Host ''
    Write-Host "[$Numero/7] $Titre" -ForegroundColor Cyan
}
function Write-Ok([string]$Texte) { Write-Host "  OK  $Texte" -ForegroundColor Green }
function Write-Info([string]$Texte) { Write-Host "      $Texte" }
function Write-Alerte([string]$Texte) { Write-Host "  !!  $Texte" -ForegroundColor Yellow }

function Stop-Sartor([string]$Texte) {
    Write-Host ''
    Write-Host $Texte -ForegroundColor Red
    Write-Host "Rien n'est cassé : corrige ce point, puis recolle la même ligne dans PowerShell."
    exit 1
}

# ---------------------------------------------------------------------------
# Outils
# ---------------------------------------------------------------------------
# Un argument tel que Windows le relit (règles de CreateProcess) : Start-Process
# colle ses arguments avec des espaces sans rien entourer.
function ConvertTo-ArgumentWindows([string]$Valeur) {
    if ($Valeur -eq '') { return '""' }
    if ($Valeur -notmatch '[\s"]') { return $Valeur }
    $e = $Valeur -replace '(\\*)"', '$1$1\"'
    $e = $e -replace '(\\+)$', '$1$1'
    return '"' + $e + '"'
}

# Lance une commande externe sans que PowerShell 5.1 transforme sa sortie
# d'erreur en exception. Modes :
#   Capturer  stdout et stderr rendus dans .Sortie
#   Stdout    stdout seul (pour lire du JSON)
#   Afficher  la commande parle directement à la console et peut poser des
#             questions (gh, winget, ssh-keygen) : elle ne doit pas voir sa
#             sortie redirigée, sinon elle se croit hors d'un terminal.
function Invoke-Natif {
    param([string]$Exe, [string[]]$Arguments = @(), [string]$Mode = 'Capturer')
    $ancien = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $sortie = $null
    try {
        switch ($Mode) {
            'Afficher' {
                $chemin = (Get-Command $Exe -ErrorAction Stop | Select-Object -First 1).Source
                $ligne = ($Arguments | ForEach-Object { ConvertTo-ArgumentWindows $_ }) -join ' '
                if ($ligne) {
                    $p = Start-Process -FilePath $chemin -ArgumentList $ligne -NoNewWindow -PassThru
                } else {
                    $p = Start-Process -FilePath $chemin -NoNewWindow -PassThru
                }
                $null = $p.Handle   # sans cette lecture, ExitCode reste vide en 5.1
                $p.WaitForExit()
                $code = $p.ExitCode
            }
            'Stdout' {
                $sortie = & $Exe @Arguments 2>$null
                $code = $LASTEXITCODE
            }
            default {
                $sortie = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
                $code = $LASTEXITCODE
            }
        }
    } catch {
        $sortie = $_.Exception.Message
        $code = 1
    } finally {
        $ErrorActionPreference = $ancien
    }
    [pscustomobject]@{ Code = $code; Sortie = (@($sortie) -join "`n") }
}

function Test-Commande([string]$Nom) {
    return [bool](Get-Command $Nom -ErrorAction SilentlyContinue)
}

# Relit le PATH de Windows (machine + utilisateur) après une installation, plus
# les dossiers où les installateurs posent leurs commandes.
function Update-SessionPath {
    $morceaux = @()
    foreach ($portee in 'Machine', 'User') {
        $valeur = [Environment]::GetEnvironmentVariable('Path', $portee)
        if ($valeur) { $morceaux += $valeur -split ';' }
    }
    $morceaux += @(
        (Join-Path $env:ProgramFiles 'Git\cmd'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd'),
        (Join-Path $env:ProgramFiles 'GitHub CLI'),
        (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'),
        (Join-Path $env:USERPROFILE '.local\bin')
    )
    $morceaux += $env:Path -split ';'
    $vus = @{}
    $garde = New-Object System.Collections.Generic.List[string]
    foreach ($p in $morceaux) {
        if (-not $p) { continue }
        $cle = $p.TrimEnd('\').ToLowerInvariant()
        if ($vus.ContainsKey($cle)) { continue }
        $vus[$cle] = $true
        if (Test-Path -LiteralPath $p) { $garde.Add($p) }
    }
    $env:Path = $garde -join ';'
}

function Add-CheminUtilisateur([string]$Dossier) {
    if (-not (Test-Path -LiteralPath $Dossier)) { return }
    $actuel = [Environment]::GetEnvironmentVariable('Path', 'User')
    $morceaux = @($actuel -split ';' | Where-Object { $_ })
    if ($morceaux | Where-Object { $_.TrimEnd('\') -ieq $Dossier.TrimEnd('\') }) { return }
    [Environment]::SetEnvironmentVariable('Path', (($morceaux + $Dossier) -join ';'), 'User')
}

function Test-Python {
    # Un Python installé pour l'utilisateur mais absent du PATH : on l'y ajoute.
    $installe = Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Programs\Python') -Filter 'Python3*' -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'python.exe') } |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($installe -and -not (Get-Command python -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -like "$($installe.FullName)*" })) {
        Add-CheminUtilisateur $installe.FullName
        Add-CheminUtilisateur (Join-Path $installe.FullName 'Scripts')
        Update-SessionPath
        $env:Path = "$($installe.FullName);$(Join-Path $installe.FullName 'Scripts');$env:Path"
    }
    $vrai = Get-Command python -All -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -and $_.Source -notlike '*\WindowsApps\*' } |
        Select-Object -First 1
    if ($vrai) { return $true }
    if (Test-Commande 'py') { return ((Invoke-Natif 'py' @('-3', '--version')).Code -eq 0) }
    return $false
}

function Test-Winget {
    if (Test-Commande 'winget') { return $true }
    # Sur un Windows neuf, winget existe mais n'est enregistré qu'après la
    # première mise à jour du Store : on tente l'enregistrement nous-mêmes.
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
    } catch { }
    Update-SessionPath
    return (Test-Commande 'winget')
}

function Install-Paquet {
    param([string]$Id, [string]$Nom, [scriptblock]$Present)
    if (& $Present) {
        Write-Ok "$Nom : déjà installé"
        $script:Prets.Add($Nom)
        return
    }
    Write-Info "Installation de $Nom (winget, quelques minutes)..."
    $base = @('install', '--id', $Id, '--exact', '--silent', '--accept-source-agreements', '--accept-package-agreements', '--disable-interactivity')
    $r = Invoke-Natif 'winget' ($base + @('--scope', 'user')) 'Afficher'
    Update-SessionPath
    if (-not (& $Present)) {
        Write-Info "Pas d'installation par utilisateur pour $Nom : Windows peut demander une autorisation, accepte-la."
        $r = Invoke-Natif 'winget' $base 'Afficher'
        Update-SessionPath
    }
    if (& $Present) {
        Write-Ok "$Nom : installé"
        $script:Prets.Add($Nom)
    } else {
        Write-Alerte "$Nom ne s'est pas installé (code winget $($r.Code))."
        $script:Manques.Add("$Nom : relance la ligne, ou installe-le à la main avec « winget install --id $Id »")
    }
}

function Install-Claude {
    if (Test-Commande 'claude') {
        Write-Ok 'Claude Code : déjà installé'
        $script:Prets.Add('Claude Code')
        return
    }
    Write-Info "Installation de Claude Code (installateur officiel d'Anthropic, claude.ai/install.ps1)..."
    # Dans un PowerShell enfant : l'installateur officiel termine par « exit »,
    # qui fermerait sinon ce script avec lui.
    $commande = '[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor 3072; & ([scriptblock]::Create((Invoke-RestMethod -UseBasicParsing https://claude.ai/install.ps1)))'
    $ps = (Get-Process -Id $PID).Path
    $r = Invoke-Natif $ps @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $commande) 'Afficher'

    $bin = Join-Path $env:USERPROFILE '.local\bin'
    if (Test-Path (Join-Path $bin 'claude.exe')) { Add-CheminUtilisateur $bin }
    Update-SessionPath
    if (Test-Commande 'claude') {
        Write-Ok 'Claude Code : installé'
        $script:Prets.Add('Claude Code')
    } else {
        Write-Alerte "Claude Code ne s'est pas installé (code $($r.Code))."
        $script:Manques.Add('Claude Code : relance la ligne ; si ça bloque encore, voir code.claude.com/docs/en/troubleshoot-install')
    }
}

# ---------------------------------------------------------------------------
# Plateforme
# ---------------------------------------------------------------------------
function Get-SartorAcces {
    param([string]$Api, [string]$Code, [string]$Machine)
    $corps = @{ code = $Code; machine = $Machine } | ConvertTo-Json -Compress
    try {
        return Invoke-RestMethod -Method Post -Uri "$Api/api/poste/echange" -UseBasicParsing `
            -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($corps))
    } catch {
        $statut = 0
        if ($_.Exception.Response) {
            try { $statut = [int]$_.Exception.Response.StatusCode } catch { }
        }
        return [pscustomobject]@{ Erreur = $statut; Message = $_.Exception.Message }
    }
}

function Get-SartorDepots {
    param([string]$Api, [string]$Jeton)
    try {
        return Invoke-RestMethod -Uri "$Api/api/moi/poste/depots" -UseBasicParsing -Headers @{ Authorization = "Bearer $Jeton" }
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------
function Test-GitHubSsh {
    $r = Invoke-Natif 'ssh' @('-T', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ConnectTimeout=20', 'git@github.com')
    return ($r.Sortie -match 'successfully authenticated')
}

# ---------------------------------------------------------------------------
# Le parcours
# ---------------------------------------------------------------------------
function Invoke-Installation {
    Write-Host ''
    Write-Host 'Sartor : installation du poste' -ForegroundColor White
    Write-Host '------------------------------'
    Write-Info "Machine : $env:COMPUTERNAME  -  Compte Windows : $env:USERNAME  -  PowerShell $($PSVersionTable.PSVersion)"

    # 1. Le code ------------------------------------------------------------
    Write-Etape 1 'Relier ce poste à ton compte Sartor'
    $jeton = $null
    $depots = @()
    $prenom = $null
    $existant = [Environment]::GetEnvironmentVariable('SARTOR_TOKEN', 'User')
    if ($existant) {
        $lu = Get-SartorDepots $SartorApi $existant
        if ($lu) {
            $jeton = $existant
            $depots = @($lu.depots)
            $prenom = $lu.compte.prenom
            Write-Ok "Ce poste a déjà un jeton valable ($($lu.compte.email)) : pas besoin de code."
        } else {
            Write-Info "Le jeton déjà posé sur ce poste n'est plus valable : il faut un nouveau code."
        }
    }
    if (-not $jeton) {
        Write-Info "Ouvre $SartorApi/admin/moi dans ton navigateur et clique « Obtenir un code »."
        for ($essai = 1; $essai -le 3 -and -not $jeton; $essai++) {
            $saisi = Read-Host '      Code (8 caractères, par exemple ABCD-EFGH)'
            if (-not "$saisi".Trim()) { continue }
            $r = Get-SartorAcces $SartorApi $saisi.Trim() $env:COMPUTERNAME
            if ($r.PSObject.Properties['jeton']) {
                $jeton = $r.jeton
                $depots = @($r.depots)
                $prenom = $r.compte.prenom
                Write-Ok "Code accepté : bonjour $prenom, ce poste est relié à $($r.compte.email)."
            } elseif ($r.Erreur -eq 429) {
                Stop-Sartor "Trop d'essais refusés. Attends un quart d'heure, demande un nouveau code sur la plateforme, puis relance."
            } elseif ($r.Erreur -eq 0) {
                Stop-Sartor "La plateforme ne répond pas ($($r.Message)). Vérifie la connexion internet, puis relance."
            } else {
                Write-Alerte 'Code refusé ou expiré : demande un nouveau code sur la plateforme.'
            }
        }
        if (-not $jeton) {
            Stop-Sartor 'Code refusé ou expiré : demande un nouveau code sur la plateforme, puis relance la ligne.'
        }
    }

    # 2. Les variables ------------------------------------------------------
    # Posées tout de suite : si la suite échoue, le jeton n'est pas perdu et
    # le script relancé n'aura pas à redemander de code.
    Write-Etape 2 "Enregistrer le jeton dans les variables d'environnement"
    [Environment]::SetEnvironmentVariable('SARTOR_TOKEN', $jeton, 'User')
    [Environment]::SetEnvironmentVariable('SARTOR_API', $SartorApi, 'User')
    [Environment]::SetEnvironmentVariable('CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE', '1', 'User')
    $env:SARTOR_TOKEN = $jeton
    $env:SARTOR_API = $SartorApi
    $env:CLAUDE_CODE_PLUGIN_KEEP_MARKETPLACE_ON_FAILURE = '1'
    Write-Ok 'SARTOR_TOKEN et SARTOR_API posés pour ton compte Windows'
    $script:Prets.Add('Jeton Sartor')

    # 3. Les outils ---------------------------------------------------------
    Write-Etape 3 'Installer Git, GitHub CLI, Python et Claude Code'
    Update-SessionPath
    if (Test-Winget) {
        Install-Paquet 'Git.Git' 'Git' { Test-Commande 'git' }
        Install-Paquet 'GitHub.cli' 'GitHub CLI' { Test-Commande 'gh' }
        Install-Paquet 'Python.Python.3.13' 'Python 3' { Test-Python }
    } else {
        Write-Alerte "winget est absent de ce Windows."
        Write-Info "Ouvre le Microsoft Store, cherche « Programme d'installation d'application » (App Installer),"
        Write-Info 'installe-le ou mets-le à jour, puis relance la ligne.'
        $script:Manques.Add("winget : installer « Programme d'installation d'application » depuis le Microsoft Store, puis relancer")
    }
    Install-Claude

    # 4. GitHub -------------------------------------------------------------
    Write-Etape 4 'Relier ce poste à ton compte GitHub'
    $env:GIT_SSH_COMMAND = 'ssh -o StrictHostKeyChecking=accept-new'
    $env:GIT_TERMINAL_PROMPT = '0'
    $githubOk = $false
    if (-not (Test-Commande 'gh')) {
        Write-Alerte "GitHub CLI manque : étape sautée."
    } else {
        if ((Invoke-Natif 'gh' @('auth', 'status', '--hostname', 'github.com')).Code -ne 0) {
            Write-Info "Ce qui va se passer :"
            Write-Info "  - GitHub CLI propose de créer une clé SSH : réponds oui (Entrée), laisse la phrase secrète vide,"
            Write-Info "    garde le titre proposé. La clé sert à cloner les dépôts sans mot de passe."
            Write-Info "  - Il affiche un code à 8 caractères. Appuie sur Entrée : le navigateur s'ouvre sur github.com."
            Write-Info "  - Connecte-toi à ton compte GitHub, colle le code, puis clique « Authorize GitHub CLI »."
            Write-Info "  - Reviens ici : la suite continue toute seule."
            [void](Read-Host '      Appuie sur Entrée pour commencer')
            [void](Invoke-Natif 'gh' @('auth', 'login', '--web', '--git-protocol', 'ssh', '--hostname', 'github.com') 'Afficher')
        } else {
            Write-Ok 'GitHub CLI est déjà connecté'
        }
        if (Test-GitHubSsh) {
            $githubOk = $true
        } elseif ((Invoke-Natif 'gh' @('auth', 'status', '--hostname', 'github.com')).Code -eq 0) {
            # Connecté, mais aucune clé SSH de ce poste n'est connue de GitHub.
            $cle = Join-Path $env:USERPROFILE '.ssh\id_ed25519'
            if (-not (Test-Path "$cle.pub")) {
                New-Item -ItemType Directory -Force -Path (Split-Path $cle) | Out-Null
                Write-Info "Création d'une clé SSH : appuie deux fois sur Entrée (sans phrase secrète)."
                [void](Invoke-Natif 'ssh-keygen' @('-t', 'ed25519', '-f', $cle, '-C', "poste $env:COMPUTERNAME") 'Afficher')
            }
            Write-Info "GitHub doit autoriser l'ajout de la clé : même principe, un code puis le navigateur."
            [void](Invoke-Natif 'gh' @('auth', 'refresh', '--hostname', 'github.com', '--scopes', 'admin:public_key') 'Afficher')
            [void](Invoke-Natif 'gh' @('ssh-key', 'add', "$cle.pub", '--title', "poste $env:COMPUTERNAME") 'Afficher')
            $githubOk = Test-GitHubSsh
        }
        if ($githubOk) {
            Write-Ok 'GitHub reconnaît la clé SSH de ce poste'
            $script:Prets.Add('GitHub (SSH)')
        } else {
            Write-Alerte "GitHub ne reconnaît pas encore ce poste."
            $script:Manques.Add('GitHub : relance la ligne et termine la connexion dans le navigateur')
        }
    }

    # 5. Les skills ---------------------------------------------------------
    Write-Etape 5 'Installer les skills Sartor dans Claude Code'
    if (-not ((Test-Commande 'claude') -and (Test-Commande 'git') -and $githubOk)) {
        Write-Alerte 'Il manque Claude Code, Git ou la connexion GitHub : étape sautée.'
        $script:Manques.Add('Skills Sartor : à refaire en relançant la ligne une fois les étapes précédentes vertes')
    } elseif ((Invoke-Natif 'git' @('ls-remote', '--heads', $Marketplace)).Code -ne 0) {
        Write-Alerte "Ton compte GitHub n'a pas encore accès au dépôt des skills (sartor-studio/sartor-skills)."
        Write-Info "Accepte l'invitation reçue par mail ou sur https://github.com/sartor-studio, puis relance la ligne."
        $script:Manques.Add("Skills Sartor : accepter l'invitation GitHub à sartor-studio, puis relancer")
    } else {
        $connue = $false
        try {
            $liste = (Invoke-Natif 'claude' @('plugin', 'marketplace', 'list', '--json') 'Stdout').Sortie | ConvertFrom-Json
            $connue = [bool](@($liste) | Where-Object { $_.name -eq 'sartor' })
        } catch { }
        if ($connue) {
            [void](Invoke-Natif 'claude' @('plugin', 'marketplace', 'update', 'sartor'))
        } else {
            [void](Invoke-Natif 'claude' @('plugin', 'marketplace', 'add', $Marketplace) 'Afficher')
        }
        $installe = $false
        try {
            $plugins = (Invoke-Natif 'claude' @('plugin', 'list', '--json') 'Stdout').Sortie | ConvertFrom-Json
            $installe = [bool](@($plugins) | Where-Object { $_.id -eq 'sartor@sartor' -and $_.scope -eq 'user' })
        } catch { }
        if (-not $installe) {
            [void](Invoke-Natif 'claude' @('plugin', 'install', 'sartor@sartor') 'Afficher')
            try {
                $plugins = (Invoke-Natif 'claude' @('plugin', 'list', '--json') 'Stdout').Sortie | ConvertFrom-Json
                $installe = [bool](@($plugins) | Where-Object { $_.id -eq 'sartor@sartor' -and $_.scope -eq 'user' })
            } catch { }
        }
        if ($installe) {
            Write-Ok 'Skills Sartor installés (sartor@sartor)'
            $script:Prets.Add('Skills Sartor')
        } else {
            Write-Alerte "L'installation des skills n'a pas abouti."
            $script:Manques.Add('Skills Sartor : relancer la ligne ; sinon, dans Claude Code, taper /plugin')
        }
    }

    # 6. Les dépôts ---------------------------------------------------------
    Write-Etape 6 "Cloner les dépôts des dossiers ouverts dans $Racine"
    $depots = @($depots | Where-Object { $_ })
    if ($depots.Count -eq 0) {
        Write-Info "Aucun dossier avec un dépôt ne t'est encore ouvert. Relance la ligne quand Enzo t'en aura ouvert un."
    } elseif (-not ((Test-Commande 'git') -and $githubOk)) {
        Write-Alerte 'Git ou la connexion GitHub manque : clonage sauté.'
        $script:Manques.Add('Dépôts : à cloner en relançant la ligne')
    } else {
        New-Item -ItemType Directory -Force -Path $Racine | Out-Null
        foreach ($d in $depots) {
            $cible = Join-Path $Racine $d.dossier
            if (Test-Path -LiteralPath $cible) {
                if (-not (Test-Path -LiteralPath (Join-Path $cible '.git'))) {
                    Write-Alerte "$($d.dossier) existe mais n'est pas un dépôt git : je n'y touche pas."
                    continue
                }
                $etat = Invoke-Natif 'git' @('-C', $cible, 'status', '--porcelain') 'Stdout'
                if ($etat.Code -eq 0 -and -not "$($etat.Sortie)".Trim()) {
                    if ((Invoke-Natif 'git' @('-C', $cible, 'pull', '--ff-only')).Code -eq 0) {
                        Write-Ok "$($d.dossier) : déjà là, mis à jour"
                    } else {
                        Write-Info "$($d.dossier) : déjà là, mise à jour impossible sans fusion, laissé tel quel"
                    }
                } else {
                    Write-Info "$($d.dossier) : déjà là avec des modifications locales, laissé tel quel"
                }
                $script:Prets.Add("Dépôt $($d.dossier)")
                continue
            }
            Write-Info "Clonage de $($d.depot)..."
            $r = Invoke-Natif 'git' @('clone', '--quiet', $d.ssh, $cible)
            if ($r.Code -eq 0) {
                Write-Ok "$($d.dossier) : cloné"
                $script:Prets.Add("Dépôt $($d.dossier)")
            } elseif ($r.Sortie -match 'not found|Permission denied|access rights|does not appear') {
                Write-Alerte "$($d.depot) : pas d'accès"
                $script:Manques.Add("Dépôt $($d.depot) : demande à Enzo de t'ouvrir le dépôt $($d.depot)")
            } else {
                Write-Alerte "$($d.depot) : clonage impossible"
                $script:Manques.Add("Dépôt $($d.depot) : relance la ligne ($(($r.Sortie -split "`n")[-1]))")
            }
        }
    }

    # 7. Récapitulatif ------------------------------------------------------
    Write-Etape 7 'Récapitulatif'
    Write-Host ''
    Write-Host 'Prêt :' -ForegroundColor Green
    foreach ($p in $script:Prets) { Write-Host "  - $p" }
    if ($script:Manques.Count -gt 0) {
        Write-Host ''
        Write-Host 'Il manque :' -ForegroundColor Yellow
        foreach ($m in $script:Manques) { Write-Host "  - $m" }
    }
    Write-Host ''
    Write-Host 'La suite :' -ForegroundColor Cyan
    Write-Host '  1. Ferme cette fenêtre et ouvre un nouveau PowerShell (les variables y seront chargées).'
    Write-Host "  2. Va dans un dossier client : cd `"$Racine\<dossier>`""
    Write-Host '  3. Lance : claude'
    Write-Host "  4. À la première ouverture, connecte-toi avec le compte Claude de l'équipe."
    Write-Host ''
    if ($script:Manques.Count -gt 0) { exit 2 }
}

try {
    Invoke-Installation
} catch {
    Write-Host ''
    Write-Host "Erreur inattendue : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Relance la ligne. Si ça recommence, envoie une capture de cette fenêtre à Enzo."
    exit 1
}
