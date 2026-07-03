# Spécifications par chantier — MacDirStats

Chaque `SPEC-*.md` est un cahier des charges autonome pour un chantier différé du [plan d'action](../PLAN-ACTION.md), rédigé pour être repris en session dédiée. Format commun :

1. **Objectif & findings couverts** — le pourquoi, avec renvois aux audits.
2. **État actuel du code (vérifié)** — ce qui existe, cité `fichier:ligne`.
3. **Axes de conception & tradeoffs** — options réelles, avec recommandation justifiée.
4. **Plan d'implémentation** — fichiers, étapes.
5. **Vérification** — tests + pilotage live (la méthode par captures d'écran + clics par coordonnées est établie et fonctionne).
6. **Risques & hypothèses (🔬)** — ce qui reste à prouver.
7. **Effort & dépendances**.

Principe directeur (repris du plan) : **intégrité > performance > robustesse > simplicité > maintenabilité**, long terme d'abord.

| Spec | Chantier | Findings | Effort | Dépend de |
|---|---|---|---|---|
| [SPEC-01](SPEC-01-keyboard-navigation.md) | Navigation clavier & liste native | J3.1, J4.2, J3.7 | 1–2 j | — |
| [SPEC-02](SPEC-02-invalidation-rescan.md) | Invalidation & re-scan de sous-arbre | B1(cure), A6, A7, J4.4, D1 | 1–2 j | — |
| [SPEC-03](SPEC-03-exact-vs-attribution.md) | Comptage exact vs attribution + réconciliation | A3, A4, A10, J9 | 2–3 j | — |
| [SPEC-04](SPEC-04-fsevents-live.md) | FSEvents — tableau de bord vivant | S3, J5.2, J4.5, D1 | 1–2 j | SPEC-02 |
| [SPEC-05](SPEC-05-file-level-treemap.md) | Treemap au niveau fichier | S5 | 2–3 j | — |
| [SPEC-06](SPEC-06-pluggable-backends.md) | Backends pluggables | S6 | ~1 j/backend | — |
| [SPEC-07](SPEC-07-distribution.md) | Distribution (icône, notarisation, About) | J1.1–J1.5, D4 | 1–2 j | — |
| [SPEC-08](SPEC-08-accessibility.md) | Accessibilité & i18n complètes | J10.1–J10.4, J9.5 | 1–2 j | SPEC-01 (partiel) |

**Ordre recommandé** : SPEC-02 (débloque SPEC-04 et ferme A6/A7 proprement) → SPEC-01 → SPEC-03 → SPEC-08 → SPEC-04 → SPEC-05/06/07 selon priorités produit.
