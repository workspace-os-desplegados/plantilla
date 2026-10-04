#!/usr/bin/env python3
"""L'actualitzador del Workspace OS al perfil individual (bloc 21 §5; sessió 16, i sessió 17 tram 4).

    python3 .wos/actualitzador/actualitza.py <paquet> <repositori> [--origen <commit>]
    python3 .wos/actualitzador/actualitza.py --proposa <paquet> <repositori>

Porta al repositori de la persona el paquet del seu intermedi, per manifest:

  · el que és al paquet, arriba;
  · el que era del sistema (és al manifest d'abans) i ja no hi és, s'esborra, però només
    si és tal com l'actualitzador el va deixar;
  · el que no ha estat mai del sistema, no es toca;
  · si el paquet porta una cosa que ja hi és i no era del sistema (una skill pròpia amb el
    mateix nom, per exemple), s'atura sense escriure res i ho diu.

⛔ Només copia i esborra fitxers: no executa mai res del paquet. Si ho fes, el que arriba
podria llegir el cervell i enviar-lo fora.

⛔ Només escriu on és del sistema (`PERMESOS_*`), i hi ha camins que no toca mai, digui el que digui
el manifest o el paquet (`PROTEGITS_*`). Tots dos es comparen sense distingir majúscules.
Aquest fitxer viu a `.wos/actualitzador/`, que és a `PROTEGITS`: el paquet no l'hi pot escriure mai.

**Un actualitzador nou només arriba amb el sí de la persona** (`--proposa`). El paquet en porta l'última versió a
`.wos/actualitzador/` (el pas d'aplicar no la llegeix mai). Si és més nova que la d'aquí, es deixa en una branca
`actualitzador-v<N>` i s'obre una proposta (o un avís, si GitHub no deixa obrir-ne) amb el que canvia. Fins que la
persona l'accepta, continua corrent aquesta; i la branca no s'executa mai.

Tot es comprova abans d'escriure: o s'aplica sencer, o no s'aplica res.
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import unicodedata
from pathlib import Path, PurePosixPath

MANIFEST = ".wos/manifest.json"

# Camins de la persona, comparats sense distingir majúscules (en un Mac o un iPad, `Brain/` i
# `brain/` són la mateixa carpeta). Dins de brain/, tot menys brain/transversal/.
# Els mateixos que el sistema declara de la persona (`sistema/.gitignore`), més els de l'entorn.
PROTEGITS_ARRELS = {".wos", "work", "wos-work", "archives", "reunions", ".devcontainer", ".vscode"}
PROTEGITS_FITXERS = {"context.md", "voice.md", "intake.md", "notes.json", ".novetats-vistes"}


class Atura(Exception):
    """Una condició per la qual no s'ha d'aplicar res."""


def clau(cami: str) -> str:
    return unicodedata.normalize("NFC", cami).casefold()


def protegit(cami: str) -> bool:
    parts = PurePosixPath(clau(cami)).parts
    if not parts:
        return True
    # .git, .github, .gitignore, .gitattributes, .gitmodules...: git els interpreta, a qualsevol nivell.
    if any(p.startswith(".git") for p in parts):
        return True
    if parts[0] in PROTEGITS_ARRELS or "/".join(parts) in PROTEGITS_FITXERS:
        return True
    # La configuració de Claude Code pot executar ordres (hooks): no la porta el paquet.
    if parts[0] == ".claude" and len(parts) == 2 and parts[1].startswith("settings"):
        return True
    # Les skills que es fa la persona porten el prefix personal- (el catàleg no en publica mai cap).
    if parts[:2] == (".claude", "skills") and len(parts) > 2 and parts[2].startswith("personal-"):
        return True
    if parts[0] == "brain":
        return not (len(parts) > 2 and parts[1] == "transversal")
    return False


# El que el paquet POT escriure (llista blanca, comparada sense majúscules). Tota la resta s'atura:
# així un fitxer nou que Claude Code o git interpretin (`.mcp.json`, per exemple) no pot arribar sense
# que la persona accepti abans un actualitzador nou.
PERMESOS_FITXERS = {"claude.md", "novetats.md", ".sistema.json", ".cataleg.json", ".skills.json", ".guia.html"}
PERMESOS_CARPETES = {"rules", "bin", "disseny"}


def permes(cami: str) -> bool:
    parts = PurePosixPath(clau(cami)).parts
    if protegit(cami) or not parts:
        return False
    if len(parts) == 1:
        return parts[0] in PERMESOS_FITXERS
    if parts[0] in PERMESOS_CARPETES:
        return True
    if parts[:2] == (".claude", "skills") and len(parts) > 3:
        return True
    return parts[:2] == ("brain", "transversal") and len(parts) > 2


def valid(cami: str) -> bool:
    p = PurePosixPath(cami)
    return not p.is_absolute() and ".." not in p.parts and cami == p.as_posix()


def resum(fitxer: Path) -> str:
    return hashlib.sha256(fitxer.read_bytes()).hexdigest()


def llegeix_paquet(paquet: Path) -> dict:
    fitxers = {}
    for arrel, dirs, noms in os.walk(paquet):
        rel_arrel = Path(arrel).relative_to(paquet)
        if rel_arrel == Path("."):
            dirs[:] = [d for d in dirs if d not in (".git", ".wos")]
        for d in dirs:
            if (Path(arrel) / d).is_symlink():
                raise Atura(f"El paquet porta un enllaç simbòlic ({(rel_arrel / d).as_posix()}): no s'aplica.")
        for nom in noms:
            f = Path(arrel) / nom
            cami = (rel_arrel / nom).as_posix()
            if f.is_symlink():
                raise Atura(f"El paquet porta un enllaç simbòlic ({cami}): no s'aplica.")
            fitxers[cami] = resum(f)
    return fitxers


def llegeix_manifest(repo: Path) -> dict:
    m = repo / MANIFEST
    if not m.exists():
        return {}
    try:
        fitxers = json.loads(m.read_text(encoding="utf-8")).get("fitxers", {})
    except (ValueError, AttributeError):
        fitxers = None
    if not isinstance(fitxers, dict) or not all(isinstance(k, str) and isinstance(v, str)
                                                for k, v in fitxers.items()):
        raise Atura(f"{MANIFEST} no es pot llegir: no s'aplica res.")
    return dict(fitxers)


def llegeix_repo(repo: Path) -> dict:
    """Els fitxers que hi ha al repositori (sense .git/), indexats per `clau`."""
    fitxers = {}
    for arrel, dirs, noms in os.walk(repo):
        rel_arrel = Path(arrel).relative_to(repo)
        if rel_arrel == Path("."):
            dirs[:] = [d for d in dirs if d != ".git"]
        for nom in noms:
            cami = (rel_arrel / nom).as_posix()
            fitxers.setdefault(clau(cami), []).append(cami)
    return fitxers


def passa_per_enllac(repo: Path, cami: str) -> bool:
    actual = repo
    for part in PurePosixPath(cami).parts:
        actual = actual / part
        if actual.is_symlink():
            return True
    return False


def planifica(paquet: Path, repo: Path):
    nous = llegeix_paquet(paquet)
    vells = llegeix_manifest(repo)

    vistos = {}
    for cami in nous:
        if not valid(cami):
            raise Atura(f"El paquet porta un camí no vàlid ({cami}): no s'aplica.")
        if protegit(cami):
            raise Atura(f"El paquet vol escriure a {cami}, que és teu: no s'aplica res.")
        if not permes(cami):
            raise Atura(f"El paquet porta {cami}, que no és cap lloc del sistema: no s'aplica res.")
        if clau(cami) in vistos:
            raise Atura(f"El paquet porta {vistos[clau(cami)]} i {cami}, que només es distingeixen per "
                        "les majúscules: no s'aplica.")
        vistos[clau(cami)] = cami

    # Què es retira: el que era del sistema, ja no és al paquet i és tal com el va deixar l'actualitzador.
    retirar, ignorats = [], []
    for cami, h in vells.items():
        if cami in nous:
            continue
        desti = repo / cami
        if not valid(cami) or not permes(cami) or passa_per_enllac(repo, cami):
            ignorats.append(cami)
        elif desti.is_file():
            (retirar if resum(desti) == h else ignorats).append(cami)
    es_retira = set(retirar)  # camins exactes: una variant de majúscules d'un fitxer teu no s'hi confon

    existents = llegeix_repo(repo)
    carpetes = {}
    for k, camins in existents.items():
        for pare in PurePosixPath(k).parents:
            if str(pare) != ".":
                carpetes.setdefault(str(pare), []).extend(camins)

    topades = []
    for cami in nous:
        if passa_per_enllac(repo, cami):
            raise Atura(f"{cami} passa per un enllaç simbòlic del teu repositori: no s'aplica res.")
        k = clau(cami)
        # Un fitxer amb el mateix nom (o només amb majúscules diferents).
        for altre in existents.get(k, []):
            if altre in es_retira:
                continue
            if altre == cami and (cami in vells or (not vells and resum(repo / cami) == nous[cami])):
                continue  # és del sistema, o (només a la primera instal·lació) és idèntic al del paquet
            topades.append(cami)
        # Una carpeta on el paquet necessita un fitxer.
        if any(f not in es_retira for f in carpetes.get(k, [])):
            topades.append(cami)
        # Un fitxer on el paquet necessita una carpeta.
        for pare in PurePosixPath(k).parents:
            if str(pare) != "." and any(c not in es_retira for c in existents.get(str(pare), [])):
                topades.append(cami)
    if topades:
        topades = sorted(set(topades))
        skills = sorted({PurePosixPath(c).parts[2] for c in topades
                         if c.startswith(".claude/skills/") and len(PurePosixPath(c).parts) > 3})
        linies = ["No s'ha aplicat l'actualització: el paquet porta coses que ja tens i que són teves."]
        if skills:
            linies.append("Skills del catàleg amb el mateix nom que una de teva: " + ", ".join(skills)
                          + ". Canvia el nom de la teva.")
        linies.append("Fitxers: " + ", ".join(topades) + ".")
        linies.append("No s'ha tocat res. Si no saps què fer, avisa qui t'ha instal·lat el Workspace OS.")
        raise Atura("\n".join(linies))
    return nous, vells, retirar, ignorats


def aplica(paquet: Path, repo: Path, origen: str = "") -> dict:
    nous, vells, retirar, ignorats = planifica(paquet, repo)
    informe = {"nous": [], "canviats": [], "desfets": [], "retirats": [], "ignorats": ignorats}

    # Primer es retira: així un fitxer del sistema que passa a ser carpeta (o al revés) no fa nosa.
    for cami in sorted(retirar):
        desti = repo / cami
        desti.unlink()
        informe["retirats"].append(cami)
        pare = desti.parent
        while pare != repo and pare.is_dir() and not any(pare.iterdir()):
            pare.rmdir()
            pare = pare.parent

    for cami, h in sorted(nous.items()):
        desti = repo / cami
        if desti.exists():
            ara = resum(desti)
            if ara == h:
                continue
            # Un fitxer del sistema que la persona havia canviat: torna a ser el del sistema, i es diu.
            informe["desfets" if cami in vells and ara != vells[cami] else "canviats"].append(cami)
        else:
            informe["nous"].append(cami)
        desti.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(paquet / cami, desti)
        os.chmod(desti, 0o755 if os.access(paquet / cami, os.X_OK) else 0o644)

    m = repo / MANIFEST
    m.parent.mkdir(parents=True, exist_ok=True)
    m.write_text(json.dumps({"versio": 1, "origen": origen, "fitxers": dict(sorted(nous.items()))},
                            ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return informe


ACTUALITZADOR = ".wos/actualitzador"
FITXERS_ACTUALITZADOR = {"actualitza.py", "actualitza.yml", "VERSIO", "CANVIS.md"}
WORKFLOW = ".github/workflows/actualitza.yml"


def versio(carpeta: Path) -> int:
    try:
        return int((carpeta / "VERSIO").read_text().strip())
    except (OSError, ValueError):
        return 0


def git(repo: Path, *args, check=True):
    import subprocess
    r = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        raise Atura(f"git {args[0]} ha fallat: {(r.stderr or r.stdout).strip()}")
    return r.stdout.strip()


def proposa(paquet: Path, repo: Path) -> str:
    """Si el paquet porta un actualitzador més nou, el deixa en una branca i en fa una proposta. No el fa
    servir mai: només corre quan la persona l'ha acceptat i ja és a `main`."""
    import subprocess
    nou, local = paquet / ACTUALITZADOR, repo / ACTUALITZADOR
    vn, vl = versio(nou), versio(local)
    if vn <= vl:
        return f"L'actualitzador és al dia (versió {vl})."
    for c in (paquet / ".wos", nou):
        if c.is_symlink():
            raise Atura(f"El paquet porta un enllaç simbòlic ({c.relative_to(paquet)}): no es proposa res.")
    fitxers = sorted(f.name for f in nou.iterdir())
    if set(fitxers) - FITXERS_ACTUALITZADOR or any((nou / f).is_symlink() or not (nou / f).is_file() for f in fitxers):
        raise Atura(f"L'actualitzador nou porta coses que no toquen ({', '.join(fitxers)}): no es proposa.")
    # El que diu el paquet de la versió nova es llegeix abans de crear res: si no es pot avisar, no es proposa.
    try:
        canvis = (nou / "CANVIS.md").read_text(encoding="utf-8") if (nou / "CANVIS.md").is_file() else ""
    except UnicodeDecodeError:
        raise Atura("El CANVIS.md de l'actualitzador nou no és text: no es proposa.")
    if len(canvis) > 20000:
        raise Atura("El CANVIS.md de l'actualitzador nou és massa llarg: no es proposa.")
    branca = f"actualitzador-v{vn}"
    if git(repo, "ls-remote", "--heads", "origin", branca):
        return f"L'actualitzador {vn} ja està proposat (branca {branca}): espera el teu sí."
    base = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    git(repo, "switch", "-q", "-c", branca)
    try:
        local.mkdir(parents=True, exist_ok=True)
        for f in fitxers:
            shutil.copyfile(nou / f, local / f)
        git(repo, "add", "--", ACTUALITZADOR)
        git(repo, "commit", "-q", "-m", f"Actualitzador nou (versió {vn})")
        git(repo, "push", "-q", "origin", branca)
    finally:
        git(repo, "switch", "-q", base, check=False)
    yml_nou = nou / "actualitza.yml"
    cal_yml = yml_nou.is_file() and (not (repo / WORKFLOW).is_file()
                                      or resum(yml_nou) != resum(repo / WORKFLOW))
    servidor = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
    nom_repo = os.environ.get("GITHUB_REPOSITORY", "")
    enllac = f"{servidor}/{nom_repo}/compare/{base}...{branca}?expand=1"
    # El text de qui publica va dins d'un bloc de codi: sense enllaços ni format que es facin passar pel sistema.
    tanca = "````"
    while tanca in canvis:
        tanca += "`"
    cos = (f"Hi ha una versió nova de l'actualitzador del Workspace OS (la {vn}; ara tens la {vl}).\n\n"
           f"Què hi diu qui t'ha instal·lat el Workspace OS:\n\n{tanca}text\n{canvis.strip()}\n{tanca}\n\n"
           "**No s'aplica fins que tu ho acceptes.** Pots llegir exactament què canvia a la pestanya "
           "«Files changed». Per acceptar-la, fes *Merge*. Si no, tanca-la: res no canvia.\n")
    if cal_yml:
        cos += (f"\n⚠️ Aquesta versió també canvia `{WORKFLOW}`, que GitHub no deixa canviar sol. Després del "
                f"*Merge*, copia-hi el contingut de `{ACTUALITZADOR}/actualitza.yml` (o demana-ho a qui t'ha "
                "instal·lat el Workspace OS).\n")
    titol = f"Actualitzador nou del Workspace OS (versió {vn})"
    pr = subprocess.run(["gh", "pr", "create", "--base", base, "--head", branca, "--title", titol, "--body", cos],
                        cwd=repo, capture_output=True, text=True)
    if pr.returncode == 0:
        return f"Proposta oberta: {pr.stdout.strip()}"
    cos_avis = cos.replace("Per acceptar-la, fes *Merge*.",
                           f"Per acceptar-la: obre {enllac}, *Create pull request* i després *Merge*.")
    av = subprocess.run(["gh", "issue", "create", "--title", titol, "--body", cos_avis],
                        cwd=repo, capture_output=True, text=True)
    if av.returncode != 0:
        git(repo, "push", "-q", "origin", "--delete", branca, check=False)   # demà ho tornarà a provar
        raise Atura(f"No s'ha pogut avisar de l'actualitzador nou ({branca}): {(av.stderr or pr.stderr).strip()}")
    return f"Avís obert: {av.stdout.strip()}"


