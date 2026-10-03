#!/usr/bin/env python3
"""L'actualitzador del Workspace OS al perfil mòbil (bloc 21 §5, sessió 16).

    python3 .github/wos/actualitza.py <paquet> <repositori> [--origen <commit>]

Porta al repositori de la persona el paquet del seu intermedi, per manifest:

  · el que és al paquet, arriba;
  · el que era del sistema (és al manifest d'abans) i ja no hi és, s'esborra, però només
    si és tal com l'actualitzador el va deixar;
  · el que no ha estat mai del sistema, no es toca;
  · si el paquet porta una cosa que ja hi és i no era del sistema (una skill pròpia amb el
    mateix nom, per exemple), s'atura sense escriure res i ho diu.

⛔ Només copia i esborra fitxers: no executa mai res del paquet. Si ho fes, el que arriba
podria llegir el cervell i enviar-lo fora.

⛔ Hi ha camins que no toca mai, digui el que digui el manifest o el paquet (`PROTEGITS`).
Aquest fitxer viu a `.github/`, que és un d'ells: el paquet no el pot reescriure, i només
canvia si la persona ho accepta.

Tot es comprova abans d'escriure: o s'aplica sencer, o no s'aplica res.
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path, PurePosixPath

MANIFEST = ".wos/manifest.json"

# Camins de la persona. Arrels senceres, i dins de brain/ tot menys brain/transversal/.
PROTEGITS_ARRELS = {".git", ".github", ".wos", "work", "archives"}
PROTEGITS_FITXERS = {"context.md", "voice.md"}


class Atura(Exception):
    """Una condició per la qual no s'ha d'aplicar res."""


def protegit(cami: str) -> bool:
    parts = PurePosixPath(cami).parts
    if not parts:
        return True
    if parts[0] in PROTEGITS_ARRELS or cami in PROTEGITS_FITXERS:
        return True
    if parts[0] == "brain":
        return not (len(parts) > 2 and parts[1] == "transversal")
    return False


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
        return dict(json.loads(m.read_text(encoding="utf-8")).get("fitxers", {}))
    except (ValueError, AttributeError):
        raise Atura(f"{MANIFEST} no es pot llegir: no s'aplica res.")


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

    for cami in nous:
        if not valid(cami):
            raise Atura(f"El paquet porta un camí no vàlid ({cami}): no s'aplica.")
        if protegit(cami):
            raise Atura(f"El paquet vol escriure a {cami}, que és teu: no s'aplica res.")

    topades = []
    for cami in nous:
        if passa_per_enllac(repo, cami):
            raise Atura(f"{cami} passa per un enllaç simbòlic del teu repositori: no s'aplica res.")
        desti = repo / cami
        if cami not in vells and (desti.exists() or desti.is_symlink()):
            topades.append(cami)
        elif desti.is_dir():
            topades.append(cami)
        else:
            # Un fitxer teu on el paquet necessita una carpeta.
            pare = desti.parent
            while pare != repo:
                if pare.is_file():
                    topades.append(cami)
                    break
                pare = pare.parent
    if topades:
        skills = sorted({PurePosixPath(c).parts[2] for c in topades
                         if c.startswith(".claude/skills/") and len(PurePosixPath(c).parts) > 3})
        linies = ["No s'ha aplicat l'actualització: el paquet porta coses que ja tens i que són teves."]
        if skills:
            linies.append("Skills del catàleg amb el mateix nom que una de teva: " + ", ".join(skills) + ".")
        linies.append("Fitxers: " + ", ".join(sorted(topades)) + ".")
        linies.append("No s'ha tocat res. Canvia el nom de la teva o avisa qui t'ha instal·lat el Workspace OS.")
        raise Atura("\n".join(linies))

    retirar, ignorats = [], []
    for cami in vells:
        if cami in nous:
            continue
        if not valid(cami) or protegit(cami):
            ignorats.append(cami)
        else:
            retirar.append(cami)
    return nous, vells, retirar, ignorats


def aplica(paquet: Path, repo: Path, origen: str = "") -> dict:
    nous, vells, retirar, ignorats = planifica(paquet, repo)
    informe = {"nous": [], "canviats": [], "retirats": [], "ignorats": ignorats}

    for cami, h in sorted(nous.items()):
        desti = repo / cami
        if desti.exists():
            if resum(desti) == h:
                continue
            informe["canviats"].append(cami)
        else:
            informe["nous"].append(cami)
        desti.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(paquet / cami, desti)
        os.chmod(desti, 0o755 if os.access(paquet / cami, os.X_OK) else 0o644)

    for cami in sorted(retirar):
        desti = repo / cami
        if passa_per_enllac(repo, cami):
            informe["ignorats"].append(cami)
            continue
        if desti.is_file():
            # Només s'esborra si és tal com el va deixar l'actualitzador: si no, ja no és del sistema.
            if resum(desti) != vells[cami]:
                informe["ignorats"].append(cami)
                continue
            desti.unlink()
            informe["retirats"].append(cami)
        pare = desti.parent
        while pare != repo and pare.is_dir() and not any(pare.iterdir()):
            pare.rmdir()
            pare = pare.parent

    m = repo / MANIFEST
    m.parent.mkdir(parents=True, exist_ok=True)
    m.write_text(json.dumps({"versio": 1, "origen": origen, "fitxers": dict(sorted(nous.items()))},
                            ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return informe


def main() -> int:
    ap = argparse.ArgumentParser(description="Actualitza el Workspace OS des del paquet de l'intermedi.")
    ap.add_argument("paquet")
    ap.add_argument("repositori")
    ap.add_argument("--origen", default="")
    a = ap.parse_args()
    try:
        inf = aplica(Path(a.paquet).resolve(), Path(a.repositori).resolve(), a.origen)
    except Atura as e:
        print(str(e), file=sys.stderr)
        return 2
    print(f"Nous: {len(inf['nous'])} · canviats: {len(inf['canviats'])} · retirats: {len(inf['retirats'])}")
    for clau in ("nous", "canviats", "retirats"):
        for cami in inf[clau]:
            print(f"  {clau}: {cami}")
    for cami in inf["ignorats"]:
        print(f"  no tocat: {cami}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
