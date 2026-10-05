#!/bin/bash
# La feina de la persona, sempre a `main` (perfil individual, `rules/perfil.md` §2).
#
#     bash .wos/a-main.sh obre    # en obrir la conversa (hook SessionStart de .claude/settings.json)
#     bash .wos/a-main.sh desa    # en acabar cada resposta (hook Stop)
#
# Les converses de Claude Code al núvol treballen en una branca `claude/…` pròpia i l'entorn no els deixa
# pujar enlloc més: el que s'hi desa no arribava a la conversa següent. Això ho fa sense dependre de Claude i
# sense moure'l de la seva branca (l'entorn vigila que la seva branca no tingui res sense pujar):
#
#   · porta `main` de GitHub a la branca on és la conversa;
#   · hi porta (merge) la feina que hagi quedat a branques `claude/…` d'altres converses;
#   · i, si tot el que la conversa hi ha afegit és de la persona, ho puja com a `main` (i la seva branca, també).
#
# A l'ordinador, si la conversa és a `main`, és el mateix: es posa al dia, hi porta les branques i puja `main`.
#
# ⛔ No canvia mai de branca, no esborra cap branca, no força res (`--force`, `reset`) i no toca mai canvis
# sense commit ni un merge que algú ha deixat a mitges. No porta mai soles a `main`:
#   · les propostes d'actualitzador (`actualitzador-v…`), ni res que en porti algun commit: només s'apliquen
#     amb el sí de la persona, des del menú;
#   · res que toqui fora del que és de la persona (el cervell personal, els treballs, les reunions, el
#     context…): ni el sistema, ni les skills, ni res que executi codi, ni esborrats. Llista blanca, no negra;
#   · cap branca que no sigui `claude/…` (les d'altres eines o persones, les publicades a GitHub Pages…).
# El que no porta, o el que xoca, ho diu a Claude, que ho resol amb la persona (`rules/perfil.md` §2).
#
# Viu a `.wos/`, que és de la persona: el paquet del sistema no el pot canviar (actualitza.py, PROTEGITS).

set -u
MODE="${1:-}"
[ "$MODE" = obre ] || [ "$MODE" = desa ] || { echo "Ús: a-main.sh obre|desa" >&2; exit 0; }
ENTRADA=$(cat 2>/dev/null || true)
cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
git remote get-url origin >/dev/null 2>&1 || exit 0
# Mai esperar ningú: ni contrasenyes, ni claus amb frase, ni una xarxa que no respon.
export GIT_TERMINAL_PROMPT=0 GIT_MERGE_AUTOEDIT=no
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o ConnectTimeout=10"
G=(git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15)
OM=refs/remotes/origin/main      # sempre la referència sencera: un tag que es digui «main» no enganya res

portades=()      # branques portades a main
conflictes=()    # branques que xoquen
retingudes=()    # branques que no es porten soles: les ha de veure la persona
avisos=()        # el que Claude ha de resoldre en aquesta conversa
bloqueja=0       # desa: cal aturar Claude perquè la feina d'aquesta conversa no arriba a main
informa=""       # el que Claude ha de saber, però no l'atura
sense_xarxa=0

