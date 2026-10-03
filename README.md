# Workspace OS

Aquest repositori és el teu Workspace OS. **És teu i privat**: ningú més hi té accés si tu no l'hi
dones. Ho pots comprovar a Settings → Collaborators, que ha d'estar buit.

## Què hi fa l'actualitzador

Cada matí, `.github/workflows/actualitza.yml` baixa del teu intermedi la versió nova del sistema
(regles, skills, marques) i la porta aquí.

- **Només toca el que és del sistema.** La llista és a `.wos/manifest.json`.
- **No toca mai el que és teu**: `brain/` (llevat de `brain/transversal/`, si en tens), `context.md`,
  `voice.md`, `work/`, `archives/`, les teves skills i `.github/`.
- **No executa res del que baixa.** Només copia fitxers. El codi que corre és el d'aquest repositori
  (`.github/workflows/actualitza.yml` i `.github/wos/actualitza.py`), i el pots llegir sencer.
- **Si una skill nova es diu igual que una de teva, s'atura** sense tocar res i t'ho diu.
- **No es canvia a si mateix.** Si mai cal una versió nova de l'actualitzador, te la proposaran i
  l'acceptes tu.

## Per posar-lo en marxa

A Settings → Secrets and variables → Actions:

1. **Secret** `WOS_CLAU`: la clau que t'han donat. Només serveix per llegir el teu intermedi; no dona
   cap accés a aquest repositori.
2. **Variable** `WOS_INSTALLACIO`: el nom de la teva instal·lació.

Després, Actions → Actualitza → *Run workflow*.
