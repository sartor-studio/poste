#!/usr/bin/env bash
# Sartor : installer un plan de travail Linux
# Source : https://github.com/sartor-studio/poste
#
# Pendant Linux de installer.ps1. Relançable autant de fois que nécessaire :
# ce qui est déjà en place est laissé tel quel.
#
# Ce script ne contient aucun secret. Il demande un code à usage unique affiché
# sur https://backlog.sartorstudio.ai/admin/moi, l'échange contre un jeton
# personnel, installe les outils, relie GitHub, installe les skills Sartor et
# clone les dépôts des dossiers ouverts au compte.
set -uo pipefail

API="${SARTOR_API:-https://backlog.sartorstudio.ai}"
MARKETPLACE="git@github.com:sartor-studio/sartor-skills.git"
RACINE="$HOME/Sartor"
CONF="$HOME/.config/sartor/env"

PRETS=() ; MANQUES=()
etape()  { printf '\n\033[36m[%s/7] %s\033[0m\n' "$1" "$2"; }
ok()     { printf '  \033[32mOK\033[0m  %s\n' "$1"; PRETS+=("$1"); }
info()   { printf '      %s\n' "$1"; }
alerte() { printf '  \033[33m!!\033[0m  %s\n' "$1"; }
manque() { MANQUES+=("$1"); }
present(){ command -v "$1" >/dev/null 2>&1; }

# 1 — le code ----------------------------------------------------------------
etape 1 "Relier cette machine à ton compte Sartor"
JETON=""
[ -f "$CONF" ] && JETON="$(grep -oP '(?<=^SARTOR_TOKEN=).*' "$CONF" 2>/dev/null || true)"
if [ -n "$JETON" ] && curl -fsS -m 20 -H "Authorization: Bearer $JETON" "$API/api/moi/poste/depots" >/dev/null 2>&1; then
  ok "jeton déjà en place et valide"
else
  info "Ouvre $API/admin/moi dans ton navigateur et clique « Obtenir un code »."
  printf '      Code à usage unique (15 min) : '
  read -r CODE
  REP="$(curl -fsS -m 30 -X POST "$API/api/poste/echange" \
        -H 'Content-Type: application/json; charset=utf-8' \
        -d "{\"code\":\"${CODE}\",\"machine\":\"$(hostname)\"}" 2>&1)" || {
    printf '\n\033[31mLe code n%s a pas été accepté.\033[0m\n' "'"
    info "Rien n'est cassé : reprends un code sur $API/admin/moi et relance ce script."
    info "Réponse : $(printf '%s' "$REP" | tail -c 200)"
    exit 1
  }
  # La plateforme renvoie la clé « jeton » (c'est ce que lit installer.ps1).
  # Le 23/09/2026 cette ligne cherchait « token » : le code partait, la plateforme
  # le consommait, et le script s'arrêtait en disant qu'il n'avait rien reçu.
  # On accepte les deux noms pour ne plus jamais rejouer ça.
  JETON="$(printf '%s' "$REP" | python3 -c 'import sys, json
d = json.load(sys.stdin)
print(d.get("jeton") or d.get("token") or "")' 2>/dev/null)"
  if [ -z "$JETON" ]; then
    printf '\n\033[31mLa plateforme a répondu sans jeton lisible.\033[0m\n'
    # Surtout pas la réponse brute : elle porte le jeton en clair.
    info "Clés reçues : $(printf '%s' "$REP" | python3 -c 'import sys, json
try: print(", ".join(json.load(sys.stdin)))
except Exception: print("réponse illisible")' 2>/dev/null)"
    info "Préviens Enzo : ce code-ci est consommé, il en faudra un neuf."
    exit 1
  fi
  ok "compte relié"
fi

