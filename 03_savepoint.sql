-- =============================================================================
-- 03_savepoint.sql
-- Escenario 3. Recuperacion parcial con SAVEPOINT.
-- Tercera venta, independiente: otra marca, otro cliente y otras canciones.
--
-- Resultado esperado:
--   * Dos detalles validos antes del punto de recuperacion.
--   * SAVEPOINT antes de la operacion de riesgo.
--   * Error real de FK (23503) y estado abortado (25P02).
--   * ROLLBACK TO SAVEPOINT deshace solo lo posterior al punto.
--   * Los dos detalles anteriores siguen.
--   * El track 999999999 no queda registrado.
--   * Un detalle corregido deja la venta con al menos tres lineas validas.
--   * El total se recalcula con la suma y se confirma con COMMIT.
--
-- RELEASE SAVEPOINT, mas abajo, solo elimina la marca. No equivale a COMMIT:
-- la transaccion explicita sigue abierta y otra sesion aun no veria la venta.
--
-- Si el cliente se detiene en el primer error, no cierre la sesion.
-- Ejecute desde el comentario BLOQUE DE RECUPERACION
-- (empieza en ROLLBACK TO SAVEPOINT antes_detalle_riesgo).
-- =============================================================================

\set ON_ERROR_STOP on
\set ECHO queries
\pset pager off
\pset null '(null)'

SET application_name = 'sesion_A_savepoint';
SET client_encoding = 'UTF8';

\echo ''
\echo '=== ESCENARIO 3. Sesion, autocommit e aislamiento ==='
\echo 'AUTOCOMMIT del cliente psql:' :AUTOCOMMIT
SHOW default_transaction_isolation;

SELECT
    pg_backend_pid() AS pid_sesion,
    current_database() AS base,
    current_setting('transaction_isolation') AS aislamiento;

\if :{?marca}
\else
\set marca PRACTICA-ESCENARIO-3
\endif

\echo 'Marca de la tercera venta:' :marca

-- Misma precondicion que el escenario 2: la referencia invalida no existe.
-- Resultado esperado: 0 filas.
SELECT track_id
FROM track
WHERE track_id = 999999999;

SELECT COUNT(*) AS tracks_invalidos
FROM track
WHERE track_id = 999999999 \gset

\if :tracks_invalidos
\echo 'PRECONDICION FALLIDA: track_id 999999999 existe. No se continua.'
\quit 1
\endif

BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;

SHOW transaction_isolation;

-- Proposito: cabecera de la tercera venta. Clave con RETURNING.
-- Tercer cliente existente, para distinguirla de las ventas anteriores.
INSERT INTO invoice (
    customer_id,
    invoice_date,
    billing_address,
    billing_city,
    billing_state,
    billing_country,
    billing_postal_code,
    total
)
SELECT
    c.customer_id,
    CURRENT_TIMESTAMP,
    :'marca',
    c.city,
    c.state,
    c.country,
    c.postal_code,
    0.00
FROM customer AS c
ORDER BY c.customer_id
OFFSET 2
LIMIT 1
RETURNING invoice_id \gset

\echo 'Clave recuperada con RETURNING:' :invoice_id

-- Proposito: dos canciones existentes para el tramo que debe conservarse.
\unset track_1
\unset price_1
SELECT track_id AS track_1, unit_price AS price_1
FROM track
ORDER BY track_id
OFFSET 20
LIMIT 1 \gset

\unset track_2
\unset price_2
SELECT track_id AS track_2, unit_price AS price_2
FROM track
ORDER BY track_id
OFFSET 21
LIMIT 1 \gset

-- Proposito: cancion de reemplazo, tambien existente, para despues del fallo.
\unset track_3
\unset price_3
SELECT track_id AS track_3, unit_price AS price_3
FROM track
ORDER BY track_id
OFFSET 22
LIMIT 1 \gset

-- Proposito: primer detalle valido. Se conserva despues del SAVEPOINT.
INSERT INTO invoice_line (invoice_id, track_id, unit_price, quantity)
VALUES (:invoice_id, :track_1, :price_1, 1)
RETURNING invoice_line_id AS linea_1 \gset

-- Proposito: segundo detalle valido. Tambien queda antes del punto de riesgo.
INSERT INTO invoice_line (invoice_id, track_id, unit_price, quantity)
VALUES (:invoice_id, :track_2, :price_2, 1)
RETURNING invoice_line_id AS linea_2 \gset

\echo 'Detalles anteriores al SAVEPOINT:' :linea_1 :linea_2

-- Proposito: mostrar el estado bueno antes de la operacion de riesgo.
-- Resultado esperado: exactamente 2 detalles.
SELECT
    invoice_line_id,
    track_id,
    unit_price,
    quantity
