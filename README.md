# Sartor : installer un poste Windows

Ce dépôt ne contient qu'un script, `installer.ps1`, qui prépare un portable Windows
neuf pour travailler chez Sartor : Git, GitHub CLI, Python 3, Claude Code, les skills
Sartor et les dépôts des dossiers ouverts au compte. Il ne contient aucun secret.

## La ligne à coller

Ouvrir **PowerShell** (touche Windows, taper « PowerShell », Entrée), coller la ligne
ci-dessous, Entrée.

<!-- BEGIN_LIGNE -->
```powershell
[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor 3072; $f="$env:TEMP\sartor-installer.ps1"; Invoke-WebRequest -UseBasicParsing "https://raw.githubusercontent.com/sartor-studio/poste/6b462fef010df5be76541dc3d96ad4671557b0f4/installer.ps1" -OutFile $f; if ((Get-FileHash $f -Algorithm SHA256).Hash -ne "80F0C2E3ABBBFB06A3A8C2B50CF11DA33812E0318F72CA8A00695DAAFDD162CA") { Remove-Item $f -ErrorAction SilentlyContinue; Write-Host "Empreinte inattendue : installation arretee." -ForegroundColor Red } else { & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $f }
```
<!-- END_LIGNE -->

La ligne télécharge le script **à un commit précis** de ce dépôt, calcule son empreinte
SHA-256 et s'arrête net si elle ne correspond pas à celle qu'elle porte. Elle ne
contient ni code d'accès ni jeton. La même ligne est affichée sur la plateforme, dans
« Mon compte ».

## Ce que fait le script

1. Il demande un **code à usage unique** (8 caractères, valable 15 minutes), affiché
   sur https://backlog.sartorstudio.ai/admin/moi par le bouton « Obtenir un code », et
   l'échange contre un jeton personnel.
2. Il pose `SARTOR_TOKEN` et `SARTOR_API` dans les variables d'environnement de
   l'utilisateur Windows.
3. Il installe ce qui manque avec `winget` : Git for Windows, GitHub CLI, Python 3,
   puis Claude Code par l'installateur officiel d'Anthropic.
4. Il relie le poste à GitHub (`gh auth login`, clé SSH), dans le navigateur.
5. Il installe les skills Sartor dans Claude Code (`claude plugin install sartor@sartor`).
6. Il clone les dépôts des dossiers ouverts au compte dans `%USERPROFILE%\Sartor\`, sans
   jamais toucher à un dossier qui existe déjà (au plus un `git pull --ff-only`).
7. Il affiche ce qui est prêt, ce qui manque et la suite.

Relancer la ligne ne casse rien : ce qui est en place est laissé tel quel, et un jeton
encore valable évite de redemander un code.

## Publier une nouvelle version

Le script se modifie ici, se commite, se pousse. Puis, depuis l'atelier :
`venv/bin/python tools/poste_publier.py`, qui relit le commit et l'empreinte, réécrit la ligne
de ce README et celle de la plateforme. Une ligne ancienne continue de pointer vers
l'ancienne version, intacte.
