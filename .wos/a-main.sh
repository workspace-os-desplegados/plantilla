#!/bin/bash
# La feina de la persona, sempre a `main` (perfil individual, `rules/perfil.md` §2).
#
#     bash .wos/a-main.sh obre    # en obrir la conversa (hook SessionStart de .claude/settings.json)
#     bash .wos/a-main.sh desa    # en acabar cada resposta (hook Stop)
#
# Les converses de Claude Code al núvol treballen en una branca `claude/…` pròpia, i la regla escrita de
# treballar a `main` no sempre guanya: el que s'hi desa no arriba a la conversa següent. Això ho fa sense
# dependre de Claude:
#
#   · posa la conversa a `main`, al dia amb `origin/main`;
#   · hi porta (merge) la feina d'aquesta conversa i la que hagi quedat a branques `claude/…` d'altres;
#   · i puja `main`.
#
# ⛔ No esborra cap branca, no força res (`--force`, `reset`) i no toca mai canvis sense commit ni un merge
# que algú ha deixat a mitges. No porta mai soles a `main`:
#   · les propostes d'actualitzador (`actualitzador-v…`), ni cap branca que en porti algun commit: només
#     s'apliquen amb el sí de la persona, des del menú;
#   · cap branca que toqui res fora del que és de la persona (el cervell personal, els treballs, les reunions,
#     el context…): ni el sistema, ni les skills, ni res que executi codi. Llista blanca, no negra;
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

portades=()      # branques portades a main
conflictes=()    # branques que xoquen amb main
retingudes=()    # branques que no es porten soles: les ha de veure la persona
avisos=()        # el que Claude ha de resoldre en aquesta conversa
bloqueja=0       # desa: cal aturar Claude perquè la seva pròpia feina no arriba a main
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
# (.git*, CLAUDE.md, .claude/, .mcp.json, AGENTS.md, .github/); i enllaços simbòlics o submòduls.
compta_fora() {
  local n=0 meta p modes
  shopt -s nocasematch
  while IFS= read -r -d '' meta && IFS= read -r -d '' p; do
    set -- $meta                              # :<mode abans> <mode després> <sha> <sha> <estat>
    case " ${1#:} ${2:-} " in *" 120000 "*|*" 160000 "*) n=$((n + 1)); continue ;; esac
    [ "${5:-}" = D ] && { n=$((n + 1)); continue; }   # un esborrat no arriba sol: la persona l'ha de veure
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
fora_de_seu() {   # fora_de_seu <ref> [<base>]: el que <ref> canvia respecte de la base (per defecte, main)
  # Si git no ho pot calcular, compta com a fora (falla tancat, no obert).
  git diff --quiet "${2:-refs/heads/main}...$1" >/dev/null 2>&1; [ $? -le 1 ] || { echo 999; return; }
  git -c core.quotePath=false diff --raw --no-renames --no-abbrev -z "${2:-refs/heads/main}...$1" 2>/dev/null | compta_fora
}

# Una operació de git a mitges (un merge que Claude resol amb la persona, un rebase…): no es toca res.
a_mitges=""
for f in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply sequencer BISECT_LOG; do
  [ -e "$(git rev-parse --git-path "$f")" ] && a_mitges="$f"
done

if [ -n "$a_mitges" ]; then
  informa="Hi ha una operació de git a mitges ($a_mitges): acaba-la i, després, porta la feina a main i puja-la. "
else
  if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    "${G[@]}" fetch -q --no-tags --unshallow origin 2>/dev/null
  fi
  if ! "${G[@]}" fetch -q --no-tags --prune origin '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null; then
    informa="No s'ha pogut parlar amb GitHub: no he pogut comprovar que tot sigui a main. "
    sense_xarxa=1
  fi
fi

if [ -z "$a_mitges" ] && ! git show-ref -q --verify refs/remotes/origin/main; then
  informa+="No trobo la branca main a GitHub: comprova-ho abans d'escriure res. "
