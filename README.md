# Prisme

A native macOS business-intelligence app (SwiftUI + Swift Charts), inspired by Power BI Desktop:
import data, then build interactive reports with drag and drop. The interface is available in French and English
(**Prisme → Settings…** / ⌘, — follows the system language by default; the sample dataset follows it too).

## Features (v0.1)

- **Data import**: CSV / TSV (detects the `,` `;` tab `|` delimiters, French-style numbers such as `1 234,56`,
  UTF-8 or Windows-1252) and Excel `.xlsx` (every sheet, Excel dates recognized). Drop a file on the page or use
  **Obtenir des données** (Get data). **Actualiser** (Refresh) re-reads the source files.
- **Databases and web sources** (**Obtenir des données** / Get data, ⌘I): **SQLite** (system library), **PostgreSQL**
  (built-in client: protocol v3, SCRAM-SHA-256 / MD5 / password authentication, optional TLS), **MySQL** (through the
  `mysql` command-line client, e.g. `brew install mysql-client`) and **web APIs / JSON** (GET with an optional header
  such as `Authorization`, nested objects flattened to `a.b` columns, optional JSON path). Passwords and tokens are
  kept in the macOS Keychain; refresh re-runs the query.
- **Automatic column typing** (number, text, date), editable in the **Données** (Data) view.
- **Data transformations** (Power Query-like **applied steps**, in the Data view: **Transform** menu or a column
  header): rename, remove, change type, filter rows, replace values, split, trim, fill down, remove duplicates /
  blank rows, keep first rows, append another table, add an index column, **merge queries** (left / inner join),
  **group by** (several keys and aggregations), **pivot**, **unpivot** and **conditional columns**. Steps are replayed on every refresh and
  can be removed in any order; a failing step is flagged and skipped.
- **16:9 report canvas** with multiple pages: visuals can be moved, resized and duplicated. The page scales to the
  window, text included.
- **Visuals**: column, bar, line, area, pie, donut, card, table, slicer, **matrix** (cross-tab with row and column
  totals), **scatter** (X / Y / bubble size), **line and column** combo, **gauge** (value, target, maximum), **KPI**
  (value vs target with a trend sparkline) and **map** (bubbles sized by value; place names are geocoded with
  Apple's geocoding service and cached locally). Also **stacked** column / bar, **100% stacked** column, **waterfall**
  and **funnel** charts.
- **Conditional formatting**: color scales, data bars and icons on table / matrix values; bars colored by value. The sample dataset has a second page showing them.
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
  Also: iterators `SUMX`, `AVERAGEX`, `MINX`, `MAXX`, `COUNTX` and `FILTER(table, condition)` (row context with
  `RELATED`), comparison filters in `CALCULATE` (`Ventes[Montant] > 1000`), time intelligence (`TOTALYTD`,
  `TOTALQTD`, `TOTALMTD`, `DATESYTD`, `DATESQTD`, `DATESMTD`, `SAMEPERIODLASTYEAR`, `DATEADD`, `PREVIOUSMONTH`,
  `PREVIOUSYEAR`), text and date functions (`&`, `UPPER`, `LOWER`, `LEN`, `LEFT`, `RIGHT`, `YEAR`, `MONTH`, `DAY`).
  Plus `VAR … RETURN`, `SWITCH`, `SELECTEDVALUE`, `HASONEVALUE`, `ISFILTERED`, `VALUES`, `RANKX`, `TOPN`,
  `ALLEXCEPT`, `KEEPFILTERS`, `USERELATIONSHIP`, `LOOKUPVALUE`, `DATEDIFF`, `EOMONTH`, `DATE`, `TODAY`, `FORMAT`,
  `CONCATENATE`, `INT`, `MOD`, `POWER`, `SQRT`, `VALUE`, and **quick measures** in the editor (year to date, previous
  year, year-over-year %, running total, % of total, rank, average per category).
- **Calculated columns** (**Nouvelle colonne** / New column): an expression evaluated for each row (row context,
  `RELATED`, measures with context transition), recomputed after each refresh.
- **Hierarchies and drill**: put several fields on a chart's axis (or turn a date into Year › Quarter › Month › Day)
  to drill up, drill down on click, or go to the next level from the visual's header. **Drillthrough**: add
  drillthrough fields to a page (Filters pane), select a category in a visual elsewhere, then “…” › Drill through;
  a Back button returns to the source page.
- **Bookmarks** (ribbon › Bookmarks): save and restore the current page, page filters, slicer selections and drill
  state. **Synced slicers**: slicers on the same field can share their selection across pages (“Add to all pages”).
- **Undo / redo** (⌘Z / ⇧⌘Z) for every document change.
- **Hover tooltips** on charts, optional **data labels**, and per-visual **formatting**: legend, gridlines, axis
  titles, main color, value format, sorting, **Top N**; click a table header to sort. Five report **themes**
  (select no visual to see the theme picker).
- **Export**: all pages as a PDF, the current page as a PNG image, a visual's data as CSV (`;` and decimal commas
  in French, `,` in English).
