#!/bin/bash
# El Workspace OS al Mac de la persona: una carpeta per MIRAR els seus treballs i reunions (perfil individual).
#
#     bash instala.sh <usuari>/<repositori>
#     (o, sense baixar res abans:)
#     curl -fsSL https://raw.githubusercontent.com/workspace-os-desplegados/plantilla/main/.wos/mac/instala.sh | bash -s <usuari>/<repositori>
#
# Deixa:
#   · ~/WOS/ amb dues carpetes, «Treballs» i «Reunions», de NOMÉS LECTURA (per editar un document, «Desa una
#     còpia» i arrossega-la a Claude, que el desa com a versió nova);
#   · l'app «WOS» a ~/Applications: un clic la posa al dia amb GitHub i obre la carpeta. No corre res sol;
#   · una clau d'aquest Mac que NOMÉS pot llegir el repositori de la persona (una «Deploy key» sense escriptura).
#
# ⛔ Aquest Mac no pot pujar res: la clau és de només lectura i els fitxers queden bloquejats. La feina es fa
# a les converses de Claude (al núvol), com al mòbil i a l'iPad.
# Es pot tornar a executar: el que ja hi és no es repeteix.

set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

REPO="${1:-}"
NOM="${WOS_NOM:-WOS}"                                   # el nom de la carpeta i de l'app (proves: WOS Paco)
ARREL="${WOS_ARREL:-$HOME/$NOM}"
SUPORT="$HOME/.wos/$(printf %s "$NOM" | tr -c 'A-Za-z0-9._-' -)"   # sense espais: ssh no els accepta a UserKnownHostsFile
CLAU="$SUPORT/clau_lectura"
HOSTS="$SUPORT/known_hosts"
APP="$HOME/Applications/$NOM.app"
# La clau d'host de GitHub, fixada: la primera connexió no pregunta ni es pot suplantar (api.github.com/meta).
GITHUB_HOST="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

pas() { printf '\n\033[1m%s\033[0m\n' "$*"; }
atura() { printf '\n✗ %s\n' "$*" >&2; exit 1; }
pregunta() { printf '%s' "$1"; read -r _ < /dev/tty || true; }

