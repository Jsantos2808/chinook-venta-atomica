-- =============================================================================
-- 04_validaciones.sql
-- Comprobaciones de la copia Chinook y consulta de la sesion B.
--
-- Modo normal (despues de 01, 02 y 03):
--   docker compose exec -T db psql -U chinook -d chinook_serial -P pager=off \
--     -f /sql/04_validaciones.sql
--
-- Resultado esperado del modo normal:
--   * PostgreSQL 18, aislamiento read committed, autocommit del cliente on.
--   * 412 facturas originales intactas (sin marca PRACTICA-).
--   * Cada factura PRACTICA- tiene al menos 3 detalles y total = suma.
--   * No persiste PRACTICA-ESCENARIO-2 (el escenario 2 hizo ROLLBACK).
--   * No queda ningun detalle con track_id 999999999.
--   * La FK invoice_line_track_id_fkey sigue activa. No hay CHECK de cantidad.
--
-- Modo visibilidad, sesion B (escenario 4). No ejecuta las validaciones:
--   Antes del COMMIT de A (resultado esperado: 0 filas):
--     psql -v fase=antes -v marca=PRACTICA-VISIBILIDAD -f /sql/04_validaciones.sql
--   Despues del COMMIT de A (resultado esperado: cabecera, 3 detalles, total = suma):
--     psql -v fase=despues -v marca=PRACTICA-VISIBILIDAD -f /sql/04_validaciones.sql
--
-- La sesion B no abre la transaccion de la venta. Con autocommit on, cada
-- SELECT es su propia lectura y, en Read Committed, solo ve datos confirmados.
-- =============================================================================

\set ON_ERROR_STOP on
\set ECHO queries
\pset pager off
\pset null '(null)'
SET client_encoding = 'UTF8';

\if :{?fase}
SET application_name = 'sesion_B';

\echo ''
\echo '=== SESION B. Visibilidad de la venta todavia no confirmada o ya confirmada ==='
\echo 'Fase:' :fase
\echo 'AUTOCOMMIT del cliente psql (sesion B):' :AUTOCOMMIT
\echo 'En esta sesion no hay BEGIN de la venta: cada consulta se confirma sola'
\echo 'y solo puede ver el trabajo que la sesion A ya haya confirmado.'

-- Proposito: fijar el aislamiento pedido para la demostracion.
SET default_transaction_isolation = 'read committed';
SHOW default_transaction_isolation;
SHOW transaction_isolation;

\if :{?marca}
\else
\echo 'Falta -v marca=LA_MISMA_MARCA_DE_LA_SESION_A'
\quit 1
\endif

-- Proposito: probar que B es otra conexion (otro pid, otro application_name).
-- Resultado esperado: el pid de B es distinto del pid que imprimio A.
SELECT
    pg_backend_pid() AS pid_sesion_b,
    current_database() AS base,
    current_setting('application_name') AS aplicacion,
    current_setting('transaction_isolation') AS aislamiento;

-- Proposito: listar los backends clientes y distinguir la transaccion explicita.
-- transaccion_explicita_previa es verdadera solo si el BEGIN ocurrio antes
-- de la sentencia que esta en curso. En autocommit vale falso, porque la
-- transaccion de esa sentencia acaba de empezar.
-- Resultado esperado en la fase "antes": dos pid, y la sesion A con
-- transaccion_explicita_previa = t mientras espera para hacer COMMIT.
SELECT
    pid,
    application_name,
    state,
    left(regexp_replace(query, '\s+', ' ', 'g'), 72) AS consulta,
    (xact_start < query_start) AS transaccion_explicita_previa
FROM pg_stat_activity
WHERE datname = current_database()
  AND backend_type = 'client backend'
ORDER BY pid;

