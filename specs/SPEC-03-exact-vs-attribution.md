# SPEC-03 — Comptage exact vs attribution + réconciliation des chiffres

> **Findings** : A3 (hardlinks comptés par lien), A4 (clones APFS non déduits), A10 (base 1024 étiquetée KB), J9 (« pourquoi ça ne matche pas Finder ? »), J9.5 (locale mixte). Renvoie à D-G/S4 du plan. A1 (montages) est **déjà corrigé**.
> **Statut** : ✅ **IMPLÉMENTÉ** — A3 exact (validé contre `du`), A10/J9.5, J9 réconciliation. A4 en repli honnête (conforme §3.b/§6).

## 0. Résultat d'implémentation

- **A3 hardlinks (exact) — validé contre `du`** : `CountingMode { attribution | exact }` (toggle toolbar, hôte). En mode exact, l'énumérateur bulk demande `ATTR_CMN_FILEID` + `ATTR_FILE_LINKCOUNT` (lus en ordre de bits exact ; **le mode attribution par défaut packe un buffer identique** — reads gardés par le masque `returned`), et le scanner dédup les inodes multi-liens (`Set<UInt64>`, seulement `linkCount > 1` → mémoire négligeable). Test golden `exactModeDedupsHardlinks` : exact ↔ `du -skx`, attribution ↔ `du -sklx`. Bascule = re-scan (dédup au scan). VM = attribution.
- **A10 + J9.5 (format)** : `Format.bytes` → base 1024 avec **libellés IEC honnêtes** (KiB/MiB/…), séparateur décimal **localisé**. Test `formatBytes` mis à jour.
- **J9 réconciliation** : `Reconciliation` (modèle) + `ReconciliationButton`/popover (scans de volume entier). Décompose « utilisé (API) » = scan + corbeille (`~/.Trash` + `.Trashes`) + purgeable (`importantUsage − available`, avec nb de snapshots `tmutil`) + non-attribué ; signale `scanExceedsUsed` (signature de l'attribution sur hardlinks/clones) et les chemins illisibles. Test `reconciliationArithmetic`.
- **A4 clones APFS — repli honnête (conforme au plan)** : le §3.b/§6 marquait `ATTR_CMNEXT_PRIVATESIZE` 🔬 « à prototyper / repli honnête si non fiable ». Le parsing d'attributs étendus (`forkattr`) est plus risqué que le buffer standard ; **non adopté**. À la place, note UI explicite (tooltip du toggle + panneau réconciliation) : « les clones APFS sont comptés pleins dans les deux modes et peuvent gonfler le total au-delà de `df` ».
- **A1 (montages)** : déjà corrigé.

## 1. Objectif

Formaliser deux **modes de comptage** explicites et régler la première objection de tout utilisateur (« ça ne matche pas Finder/df ») :
- **Attribution** (défaut actuel) : « qui est responsable de l'espace » — hardlinks par lien, clones pleins.
- **Exact disque** : dédup hardlinks + taille privée des clones + borné au volume (A1 déjà fait) → **matche `df`**.
Plus un **panneau de réconciliation** qui décompose l'écart avec l'espace « utilisé » du volume.

## 2. État actuel du code (vérifié)

- `physical` = Σ `fileAllocSize` ([FSAttr.swift](../Sources/MacDirStats/Scanner/FSAttr.swift), `ATTR_FILE_ALLOCSIZE`). Hardlinks : chaque lien compté (validé = `du -skl`). Clones : comptés pleins.
- A1 (mount status) : **corrigé et vérifié** — le scan reste sur le volume (`du -skx`).
- `Format.bytes` ([Formatting.swift:5](../Sources/MacDirStats/Util/Formatting.swift#L5)) : base 1024, libellés « KB/MB » (non localisé) ; `Format.count` localisé (J9.5, locale mixte).
- Le volume expose déjà capacités via `Volume` / `URLResourceValues`.

## 3. Axes de conception & tradeoffs

### 3.a Hardlinks (A3)
- Demander `ATTR_CMN_FILEID` + `ATTR_CMN_DEVID` + `ATTR_FILE_LINKCOUNT` dans le bulk.
- Pour les seules entrées `nlink > 1` : dédup via `Set<UInt64>` clé `(dev, ino)` (ou `[dev: Set<ino>]`). Ne compter les blocs qu'à la **première** occurrence. Mémoire bornée au nb de fichiers multi-liens (marginal).
- *Tradeoff* : +12 octets/entrée dans le buffer bulk, un `Set` partagé sous lock (ou par-worker fusionné). En mode « Exact » seulement.

### 3.b Clones APFS (A4)
- `ATTR_CMNEXT_PRIVATESIZE` (taille non partagée par fichier) via `FSOPT_ATTR_CMN_EXTENDED` + `forkattr`. 🔬 disponibilité/fiabilité selon versions, coût buffer plus gros — **à mesurer avant d'adopter**.
- Repli honnête si non fiable : note UI « les clones APFS peuvent gonfler ce total ».

### 3.c Réconciliation (J9)
Panneau en fin de scan de volume :
```
Volume utilisé (API)  = scan + corbeille + snapshots locaux + purgeable + illisible + delta
```
- scan = total mesuré ; corbeille = taille de `~/.Trash` (et `.Trashes` du volume) ; snapshots = `tmutil listlocalsnapshots` ; purgeable = `volumeAvailableCapacityForImportantUsage − volumeAvailableCapacity` ; illisible = `errorCount` (chemins skipped) ; delta = reste inexpliqué.

### 3.d Base 1024 / locale (A10, J9.5)
- Libellés honnêtes **KiB/MiB** *ou* toggle base 10 / 1024 à côté du toggle On disk/Logical.
- Unifier la locale : `Format.bytes` via `MeasurementFormatter`/`ByteCountFormatter` localisé, cohérent avec `Format.count`.

## 4. Plan d'implémentation

1. Enum `CountingMode { .attribution, .exact }` dans `ScanController`, exposé par un toggle (à côté de On disk/Logical).
2. `DirectoryScanner` : en mode `.exact`, demander les attributs hardlink + (optionnel) private-size ; dédup `(dev,ino)` ; utiliser `privateSize` au lieu de `allocSize` pour les clones si disponible.
3. Panneau **Réconciliation** : nouveau composant sous le treemap (ou onglet), alimenté par `Volume` capacités + `tmutil` (via `ProcessRunner`) + taille corbeille + `errorCount`.
4. `Format.bytes` : libellés KiB/MiB (ou toggle) + localisation.

## 5. Vérification

- **Golden tests** : fixture avec hardlinks → mode **Exact** == `du -sk` (dédupliqué), mode **Attribution** == `du -skl`. Fixture avec clone `cp -c` → mode Exact ≈ taille privée.
- **Réconciliation** : sur un vrai volume, `scan + corbeille + snapshots + purgeable + illisible + delta ≈ used(API)` avec delta petit ; comparer à `df`.
- **Live** : basculer Exact/Attribution → le total change du bon montant sur une fixture à hardlinks.

## 6. Risques & hypothèses

- 🔬 `ATTR_CMNEXT_PRIVATESIZE` : disponibilité, coût buffer, sémantique exacte sur clones partiels — **à prototyper**.
- 🔬 Ordre de packing des attributs étendus (`forkattr`) dans le buffer bulk — même prudence que pour A1 (`dirattr`).
- La réconciliation dépend de `tmutil` (droit d'accès aux snapshots) et de la précision de `purgeable` (approximation Apple).

## 7. Effort & dépendances

**2–3 jours** (A3 ~½ j, A4 incertain ~½–1 j, réconciliation ~1 j, formatage ~¼ j). Indépendant. Décision **produit** (deux modes) autant que technique.
