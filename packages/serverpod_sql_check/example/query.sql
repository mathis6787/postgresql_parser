-- Check offline with: serverpod_sql_check /path/to/example/query.sql
-- Monthly rental revenue for a tenant, grouped by equipment category.
-- Offline checks validate syntax; they do not require these tables to exist.
WITH completed_rentals AS (
  SELECT
    rental.equipment_id,
    rental.quantity,
    rental.total_amount
  FROM rental
  WHERE rental.tenant_id = 42
    AND rental.status = 'returned'
    AND rental.returned_at >= DATE '2026-09-01'
    AND rental.returned_at < DATE '2026-10-01'
)
SELECT
  category.name AS category,
  COUNT(*) AS rental_count,
  SUM(completed_rentals.quantity) AS units_rented,
  SUM(completed_rentals.total_amount) AS revenue
FROM completed_rentals
JOIN equipment ON equipment.id = completed_rentals.equipment_id
JOIN category ON category.id = equipment.category_id
GROUP BY category.id, category.name
HAVING SUM(completed_rentals.total_amount) > 0
ORDER BY revenue DESC;

-- A maintenance job marks overdue rentals. Its body is parsed, never executed.
DO $body$
BEGIN
  UPDATE rental
  SET status = 'overdue'
  WHERE status = 'active'
    AND due_at < CURRENT_TIMESTAMP;
END;
$body$;

-- Intentionally invalid SQL: this example is expected to fail.
-- serverpod_sql_check detects the missing expression after "=" and reports
-- the file, line and column, with exit code 1. It never executes the query.
SELECT equipment.id FROM equipment WHERE equipment.tenant_id = ;

-- Intentionally invalid PL/pgSQL syntax.
-- Fix or comment out the invalid SELECT above to reach the PL/pgSQL check:
-- procedural bodies are checked only after the outer SQL syntax passes.
-- serverpod_sql_check detects the missing condition between IF and THEN,
-- labels the diagnostic PL/pgSQL and returns exit code 1.
DO $invalid_body$
BEGIN
  IF THEN
    UPDATE rental SET status = 'overdue';
  END IF;
END;
$invalid_body$;