-- Proposito: buscar la venta de A por su marca, sin adivinar el invoice_id.
-- Fase antes: 0 filas. La cabecera y los detalles todavia no son visibles.
-- Fase despues: una cabecera, al menos tres detalles y total = suma.
SELECT
    i.invoice_id,
    i.billing_address,
    i.total AS total_factura,
    COUNT(il.invoice_line_id) AS cantidad_detalles,
    COALESCE(SUM(il.unit_price * il.quantity), 0)::numeric(10,2) AS total_calculado,
    CASE
        WHEN COUNT(il.invoice_line_id) = 0 THEN 0
        WHEN i.total = COALESCE(SUM(il.unit_price * il.quantity), 0)::numeric(10,2)
        THEN 1
        ELSE 0
    END AS total_coincide
FROM invoice AS i
LEFT JOIN invoice_line AS il ON il.invoice_id = i.invoice_id
WHERE i.billing_address = :'marca'
GROUP BY i.invoice_id, i.billing_address, i.total
ORDER BY i.invoice_id;

-- Proposito: mostrar los detalles solo si la venta ya es visible.
-- Fase antes: 0 filas. Fase despues: al menos 3.
SELECT
    il.invoice_line_id,
    il.invoice_id,
    il.track_id,
    left(t.name, 40) AS cancion,
    il.unit_price,
    il.quantity,
    (il.unit_price * il.quantity)::numeric(10,2) AS importe
FROM invoice_line AS il
JOIN invoice AS i ON i.invoice_id = il.invoice_id
JOIN track AS t ON t.track_id = il.track_id
WHERE i.billing_address = :'marca'
ORDER BY il.invoice_line_id;

\echo 'Fin de la consulta de la sesion B. Fase:' :fase
\quit
\endif

-- =============================================================================
-- Modo normal. Validacion de la copia despues de los escenarios.
-- =============================================================================

SET application_name = 'sesion_validaciones';

\echo ''
\echo '=== Entorno ==='
\echo 'AUTOCOMMIT del cliente psql:' :AUTOCOMMIT
SHOW default_transaction_isolation;

-- Proposito: documentar version, base y backend de esta conexion.
SELECT
    version() AS version_servidor,
    current_database() AS base,
    pg_backend_pid() AS pid_sesion,
    current_setting('transaction_isolation') AS aislamiento;

-- Proposito: recordar que el total de la factura no lo mantiene el esquema.
-- Resultado esperado: la FK de track y la FK de invoice; ningun CHECK de cantidad;
-- ningun trigger de usuario sobre invoice o invoice_line.
SELECT
    conrelid::regclass AS tabla,
    conname,
    contype,
    pg_get_constraintdef(oid) AS definicion
FROM pg_constraint
WHERE conrelid IN ('invoice'::regclass, 'invoice_line'::regclass)
ORDER BY conrelid::regclass::text, contype, conname;

-- Proposito: ver si hay triggers de usuario. Los triggers internos de las FK no se listan.
-- Resultado esperado: 0 filas.
SELECT
    tgrelid::regclass AS tabla,
    tgname
FROM pg_trigger
WHERE tgrelid IN ('invoice'::regclass, 'invoice_line'::regclass)
  AND NOT tgisinternal
ORDER BY tgrelid::regclass::text, tgname;

-- Proposito: conteos del conjunto importado mas las ventas de practica.
SELECT
    (SELECT COUNT(*) FROM customer) AS clientes,
    (SELECT COUNT(*) FROM track) AS canciones,
    (SELECT COUNT(*) FROM invoice) AS facturas,
    (SELECT COUNT(*) FROM invoice_line) AS detalles;

-- Proposito: listar solo las ventas nuevas de practica y su coherencia.
-- Resultado esperado: cada fila con cantidad_detalles >= 3 y total_coincide = 1.
-- No debe aparecer PRACTICA-ESCENARIO-2.
SELECT
    i.invoice_id,
    i.customer_id,
    i.billing_address,
    i.total AS total_factura,
    COUNT(il.invoice_line_id) AS cantidad_detalles,
    COALESCE(SUM(il.unit_price * il.quantity), 0)::numeric(10,2) AS total_calculado,
    CASE
        WHEN COUNT(il.invoice_line_id) >= 3
         AND i.total = COALESCE(SUM(il.unit_price * il.quantity), 0)::numeric(10,2)
        THEN 1
        ELSE 0
    END AS total_coincide