def main() -> int:
    ap = argparse.ArgumentParser(description="Actualitza el Workspace OS des del paquet de l'intermedi.")
    ap.add_argument("paquet")
    ap.add_argument("repositori")
    ap.add_argument("--origen", default="")
    ap.add_argument("--proposa", action="store_true", help="proposa l'actualitzador nou, si n'hi ha, sense aplicar-lo")
    a = ap.parse_args()
    if a.proposa:
        try:
            print(proposa(Path(a.paquet).resolve(), Path(a.repositori).resolve()))
        except Atura as e:
            print(str(e), file=sys.stderr)
            return 2
        return 0
    try:
        inf = aplica(Path(a.paquet).resolve(), Path(a.repositori).resolve(), a.origen)
    except Atura as e:
        print(str(e), file=sys.stderr)
        return 2
    print(f"Nous: {len(inf['nous'])} · canviats: {len(inf['canviats'])} · retirats: {len(inf['retirats'])}")
    for tipus in ("nous", "canviats", "retirats"):
        for cami in inf[tipus]:
            print(f"  {tipus}: {cami}")
    for cami in inf["desfets"]:
        print(f"  l'havies canviat i torna a ser el del sistema: {cami}")
    for cami in inf["ignorats"]:
        print(f"  no tocat: {cami}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
