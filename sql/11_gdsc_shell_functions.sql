-- FUNCTION: backbone.gdsc_exec(text, text)

-- DROP FUNCTION IF EXISTS backbone.gdsc_exec(text, text);

CREATE OR REPLACE FUNCTION backbone.gdsc_exec(
    shell text,
    script text)
    RETURNS text
    LANGUAGE 'plsh'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
#!/bin/sh

$1 $2.sh

echo "Complete"
$BODY$;

ALTER FUNCTION backbone.gdsc_exec(text, text)
    OWNER TO postgres;

COMMENT ON FUNCTION backbone.gdsc_exec(text, text)
    IS 'run a shell script';


-- FUNCTION: backbone.gdsc_path_and_dependencies(text)

-- DROP FUNCTION IF EXISTS backbone.gdsc_path_and_dependencies(text);

CREATE OR REPLACE FUNCTION backbone.gdsc_path_and_dependencies(
    table_id text)
    RETURNS text
    LANGUAGE 'plsh'
    COST 100
    VOLATILE PARALLEL UNSAFE
AS $BODY$
#!/bin/sh

dpath=$(find /data -name "$1" -type d)
echo $dpath
deps=$(cat $dpath/meta_etl_$1.json | grep dependency)
if [[ ${#deps} -gt 0 ]]
then
  echo $deps | grep -o '\[[^][]*]' | sed 's/^.//;s/.$//' | awk -F',' '{for(i=1;i<=NF;i++) print $i}'
fi

$BODY$;

ALTER FUNCTION backbone.gdsc_path_and_dependencies(text)
    OWNER TO postgres;

COMMENT ON FUNCTION backbone.gdsc_path_and_dependencies(text)
    IS 'get the path and dependencies from the metadata';