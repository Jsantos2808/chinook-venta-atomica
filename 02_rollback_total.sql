-- =============================================================================
-- 02_rollback_total.sql
-- Escenario 2. Error real de llave foranea y reversion completa.
-- Esta venta es distinta de la del escenario 1: otra marca, otro cliente
-- y otra cancion. No depende del invoice_id de ningun script anterior.
--
-- Resultado esperado:
--   * Se crea una cabecera y un detalle valido dentro de la transaccion.
--   * track_id 999999999 no existe (se comprueba antes).
--   * El INSERT invalido responde SQLSTATE 23503 (foreign_key_violation)
--     sobre invoice_line_track_id_fkey.
--   * La transaccion queda abortada: SQLSTATE 25P02.
--   * ROLLBACK. La clave recuperada con RETURNING no queda en invoice
--     ni en invoice_line.
--   * La secuencia no retrocede: puede quedar un hueco.
--
-- Si el cliente se detiene en el primer error
-- (DBeaver, pgAdmin, o psql que no llegue a ejecutar lo que sigue):
--   NO cierre la sesion. Si la cierra, PostgreSQL revierte al desconectar
--   y perdera la variable invoice_id.
--   Ejecute a mano desde la linea marcada BLOQUE DE RECUPERACION.
--   En este escenario ese bloque empieza en ROLLBACK.
--
-- psql, con el \set ON_ERROR_STOP off de mas abajo, no se detiene: el mismo
-- archivo continua y ejecuta el bloque de recuperacion.
-- =============================================================================

\set ON_ERROR_STOP on
\set ECHO queries
\pset pager off
\pset null '(null)'

SET application_name = 'sesion_A_rollback';
SET client_encoding = 'UTF8';

\echo ''
\echo '=== ESCENARIO 2. Sesion, autocommit e aislamiento ==='
\echo 'AUTOCOMMIT del cliente psql:' :AUTOCOMMIT
SHOW default_transaction_isolation;

-- Proposito: identificar este backend. Es independiente de cualquier otra conexion.
SELECT
    pg_backend_pid() AS pid_sesion,
    current_database() AS base,
    current_setting('transaction_isolation') AS aislamiento;

\if :{?marca}
\else
\set marca PRACTICA-ESCENARIO-2
\endif

\echo 'Marca de la venta que debe desaparecer:' :marca

-- Proposito: comprobar que la cancion del fallo no existe, antes de usarla.
-- No es la clave de la factura. Solo es una referencia invalida.
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

\echo 'Precondicion correcta: track_id 999999999 no existe.'

-- Limite transaccional explicito. Todo lo siguiente es una sola venta.
BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;

SHOW transaction_isolation;

-- Proposito: cabecera de una venta nueva. Clave por RETURNING / SERIAL.
-- Se usa el segundo cliente para que la venta no sea la del escenario 1.
-- El total 0.00 es provisional y no llegara a confirmarse.
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
OFFSET 1
LIMIT 1
RETURNING invoice_id \gset

\echo 'Clave de ESTA venta (RETURNING):' :invoice_id

-- Proposito: una cancion existente, distinta de las tres del escenario 1.
\unset track_ok
\unset price_ok
SELECT track_id AS track_ok, unit_price AS price_ok
FROM track
ORDER BY track_id
OFFSET 10
LIMIT 1 \gset

-- Proposito: dejar al menos un detalle valido antes del fallo.
INSERT INTO invoice_line (invoice_id, track_id, unit_price, quantity)
VALUES (:invoice_id, :track_ok, :price_ok, 1);

-- Proposito: mostrar que, antes del error, la cabecera y el detalle existen
-- dentro de esta transaccion. Otra sesion todavia no los veria.
-- Resultado esperado: 1 detalle.
SELECT
    i.invoice_id,
    i.billing_address,
    il.invoice_line_id,
    il.track_id,
    il.unit_price,
    il.quantity
FROM invoice AS i
JOIN invoice_line AS il ON il.invoice_id = i.invoice_id
WHERE i.invoice_id = :invoice_id;

\echo ''
\echo '--- Operacion de riesgo: detalle con track_id 999999999 ---'
\echo 'Resultado esperado: ERROR 23503, constraint invoice_line_track_id_fkey.'
\echo 'Si el cliente se detiene aqui, ejecute el BLOQUE DE RECUPERACION'
\echo 'sin cerrar la sesion. La clave es' :invoice_id