elif [ -z "$a_mitges" ]; then
  actual=$(git symbolic-ref -q --short HEAD || true)
  anterior=""                                   # on era la conversa, si no era a main
  [ "$actual" = main ] || anterior=$(git rev-parse -q --verify HEAD || true)
  net=1                                         # sense canvis als fitxers que git segueix (es pot canviar de branca)
  { git diff --quiet && git diff --cached --quiet; } || net=0
  # Feina sense commit, també fitxers nous (fora dels de l'ordinador que mai es pugen).
  pendent=$(git status --porcelain --untracked-files=all 2>/dev/null \
            | grep -vE '(^...|/)\.DS_Store$|^...\.claude/settings\.local\.json$|^...\.claude/worktrees/' | head -1)

  a_main=0
  conversa=1                                    # branca d'una conversa (claude/…) o HEAD separat
  case "$actual" in main|claude/*) ;; *) conversa=0 ;; esac
  if [ -z "$actual" ]; then
    # HEAD separat: només si els seus commits són d'aquesta conversa o de branques claude/… (no ensenyar una
    # altra branca i portar-la a main de passada).
    conversa=1
    while read -r c; do
      [ -n "$c" ] || continue
      while read -r r; do
        case "$r" in refs/stash|refs/remotes/origin/claude/*|refs/heads/claude/*|refs/remotes/origin/main|refs/heads/main|refs/remotes/origin/HEAD) ;;
          *) conversa=0 ;; esac
      done < <(git for-each-ref --format='%(refname)' --contains "$c" refs/ 2>/dev/null)
    done < <(git rev-list HEAD ^refs/remotes/origin/main 2>/dev/null)
  fi
  # La xarxa de seguretat: la feina d'aquesta conversa que no és a GitHub hi puja abans de res, a la seva branca
  # (o a una de nova si és un HEAD separat o la seva ja hi té una altra cosa). Mai --force. Així, passi el que
  # passi després, la conversa següent la troba i la porta a main.
  worktree=0                                    # una còpia a part (git worktree): main és d'una altra carpeta
  [ "$(git rev-parse --git-dir 2>/dev/null)" != "$(git rev-parse --git-common-dir 2>/dev/null)" ] && worktree=1

  desada=""
  desa_a_github() {   # la puja a la seva branca o a una de nova; mai --force
    [ "$conversa" = 1 ] && [ -n "$anterior" ] && [ "$sense_xarxa" = 0 ] || return 0
    [ "$(git rev-list --count "$anterior" --not --remotes=origin 2>/dev/null || echo 0)" -gt 0 ] || return 0
    local curt desti
    curt=$(git rev-parse --short "$anterior")
    for desti in ${actual:+"$actual"} "claude/desat-$curt"; do
      if "${G[@]}" push -q origin "$anterior:refs/heads/$desti" 2>/dev/null; then desada="$desti"; return 0; fi
    done
    avisos+=("La feina d'aquesta conversa no és a GitHub i no l'he poguda pujar: puja-la abans que es tanqui la conversa.")
  }
  # En una còpia a part, primer s'intenta pujar a main directament: la branca de reserva, només si no hi arriba.
  [ "$worktree" = 1 ] || desa_a_github

  if [ "$actual" = main ]; then
    a_main=1
  elif [ "$conversa" = 0 ] || [ "$worktree" = 1 ]; then
    :
  elif [ "$net" = 1 ]; then
    if git show-ref -q --verify refs/heads/main; then
      git switch -q main 2>/dev/null && a_main=1
    else
      git switch -q -c main refs/remotes/origin/main 2>/dev/null && a_main=1   # sense --track: un clon d'una sola branca no el pot seguir
    fi
  fi

  # Les propostes d'actualitzador, pel contingut i no pel nom.
  actualitzadors=()
  while read -r r; do [ -n "$r" ] && actualitzadors+=("^$r"); done \
    < <(git for-each-ref --format='%(refname)' 'refs/remotes/origin/actualitzador-v*')

  if [ "$conversa" = 0 ]; then
    informa+="Ets a $(llegible "${actual:-}" HEAD), que no és de cap conversa: no l'he tocada. "
  elif [ "$worktree" = 1 ]; then
    # No es pot canviar a main: s'hi porta main a la branca i, si tot és de la persona, es puja com a main.
    if [ "$net" = 1 ] && [ "$(git rev-list --count HEAD..refs/remotes/origin/main)" -gt 0 ] && \
       ! git merge -q --no-edit -m "Porta main al dia" refs/remotes/origin/main >/dev/null 2>&1; then
      git merge --abort 2>/dev/null
      avisos+=("Aquesta conversa és en una còpia a part i xoca amb main: resol-ho amb la persona (rules/perfil.md §2).")
      bloqueja=1
    elif n=$(git rev-list --count refs/remotes/origin/main..HEAD) && [ "$n" -gt 0 ] && \
         git merge-base --is-ancestor refs/remotes/origin/main HEAD; then
      if [ ${#actualitzadors[@]} -gt 0 ] && \
         [ "$(git rev-list --count HEAD ^refs/remotes/origin/main "${actualitzadors[@]}")" != "$n" ]; then
        avisos+=("Aquesta conversa porta una versió nova de l'actualitzador: només s'aplica amb el sí de la persona, des del menú.")
        bloqueja=1
      elif [ "$(fora_de_seu HEAD refs/remotes/origin/main)" -gt 0 ]; then
        avisos+=("Aquesta conversa canvia fitxers que no són de la persona: ensenya-li què canvia i porta-ho a main només amb el seu sí (git push origin HEAD:main).")
        bloqueja=1
      elif "${G[@]}" push -q origin HEAD:refs/heads/main 2>/dev/null; then
        portades+=("$(llegible "${actual:-la conversa}" HEAD)")
      else
        avisos+=("No he pogut pujar la feina d'aquesta conversa a main: torna-ho a provar (git push origin HEAD:main).")
        bloqueja=1
      fi
    fi
    [ "$bloqueja" = 1 ] && desa_a_github
  elif [ "$a_main" = 0 ]; then
    on=$(llegible "${actual:-}" HEAD)
    if [ "$net" = 0 ]; then
      avisos+=("Ets a $on amb canvis sense commit: fes-ne commit, torna a main i porta-hi aquesta feina (git switch main && git merge $(git rev-parse --short HEAD)), i puja main.")
    else
      avisos+=("No he pogut passar a main des de $on: fes-ho tu, porta-hi aquesta feina i puja main.")
    fi
    bloqueja=1
  else

    # porta <ref> <nom>: la porta a main si pot. Torna 1 si la feina queda fora de main.
    porta() {   # porta <ref> <nom> [propia]
      local ref="$1" nom="$2" propia="${3:-}" n codi
      n=$(git rev-list --count "refs/heads/main..$ref" 2>/dev/null || echo 0)
      [ "$n" -gt 0 ] || return 0
      if [ "$ref" != refs/remotes/origin/main ]; then
        if ! git merge-base refs/heads/main "$ref" >/dev/null 2>&1; then
          [ -z "$propia" ] && return 0           # una història a part (gh-pages…): no és feina de converses
          retingudes+=("$nom (no comparteix història amb main: mira-ho amb la persona)")
          return 1
        fi
        if [ ${#actualitzadors[@]} -gt 0 ] && \
           [ "$(git rev-list --count "$ref" ^refs/heads/main "${actualitzadors[@]}")" != "$n" ]; then
          retingudes+=("$nom (porta una versió nova de l'actualitzador: només s'aplica amb el sí de la persona, des del menú)")
          return 1
        fi
        codi=$(fora_de_seu "$ref")
        if [ "$codi" -gt 0 ]; then
          retingudes+=("$nom ($codi fitxers fora de les carpetes de la persona —el cervell personal, WOS-work, reunions, el context— o esborrats; per exemple, un fitxer nou a l'arrel, el sistema, skills o codi: ensenya-li què canvia amb git diff --stat main...$(git rev-parse --short "$ref") i porta-la a main només amb el seu sí)")
          return 1
        fi
      fi
      if [ "$ref" = refs/remotes/origin/main ]; then
        git merge -q --no-edit -m "Posa main al dia amb GitHub" "$ref" >/dev/null 2>&1 && return 0
      elif git merge -q --no-commit --no-ff "$ref" >/dev/null 2>&1; then
        # Es comprova el resultat de debò del merge, no només la diferència d'abans.
        git diff --cached --quiet HEAD >/dev/null 2>&1; local rc=$?
        if [ "$rc" -gt 1 ] || [ "$(git -c core.quotePath=false diff --cached --raw --no-renames --no-abbrev -z HEAD | compta_fora)" -gt 0 ]; then
          git merge --abort 2>/dev/null
          retingudes+=("$nom (en portar-la, canviaria fitxers que no són de la persona: porta-la a main només amb el seu sí)")
          return 1
        fi
        git commit -q --no-edit -m "Porta a main la feina de $nom" >/dev/null 2>&1 && { portades+=("$nom"); return 0; }
      fi
      # No ha entrat: si ha deixat un merge a mitges és seu (abans no n'hi havia cap) i es desfà.
      local era_conflicte=0
      if [ -e "$(git rev-parse --git-path MERGE_HEAD)" ]; then
        [ -n "$(git diff --name-only --diff-filter=U)" ] && era_conflicte=1
        git merge --abort 2>/dev/null
      fi
      if [ "$era_conflicte" = 1 ]; then
        conflictes+=("$nom")
      else
        retingudes+=("$nom (git no l'ha pogut portar: mira per què amb git merge $(git rev-parse --short "$ref"))")
      fi
      return 1
    }

    if ! porta refs/remotes/origin/main origin/main; then
      if [ ${#conflictes[@]} -gt 0 ]; then
        avisos+=("main d'aquí i main de GitHub han canviat la mateixa línia: resol-ho amb la persona (rules/perfil.md §2) abans d'escriure res.")
      else
        avisos+=("No he pogut posar main al dia amb GitHub (git pull --no-rebase diu per què; potser hi ha canvis sense commit que xocarien).")
      fi
      conflictes=()
      retingudes=()
      bloqueja=1
    else
      if [ -n "$anterior" ]; then
        if ! porta "$anterior" "$(llegible "${actual:-la conversa}" "$anterior")" propia; then
          # No ha entrat a main: si és a GitHub (desada), la conversa següent la hi tornarà a provar.
          [ -n "$desada" ] && informa+="La feina d'aquesta conversa és a GitHub, a $(llegible "$desada" "$anterior"), fins que es pugui portar a main. "
          bloqueja=1
        fi
      fi
      while read -r nom; do
        [ -n "$anterior" ] && [ "$(git rev-parse -q --verify "refs/remotes/origin/$nom")" = "$anterior" ] && continue
        porta "refs/remotes/origin/$nom" "$(llegible "$nom" "refs/remotes/origin/$nom")"
      done < <(git for-each-ref --format='%(refname:lstrip=3)' 'refs/remotes/origin/claude/')

      if [ "$(git rev-list --count refs/remotes/origin/main..refs/heads/main)" -gt 0 ]; then
        if ! "${G[@]}" push -q origin refs/heads/main:refs/heads/main 2>/dev/null; then
          # Algú (el mòbil, l'actualitzador) ha pujat entremig: un sol reintent.
          if ! { "${G[@]}" fetch -q --no-tags origin '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null && porta refs/remotes/origin/main origin/main \
                 && "${G[@]}" push -q origin refs/heads/main:refs/heads/main 2>/dev/null; }; then
            conflictes=()          # aquí, l'únic que pot xocar és main de GitHub: no es proposa «-s ours»
            if [ "$sense_xarxa" = 1 ]; then
              # Una sola vegada per a la mateixa feina: Claude no ho pot arreglar sense xarxa.
              marca=$(git rev-parse --git-path wos-avisat-sense-xarxa)
              if [ "$(cat "$marca" 2>/dev/null)" != "$(git rev-parse refs/heads/main)" ]; then
                git rev-parse refs/heads/main > "$marca" 2>/dev/null
                avisos+=("La feina és a main d'aquí però no a GitHub, perquè ara no hi ha xarxa: puja-la quan n'hi hagi (git push origin main), abans que es tanqui la conversa.")
                bloqueja=1
              else
                informa+="main encara no és a GitHub (sense xarxa). "
              fi
            else
              avisos+=("No he pogut pujar main a GitHub: torna-ho a provar (git pull --no-rebase && git push origin main).")
              bloqueja=1
            fi
          fi
        fi
      fi
    fi
  fi
fi

if [ -z "$a_mitges" ] && [ -n "${pendent:-}" ] && [ "${conversa:-1}" = 1 ] && [ "$bloqueja" = 0 ]; then
  avisos+=("Hi ha feina sense commit (git status): fes-ne commit i git push origin main, o es perdrà quan es tanqui la conversa.")
  bloqueja=1
fi

text=""
[ ${#portades[@]} -gt 0 ] && text+="He portat a main la feina que havia quedat a: ${portades[*]}. "
if [ ${#conflictes[@]} -gt 0 ]; then
  text+="No he pogut portar a main aquestes branques perquè xoquen amb main: ${conflictes[*]}. Resol-ho amb la persona com diu rules/perfil.md §2, sense perdre cap de les dues versions; si vol quedar-se només la de main, git merge -s ours <branca> (no s'esborra res). "
fi
if [ ${#retingudes[@]} -gt 0 ]; then
  text+="No he portat a main, perquè ho ha de veure la persona: "
  for r in "${retingudes[@]}"; do text+="$r; "; done
fi
for a in ${avisos[@]+"${avisos[@]}"}; do text+="$a "; done
text+="$informa"

json() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null \
         || printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

if [ "$MODE" = obre ] && [ "${worktree:-0}" = 1 ] && [ "${conversa:-0}" = 1 ]; then
  echo "Workspace OS (perfil individual): aquesta conversa és en una còpia a part (git worktree) i no pot passar a main. Fes commit a la branca on ets: en acabar cada resposta, el que sigui de la persona es puja sol a main. No parlis de branques ni de hooks amb la persona. ${text}"
  exit 0
fi
if [ "$MODE" = obre ] && [ "${conversa:-1}" = 0 ]; then
  echo "Workspace OS (perfil individual): ets en una branca que no és de cap conversa, i no la porto a main. El que hi desis no arribarà a la conversa següent si no ho portes tu a main (amb el sí de la persona). ${text}"
  exit 0
fi
if [ "$MODE" = obre ]; then
  # El que Claude llegeix abans del primer missatge. No s'explica a la persona.
  echo "Workspace OS (perfil individual): cada vegada que desis alguna cosa, fes-ne commit i puja-ho on l'entorn et digui (aquí o la branca de la conversa). En acabar cada resposta, el Workspace OS porta sol a main el que és de la persona; el que no, t'ho dirà perquè ho preguntis. No parlis de branques, de main ni de hooks amb la persona: no sap què són. ${text}"
  exit 0
fi

# desa: només atura Claude quan la feina d'aquesta conversa no ha arribat a main, i mai dues vegades seguides.
# El que ve d'altres converses ja li ha dit `obre`: no s'hi insisteix a cada resposta.
case "$ENTRADA" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac
if [ "$bloqueja" = 1 ]; then
  printf '{"decision":"block","reason":%s}\n' "$(json "Workspace OS: ${text} Explica-ho a la persona en paraules planeres, sense parlar de branques, de main ni de hooks.")"
fi
exit 0
