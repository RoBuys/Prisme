# Prisme

A native macOS business-intelligence app (SwiftUI + Swift Charts), inspired by Power BI Desktop:
import data, then build interactive reports with drag and drop. The interface is available in French and English
(**Prisme → Settings…** / ⌘, — follows the system language by default; the sample dataset follows it too).

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
- **Undo / redo** (⌘Z / ⇧⌘Z) for every document change.
- **Hover tooltips** on charts, optional **data labels**, and per-visual **formatting**: legend, gridlines, axis
  titles, main color, value format, sorting, **Top N**; click a table header to sort. Five report **themes**
  (select no visual to see the theme picker).
- **Export**: all pages as a PDF, the current page as a PNG image, a visual's data as CSV (`;` and decimal commas
  in French, `,` in English).
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

Development options:

- `Prisme --inspect file.csv`: prints how a file is imported, then quits.
- `Prisme --sample`: starts with the sample dataset (`--model` opens the Model view, `--powerbi` the Power BI view,
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
- Limited measure language: no iterators (`SUMX`, `FILTER`), no time intelligence (`TOTALYTD`,
  `SAMEPERIODLASTYEAR`), no calculated columns; `CALCULATE` only accepts equality filters.
- No query editor (Power Query).

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
| `PowerBIAuth.swift` | Microsoft Entra sign-in (PKCE) and Keychain storage |
| `PowerBIService.swift` | Power BI REST API client and state |
| `PowerBIView.swift` | Power BI view, settings and embedded report |
| `Localization.swift` | `L()` translation helper, language setting and English strings |
| `SampleData.swift` | Sample dataset (Ventes, Produits, Régions) |

## License

MIT — see [LICENSE](LICENSE).
