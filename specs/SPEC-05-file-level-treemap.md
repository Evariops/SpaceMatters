# SPEC-05 — Treemap au niveau fichier (budget RAM maîtrisé)

> **Findings** : S5 (README l'évoque), complète A8 (couleur de tuile). Optionnel, activable par toggle.

## 1. Objectif

Permettre au treemap de descendre **jusqu'aux fichiers** (pas seulement l'agrégat par répertoire), sans casser la promesse « low-RAM » — donc uniquement pour les répertoires dont les fichiers pèsent plus que le seuil de tuile visible, et de façon compacte.

## 2. État actuel (vérifié)

- Modèle « 1 nœud/répertoire » ([FSNode.swift](../Sources/MacDirStats/Model/FSNode.swift)) : les fichiers ne sont **pas** des objets ; agrégés dans `directFiles*`. Énumération on-demand des fichiers existe (`filesIn` [ScanController.swift:344](../Sources/MacDirStats/ViewModel/ScanController.swift#L344)) mais non persistée.
- Le treemap ([TreemapLayout.swift](../Sources/MacDirStats/Views/TreemapLayout.swift)) rend des tuiles par nœud ; les feuilles-fichiers manquent.

## 3. Axes & tradeoffs

- **Axe A — Un `FSNode` par fichier** : simple mais explose la RAM (le contraire du parti pris). ❌
- **Axe B — Stockage colonnaire par répertoire (recommandé)** : un blob compact `[(nameOffset: UInt32, logical: Int64, physical: Int64, extIndex: UInt8/UInt16)]` + une arène de noms, rempli **à la volée** pour les seuls répertoires dont les fichiers dépassent le seuil de tuile. ~24 octets/fichier affiché. Libéré quand le nœud sort du zoom.
- **Axe C — Rendu fichier sans persistance** : re-`filesIn` à chaque layout → coûteux (E1-like). ❌

**Recommandé : Axe B**, activable par un toggle « détail fichiers ».

## 4. Plan d'implémentation

1. `FileBlock` compact (colonnaire) attaché optionnellement à un `FSNode` quand il entre dans le zoom et que ses fichiers dépassent le seuil visible.
2. `TreemapLayout.compute` : quand un nœud est rendu et a un `FileBlock`, subdiviser sa tuile en tuiles-fichiers (squarify des tailles fichiers) au lieu d'une tuile-feuille unique.
3. Réutiliser `ExtKey`/palette pour la couleur par fichier (déjà cohérent avec la légende).
4. Gestion mémoire : remplir au zoom-in, vider au zoom-out (borne stricte).
5. (Lié A8) profiter du passage pour propager un dominant *pondéré du sous-arbre* pour les tuiles agrégées.

## 5. Vérification

- **Test** : `FileBlock` compact round-trip (noms, tailles, ext) ; budget mémoire ≤ 24 o/fichier.
- **Live** : zoomer dans un dossier de N gros fichiers → tuiles individuelles colorées par type, labels sur les grosses.

## 6. Risques & hypothèses

- 🔬 Seuil de matérialisation (taille de tuile visible) à calibrer pour éviter de matérialiser des milliers de petits fichiers invisibles.
- Interaction avec le hit-test/hover/selection au niveau fichier (le treemap raisonne aujourd'hui en nœuds).

## 7. Effort & dépendances

**2–3 jours.** Indépendant (synergie avec A8).