- **Power BI import** (**File › Import a Power BI Report…**, ⌥⌘O, or drop the file): **.pbit** templates and
  **.pbip** projects (TMSL `model.bim` or TMDL, PBIR or legacy `report.json`) bring tables, columns, calculated
  columns, measures, relationships, pages and visuals (scaled to the page). Data is reloaded from the sources found
  in the M queries (CSV / Excel / JSON files — Windows paths are looked up next to the report or asked for — web,
  PostgreSQL, MySQL). **.pbix** files only expose their layout: tables are recreated empty from the visuals' fields
  (use **Change Source…** on a table) and measures as placeholders. An import summary lists what couldn't be
  converted (unsupported visuals or DAX, calculated tables, bidirectional relationships).
- **Saving** reports (data included) as `.prisme` files.
- **Power BI reports shared with you** (**Power BI** view, cloud icon): sign in with your Microsoft work account,
  browse My workspace and shared reports, workspaces and apps, and display reports interactively (embedded with the
  official Power BI JavaScript client). You can also paste a link copied from app.powerbi.com; "Publish to web"
  links open without signing in. See [Connecting to Power BI](#connecting-to-power-bi).

## Building

```bash
./build.sh          # creates Prisme.app
open Prisme.app
```

Requires the Command Line Tools (Swift 6) and macOS 14+. The script builds against the macOS 26.5 SDK because,
without a full Xcode, the SwiftUI macros of the macOS 27 SDK are not available.

Tests (Swift Testing — importers, query engine, DAX, transformations, documents, undo, Power BI import,
translations):

```bash
./test.sh
```

The Power BI fixtures in `Tests/PrismeTests/Fixtures` are synthetic files written from Microsoft's format
documentation.

Development options:

- `Prisme --inspect file.csv`: prints how a file is imported, then quits.
- `Prisme --sample`: starts with the sample dataset (`--page 2` selects a page, `--data` / `--model` / `--powerbi`
  open those views,
  `--edit-measure "Name"` opens a measure's editor).
- `Prisme --snapshot capture.png`: saves an image of the window 3 s after launch.

## Connecting to Power BI

Prisme signs in as you (delegated permissions, OAuth 2.0 authorization code flow with PKCE; no client secret). The
refresh token is stored in the macOS Keychain. Requirements:

- A Microsoft work or school account with a **Power BI Pro** or **Premium Per User** license (or content hosted on a
  Premium / Fabric capacity).
- An **app registration** in Microsoft Entra ID, created once (you may need your administrator for consent):

1. Open the [Microsoft Entra admin center](https://entra.microsoft.com) → **Applications** → **App registrations** →
   **New registration**.
2. Name: `Prisme`. Supported account types: *Accounts in this organizational directory only* (or multitenant if you
   need several organizations).
3. Redirect URI: platform **Public client/native (mobile & desktop)**, value `prisme://auth`. Register.
4. **API permissions** → **Add a permission** → **Power BI Service** → **Delegated permissions**: `Report.Read.All`,
   `Workspace.Read.All`, `App.Read.All`, `Dataset.Read.All`. If your organization requires it, click
   **Grant admin consent** (or ask an administrator).
5. Copy the **Application (client) ID** (and optionally the **Directory (tenant) ID**) from the app's Overview page.
6. In Prisme: **Power BI** view → gear icon → paste the client ID (tenant: keep `organizations`, or paste your tenant
   ID / domain) → **Se connecter avec Microsoft**.

The report list uses the Power BI REST API (`GET /reports`, which includes reports shared with you, `GET /groups`,
`GET /groups/{id}/reports`, `GET /apps`, `GET /apps/{id}/reports`). Reports are displayed in a web view with
`powerbi-client` (loaded from jsDelivr with Subresource Integrity), using your Entra token (`TokenType.Aad`), which is
renewed automatically.

## Known limitations

- No many-to-many relationships, no bidirectional filtering.
- The measure language is a subset of DAX: no calculated tables, no table variables, no `SUMMARIZE` / `ADDCOLUMNS`.
- Power BI import doesn't run M transformations (only the source is read), and .pbix data can't be read.
- Transformations cover common steps only (no custom M code, no fuzzy merge).

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
| `Transforms.swift` | Transformation steps, applied-steps pane and step editor |
| `MoreVisuals.swift` | Scatter, gauge, KPI and map visuals |
| `Export.swift` | PDF / PNG / CSV export |
| `ModelView.swift` | Model view and Relationships pane |
| `PowerBIAuth.swift` | Microsoft Entra sign-in (PKCE) and Keychain storage |
| `PowerBIService.swift` | Power BI REST API client and state |
| `PowerBIView.swift` | Power BI view, settings and embedded report |
| `Localization.swift` | `L()` translation helper, language setting and English strings |
| `PowerBIImport.swift` | .pbit / .pbip / .pbix import (TMSL, TMDL, Layout, PBIR, M sources) |
| `SampleData.swift` | Sample dataset (Ventes, Produits, Régions) |

## License

MIT — see [LICENSE](LICENSE).
