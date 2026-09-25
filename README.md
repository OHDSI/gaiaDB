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

This runs three steps in sequence and streams a status row for each:

| Step | Script / Action | Description |
|------|----------------|-------------|
| `metadata_load` | `load_datasource_metadata()` | Reads `/data/{table_id}/meta_json-ld_{table_id}.json`, populates `backbone.data_source` and `backbone.variable_source`, and registers `backbone.geom_index` / `backbone.attr_index` catalog entries (variables without `startDate`/`endDate` are skipped from `attr_index` with a warning) |
| `ingestion` | `{table_id}_osgeo.sh` | Downloads the source file and loads it into PostGIS via `ogr2ogr` |
| `postgis` | `{table_id}_postgis.sh` | Cleans geometry (`ST_MakeValid`), adds a local-projection column, creates spatial index |

The postgis step is skipped automatically if the osgeo step fails.

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
| **Spatial join** (`sql/04`) | |
| `working.spatial_join_all_from_catalog(table_id, operator, buffer_m)` | Join every loaded variable for a table |
| `working.spatial_join_from_catalog(variable, table_id, operator, buffer_m)` | Join a single catalogued variable |
| `working.exposure_statistics()` / `working.clear_exposure_data(variable)` | Summarize or clear `external_exposure` |

`working.spatial_join_exposure()`, `spatial_join_simple()`, and `spatial_join_all_variables()` are the older join path. They read raw tables directly rather than the catalog and use a single date range per variable. Prefer the `*_from_catalog` functions.

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
  ```
