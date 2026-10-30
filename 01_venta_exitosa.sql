-- =============================================================================
-- 01_venta_exitosa.sql
-- Escenario 1. Venta atomica confirmada en Chinook (customer, invoice,
-- invoice_line, track).
--
-- Resultado esperado:
--   * Transaccion explicita con aislamiento Read Committed.
--   * invoice_id recuperado con RETURNING, sin MAX(id) + 1.
--   * Al menos tres detalles de canciones existentes, cantidad positiva
--     y precio de catalogo.
--   * total = SUM(unit_price * quantity), con numeric(10,2).
--   * COMMIT solo si esa comprobacion pasa.
--
-- Escenario 4, integrado aqui:
--   docker compose exec -T db psql -U chinook -d chinook_serial -P pager=off \
--     -v modo_visibilidad=1 -v marca=PRACTICA-VISIBILIDAD \
--     -f /sql/01_venta_exitosa.sql
--   Antes del COMMIT la sesion permanece abierta (pg_sleep) y escribe
--   /tmp/a_lista.txt. La sesion B debe consultar en ese intervalo.
--   Sin esas variables, el script confirma la venta de una vez.
--
-- Ejecucion normal:
--   docker compose exec -T db psql -U chinook -d chinook_serial -P pager=off \
--     -f /sql/01_venta_exitosa.sql
-- =============================================================================

\set ON_ERROR_STOP on
\set ECHO queries
\pset pager off
\pset null '(null)'

-- Proposito: identificar esta conexion como sesion A.
SET application_name = 'sesion_A';
SET client_encoding = 'UTF8';

\echo ''
\echo '=== SESION A: autocommit del cliente, aislamiento e identificador ==='
\echo 'AUTOCOMMIT es del cliente psql, no un parametro del servidor.'
\echo 'Valor de AUTOCOMMIT en este cliente:' :AUTOCOMMIT
-- Resultado esperado: on. Fuera de BEGIN, cada sentencia se confirma sola.

-- Proposito: documentar el aislamiento por defecto de la sesion.
-- Resultado esperado: read committed.
SHOW default_transaction_isolation;

-- Proposito: dejar constancia del backend de esta conexion.
-- Resultado esperado: un pid propio de esta sesion.
SELECT
    pg_backend_pid() AS pid_sesion,
    current_database() AS base,
    current_user AS usuario,
    current_setting('transaction_isolation') AS aislamiento,
    version() AS version_servidor;

\if :{?marca}
\else
\set marca PRACTICA-ESCENARIO-1
\endif

\echo 'Marca de esta venta de practica:' :marca

-- Proposito: abrir la transaccion explicita. Read Committed es el nivel
-- pedido para la prueba de visibilidad entre sesiones.
-- El total 0.00 es provisional y no se confirma: se recalcula con la suma
-- de los detalles antes del COMMIT. Chinook no trae un CHECK ni un trigger
-- que obligue esa igualdad.
BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED;

-- Proposito: comprobar el aislamiento ya dentro de la transaccion.
-- Resultado esperado: read committed.
SHOW transaction_isolation;

-- Proposito: crear la cabecera con un cliente existente y recuperar la clave
-- generada por la secuencia (SERIAL). No se calcula MAX(invoice_id) + 1.
-- Resultado esperado: una fila insertada y la variable invoice_id definida.
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
LIMIT 1
RETURNING invoice_id \gset

\echo 'Clave recuperada con RETURNING:' :invoice_id

-- Proposito: elegir tres canciones que ya existen y usar su precio de venta.
-- No se inventan pistas ni precios.
\unset track_1
\unset price_1
SELECT track_id AS track_1, unit_price AS price_1
FROM track
ORDER BY track_id
OFFSET 0
LIMIT 1 \gset

\unset track_2
\unset price_2
SELECT track_id AS track_2, unit_price AS price_2
FROM track
ORDER BY track_id
OFFSET 1
LIMIT 1 \gset

\unset track_3
\unset price_3
SELECT track_id AS track_3, unit_price AS price_3
FROM track
ORDER BY track_id
OFFSET 2
LIMIT 1 \gset

\echo 'Canciones existentes:' :track_1 :track_2 :track_3
\echo 'Precios de catalogo:' :price_1 :price_2 :price_3

-- Proposito: detalle 1. Cantidad positiva. El precio sale de track.unit_price.
INSERT INTO invoice_line (invoice_id, track_id, unit_price, quantity)
VALUES (:invoice_id, :track_1, :price_1, 1);

