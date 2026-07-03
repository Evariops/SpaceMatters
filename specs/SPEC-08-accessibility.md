# SPEC-08 — Accessibilité & internationalisation complètes

> **Findings** : J10.1 (VoiceOver), J10.2 (daltonisme), J10.3 (tailles de texte figées), J10.4 + J9.5 (i18n, locale mixte).
> **Statut** : ✅ VoiceOver complété · ✅ daltonisme/F6 · ✅ J9.5 · 🔬 J10.3 & traduction complète = chantiers dédiés documentés.

## 0. Résultat d'implémentation

- **VoiceOver (J10.1 complété)** : labels/valeurs ajoutés sur — pickers *Size metric* / *Counting mode*, bascule de thème, bouton *Storage reconciliation*, lignes *File types* (nom + taille + nb, trait bouton/sélection), segments du *breadcrumb* (nom + taille + « current/zoom »), **cartes de volume** (label+valeur « N% full »), **jauge K8s** (`N percent, OK/High/Critical`). Le **treemap** (Canvas opaque) expose désormais un résumé parlé : dossier zoomé + ses plus gros enfants en %. S'ajoute au 1er passage (stats, lignes de liste, dézoom).
- **Daltonisme (J10.2)** : le **pourcentage en texte** est un canal redondant sûr sur les jauges de volume (live-vérifié « 81% · … »), et un **niveau textuel** `OK/High/Critical` (`Theme.usageLevel`) dans l'accessibilité. **F6 corrigé** : seuils **unifiés 70/90** partout (`Theme.usageColor`) — volumes et K8s étaient 70/90 vs 70/85.
- **i18n — J9.5 corrigé** (SPEC-03) : `Format.bytes` est **localisé** (séparateur décimal), cohérent avec `Format.count` — plus de locale mixte (live-vérifié : « 85,7 GiB »).

## 0.b Chantiers dédiés restants (honnêtes)

- **🔬 J10.3 (échelle de texte / Dynamic Type)** : l'app utilise des tailles `.system(size:)` **fixes** par choix de densité ; les rendre réactives à « Larger Text » est un **rétrofit design global** (≈200 sites) qui doit être calibré pour ne pas casser la mise en page dense — chantier dédié, pas un bolt-on (cohérent avec le parti « robustesse du design »). Non tenté à chaud.
- **🔬 J10.4 (traduction complète)** : le **bug** de locale mixte (J9.5) est réglé ; la **traduction** dans d'autres langues (String Catalog `.xcstrings` peuplé) est un effort de localisation à part entière, hors v1.

## 1. Objectif

Rendre l'app utilisable au lecteur d'écran, robuste au daltonisme et aux préférences de taille de texte, et prête pour la localisation.

## 2. État actuel (vérifié)

- **J10.1 (premier passage livré)** : `accessibilityLabel/Value` ajoutés sur la barre de stats, les lignes de la liste (« Folder sub1, 979 KB » — **lu en live via l'API AX**), le treemap (zoom root + taille) et le bouton dézoom. Le reste du contenu (treemap = `Canvas`, tuiles individuelles) reste opaque.
- Couleur : info « type de fichier » portée par la **seule teinte** (16 teintes, collisions) ; jauges vert/orange/rouge sans forme/texte de secours (J10.2).
- Typos figées 9–13 pt, pas de réaction à la taille de texte système (J10.3).
- Tout en anglais hardcodé ; `Format.count` localisé mais `Format.bytes` non (J9.5, locale mixte).

## 3. Plan d'implémentation

1. **VoiceOver (compléter J10.1)** :
   - Boutons toolbar (Home/Rescan/theme) : `accessibilityLabel`.
   - Treemap : exposer les tuiles comme `accessibilityChildren` (ou un rotor) avec label « nom, taille, % du parent » — permet de parcourir la carte au clavier/VoiceOver.
   - Panneau File types, breadcrumb, jauges K8s : labels + valeurs.
   - (Synergie SPEC-01 : un `NSTableView` donne la sélection/focus/rotor accessibles nativement.)
2. **Daltonisme (J10.2)** : ne pas reposer sur la seule teinte — ajouter le **% en texte** sur les jauges, un motif/onde léger ou une étiquette de type sur les tuiles au survol, et vérifier les contrastes. Unifier les seuils de couleur (70/90 % VolumeCard vs 70/85 % K8s, cf. F6).
3. **Taille de texte (J10.3)** : facteur d'échelle global dans `Theme` piloté par la préférence système (ou un réglage), appliqué aux tailles de police.
4. **i18n (J10.4, J9.5)** : String Catalog (`.xcstrings`) pour les chaînes ; `Format.bytes` via un formateur **localisé** (cohérent avec `Format.count`) ; décider KiB/MiB vs base 10 (cf. SPEC-03).

## 4. Vérification

- **Live (méthode établie)** : lire l'arbre AX de l'app (`osascript` System Events) → chaque contrôle expose un label/valeur pertinent ; naviguer le treemap au rotor.
- Test manuel VoiceOver ; simulateur daltonien (Sim Daltonism) ; « Larger Text ».

## 5. Risques & hypothèses

- 🔬 Exposer les tuiles du `Canvas` treemap à AX sans dégrader le rendu (overlay d'éléments accessibles invisibles vs `accessibilityRepresentation`).
- i18n : le mélange de locales actuel (J9.5) est le premier bug à corriger avant toute traduction.

## 6. Effort & dépendances

**1–2 jours.** Le volet VoiceOver bénéficie de SPEC-01 (liste native). Indépendant sinon.