FROM invoice_line
WHERE invoice_id = :invoice_id
ORDER BY invoice_line_id;

-- Proposito: marcar el punto al que se puede volver sin perder los dos detalles.
-- SAVEPOINT abre una subtransaccion. No confirma la venta.
SAVEPOINT antes_detalle_riesgo;

\echo ''
\echo '--- Operacion de riesgo despues del SAVEPOINT ---'
\echo 'Resultado esperado: ERROR 23503 en invoice_line_track_id_fkey.'
\echo 'Si el cliente se detiene, continue en BLOQUE DE RECUPERACION.'
\echo 'Clave de la venta:' :invoice_id

\set ON_ERROR_STOP off

-- Proposito: detalle con una cancion inexistente. La FK debe rechazarlo.
INSERT INTO invoice_line (invoice_id, track_id, unit_price, quantity)
VALUES (:invoice_id, 999999999, 0.99, 1);

\set estado_fk :SQLSTATE
\echo 'SQLSTATE de la insercion invalida (esperado 23503):' :estado_fk

-- Proposito: el error aborta la transaccion entera hasta volver al SAVEPOINT.
-- Resultado esperado: SQLSTATE 25P02.
SELECT invoice_id
FROM invoice
WHERE invoice_id = :invoice_id;

\set estado_abortado :SQLSTATE
\echo 'SQLSTATE del estado abortado (esperado 25P02):' :estado_abortado

\set ON_ERROR_STOP on

-- =============================================================================
-- BLOQUE DE RECUPERACION
-- Ejecutar desde aqui si el cliente se detuvo en el error de FK.
-- ROLLBACK TO SAVEPOINT no es un COMMIT: deshace el detalle invalido,
-- reactiva la transaccion y conserva los dos detalles anteriores.
-- =============================================================================

-- Proposito: volver al punto anterior al detalle invalido.
ROLLBACK TO SAVEPOINT antes_detalle_riesgo;

\echo 'ROLLBACK TO SAVEPOINT ejecutado. La transaccion vuelve a estar activa.'

\if :{?estado_fk}
SELECT
    CASE WHEN :'estado_fk' = '23503' THEN 1 ELSE 0 END AS fk_ok,
    CASE WHEN :'estado_abortado' = '25P02' THEN 1 ELSE 0 END AS abortado_ok \gset
\echo 'fk_ok (1 = 23503):' :fk_ok
\echo 'abortado_ok (1 = 25P02):' :abortado_ok
\if :fk_ok
\else
\echo 'No se observo la violacion de FK. Se revierte la venta completa.'
ROLLBACK;
\quit 1
\endif
\else
\echo 'Sin SQLSTATE guardado. Se continua con la correccion y las comprobaciones.'
\endif

-- Proposito: comprobar que la transaccion ya acepta sentencias
-- y que los dos detalles previos siguen en esta venta.
-- Resultado esperado: las lineas linea_1 y linea_2, sin track 999999999.
SELECT
    invoice_line_id,
    track_id,
    unit_price,
    quantity,
    CASE WHEN invoice_line_id IN (:linea_1, :linea_2) THEN 1 ELSE 0 END AS anterior_al_punto
FROM invoice_line
WHERE invoice_id = :invoice_id
ORDER BY invoice_line_id;

-- Proposito: reemplazar el detalle rechazado por una cancion existente.
INSERT INTO invoice_line (invoice_id, track_id, unit_price, quantity)
VALUES (:invoice_id, :track_3, :price_3, 1)
RETURNING invoice_line_id AS linea_3 \gset

\echo 'Detalle corregido:' :linea_3
\echo 'La secuencia de invoice_line no retrocede con el fallo: el id corregido puede no ser consecutivo.'

-- Proposito: recalcular el total con la suma de los detalles que si quedaron.
-- No se escribe un total a mano.
UPDATE invoice AS i
SET total = detalle.total_calculado
FROM (
    SELECT COALESCE(SUM(unit_price * quantity), 0)::numeric(10,2) AS total_calculado
    FROM invoice_line
    WHERE invoice_id = :invoice_id
) AS detalle
WHERE i.invoice_id = :invoice_id;

-- Proposito: ver la venta corregida antes de confirmar.
-- Resultado esperado: 3 o mas detalles, los dos anteriores presentes,
-- ninguna fila con track_id 999999999.
SELECT
    il.invoice_line_id,
    il.track_id,
    left(t.name, 40) AS cancion,
    il.unit_price,
    il.quantity,
    (il.unit_price * il.quantity)::numeric(10,2) AS importe,
    CASE WHEN il.invoice_line_id IN (:linea_1, :linea_2) THEN 1 ELSE 0 END AS anterior_al_punto,
    CASE WHEN il.track_id = 999999999 THEN 1 ELSE 0 END AS referencia_invalida
