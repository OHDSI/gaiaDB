-- Privileges of the functions (run last: it covers every function defined above)
--
-- Functions are executable by PUBLIC unless revoked. The ones below run shell scripts (plsh), load files or build tables
-- from names the caller chooses, so they are for the authenticated role (crud_user) and the database owner only. The
-- unauthenticated PostgREST role (web_anon) keeps the read-only catalog functions.
--
-- NOTE: the catalog's Flask loader calls these through PostgREST as web_anon (ohdsi.py: gdsc_exec, ...). Until it
-- sends a JWT for the crud_user role (PGRST_JWT_SECRET in gaiaDocker) this revokes its ETL loader.
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT p.oid::regprocedure AS sig
        FROM pg_proc p
        JOIN pg_language l ON l.oid = p.prolang
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname IN ('backbone', 'working', 'public')
          AND (l.lanname = 'plsh'
               OR p.proname IN ('ingest_datasource', 'quick_ingest_datasource', 'retrieve_and_ingest_datasource',
                                'load_datasource_metadata', 'ingest_jsonld_metadata', 'ingest_jsonld_variables',
                                'gdsc_load_variable', 'gdsc_load_all_variables',
                                'gdsc_load_raster_variable', 'gdsc_load_all_raster_variables',
                                'create_voronoi_source'))
    LOOP
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC', r.sig);
        EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM web_anon', r.sig);
        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO crud_user', r.sig);
    END LOOP;
END
$$;
