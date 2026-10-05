-- Check offline with: serverpod_sql_check /path/to/example/query.sql
SELECT 1 AS value;

DO $body$
BEGIN
  RAISE NOTICE 'this body is parsed, never executed';
END;
$body$;