-- A partir de aqui un error no debe cortar el archivo: el bloque de
-- recuperacion tiene que ejecutarse despues.
\set ON_ERROR_STOP off

-- Proposito: provocar la violacion real de la FK invoice_line_track_id_fkey.
-- No se desactiva la restriccion. La cantidad es positiva; el fallo es la FK,
-- no un CHECK de cantidad (Chinook no trae ese CHECK).
INSERT INTO invoice_line (invoice_id, track_id, unit_price, quantity)
VALUES (:invoice_id, 999999999, 0.99, 1);

-- El SQLSTATE queda en el cliente. Hay que guardarlo antes de la siguiente
-- sentencia, porque esa tambien fallara y lo reemplazara.
\set estado_fk :SQLSTATE
\echo 'SQLSTATE de la insercion invalida (esperado 23503):' :estado_fk

-- Proposito: demostrar el estado abortado de TODA la transaccion.
-- PostgreSQL no revierte solo la sentencia fallida: ignora cualquier orden
-- posterior hasta ROLLBACK o ROLLBACK TO SAVEPOINT.
-- Resultado esperado: ERROR 25P02
--   current transaction is aborted, commands ignored until end of transaction block
-- Aunque la factura exista dentro de la transaccion, esta consulta no puede leerla.
SELECT invoice_id
FROM invoice
WHERE invoice_id = :invoice_id;

\set estado_abortado :SQLSTATE
\echo 'SQLSTATE del estado abortado (esperado 25P02):' :estado_abortado

\set ON_ERROR_STOP on

-- =============================================================================
-- BLOQUE DE RECUPERACION
-- Ejecutar desde aqui si el cliente se detuvo en el error de llave foranea.
-- No confirma nada: deshace la cabecera y el detalle valido junto con el
-- intento invalido.
-- =============================================================================

-- Proposito: revertir la transaccion completa.
ROLLBACK;

\echo 'ROLLBACK ejecutado.'

-- Proposito: exigir que el error observado haya sido la FK, cuando psql
-- pudo guardar el SQLSTATE. En una ejecucion manual que empiece en este
-- bloque, esa variable puede no existir y solo se comprueba la ausencia.
\if :{?estado_fk}
SELECT
    CASE WHEN :'estado_fk' = '23503' THEN 1 ELSE 0 END AS fk_ok,
    CASE WHEN :'estado_abortado' = '25P02' THEN 1 ELSE 0 END AS abortado_ok \gset
\echo 'fk_ok (1 = 23503):' :fk_ok
\echo 'abortado_ok (1 = 25P02):' :abortado_ok
\if :fk_ok
\else
\echo 'No se observo la violacion de FK esperada.'
\quit 1
\endif
\if :abortado_ok
\else
\echo 'No se observo el estado abortado 25P02.'
\quit 1
\endif
\else
\echo 'Sin SQLSTATE guardado: se comprueba solo la ausencia de la clave.'
\endif

-- Proposito: demostrar, por la clave de ESTA venta, que no quedo cabecera.
-- Resultado esperado: 0 filas.
SELECT invoice_id, customer_id, billing_address, total
FROM invoice
WHERE invoice_id = :invoice_id;

-- Proposito: demostrar que tampoco quedo ningun detalle de esa clave.
-- Resultado esperado: 0 filas.
SELECT invoice_line_id, invoice_id, track_id, unit_price, quantity
FROM invoice_line
WHERE invoice_id = :invoice_id;

-- Proposito: la marca de practica de este escenario tampoco puede persistir.
-- Resultado esperado: 0.
SELECT COUNT(*) AS cabeceras_con_la_marca
FROM invoice
WHERE billing_address = :'marca';

-- Proposito: explicar el hueco de la secuencia.
-- nextval() no es transaccional: ROLLBACK no devuelve el valor.
-- Resultado esperado: facturas = 0, detalles = 0 y la secuencia ya
-- alcanzo, como minimo, la clave revertida.
SELECT
    :invoice_id::int AS clave_revertida,
    (SELECT COUNT(*) FROM invoice WHERE invoice_id = :invoice_id) AS facturas,
    (SELECT COUNT(*) FROM invoice_line WHERE invoice_id = :invoice_id) AS detalles,
    s.last_value AS ultimo_valor_secuencia,
    s.is_called
FROM invoice_invoice_id_seq AS s;

\echo 'Fin del escenario 2. La clave anunciada no debe existir.'
