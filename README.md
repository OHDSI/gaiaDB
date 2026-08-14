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
- [Support](#support)
- [Developer Guidelines](#developer-guidelines)

---

## Architecture

gaiaDB extends `postgis/postgis:16-3.4-alpine` with:

| Schema | Purpose |
|--------|---------|
| `backbone` | Core metadata tables (`data_source`, `variable_source`, `geom_template`, `attr_template`) and all ingestion/retrieval functions |
| `working` | Location, location history, and exposure output tables |
| `vocabulary` | OMOP vocabulary tables (concept, relationship, domain, etc.) |

SQL functions are loaded from `/sql/` at container init time. ETL scripts for each dataset live under `/data/{table_id}/etl/`.

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
  --hostname gaia-db 
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
| `INIT_WITH_CATALOG` | `TRUE` | When `TRUE`, shallow-clone [OHDSI/gaiaCatalog](https://github.com/OHDSI/gaiaCatalog) and copy `./datastore/data/*` into `/data/` |
| `INIT_WITH_CATALOG` | `TRUE` | When `FALSE`, copy the bundled example dataset from `/extras/` into `/data/` |

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
| `metadata_load` | `load_datasource_metadata()` | Reads `/data/{table_id}/meta_json-ld_{table_id}.json` and populates `backbone.data_source` and `backbone.variable_source` |
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

---

## End-to-End Demo:


```sql
SELECT * FROM backbone.ingest_datasource('ma_2022_svi_tract');
select * from working.load_location_csv('/data/csv/LOCATION_MA.csv');
SELECT * from working.load_location_history_csv('/data/csv/LOCATION_HISTORY.csv');
SELECT * FROM backbone.gdsc_load_all_variables(
      p_table_id        => 'ma_2022_svi_tract',
      p_geom_label      => 'location',
      p_variable_nodata => -999,
      p_source          => 'CDC/ATSDR SVI 2022'
  );
select * from working.spatial_join_all_from_catalog('ma_2022_svi_tract');
```

## Support

Please use the [GitHub issue tracker](https://github.com/OHDSI/gaiaDB/issues) for bugs and feature requests.

---

## Developer Guidelines

- Open an issue before starting significant work
- Create a feature branch and submit a Pull Request when ready
- PRs require review before merge to `main`
- Run the test suite against a live container before submitting:
  ```bash
  psql -U postgres -d gaiacore -f tests/test_jsonld_ingestion.sql
  ```
