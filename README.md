# Prisme

Application macOS native (SwiftUI + Swift Charts) d'informatique décisionnelle, inspirée de Power BI Desktop :
importez des données, construisez des rapports interactifs par glisser-déposer.

## Fonctionnalités (v0.1)

- **Import de données** : CSV / TSV (détection du séparateur `,` `;` tab `|`, nombres au format français `1 234,56`,
  UTF-8 ou Windows-1252) et Excel `.xlsx` (toutes les feuilles, dates Excel reconnues). Glissez un fichier sur la page
  ou utilisez **Obtenir des données**. **Actualiser** relit les fichiers sources.
- **Typage automatique** des colonnes (Nombre, Texte, Date), modifiable dans la vue **Données**.
- **Canvas de rapport** 16:9 multi-pages : visuels déplaçables, redimensionnables, dupliquables.
- **Visuels** : histogramme, barres, courbe, aires, secteurs, anneau, carte (KPI), tableau, segment.
- **Volet Champs** : glissez les colonnes dans Axe / Légende / Valeurs, ou cliquez-les pour les ajouter au visuel
  sélectionné. Agrégations : somme, moyenne, min, max, nombre, nombre distinct. Hiérarchie de dates
  (année, trimestre, mois, jour).
- **Filtres** : segments, filtres de page (volet Filtres) et **filtrage croisé** (cliquez sur une barre, une part,
  un point ou une ligne de tableau pour filtrer les autres visuels de la page).
- **Relations entre tables** (vue **Modèle**) : relations plusieurs-à-un détectées automatiquement à l'import
  (colonnes de même nom et même type, dont l'une contient des valeurs uniques), ou créées en glissant une colonne
  sur une autre. Un visuel peut combiner des champs de plusieurs tables reliées (schéma en étoile ou en flocon), et
  les filtres se propagent du côté « 1 » vers le côté « * » (comme le filtrage à sens unique de Power BI).
  Les relations peuvent être désactivées ; un second chemin entre deux tables est créé inactif pour éviter les
  ambiguïtés.
- **Mesures calculées** (bouton **Nouvelle mesure**, ou clic droit sur une table) avec un langage inspiré de DAX :
  `SUM`, `AVERAGE`, `MIN`, `MAX`, `COUNT`, `DISTINCTCOUNT`, `COUNTROWS`, `DIVIDE`, `IF`, `ROUND`, `ABS`, `AND`/`OR`/`NOT`,
  `ISBLANK`, `COALESCE`, opérateurs `+ - * /`, comparaisons, `&&`/`||`, références `[Autre mesure]`, et
  `CALCULATE(expr, Table[Colonne] = valeur, ALL(…), ALLSELECTED(…), REMOVEFILTERS(…))`. L'éditeur valide
  l'expression en direct et affiche sa valeur ; formats : entier, décimal, pourcentage, monétaire.
  Exemple : `Part du CA = DIVIDE([Chiffre d'affaires], CALCULATE([Chiffre d'affaires], ALLSELECTED(Ventes)))`.
- **Enregistrement** des rapports (données incluses) au format `.prisme`.

## Construire

```bash
./build.sh          # crée Prisme.app
open Prisme.app
```

Nécessite les Command Line Tools (Swift 6) et macOS 14+. Le script compile avec le SDK macOS 26.5 car, sans Xcode
complet, les macros SwiftUI du SDK 27 ne sont pas disponibles.

Options utiles au développement :

- `Prisme --inspect fichier.csv` : affiche la façon dont un fichier est importé, puis quitte.
- `Prisme --sample` : démarre avec le jeu de données d'exemple (`--model` pour ouvrir la vue Modèle,
  `--edit-measure "Nom"` pour ouvrir l'éditeur d'une mesure).
- `Prisme --snapshot capture.png` : enregistre une image de la fenêtre 3 s après le lancement.

## Limites connues

- Pas de relations plusieurs-à-plusieurs ni de filtrage bidirectionnel.
- Langage de mesures limité : pas de fonctions d'itération (`SUMX`, `FILTER`), ni d'intelligence temporelle
  (`TOTALYTD`, `SAMEPERIODLASTYEAR`), ni de colonnes calculées ; `CALCULATE` n'accepte que des filtres d'égalité.
- Pas d'éditeur de requêtes (Power Query).
- Pas d'annuler / rétablir.

## Structure

| Fichier | Rôle |
|---|---|
| `Models.swift` | Tables, champs, visuels, pages, document |
| `Importer.swift` | Lecture CSV / XLSX et inférence des types |
| `Measures.swift` | Langage des mesures : analyse, validation, évaluation |
| `MeasureEditor.swift` | Éditeur de mesure |
| `Engine.swift` | Modèle de données, résolution des relations, filtrage, regroupement et agrégation |
| `AppState.swift` | État de l'application et actions |
| `CanvasView.swift` | Page de rapport, déplacement / redimensionnement |
| `VisualViews.swift` | Rendu des visuels (Swift Charts) |
| `Panes.swift` | Volets Visualisations, Données, Filtres |
| `DataGridView.swift` | Vue Données |
| `ModelView.swift` | Vue Modèle et volet Relations |
| `SampleData.swift` | Jeu de données d'exemple (Ventes, Produits, Régions) |

## Licence

MIT — voir [LICENSE](LICENSE).