-- Proposito: detalle 2. Cantidad positiva distinta, para que el total no sea
-- una copia de un solo precio.
INSERT INTO invoice_line (invoice_id, track_id, unit_price, quantity)
VALUES (:invoice_id, :track_2, :price_2, 2);

-- Proposito: detalle 3. La venta queda con al menos tres lineas.
INSERT INTO invoice_line (invoice_id, track_id, unit_price, quantity)
VALUES (:invoice_id, :track_3, :price_3, 1);

-- Proposito: calcular el total como suma de precio por cantidad.
-- No se escribe un total supuesto a mano.
-- Resultado esperado: el total deja de ser 0.00.
UPDATE invoice AS i
SET total = detalle.total_calculado
FROM (
    SELECT COALESCE(SUM(unit_price * quantity), 0)::numeric(10,2) AS total_calculado
    FROM invoice_line
    WHERE invoice_id = :invoice_id
) AS detalle
WHERE i.invoice_id = :invoice_id;

-- Proposito: listar los detalles que se van a confirmar.
-- Resultado esperado: 3 filas, cantidades > 0 e importe = precio * cantidad.
SELECT
    il.invoice_line_id,
    il.track_id,
    left(t.name, 40) AS cancion,
    il.unit_price,
    il.quantity,
    (il.unit_price * il.quantity)::numeric(10,2) AS importe
FROM invoice_line AS il
JOIN track AS t ON t.track_id = il.track_id
WHERE il.invoice_id = :invoice_id
ORDER BY il.invoice_line_id;

-- Proposito: comprobar cantidad de detalles y coincidencia exacta del total.
-- Resultado esperado: cantidad_detalles >= 3 y venta_ok = 1.
SELECT
    i.invoice_id,
    i.total AS total_factura,
    COUNT(il.invoice_line_id) AS cantidad_detalles,
    COALESCE(SUM(il.unit_price * il.quantity), 0)::numeric(10,2) AS total_calculado,
    CASE
        WHEN COUNT(il.invoice_line_id) >= 3
         AND i.total = COALESCE(SUM(il.unit_price * il.quantity), 0)::numeric(10,2)
        THEN 1
        ELSE 0
    END AS venta_ok
FROM invoice AS i
LEFT JOIN invoice_line AS il ON il.invoice_id = i.invoice_id
WHERE i.invoice_id = :invoice_id
GROUP BY i.invoice_id, i.total \gset

\echo 'invoice_id=' :invoice_id
\echo 'total_factura=' :total_factura
\echo 'cantidad_detalles=' :cantidad_detalles
\echo 'total_calculado=' :total_calculado
\echo 'venta_ok (1 = coincide)=' :venta_ok

\if :venta_ok
\else
\echo 'La venta no cumple la comprobacion. Se revierte y no hay COMMIT.'
ROLLBACK;
\quit 1
\endif

\if :{?modo_visibilidad}
\echo ''
\echo 'MODO VISIBILIDAD: la transaccion SIGUE ABIERTA. Aun no hay COMMIT.'
\echo 'La sesion B no debe ver la marca' :marca
\echo 'Clave aun no confirmada:' :invoice_id
\o /tmp/a_lista.txt
\echo LISTO
\o
-- Proposito: mantener la transaccion abierta para que la otra conexion
-- consulte antes del COMMIT. No confirma nada.
-- Resultado esperado: la sesion B, en ese intervalo, obtiene 0 filas.
SELECT pg_sleep(40);
\endif

-- Limite transaccional explicito. No esta dentro de un procedimiento.
-- A partir de este COMMIT la venta es visible para otras sesiones.
COMMIT;

\if :{?modo_visibilidad}
\o /tmp/a_commit.txt
\echo COMMIT_OK
\o
\echo 'COMMIT realizado. La sesion B ya debe ver la venta.'
\endif

-- Proposito: leer la venta ya confirmada en esta misma sesion.
-- Resultado esperado: la cabecera, tres detalles y totales iguales.
SELECT
    i.invoice_id,
    i.customer_id,
    i.billing_address,
    i.total AS total_factura,
    COUNT(il.invoice_line_id) AS cantidad_detalles,
    COALESCE(SUM(il.unit_price * il.quantity), 0)::numeric(10,2) AS total_calculado
FROM invoice AS i
JOIN invoice_line AS il ON il.invoice_id = i.invoice_id
WHERE i.invoice_id = :invoice_id
GROUP BY i.invoice_id, i.customer_id, i.billing_address, i.total;

\echo 'Fin del escenario 1. La comprobacion desde la otra conexion esta en 04_validaciones.sql.'