# Un nom de branca es llegeix a la conversa com a dada: només lletres, xifres i . _ / -, i curt. Si no, el commit.
llegible() {
  case "$1" in
    *[!A-Za-z0-9._/-]*|"") echo "una branca ($(git rev-parse --short "$2" 2>/dev/null))" ;;
    *) if [ ${#1} -le 40 ]; then echo "«$1»"; else echo "una branca ($(git rev-parse --short "$2" 2>/dev/null))"; fi ;;
  esac
}

# Quants canvis queden fora del que és de la persona (sistema/.gitignore), llegint un `git diff --raw -z`
# (rutes en cru, sense escapar ni detectar renoms: un nom amb accents o un renom no s'escapen de la llista).
# Fora: tot el que no és a la llista blanca; a qualsevol nivell, el que git o Claude Code interpreten
# (.git*, CLAUDE.md, .claude/, .mcp.json, AGENTS.md, .github/); els enllaços simbòlics i els submòduls; i
# els esborrats.
compta_fora() {
  local n=0 meta p
  shopt -s nocasematch
  while IFS= read -r -d '' meta && IFS= read -r -d '' p; do
    set -- $meta                              # :<mode abans> <mode després> <sha> <sha> <estat>
    case " ${1#:} ${2:-} " in *" 120000 "*|*" 160000 "*) n=$((n + 1)); continue ;; esac
    [ "${5:-}" = D ] && { n=$((n + 1)); continue; }
    case "/$p" in
      */.git*|*/CLAUDE.md|*/CLAUDE.local.md|*/.claude/*|*/.mcp.json|*/AGENTS.md|*/.github/*) n=$((n + 1)); continue ;;
    esac
    case "$p" in
      brain/personal/*|WOS-work/*|work/*|reunions/*|archives/*) ;;
      context.md|voice.md|intake.md|notes.json|.novetats-vistes) ;;
      *) n=$((n + 1)) ;;
    esac
  done
  shopt -u nocasematch
  echo "$n"
}
fora_de_seu() {   # fora_de_seu <ref> <base>: el que <ref> afegeix respecte de la base. Si git falla, fora.
  git diff --quiet "$2...$1" >/dev/null 2>&1; [ $? -le 1 ] || { echo 999; return; }
  git -c core.quotePath=false diff --raw --no-renames --no-abbrev -z "$2...$1" 2>/dev/null | compta_fora
}

# Una operació de git a mitges (un merge que Claude resol amb la persona, un rebase…): no es toca res.
a_mitges=""
for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer BISECT_LOG; do
  [ -e "$(git rev-parse --git-path "$f")" ] && a_mitges="$f"
done

if [ -n "$a_mitges" ]; then
  informa="Hi ha una operació de git a mitges ($a_mitges): acaba-la i, després, fes commit i puja-ho. "
else
  if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    "${G[@]}" fetch -q --no-tags --unshallow origin 2>/dev/null
  fi
  if ! "${G[@]}" fetch -q --no-tags --prune origin '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null; then
    informa="No s'ha pogut parlar amb GitHub: no he pogut comprovar que tot sigui a main. "
    sense_xarxa=1
  fi
fi

if [ -z "$a_mitges" ] && ! git show-ref -q --verify "$OM"; then
  informa+="No trobo la branca main a GitHub: comprova-ho abans d'escriure res. "
elif [ -z "$a_mitges" ]; then
  actual=$(git symbolic-ref -q --short HEAD || true)
  net=1                                         # sense canvis als fitxers que git segueix (es pot fer merge)
  { git diff --quiet && git diff --cached --quiet; } || net=0
  # Feina sense commit, també fitxers nous (fora dels de l'ordinador i les eines, que mai es pugen).
  pendent=$(git status --porcelain --untracked-files=all 2>/dev/null \
            | grep -vE '(^...|/)\.DS_Store$|^...\.claude/settings\.local\.json$|^...\.claude/worktrees/' | head -1)

  # De quina conversa és la feina on som: main, una branca claude/…, o un HEAD separat amb commits que només
  # són d'aquesta conversa o de branques claude/… (no ensenyar una altra branca i portar-la a main de passada).
  conversa=1
  case "$actual" in main|claude/*) ;; *) conversa=0 ;; esac
  if [ -z "$actual" ]; then
    conversa=1
    while read -r c; do
      [ -n "$c" ] || continue
      while read -r r; do
        case "$r" in refs/stash|refs/remotes/origin/claude/*|refs/heads/claude/*|"$OM"|refs/heads/main|refs/remotes/origin/HEAD) ;;
          *) conversa=0 ;; esac
      done < <(git for-each-ref --format='%(refname)' --contains "$c" refs/ 2>/dev/null)
    done < <(git rev-list HEAD "^$OM" 2>/dev/null)
  fi

  actualitzadors=()   # les propostes d'actualitzador, pel contingut i no pel nom
  while read -r r; do [ -n "$r" ] && actualitzadors+=("^$r"); done \
    < <(git for-each-ref --format='%(refname)' 'refs/remotes/origin/actualitzador-v*')

  # porta <ref> <nom> [propia]: la porta a la feina on som (HEAD), si pot. Torna 1 si queda fora.
  porta() {
    local ref="$1" nom="$2" propia="${3:-}" n rc
    n=$(git rev-list --count "HEAD..$ref" 2>/dev/null || echo 0)
    [ "$n" -gt 0 ] || return 0
    if [ "$ref" = "$OM" ]; then
      git merge -q --no-edit -m "Posa al dia amb main de GitHub" "$ref" >/dev/null 2>&1 && return 0
    else
      if ! git merge-base HEAD "$ref" >/dev/null 2>&1; then
        [ -z "$propia" ] && return 0              # una història a part (gh-pages…): no és feina de converses
        retingudes+=("$nom (no comparteix història amb main: mira-ho amb la persona)"); return 1
      fi
      if [ ${#actualitzadors[@]} -gt 0 ] && \
         [ "$(git rev-list --count "$ref" ^HEAD "${actualitzadors[@]}")" != "$n" ]; then
        retingudes+=("$nom (porta una versió nova de l'actualitzador: només s'aplica amb el sí de la persona, des del menú)")
        return 1
      fi
      if [ "$(fora_de_seu "$ref" HEAD)" -gt 0 ]; then
        retingudes+=("$nom (fitxers fora de les carpetes de la persona o esborrats: ensenya-li què canvia amb git diff --stat HEAD...$(git rev-parse --short "$ref") i porta-ho només amb el seu sí)")
        return 1
      fi
      if git merge -q --no-commit --no-ff "$ref" >/dev/null 2>&1; then
        # Es comprova el resultat de debò del merge, no només la diferència d'abans.
        git diff --cached --quiet HEAD >/dev/null 2>&1; rc=$?
        if [ "$rc" -gt 1 ] || [ "$(git -c core.quotePath=false diff --cached --raw --no-renames --no-abbrev -z HEAD | compta_fora)" -gt 0 ]; then
          git merge --abort 2>/dev/null
          retingudes+=("$nom (en portar-la, canviaria fitxers que no són de la persona: porta-ho només amb el seu sí)")
          return 1
        fi
        git commit -q --no-edit -m "Porta a main la feina de $nom" >/dev/null 2>&1 && { portades+=("$nom"); return 0; }
      fi
    fi
    # No ha entrat: si ha deixat un merge a mitges és seu (abans no n'hi havia cap) i es desfà.
    local era_conflicte=0
    if [ -e "$(git rev-parse --git-path MERGE_HEAD)" ]; then
      [ -n "$(git diff --name-only --diff-filter=U)" ] && era_conflicte=1
      git merge --abort 2>/dev/null
    fi
    if [ "$era_conflicte" = 1 ]; then conflictes+=("$nom")
    else retingudes+=("$nom (git no l'ha pogut portar: mira per què amb git merge $(git rev-parse --short "$ref"))"); fi
    return 1
  }

  # puja <ref remota>: puja HEAD allà sense forçar, i deixa al dia la referència local. Torna 1 si no hi arriba.
  puja() {
    "${G[@]}" push -q origin "HEAD:$1" 2>/dev/null || return 1
    git update-ref "refs/remotes/origin/${1#refs/heads/}" HEAD 2>/dev/null
  }
  # puja_main: puja a main i, en el mateix moment, la branca de la conversa (l'entorn del núvol vigila que no
  # hi quedi res sense pujar). Cada referència va a part: si main no hi arriba, la branca sí.
  puja_main() {
    case "${actual:-}" in claude/*) puja "refs/heads/$actual" ;; esac
    puja refs/heads/main
  }

  if [ "$conversa" = 0 ]; then
    informa+="Ets a $(llegible "${actual:-}" HEAD), que no és de cap conversa: no l'he tocada. "
  elif [ "$net" = 0 ]; then
    avisos+=("Hi ha canvis sense commit: fes-ne commit i puja'ls; en acabar la resposta, el Workspace OS els portarà a main.")
    bloqueja=1
  elif [ "$sense_xarxa" = 0 ]; then
    propia_ok=1
    if ! porta "$OM" origin/main; then
      # main de GitHub no entra on som: aquí, l'únic que xoca és main, i no es proposa «-s ours».
      if [ ${#conflictes[@]} -gt 0 ]; then
        avisos+=("La feina d'aquesta conversa i main de GitHub han canviat la mateixa línia: resol-ho amb la persona (rules/perfil.md §2), sense perdre cap de les dues versions.")
      else
        avisos+=("No he pogut posar la feina al dia amb main de GitHub (git merge origin/main diu per què).")
      fi
      conflictes=(); retingudes=(); propia_ok=0; bloqueja=1
    elif [ "$actual" != main ]; then
      # El que aquesta conversa hi ha afegit respecte de main, amb els mateixos filtres que qualsevol branca.
      n=$(git rev-list --count "$OM..HEAD")
      if [ "$n" -gt 0 ]; then
        if [ ${#actualitzadors[@]} -gt 0 ] && \
           [ "$(git rev-list --count HEAD "^$OM" "${actualitzadors[@]}")" != "$n" ]; then
          avisos+=("Aquesta conversa porta una versió nova de l'actualitzador: només s'aplica amb el sí de la persona, des del menú.")
          propia_ok=0; bloqueja=1
        elif [ "$(fora_de_seu HEAD "$OM")" -gt 0 ]; then
          avisos+=("Aquesta conversa ha desat fitxers fora de les carpetes de la persona (o n'ha esborrat): ensenya-li què canvia (git diff --stat origin/main...HEAD) i porta-ho a main només amb el seu sí (git push origin HEAD:main).")
          propia_ok=0; bloqueja=1
        fi
      fi
    fi

    if [ "$propia_ok" = 1 ]; then
      while read -r nom; do
        [ "$nom" = "${actual:-}" ] && continue
        [ "$(git rev-parse -q --verify "refs/remotes/origin/$nom")" = "$(git rev-parse HEAD)" ] && continue
        porta "refs/remotes/origin/$nom" "$(llegible "$nom" "refs/remotes/origin/$nom")"
      done < <(git for-each-ref --format='%(refname:lstrip=3)' 'refs/remotes/origin/claude/')

      if [ "$(git rev-list --count "$OM..HEAD")" -gt 0 ]; then
        if ! puja_main; then
          # Algú (el mòbil, l'actualitzador) ha pujat entremig: un sol reintent.
          if ! { "${G[@]}" fetch -q --no-tags origin "+refs/heads/main:$OM" 2>/dev/null && porta "$OM" origin/main \
                 && puja_main; }; then
            conflictes=()
            avisos+=("No he pogut pujar la feina a main de GitHub: torna-ho a provar (git pull --no-rebase origin main && git push origin HEAD:main).")
            bloqueja=1
          fi
        fi
        # Sense moure Claude: main local, si existeix i no és on som, es queda com era; s'actualitza sol.
      fi
    fi

    # La branca de la conversa, també a GitHub: res sense pujar (l'entorn del núvol ho vigila) i, si la conversa
    # es tanca, no es perd. Un HEAD separat, només si la seva feina no és a cap lloc de GitHub.
    cal_pujar=0
    case "${actual:-}" in
      main) ;;
      claude/*) git show-ref -q --verify "refs/remotes/origin/$actual" \
                  && [ "$(git rev-list --count "refs/remotes/origin/$actual..HEAD")" = 0 ] || cal_pujar=1 ;;
      *) [ "$(git rev-list --count HEAD --not --remotes=origin 2>/dev/null || echo 0)" -gt 0 ] && cal_pujar=1 ;;
    esac
    if [ "$cal_pujar" = 1 ]; then
      desti=""
      for b in ${actual:+"$actual"} "claude/desat-$(git rev-parse --short HEAD)"; do
        if puja "refs/heads/$b"; then desti="$b"; break; fi
      done
      if [ -z "$desti" ]; then
        avisos+=("La feina d'aquesta conversa no és a GitHub i no l'he poguda pujar: puja-la abans que es tanqui la conversa.")
        bloqueja=1
      elif [ "$bloqueja" = 1 ]; then
        informa+="Mentrestant, la feina d'aquesta conversa és a GitHub, a $(llegible "$desti" HEAD). "
      fi
    elif [ "${actual:-}" = main ] && [ "$(git rev-list --count "$OM..HEAD")" -gt 0 ] && [ "$bloqueja" = 0 ]; then
      puja refs/heads/main || { avisos+=("No he pogut pujar main a GitHub: torna-ho a provar (git push origin main)."); bloqueja=1; }
    fi
  else
    # Sense xarxa: si hi ha feina que no és a GitHub, s'avisa una sola vegada per a la mateixa feina.
    if [ "$(git rev-list --count HEAD --not --remotes=origin 2>/dev/null || echo 0)" -gt 0 ]; then
      marca=$(git rev-parse --git-path wos-avisat-sense-xarxa)
      if [ "$(cat "$marca" 2>/dev/null)" != "$(git rev-parse HEAD)" ]; then
        git rev-parse HEAD > "$marca" 2>/dev/null
        avisos+=("La feina és desada aquí però no a GitHub, perquè ara no hi ha xarxa: puja-la quan n'hi hagi, abans que es tanqui la conversa.")
        bloqueja=1
      else
        informa+="La feina encara no és a GitHub (sense xarxa). "
      fi
    fi
  fi
fi

if [ -z "$a_mitges" ] && [ -n "${pendent:-}" ] && [ "${conversa:-1}" = 1 ] && [ "$bloqueja" = 0 ]; then
  avisos+=("Hi ha feina sense commit (git status): fes-ne commit i puja-la, o es perdrà quan es tanqui la conversa.")
  bloqueja=1
fi

text=""
[ ${#portades[@]} -gt 0 ] && text+="He portat a main la feina que havia quedat a: ${portades[*]}. "
if [ ${#conflictes[@]} -gt 0 ]; then
  text+="No he pogut portar a main aquestes branques perquè xoquen: ${conflictes[*]}. Resol-ho amb la persona com diu rules/perfil.md §2, sense perdre cap de les dues versions; si vol quedar-se només la de main, git merge -s ours <branca> (no s'esborra res). "
fi
if [ ${#retingudes[@]} -gt 0 ]; then
  text+="No he portat a main, perquè ho ha de veure la persona: "
  for r in "${retingudes[@]}"; do text+="$r; "; done
fi
for a in ${avisos[@]+"${avisos[@]}"}; do text+="$a "; done
text+="$informa"

json() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null \
         || printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

if [ "$MODE" = obre ]; then
  # El que Claude llegeix abans del primer missatge. No s'explica a la persona.
  if [ "${conversa:-1}" = 0 ]; then
    echo "Workspace OS (perfil individual): ets en una branca que no és de cap conversa, i no la porto a main. El que hi desis no arribarà a la conversa següent si no ho portes tu a main (amb el sí de la persona). ${text}"
  else
    echo "Workspace OS (perfil individual): treballa on ets. Cada vegada que desis alguna cosa, fes-ne commit i puja-la (git push) a la branca on ets, com et digui l'entorn. En acabar cada resposta, el Workspace OS porta sol a main el que és de la persona; el que no, t'ho dirà perquè ho preguntis. No canviïs de branca, i no parlis de branques, de main ni de hooks amb la persona: no sap què són. ${text}"
  fi
  exit 0
fi

# desa: només atura Claude quan la feina d'aquesta conversa no arriba a main, i mai dues vegades seguides.
# El que ve d'altres converses ja li ha dit `obre`: no s'hi insisteix a cada resposta.
case "$ENTRADA" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac
if [ "$bloqueja" = 1 ]; then
  printf '{"decision":"block","reason":%s}\n' "$(json "Workspace OS: ${text} Explica-ho a la persona en paraules planeres, sense parlar de branques, de main ni de hooks.")"
fi
exit 0