# 2 — le jeton ---------------------------------------------------------------
etape 2 "Enregistrer le jeton"
mkdir -p "$(dirname "$CONF")" && chmod 700 "$(dirname "$CONF")"
printf 'SARTOR_TOKEN=%s\nSARTOR_API=%s\n' "$JETON" "$API" > "$CONF"
chmod 600 "$CONF"
LIGNE='set -a; [ -f "$HOME/.config/sartor/env" ] && . "$HOME/.config/sartor/env"; set +a'
grep -qF 'config/sartor/env' "$HOME/.bashrc" 2>/dev/null || printf '\n# Sartor\n%s\n' "$LIGNE" >> "$HOME/.bashrc"
export SARTOR_TOKEN="$JETON" SARTOR_API="$API"
ok "SARTOR_TOKEN et SARTOR_API posés dans ~/.config/sartor/env"

# 3 — les outils -------------------------------------------------------------
etape 3 "Installer Git, GitHub CLI, Python et Claude Code"
sudo apt-get update -qq || true
sudo apt-get install -y -qq git python3-venv python3-pip curl jq >/dev/null 2>&1
present git && ok "git $(git --version | awk '{print $3}')"

if ! present gh; then
  info "Installation de GitHub CLI..."
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | sudo tee /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq && sudo apt-get install -y -qq gh >/dev/null 2>&1
fi
present gh && ok "gh $(gh --version | head -1 | awk '{print $3}')" || manque "GitHub CLI : à installer à la main"

# Claude Code par npm plutôt qu'un script distant passé au shell : la maison
# n'exécute pas ce qu'elle télécharge sans le voir (plan de bridage, 07/06/2026).
if ! present claude; then
  sudo apt-get install -y -qq nodejs npm >/dev/null 2>&1
  mkdir -p "$HOME/.npm-global" && npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1
  grep -qF '.npm-global/bin' "$HOME/.bashrc" 2>/dev/null || echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$HOME/.bashrc"
  export PATH="$HOME/.npm-global/bin:$PATH"
  info "Installation de Claude Code (quelques minutes)..."
  npm install -g @anthropic-ai/claude-code >/dev/null 2>&1
fi
export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$PATH"
present claude && ok "claude $(claude --version 2>/dev/null | head -1)" || manque "Claude Code : à installer à la main"

# 4 — GitHub -----------------------------------------------------------------
etape 4 "Relier cette machine à ton compte GitHub"
GITHUB_OK=0
if ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 git@github.com 2>&1 | grep -q 'successfully authenticated'; then
  GITHUB_OK=1; ok "GitHub répond déjà en SSH"
elif present gh; then
  info "Une fenêtre va te donner un code à coller sur github.com/login/device."
  gh auth login --hostname github.com --git-protocol ssh --web && gh auth setup-git
  if ssh -T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 git@github.com 2>&1 | grep -q 'successfully authenticated'; then
    GITHUB_OK=1; ok "GitHub relié"
  else
    alerte "GitHub ne répond pas encore en SSH."
    manque "GitHub : relance ce script une fois l'authentification terminée"
  fi
fi

# Dire à la plateforme quel compte GitHub c'est, pour que les droits y descendent.
# Sans ce chaînon, un dossier ouvert dans /admin/comptes n'atteint jamais le dépôt :
# la plateforme connaît quelqu'un par son adresse Microsoft, GitHub par un
# pseudonyme, et personne ne dit que c'est la même personne. On ne le devine pas,
# on le constate : `gh` vient d'authentifier quelqu'un, on demande qui.
if [ "$GITHUB_OK" -eq 1 ] && present gh; then
  LOGIN="$(gh api user --jq .login 2>/dev/null || true)"
  if [ -n "$LOGIN" ]; then
    if curl -fsS -m 20 -X PUT "$API/api/moi/github" \
         -H "Authorization: Bearer $JETON" \
         -H 'Content-Type: application/json; charset=utf-8' \
         -d "{\"login\":\"$LOGIN\"}" >/dev/null 2>&1; then
      ok "compte GitHub $LOGIN relié à ton compte Sartor"
      info "Tes dépôts te seront ouverts tout seuls, dans le quart d'heure."
    else
      alerte "GitHub $LOGIN n'a pas pu être signalé à la plateforme."
      manque "Lien GitHub : relance ce script, ou préviens Enzo"
    fi
  fi