[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || atura "Ús: bash instala.sh <usuari>/<repositori>   (el repositori de la persona)"

pas "1/4 · Eines del Mac"
if ! xcode-select -p >/dev/null 2>&1 || ! git --version >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  atura "Falten les eines de línia d'ordres d'Apple. S'ha obert la finestra per instal·lar-les: accepta-la,
  espera que acabi i torna a executar aquesta mateixa ordre."
fi
echo "✓ git disponible"

pas "2/4 · La clau de només lectura d'aquest Mac"
mkdir -p "$SUPORT" && chmod 700 "$SUPORT"
echo "$GITHUB_HOST" > "$HOSTS"
if [ ! -f "$CLAU" ]; then
  ssh-keygen -q -t ed25519 -N "" -C "WOS $(scutil --get ComputerName 2>/dev/null || hostname -s) (només lectura)" -f "$CLAU"
fi
SSH="ssh -F /dev/null -i \"$CLAU\" -o IdentitiesOnly=yes -o UserKnownHostsFile=\"$HOSTS\" -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=15"
URL="git@github.com:$REPO.git"
if GIT_SSH_COMMAND="$SSH" git ls-remote "$URL" >/dev/null 2>&1; then
  echo "✓ la clau ja té accés de lectura a $REPO"
else
  pbcopy < "$CLAU.pub"
  open "https://github.com/$REPO/settings/keys/new" 2>/dev/null || true
  cat <<EOF

  S'ha obert GitHub al navegador, i la clau ja és copiada. Amb el compte de la persona:
    1. Title: «Mac (només lectura)». Key: enganxa (⌘V).
    2. ⛔ NO marquis «Allow write access». → «Add key».
  (Si no s'ha obert: https://github.com/$REPO/settings/keys/new)
EOF
  for _ in 1 2 3; do
    pregunta "  Quan estigui afegida, prem Retorn… "
    if GIT_SSH_COMMAND="$SSH" git ls-remote "$URL" >/dev/null 2>&1; then echo "✓ accés de lectura comprovat"; break; fi
    echo "  Encara no hi arriba. Comprova que és al repositori $REPO i torna-ho a provar."
  done
  GIT_SSH_COMMAND="$SSH" git ls-remote "$URL" >/dev/null 2>&1 || atura "La clau no té accés a $REPO."
fi

pas "3/4 · La carpeta $NOM"
CLON="$SUPORT/repositori"
if [ ! -d "$CLON/.git" ]; then
  GIT_SSH_COMMAND="$SSH" git clone -q --branch main --single-branch "$URL" "$CLON"
fi
git -C "$CLON" config core.sshCommand "$SSH"
mkdir -p "$ARREL" "$CLON/WOS-work" "$CLON/reunions"
ln -sfn "$CLON/WOS-work" "$ARREL/Treballs"
ln -sfn "$CLON/reunions" "$ARREL/Reunions"
echo "✓ $ARREL, amb Treballs i Reunions"

# L'actualitzador: el crida l'app. Només baixa; deixa els fitxers en només lectura.
ACT="$SUPORT/actualitza.sh"
cat > "$ACT" <<EOF
#!/bin/bash
# Posa al dia la carpeta $NOM amb GitHub i l'obre. Només baixa: aquest Mac no pot pujar res.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin GIT_TERMINAL_PROMPT=0
CLON="$CLON"
avisa() { osascript -e "display notification \"\$1\" with title \"$NOM\"" >/dev/null 2>&1 || true; }
chmod -R u+w "\$CLON/WOS-work" "\$CLON/reunions" 2>/dev/null
if git -C "\$CLON" fetch -q origin main 2>/dev/null; then
  if git -C "\$CLON" merge -q --ff-only origin/main >/dev/null 2>&1; then
    avisa "Al dia"
  else
    # Algú ha tocat la còpia d'aquest Mac: es deixa com és i es diu, no es perd res.
    avisa "No s'ha pogut posar al dia: hi ha canvis en aquest Mac. Avisa qui t'ho va instal·lar."
  fi
else
  avisa "Sense connexió: ensenyo l'última versió que tenia."
fi
chmod -R a-w "\$CLON/WOS-work" "\$CLON/reunions" 2>/dev/null
open "$ARREL"
EOF
chmod 700 "$ACT"

pas "4/4 · L'app $NOM"
mkdir -p "$HOME/Applications"
TMP=$(mktemp -d)
printf 'do shell script quoted form of "%s"\n' "$ACT" > "$TMP/app.applescript"
rm -rf "$APP"
osacompile -o "$APP" "$TMP/app.applescript"
# La icona: la del repositori (ve de la plantilla) o, en una instal·lació d'abans, la de la plantilla pública.
ICONA="$CLON/.wos/mac/WOS.icns"
[ -f "$ICONA" ] || { curl -fsSL -o "$TMP/WOS.icns" \
  https://raw.githubusercontent.com/workspace-os-desplegados/plantilla/main/.wos/mac/WOS.icns 2>/dev/null && ICONA="$TMP/WOS.icns"; }
if [ -f "$ICONA" ]; then
  cp "$ICONA" "$APP/Contents/Resources/applet.icns"
  codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true   # la icona nova toca el paquet: es torna a signar
  touch "$APP"
fi
rm -rf "$TMP"
# Al Dock, si encara no hi és.
APP_URL="file://${APP// /%20}/"
if ! defaults read com.apple.dock persistent-apps 2>/dev/null | grep -qF "$APP_URL"; then
  defaults write com.apple.dock persistent-apps -array-add "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$APP_URL</string><key>_CFURLStringType</key><integer>15</integer></dict></dict></dict>"
  killall Dock 2>/dev/null || true
fi
"$ACT" >/dev/null 2>&1 || true
echo "✓ $APP"

cat <<EOF

Fet. L'app «$NOM» ja és al Dock: un clic posa la carpeta al dia i l'obre. Si vols, arrossega la carpeta
$ARREL a la barra lateral del Finder. Els fitxers són de només lectura: per editar-ne un, «Desa una
còpia» i arrossega-la a Claude.

Per treure-ho tot: esborra $ARREL, $APP i $SUPORT, i la «Deploy key» de GitHub.
EOF