FROM invoice AS i
LEFT JOIN invoice_line AS il ON il.invoice_id = i.invoice_id
WHERE i.billing_address LIKE 'PRACTICA-%'
GROUP BY i.invoice_id, i.customer_id, i.billing_address, i.total
ORDER BY i.invoice_id;

-- Proposito: mostrar huecos de invoice_id. Un ROLLBACK no devuelve el valor
-- de la secuencia, asi que la clave del escenario 2 puede aparecer aqui.
-- Resultado esperado: ausencias puntuales, no un fallo de la venta confirmada.
SELECT s.n AS invoice_id_ausente
FROM generate_series(
    (SELECT MIN(invoice_id) FROM invoice),
    (SELECT last_value FROM invoice_invoice_id_seq)::int
) AS s(n)
WHERE NOT EXISTS (
    SELECT 1
    FROM invoice AS i
    WHERE i.invoice_id = s.n
)
ORDER BY s.n;

-- Proposito: fallar si la copia o las ventas de practica no cumplen las reglas.
-- No hay COMMIT escondido: este bloque solo lee y, si algo no cuadra, lanza un error.
-- Resultado esperado: termina sin excepcion.
DO $$
DECLARE
    practicas integer;
    incoherentes integer;
    originales integer;
    invalidas integer;
    escenario2 integer;
BEGIN
    SELECT COUNT(*) INTO practicas
    FROM invoice
    WHERE billing_address LIKE 'PRACTICA-%';

    IF practicas < 1 THEN
        RAISE EXCEPTION
            'No hay facturas de practica. Ejecute 01_venta_exitosa.sql y 03_savepoint.sql antes de este script.';
    END IF;

    SELECT COUNT(*) INTO incoherentes
    FROM (
        SELECT i.invoice_id
        FROM invoice AS i
        LEFT JOIN invoice_line AS il ON il.invoice_id = i.invoice_id
        WHERE i.billing_address LIKE 'PRACTICA-%'
        GROUP BY i.invoice_id, i.total
        HAVING COUNT(il.invoice_line_id) < 3
            OR i.total IS DISTINCT FROM COALESCE(SUM(il.unit_price * il.quantity), 0)::numeric(10,2)
    ) AS malas;

    IF incoherentes > 0 THEN
        RAISE EXCEPTION
            'Hay % factura(s) de practica cuyo total no coincide con la suma o que tienen menos de 3 detalles.',
            incoherentes;
    END IF;

    SELECT COUNT(*) INTO originales
    FROM invoice
    WHERE COALESCE(billing_address, '') NOT LIKE 'PRACTICA-%';

    IF originales <> 412 THEN
        RAISE EXCEPTION
            'Se esperaban 412 facturas originales de Chinook 1.4.5 y hay %.',
            originales;
    END IF;

    SELECT COUNT(*) INTO invalidas
    FROM invoice_line
    WHERE track_id = 999999999;

    IF invalidas > 0 THEN
        RAISE EXCEPTION
            'Persiste un detalle con track_id 999999999. La FK debio impedirlo o el ROLLBACK debio quitarlo.';
    END IF;

    SELECT COUNT(*) INTO escenario2
    FROM invoice
    WHERE billing_address = 'PRACTICA-ESCENARIO-2';

    IF escenario2 > 0 THEN
        RAISE EXCEPTION
            'La venta del escenario 2 persiste. El ROLLBACK no elimino la cabecera.';
    END IF;
END
$$;

\echo 'Validaciones completas: originales intactas, totales coherentes y FK respetada.'