fi

# 5 — les skills -------------------------------------------------------------
etape 5 "Installer les skills Sartor dans Claude Code"
if ! present claude || [ "$GITHUB_OK" -ne 1 ]; then
  alerte "Claude Code ou la connexion GitHub manque : étape sautée."
  manque "Skills Sartor : à refaire en relançant ce script"
elif ! git ls-remote --heads "$MARKETPLACE" >/dev/null 2>&1; then
  alerte "Ton compte GitHub n'a pas encore accès au dépôt des skills."
  info "Accepte l'invitation sur https://github.com/sartor-studio, puis relance."
  manque "Skills Sartor : accepter l'invitation GitHub à sartor-studio, puis relancer"
else
  if claude plugin marketplace list --json 2>/dev/null | grep -q '"sartor"'; then
    claude plugin marketplace update sartor >/dev/null 2>&1
  else
    claude plugin marketplace add "$MARKETPLACE" >/dev/null 2>&1
  fi
  claude plugin list --json 2>/dev/null | grep -q 'sartor@sartor' || claude plugin install sartor@sartor >/dev/null 2>&1
  claude plugin list --json 2>/dev/null | grep -q 'sartor@sartor' \
    && ok "paquet sartor installé" || manque "Skills Sartor : installation à refaire"
fi

# 6 — les dépôts -------------------------------------------------------------
etape 6 "Cloner les dépôts des dossiers ouverts dans $RACINE"
DEPOTS="$(curl -fsS -m 30 -H "Authorization: Bearer $JETON" "$API/api/moi/poste/depots" 2>/dev/null || echo '[]')"
NB="$(printf '%s' "$DEPOTS" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(len(d if isinstance(d,list) else d.get("depots",[])))' 2>/dev/null || echo 0)"
if [ "$NB" = "0" ]; then
  info "Aucun dossier avec un dépôt ne t'est encore ouvert. Relance quand Enzo t'en aura ouvert un."
elif [ "$GITHUB_OK" -ne 1 ]; then
  alerte "Connexion GitHub manquante : clonage sauté."
  manque "Dépôts : à cloner en relançant ce script"
else
  mkdir -p "$RACINE"
  printf '%s' "$DEPOTS" | python3 -c '
import sys, json
d = json.load(sys.stdin)
for x in (d if isinstance(d, list) else d.get("depots", [])):
    print(f'"'"'{x.get("dossier","")}\t{x.get("ssh","")}\t{x.get("depot","")}'"'"')
' | while IFS=$'\t' read -r dossier ssh depot; do
    [ -z "$dossier" ] && continue
    cible="$RACINE/$dossier"
    if [ -d "$cible/.git" ]; then
      if [ -z "$(git -C "$cible" status --porcelain)" ] && git -C "$cible" pull --ff-only >/dev/null 2>&1; then
        echo "  OK  $dossier : déjà là, mis à jour"
      else
        echo "      $dossier : déjà là, laissé tel quel"
      fi
    elif [ -e "$cible" ]; then
      echo "  !!  $dossier existe mais n'est pas un dépôt git : je n'y touche pas."
    elif git clone --quiet "$ssh" "$cible" 2>/dev/null; then
      echo "  OK  $dossier : cloné"
    else
      echo "  !!  $depot : pas d'accès, demande à Enzo de t'ouvrir le dépôt"
    fi
  done
fi

# 7 — récapitulatif ----------------------------------------------------------
etape 7 "Récapitulatif"
for p in "${PRETS[@]:-}";   do [ -n "$p" ] && printf '  \033[32m✓\033[0m %s\n' "$p"; done
if [ "${#MANQUES[@]}" -gt 0 ]; then
  printf '\n\033[33mIl reste :\033[0m\n'
  for m in "${MANQUES[@]}"; do printf '  - %s\n' "$m"; done
  printf '\nRelance ce script une fois ces points réglés : il reprend où il en est.\n'
else
  printf '\n\033[32mTout est en place. Ouvre une nouvelle session shell, puis tape « claude ».\033[0m\n'
fi
