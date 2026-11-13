# gaiaDB

A PostGIS Docker image for the [OHDSI GIS workgroup](https://github.com/OHDSI). gaiaDB provides a schema and function library for ingesting, cataloguing, and spatially joining external geospatial data sources against OMOP cohort locations.

> **Status:** under active development

---

## Contents

- [Architecture](#architecture)
- [Quick Start](#quick-start)
- [Data Initialization](#data-initialization)
- [Ingestion Protocol](#ingestion-protocol)
- [Dataset Structure](#dataset-structure)
- [Loading Variables and Spatial Joins](#loading-variables-and-spatial-joins)
- [Raster Sources](#raster-sources)
- [Point Sources](#point-sources-voronoi-cells-and-nearest-point-joins)
- [End-to-End Demo](#end-to-end-demo)
- [Function Reference](#function-reference)
- [Support](#support)
- [Developer Guidelines](#developer-guidelines)

---

## Architecture

gaiaDB extends `postgis/postgis:16-3.5-alpine` with:

| Schema | Purpose |
|--------|---------|
| `backbone` | Metadata and catalog tables (`data_source`, `variable_source`, `geom_index`, `attr_index`, `geom_template`, `attr_template`) and all ingestion/retrieval functions |
| `working` | `location`, `location_history` (joined by the `location_merge` view), per-dataset `geom_{table_id}` / `attr_{table_id}` instance tables, and the `external_exposure` output table |
| `vocabulary` | OMOP vocabulary tables (concept, relationship, domain, etc.) |
| `public` | Raw source tables loaded by each dataset's ETL scripts (one table per `table_id`) |

SQL functions are loaded from `/sql/` at container init time. ETL scripts for each dataset live under `/data/{table_id}/etl/`. Example location CSVs are bundled at `/extras/csv/`.

---

## Quick Start

```bash
git clone https://github.com/OHDSI/gaiaDB.git
cd gaiaDB
docker build -t gaia-db .

docker run -d \
  -e POSTGRES_PASSWORD=secret \
  -e DB_AUTHENTICATOR_PASSWORD=secret \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_DB=gaiacore \
  -e POSTGRES_PORT=5432 \
  -e POSTGRES_HOST=gaia-db \
  -p 5432:5432 \
  --name gaia-db \
  --hostname gaia-db \
  gaia-db
```

On first start the container automatically:
1. Populates `/data/` (see [Data Initialization](#data-initialization))
2. Runs `/docker-entrypoint-initdb.d/` scripts to create schemas, tables, vocabulary, and load all SQL functions

---

## Data Initialization

Three mutually exclusive modes are controlled by environment variables. `INIT_WITH_DATASOURCE_MOUNT` takes priority.

| Variable | Default | Behaviour |
|----------|---------|-----------|
| `INIT_WITH_DATASOURCE_MOUNT` | `FALSE` | When `TRUE`, skip all population — `/data` must be a bind-mount containing datasets in the standard structure as -v /absolute/path/to/data:/data |
| `INIT_WITH_CATALOG` | `TRUE` | When `TRUE`, shallow-clone [OHDSI/gaiaCatalog](https://github.com/OHDSI/gaiaCatalog) and copy `./datastore/data/*` into `/data/`. When `FALSE`, copy the bundled example dataset from `/extras/` into `/data/` |

The example location CSVs are always available at `/extras/csv/` regardless of mode.

### Using a local data directory (bind-mount)

Note that you may need to adjust permissions on your local directory structure that you are going to mount. The directory structure will need to have the equivalent of 755 permissions for a non-root user (drwxr-xr-x).

```bash
docker run -d \
  -e INIT_WITH_DATASOURCE_MOUNT=TRUE \
  -v /path/to/your/data:/data \
  ... gaia-db
```

### Using the bundled example dataset only

```bash
docker run -d \
  -e INIT_WITH_CATALOG=FALSE \
  ... gaia-db
```

---

## Ingestion Protocol

After the container is running, ingest a dataset with a single SQL call:

```sql
SELECT * FROM backbone.ingest_datasource('ma_2022_svi_tract');
```

This runs three steps in sequence (four for a raster) and streams a status row for each:

| Step | Script / Action | Description |
|------|----------------|-------------|
| `metadata_load` | `load_datasource_metadata()` | Reads `/data/{table_id}/meta_json-ld_{table_id}.json`, populates `backbone.data_source` and `backbone.variable_source`, and registers `backbone.geom_index` / `backbone.attr_index` catalog entries (variables whose dates are ambiguous, see below, are skipped from `attr_index` with a warning) |
| `ingestion` | `{table_id}_osgeo.sh` | Downloads the source file and loads it into PostGIS via `ogr2ogr` |
| `postgis` | `{table_id}_postgis.sh` | Cleans geometry (`ST_MakeValid`), adds a local-projection column, creates spatial index |

The postgis step is skipped automatically if the osgeo step fails.

### Variable dates

A variable's period is `startDate`/`endDate` in the JSON-LD. A date may be given only to the year (`"2021"`) or the month (`"2021-03"`) and then stands for the whole period (1 January to 31 December, or the whole month). When only one end is given, the other is the end of the same period: `startDate` `"2021"` alone is the year 2021. A variable with neither date takes, in this order, the dataset's `temporalCoverage` (`"2014-01-01/2019-12-31"`, or a single year or date); the **static** period when the dataset is marked static (below); and, for a **raster** source only, the year in the dataset name (leading, `"2021 Miami-Dade NLCD Land Cover"`) and the table_id (`mdc_2021_nlcd_land_cover`), which must agree when both have one. A dataset whose attributes do not change over time (an elevation model, the area of a boundary) is marked in its JSON-LD, for any data structure:

```json
"additionalProperty": [{"@type": "PropertyValue", "name": "temporalDimension", "value": "static"}]
```

Its undated variables get the period 1900-01-01 to 2100-12-31, so a join returns them for the whole residence period, as for a geometry-only source. For a vector or table dataset only variables with a numeric `qudt:dataType` (`float8`, `int4`, ...) are registered this way: identifiers and names (`varchar`, `string`, no type) stay unregistered, because the variable loader writes each registered variable's column into a numeric value field. A **raster** that is not marked and still has no date is treated as static in the same way, like an elevation model. The exception is a raster whose name and table_id disagree on the year: that is ambiguous and the variable is skipped with a warning. **Vector** variables without dates, in a dataset that is not marked static, are still skipped (a warning): many are undated on purpose, such as identifiers, names and the attributes of a vintage. Every date taken from somewhere other than the variable's own full dates is reported with a `NOTICE`. Explicit dates always win, so check them: a wrong `startDate` is used as it is.

For a **raster** source (`measurementTechnique` term `raster` in the JSON-LD) the `postgis` step loads the raster table (`raster2pgsql`) and a fourth step, `raster_register`, calls `backbone.gdsc_load_all_raster_variables()` so the variables and their layers are registered in `backbone.attr_index` / `backbone.raster_layer`. For a table loaded from one file per period, list the periods in a `raster_layers` array in `/data/{table_id}/meta_etl_{table_id}.json` (`[{"filename": "...", "start_date": "...", "end_date": "..."}]`); without it the whole table is one layer over the variable's dates. See [Raster Sources](#raster-sources).

### Individual steps

```sql
-- Load metadata only
SELECT * FROM backbone.load_datasource_metadata('ma_2022_svi_tract');

-- Run just the osgeo script (download + load)
SELECT * FROM backbone.retrieve_and_ingest_datasource(
    '<uuid>',
    '/data/ma_2022_svi_tract/etl/ma_2022_svi_tract_osgeo'
);

-- List all registered datasets with their ETL script paths
SELECT * FROM backbone.list_downloadable_datasources();
```

---

## Dataset Structure

Each dataset under `/data/` follows this layout (mirrored from gaiaCatalog):

```
/data/{table_id}/
  meta_json-ld_{table_id}.json       ← JSON-LD metadata (dataset + variables)
  meta_etl_{table_id}.json           ← ETL configuration (geometry, EPSG, fields)
  meta_dcat_{table_id}.json          ← DCAT catalog metadata
  etl/
    {table_id}_osgeo.sh              ← Step 1: download + ogr2ogr load
    {table_id}_postgis.sh            ← Step 2: geometry cleanup + local projection
    {table_id}_osgeo_derivative.sh   ← (publishing) create derived osgeo outputs
    {table_id}_postgis_derivative.sh ← (publishing) pg_dump + tarball for download
  download/                          ← created at runtime by _osgeo.sh
  derived/                           ← created at runtime by derivative scripts
```

The JSON-LD file drives metadata ingestion. Key fields used:

| JSON-LD field | `backbone.data_source` column |
|---------------|-------------------------------|
| `@id` | `dataset_id` |
| `name` | `dataset_name` |
| `measurementTechnique[vectorGeometry].termCode` | `geom_type` |
| `additionalProperty[Spatial_reference_system].value` | `srid` |
| `about` | `etl_metadata` |
| `variableMeasured[].propertyID[0]` | `variable_source.property_id` / `attr_concept_id` |
| `variableMeasured[].startDate` / `endDate` | `variable_source.start_date` / `end_date`, `attr_index.attr_start_date` / `attr_end_date` |

---

## Loading Variables and Spatial Joins

Once a dataset's raw table exists in `public`, two catalog steps turn it into exposures:

1. **`backbone.gdsc_load_all_variables(table_id, geom_label, ...)`** runs `gdsc_load_variable()` for every variable registered in `backbone.attr_index`. It creates and fills `working.geom_{table_id}` (one row per feature; `geom_record_id` is the raw table's primary key, e.g. `ogc_fid`) and `working.attr_{table_id}` (one row per feature, variable, and time window, keyed by `attr_index_id`).
2. **`working.spatial_join_all_from_catalog(table_id)`** runs `spatial_join_from_catalog()` for each variable, matching `working.location_merge` rows to geometries (`st_within` by default, optional buffer in meters) and writing to `working.external_exposure`.

### Time windows

Each `attr_{table_id}` row carries its own `attr_start_date` / `attr_end_date`:

- **Scalar columns** (e.g. SVI) get one row per feature, dated with the variable's `startDate`/`endDate` from the JSON-LD.
- **`jsonb` time-series columns** (e.g. `us_2014_2019_monthly_pm25_by_county_cdc`) are keyed by `"{start}/{end}"` intervals, such as `{"2014-01-01/2014-01-31": 7.2, ...}`. Each key becomes its own row with that window.

The spatial join uses each row's window, not the variable's overall span in `attr_index`. A location is matched when its `location_history` period overlaps the window, and the exposure dates are clipped to the overlap. For example, a person at one address from 2010 to 2025 gets 72 monthly exposure rows from the 2014–2019 pm2.5 series.

---

## Raster Sources

A raster (e.g. NLCD tree canopy, or an annual exposure series) is loaded by its `_postgis.sh` step with `raster2pgsql` into `public.{table_id}` (column `rast`, one row per tile; add `-F` for a `filename` column when several files go into one table) and is **not** copied into `geom_*` / `attr_*` tables. Two steps make it joinable:

1. **`backbone.gdsc_load_all_raster_variables(table_id, layers, source, band)`** (or `gdsc_load_raster_variable(params)` for one variable) registers each variable of the table in `backbone.attr_index` and writes its layers to `backbone.raster_layer`; `ingest_datasource` calls it for you for raster sources (see Ingestion Protocol), and you can call it yourself for a raster you loaded by hand. Each layer records the raster table, band, SRID and the period it stands for. Pass `layers` as `[{"filename": "...", "start_date": "...", "end_date": "..."}]` for a table with one file per period (an annual series); without it the whole table is one layer over the variable's dates. The geometry type concept on `geom_index` is set to Raster (2052496985).
2. **`working.spatial_join_raster_from_catalog(variable, table_id, method, buffer_m, exposure_type_concept_id)`** matches `working.location_merge` rows to the layers whose period overlaps theirs and writes `working.external_exposure`, with the exposure dates clipped to the overlap, as for vector sources. `method` is `point` (the value of the cell containing the location, `ST_Value`; nodata or outside the raster gives no row), `buffer_mean` (the mean of the cells whose centre is within `buffer_m` metres, `ST_Clip` + `ST_SummaryStats` over the tiles; the buffer is a geography buffer, as for vector sources) or `class_fraction` (categorical rasters: one row per class present in the buffer, with the share of the valid cells in `value_as_number` and the class value in `modifier_source_value`; classes with share 0 get no row, and the shares of a location period sum to 1). A location on a tile edge gets one value per layer.

```sql
SELECT * FROM backbone.gdsc_load_all_raster_variables('synthetic_raster_annual',
    p_layers => '[{"filename": "synthetic_raster_annual_2014.tif", "start_date": "2014-01-01", "end_date": "2014-12-31"}, ...]');
SELECT working.spatial_join_raster_from_catalog('pm25_annual', 'synthetic_raster_annual', 'point', 0, 2052499878);
SELECT working.spatial_join_raster_from_catalog('pm25_annual', 'synthetic_raster_annual', 'buffer_mean', 1000, 2052499878);
```

Locations are transformed to the raster's SRID, so the raster can be in any projection. For a categorical raster `point` returns the class code as `value_as_number`; class codes are not mapped to concepts (open design questions are on [OHDSI/GIS#537](https://github.com/OHDSI/GIS/issues/537)). Example rasters with an answer key are in [`syntheticDataGIS/raster`](https://github.com/OHDSI/GIS/tree/main/syntheticDataGIS/raster); the unit tests are in `tests/test_raster_join.sql`.

---

## Point Sources: Voronoi Cells and Nearest-Point Joins

A point source (monitors, sensors) has no area, so `spatial_join_from_catalog` can only join it through a distance buffer, which gives a location no monitor, or several rows (one per monitor in range). Two functions in `sql/08` assign each location the value of its nearest monitor instead:

1. **`backbone.create_voronoi_source(source_table_id, target_table_id, clip, working_srid, segment_m)`** builds the Voronoi (Thiessen) cells of a point table in `public` as a new polygon table with the same attributes (the series of each monitor stays with its cell). A location inside a cell is closer to the cell's monitor than to any other, so the cells join like any polygon source: register them (JSON-LD, `gdsc_load_all_variables`) and run `spatial_join_from_catalog(..., 'ST_Within')`. Each time window gives one row with the dates clipped to the residence period. The cells are computed in a projected CRS (`working_srid`, default the UTM zone of the points; Voronoi cells must not be computed in lon/lat), cut to `clip` (default: the bounding box of the points enlarged by 10% of its longer side, since the outer cells are unbounded) and returned in the CRS of the point table. Points at identical locations are an error; a point outside `clip` has no cell. The catalog's `_postgis.sh` step of a derived source calls it (for example `synthetic_monitors_60_voronoi`, built from `synthetic_monitors_60`).
2. **`working.spatial_join_nearest_from_catalog(variable, table_id, k, max_distance_m, idw_power, record_distance, exposure_type_concept_id)`** joins a loaded point variable without building cells: `k` = 1 (default) is the value of the nearest point, a larger `k` the inverse-distance weighted mean of the `k` nearest (weights 1 / distance^`idw_power`). Distances are geodesic, in metres; a point with no value for a window is not a candidate for it; `max_distance_m` drops points that are too far, and a location with none gets no row. The relationship is "Near/Proximity to" (2052497004) and the method (`nearest`, `idw k=3 power=2`) is written verbatim to `exposure_relationship_source_value`. With `record_distance` the distance to the nearest point is written to `modifier_source_value` (`distance_m=201.4`).

The two agree: a location is in the cell of its nearest monitor. They differ only where two monitors are almost equally far, because the cells use distances in the working CRS and the join geodesic ones (in an Albers map such as EPSG:5070 distances are off by up to about 0.7%, depending on direction, around Los Angeles). The nearest-point join compares every location with every point, which is fine for networks of up to some thousands of points; for more, build the cells.

```sql
-- the cells, from a point source that has been ingested
SELECT backbone.create_voronoi_source('synthetic_monitors_60', 'synthetic_monitors_60_voronoi');
-- or the nearest monitor without cells; k = 3 gives an inverse-distance weighted mean
SELECT working.spatial_join_nearest_from_catalog('pm25_monitor', 'synthetic_monitors_60', 1, NULL, 2, TRUE, 2052499878);
```

Example monitors with an answer key are in [`syntheticDataGIS/monitors`](https://github.com/OHDSI/GIS/tree/main/syntheticDataGIS/monitors); the unit tests are in `tests/test_point_sources.sql`.

---

## End-to-End Demo

```sql
-- 1. Ingest a data source (metadata + download + geometry cleanup)
SELECT * FROM backbone.ingest_datasource('ma_2022_svi_tract');

-- 2. Load example locations and location history
SELECT * FROM working.load_location_csv('/extras/csv/LOCATION_MA.csv');
SELECT * FROM working.load_location_history_csv('/extras/csv/LOCATION_HISTORY.csv');

-- 3. Build the geom/attr instance tables for every catalogued variable
SELECT * FROM backbone.gdsc_load_all_variables(
    p_table_id        => 'ma_2022_svi_tract',
    p_geom_label      => 'location',
    p_variable_nodata => -999,
    p_source          => 'CDC/ATSDR SVI 2022'
);

-- 4. Spatially join locations to every variable and inspect the results
SELECT * FROM working.spatial_join_all_from_catalog('ma_2022_svi_tract');
SELECT * FROM working.exposure_statistics();
```

To re-run a join, clear prior output first with `SELECT working.clear_exposure_data('variable_name');` (or no argument to clear everything).

---

## Function Reference

| Function | Purpose |
|----------|---------|
| **Ingestion** (`sql/02`, `sql/05`) | |
| `backbone.ingest_datasource(table_id)` | Full protocol: metadata, `_osgeo.sh`, `_postgis.sh` |
| `backbone.load_datasource_metadata(table_id)` | Load the dataset's JSON-LD from `/data/{table_id}/` |
| `backbone.retrieve_and_ingest_datasource(uuid, script_path)` | Run one ETL script for a registered data source |
| `backbone.quick_ingest_datasource(dataset_name)` | Re-run a dataset's ETL script without reloading metadata |
| `backbone.list_downloadable_datasources()` | List registered data sources and their ETL script paths |
| `backbone.fetch_and_load_jsonld(url)` / `backbone.load_jsonld_from_path(path)` | Load JSON-LD metadata from a URL or file |
| **Locations** (`sql/03`) | |
| `working.load_location_csv(path)` / `working.load_location_history_csv(path)` | Load OMOP-style LOCATION / LOCATION_HISTORY CSVs (server-side paths) |
| `working.load_location_data(location_path, history_path)` | Load both CSVs in one call |
| `working.validate_location_data()` / `working.location_statistics()` | Data quality checks and summary counts |
| **Catalog** (`sql/06`) | |
| `backbone.gdsc_load_all_variables(table_id, geom_label, nodata, source)` | Build instance tables for every variable in `attr_index` |
| `backbone.gdsc_load_variable(params jsonb)` | Build instance tables for a single variable |
| `backbone.gdsc_get_loaded_variables_for_table(table_id)` | List variables already loaded for a table |
| **Raster** (`sql/07`) | |
| `backbone.gdsc_load_all_raster_variables(table_id, layers, source, band)` | Register every variable of a raster table and its layers |
| `backbone.gdsc_load_raster_variable(params jsonb)` | Register a single raster variable and its layers in `backbone.raster_layer` |
| `working.spatial_join_raster_from_catalog(variable, table_id, method, buffer_m, exposure_type_concept_id)` | Join a raster variable by `point`, `buffer_mean` or `class_fraction` |
| **Point sources** (`sql/08`) | |
| `backbone.create_voronoi_source(source_table_id, target_table_id, clip, working_srid, segment_m)` | Voronoi cells of a point table as a polygon source |
| `working.spatial_join_nearest_from_catalog(variable, table_id, k, max_distance_m, idw_power, record_distance, exposure_type_concept_id)` | Join a point variable by its nearest point(s): nearest or inverse-distance weighted |
| **Spatial join** (`sql/04`) | |
| `working.spatial_join_all_from_catalog(table_id, operator, buffer_m)` | Join every loaded variable for a table |
| `working.spatial_join_from_catalog(variable, table_id, operator, buffer_m, exposure_type_concept_id)` | Join a single catalogued variable; the last argument is the Exposure Type Concept of the data source (default 0) |
| `working.exposure_statistics()` / `working.clear_exposure_data(variable)` | Summarize or clear `external_exposure` |

## Support

Please use the [GitHub issue tracker](https://github.com/OHDSI/gaiaDB/issues) for bugs and feature requests.

---

## Developer Guidelines

- Open an issue before starting significant work
- Create a feature branch and submit a Pull Request when ready
- PRs require review before merge to `main`
- Run the test suite against a live container before submitting (all test data is rolled back):
  ```bash
  docker exec -i gaia-db psql -U postgres -d gaiacore < tests/test_jsonld_ingestion.sql
  docker exec -i gaia-db psql -U postgres -d gaiacore < tests/test_raster_join.sql
  docker exec -i gaia-db psql -U postgres -d gaiacore < tests/test_point_sources.sql
  ```
