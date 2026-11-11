# Prisme

A native macOS business-intelligence app (SwiftUI + Swift Charts), inspired by Power BI Desktop:
import data, then build interactive reports with drag and drop. The user interface is in French.

## Features (v0.1)

- **Data import**: CSV / TSV (detects the `,` `;` tab `|` delimiters, French-style numbers such as `1 234,56`,
  UTF-8 or Windows-1252) and Excel `.xlsx` (every sheet, Excel dates recognized). Drop a file on the page or use
  **Obtenir des données** (Get data). **Actualiser** (Refresh) re-reads the source files.
- **Automatic column typing** (number, text, date), editable in the **Données** (Data) view.
- **16:9 report canvas** with multiple pages: visuals can be moved, resized and duplicated. The page scales to the
  window, text included.
- **Visuals**: column, bar, line, area, pie, donut, card (KPI), table, slicer.
- **Fields pane**: drag columns into Axis / Legend / Values, or click them to add them to the selected visual.
  Aggregations: sum, average, min, max, count, distinct count. Date hierarchy (year, quarter, month, day).
- **Filters**: slicers, page filters (Filters pane) and **cross-filtering** (click a bar, a slice, a point or a table
  row to filter the other visuals of the page).
- **Relationships between tables** (**Modèle** / Model view): many-to-one relationships are detected on import
  (columns with the same name and type, one of which has unique values), or created by dragging a column onto
  another. A visual can combine fields from related tables (star or snowflake schema), and filters flow from the
  "one" side to the "many" side (like Power BI's single-direction filtering). Relationships can be deactivated; a
  second path between two tables is created inactive to avoid ambiguity.
- **Calculated measures** (**Nouvelle mesure** / New measure button, or right-click a table) with a DAX-inspired
  language: `SUM`, `AVERAGE`, `MIN`, `MAX`, `COUNT`, `DISTINCTCOUNT`, `COUNTROWS`, `DIVIDE`, `IF`, `ROUND`, `ABS`,
  `AND`/`OR`/`NOT`, `ISBLANK`, `COALESCE`, `+ - * /` operators, comparisons, `&&`/`||`, `[Other measure]`
  references, and `CALCULATE(expr, Table[Column] = value, ALL(…), ALLSELECTED(…), REMOVEFILTERS(…))`. The editor
  validates the expression as you type and previews its value; formats: integer, decimal, percentage, currency.
  Example: `Part du CA = DIVIDE([Chiffre d'affaires], CALCULATE([Chiffre d'affaires], ALLSELECTED(Ventes)))`.
- **Saving** reports (data included) as `.prisme` files.

## Building

```bash
./build.sh          # creates Prisme.app
open Prisme.app
```

Requires the Command Line Tools (Swift 6) and macOS 14+. The script builds against the macOS 26.5 SDK because,
without a full Xcode, the SwiftUI macros of the macOS 27 SDK are not available.

Development options:

- `Prisme --inspect file.csv`: prints how a file is imported, then quits.
- `Prisme --sample`: starts with the sample dataset (`--model` opens the Model view,
  `--edit-measure "Name"` opens a measure's editor).
- `Prisme --snapshot capture.png`: saves an image of the window 3 s after launch.

## Known limitations

- No many-to-many relationships, no bidirectional filtering.
- Limited measure language: no iterators (`SUMX`, `FILTER`), no time intelligence (`TOTALYTD`,
  `SAMEPERIODLASTYEAR`), no calculated columns; `CALCULATE` only accepts equality filters.
- No query editor (Power Query).
- No undo / redo.

## Structure

| File | Role |
|---|---|
| `Models.swift` | Tables, fields, visuals, pages, measures, relationships, document |
| `Importer.swift` | CSV / XLSX reading and type inference |
| `Measures.swift` | Measure language: parsing, validation, evaluation |
| `MeasureEditor.swift` | Measure editor |
| `Engine.swift` | Data model, relationship resolution, filtering, grouping and aggregation |
| `AppState.swift` | Application state and actions |
| `CanvasView.swift` | Report page, moving / resizing visuals |
| `VisualViews.swift` | Visual rendering (Swift Charts) |
| `Panes.swift` | Visualizations, Data and Filters panes |
| `DataGridView.swift` | Data view |
| `ModelView.swift` | Model view and Relationships pane |
| `SampleData.swift` | Sample dataset (Ventes, Produits, Régions) |

## License

MIT — see [LICENSE](LICENSE).