FROM invoice_line AS il
JOIN track AS t ON t.track_id = il.track_id
WHERE il.invoice_id = :invoice_id
ORDER BY il.invoice_line_id;

-- Proposito: resumir la recuperacion y el total.
-- Resultado esperado: recuperacion_ok = 1 y total_ok = 1.
SELECT
    i.invoice_id,
    i.total AS total_factura,
    COUNT(il.invoice_line_id) AS cantidad_detalles,
    COUNT(il.invoice_line_id) FILTER (
        WHERE il.invoice_line_id IN (:linea_1, :linea_2)
    ) AS lineas_conservadas,
    COUNT(il.invoice_line_id) FILTER (
        WHERE il.track_id = 999999999
    ) AS lineas_invalidas,
    COALESCE(SUM(il.unit_price * il.quantity), 0)::numeric(10,2) AS total_calculado,
    CASE
        WHEN COUNT(il.invoice_line_id) >= 3
         AND COUNT(il.invoice_line_id) FILTER (
                WHERE il.invoice_line_id IN (:linea_1, :linea_2)
             ) = 2
         AND COUNT(il.invoice_line_id) FILTER (
                WHERE il.track_id = 999999999
             ) = 0
         AND i.total = COALESCE(SUM(il.unit_price * il.quantity), 0)::numeric(10,2)
        THEN 1
        ELSE 0
    END AS recuperacion_ok
FROM invoice AS i
LEFT JOIN invoice_line AS il ON il.invoice_id = i.invoice_id
WHERE i.invoice_id = :invoice_id
GROUP BY i.invoice_id, i.total \gset

\echo 'invoice_id=' :invoice_id
\echo 'total_factura=' :total_factura
\echo 'total_calculado=' :total_calculado
\echo 'cantidad_detalles=' :cantidad_detalles
\echo 'lineas_conservadas (esperado 2)=' :lineas_conservadas
\echo 'lineas_invalidas (esperado 0)=' :lineas_invalidas
\echo 'recuperacion_ok (1 = correcta)=' :recuperacion_ok

\if :recuperacion_ok
\else
\echo 'La recuperacion no cumple las comprobaciones. ROLLBACK completo.'
ROLLBACK;
\quit 1
\endif

-- -----------------------------------------------------------------------------
-- Por que RELEASE SAVEPOINT no equivale a COMMIT
-- RELEASE solo destruye la marca. Las sentencias hechas despues del
-- SAVEPOINT (y las anteriores) siguen sin confirmar. Otra sesion con
-- Read Committed no las ve hasta el COMMIT de mas abajo.
-- ROLLBACK TO, en cambio, descarta el trabajo posterior al punto.
-- -----------------------------------------------------------------------------

-- Proposito: crear una marca unicamente para liberarla.
SAVEPOINT marca_solo_para_release;

-- Proposito: eliminar la marca. No cierra la transaccion ni publica la venta.
RELEASE SAVEPOINT marca_solo_para_release;

-- Proposito: demostrar que seguimos dentro de la transaccion abierta al inicio.
-- Durante esta consulta, xact_start es el BEGIN de la venta, anterior a
-- query_start. En autocommit las dos marcas de tiempo coinciden.
-- Resultado esperado: transaccion_previa = t.
SELECT
    xact_start,
    query_start,
    (xact_start < query_start) AS transaccion_previa,
    state
FROM pg_stat_activity
WHERE pid = pg_backend_pid();

\echo 'RELEASE ya se ejecuto y la transaccion sigue abierta. El COMMIT va aparte.'

-- Limite transaccional explicito de la venta ya corregida.
COMMIT;

-- Proposito: leer la venta confirmada.
-- Resultado esperado: al menos 3 detalles, total igual a la suma,
-- sin la referencia invalida.
SELECT
    i.invoice_id,
    i.billing_address,
    i.total AS total_factura,
    COUNT(il.invoice_line_id) AS cantidad_detalles,
    COALESCE(SUM(il.unit_price * il.quantity), 0)::numeric(10,2) AS total_calculado,
    COUNT(il.invoice_line_id) FILTER (WHERE il.track_id = 999999999) AS lineas_invalidas
FROM invoice AS i
JOIN invoice_line AS il ON il.invoice_id = i.invoice_id
WHERE i.invoice_id = :invoice_id
GROUP BY i.invoice_id, i.billing_address, i.total;

\echo 'Fin del escenario 3.'
