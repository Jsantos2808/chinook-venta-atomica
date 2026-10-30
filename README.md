# Venta atómica en Chinook (PostgreSQL 18)

José Alberto Santos Aguilar — carné 2890-23-18464  
Universidad Mariano Gálvez de Guatemala — Base de Datos I

Repositorio: https://github.com/Jsantos2808/chinook-venta-atomica

La tienda Chinook registra una venta como una sola transacción: un cliente que ya existe, una factura y varios detalles de canciones. Cada detalle guarda el precio de venta y la cantidad. El total de la factura tiene que ser la suma de precio por cantidad. Si una canción no existe, no puede quedar una factura a medias. Si solo un detalle está mal, se corrige ese tramo sin perder los detalles válidos. Una segunda conexión comprueba cuándo la venta se vuelve visible.

## Variante y versión

| Dato | Valor |
| --- | --- |
| Servidor | PostgreSQL 18.6 (imagen oficial `postgres:18.6`) |
| Base | `chinook_serial`, creada por el script oficial |
| Variante | Chinook Database 1.4.5, `Chinook_PostgreSql_SerialPKs.sql` |
| Fuente | https://github.com/lerocha/chinook-database/blob/master/ChinookDatabase/DataSources/Chinook_PostgreSql_SerialPKs.sql |
| Licencia de Chinook | Copyright (c) 2008-2024 Luis Rocha. El aviso va en el propio script. |
| Tablas usadas | `customer`, `invoice`, `invoice_line`, `track` |

Las claves primarias de esa variante son `SERIAL`. Por eso la factura nueva se recupera con `RETURNING` y no con `MAX(id) + 1`.

Documentación de PostgreSQL 18 usada como referencia:

- Transacciones: https://www.postgresql.org/docs/18/tutorial-transactions.html
- Aislamiento: https://www.postgresql.org/docs/18/transaction-iso.html
- `SAVEPOINT`: https://www.postgresql.org/docs/18/sql-savepoint.html

## Qué hace el script de importación

Hay que leerlo antes de ejecutarlo. Al inicio hace exactamente esto:

```sql
DROP DATABASE IF EXISTS chinook_serial;
CREATE DATABASE chinook_serial;
\c chinook_serial;
```

`DROP DATABASE` borra esa base si ya existe. `\c` es una metaorden de psql: cambia la conexión a `chinook_serial`. No es SQL y hay que ejecutarlo con psql, no pegándolo en un cliente que ignore las metaórdenes.

Ese archivo solo elimina `chinook_serial`. Aun así, no debe lanzarse contra un servidor donde esa base tenga datos que se quieran conservar. Aquí se importa únicamente dentro del contenedor de esta práctica.

El esquema original no tiene un `CHECK` de cantidad positiva ni un trigger que iguale `invoice.total` con sus detalles. La violación que se provoca en los escenarios 2 y 3 es la llave foránea real `invoice_line_track_id_fkey`. El total se calcula en la transacción, antes de `COMMIT`, y después se comprueba.

## Instalación

Requisitos: Docker con Compose v2. No hace falta instalar PostgreSQL en Windows.

```powershell
copy .env.example .env
```

Edite `.env` y cambie `POSTGRES_PASSWORD`. Ese archivo no se sube al repositorio ni se pega en el PDF.

```powershell
docker compose up -d
docker compose ps
```

El puerto publicado es `127.0.0.1:5433`. El volumen de PostgreSQL 18 está en `/var/lib/postgresql`.

`docker compose down` detiene el contenedor y conserva los datos. `docker compose down -v` borra el volumen; después hay que importar otra vez.

## Importación

Con el contenedor en marcha:

```powershell
docker compose exec -T db psql -U chinook -d postgres -v ON_ERROR_STOP=1 -f /datos/Chinook_PostgreSql_SerialPKs.sql
```

`-d postgres` importa desde la base de mantenimiento. El propio script crea `chinook_serial` y se conecta a ella. Si cambia `POSTGRES_USER` en `.env`, use ese usuario en lugar de `chinook`.

Comprobación rápida:

```powershell
docker compose exec -T db psql -U chinook -d chinook_serial -c "SELECT version();"
docker compose exec -T db psql -U chinook -d chinook_serial -c "SELECT COUNT(*) AS facturas FROM invoice;"
```

Chinook 1.4.5 deja 59 clientes, 3503 canciones, 412 facturas y 2240 detalles. `04_validaciones.sql` vuelve a exigir las 412 facturas originales.

Para repetir la importación desde cero, el mismo comando sirve: el script oficial vuelve a eliminar y crear `chinook_serial`. Conviene cerrar antes las sesiones psql que estén conectadas a esa base.

## Conexiones A y B

Hacen falta dos procesos de psql. No sirven dos consultas seguidas en la misma sesión para probar visibilidad.

| | Sesión A | Sesión B |
| --- | --- | --- |
| Papel | Crea la venta dentro de `BEGIN` … `COMMIT` | Solo consulta |
| `application_name` | `sesion_A` (u otra marca del escenario) | `sesion_B` |
| Identificador | `pg_backend_pid()` impreso al inicio | Otro `pg_backend_pid()` |
| Autocommit | `on` en el cliente, pero la venta va entre `BEGIN` y `COMMIT` | `on`: cada `SELECT` es su propia lectura |
| Aislamiento | `BEGIN TRANSACTION ISOLATION LEVEL READ COMMITTED` | `read committed` |

PostgreSQL no tiene un parámetro de servidor llamado autocommit. En psql la variable `AUTOCOMMIT` vale `on` por defecto: fuera de un bloque explícito, cada sentencia se confirma sola. Por eso los scripts abren la venta con `BEGIN`. Si no lo hicieran, un error posterior no podría deshacer la cabecera ya confirmada.

Desde otra terminal, la sesión B se abre así:

```powershell
docker compose exec -it db psql -U chinook -d chinook_serial
```

Dentro de psql: `\echo :AUTOCOMMIT`, `SHOW transaction_isolation` y `SELECT pg_backend_pid();`.

## Orden de ejecución

Cada escenario se puede lanzar solo, sobre la copia ya importada. Ninguno adivina el `invoice_id` de otro: lo recibe con `RETURNING` o busca la marca `PRACTICA-...`.

1. `01_venta_exitosa.sql` — confirma una venta de tres detalles.
2. `02_rollback_total.sql` — provoca la FK, hace `ROLLBACK` y comprueba que esa clave no quedó.
3. `03_savepoint.sql` — recupera los dos detalles buenos, corrige el tercero y confirma.
4. `04_validaciones.sql` — revisa totales, originales y restricciones.
5. Prueba de visibilidad — protocolo de la sección siguiente. Puede repetirse cuando se quiera; crea otra venta con una marca propia.

```powershell
docker compose exec -T db psql -U chinook -d chinook_serial -P pager=off -f /sql/01_venta_exitosa.sql
docker compose exec -T db psql -U chinook -d chinook_serial -P pager=off -f /sql/02_rollback_total.sql
docker compose exec -T db psql -U chinook -d chinook_serial -P pager=off -f /sql/03_savepoint.sql
docker compose exec -T db psql -U chinook -d chinook_serial -P pager=off -f /sql/04_validaciones.sql
```

Los cuatro archivos están montados en `/sql` dentro del contenedor. `\set ECHO queries` imprime cada sentencia junto con su resultado.

Volver a ejecutar 01 o 03 añade otra factura de práctica. No modifica las 412 originales. El escenario 2 nunca deja filas con la marca `PRACTICA-ESCENARIO-2`.

## Visibilidad entre sesiones

La prueba usa el escenario 1. Elija una marca que no exista todavía, por ejemplo `PRACTICA-VISIBILIDAD`.

Terminal A:

```powershell
docker compose exec -it db psql -U chinook -d chinook_serial -P pager=off -v modo_visibilidad=1 -v marca=PRACTICA-VISIBILIDAD -f /sql/01_venta_exitosa.sql
```

A inserta la venta, comprueba el total y, antes de `COMMIT`, espera 40 segundos. En ese intervalo la transacción sigue abierta.

Terminal B, durante esa espera:

```powershell
docker compose exec -T db psql -U chinook -d chinook_serial -P pager=off -v fase=antes -v marca=PRACTICA-VISIBILIDAD -f /sql/04_validaciones.sql
```

Resultado esperado: 0 filas y un `pid` distinto del de A. En `pg_stat_activity` se ven las dos conexiones.

Cuando A imprime que el `COMMIT` ya se hizo, repita en B con `-v fase=despues`. Resultado esperado: la cabecera, al menos tres detalles y el total igual a la suma.

`scripts/demo_visibilidad.py` hace ese protocolo y evita la carrera: B consulta cuando A ya escribió `/tmp/a_lista.txt` y todavía no ha confirmado, y vuelve a consultar cuando aparece `/tmp/a_commit.txt`.

## Si el cliente se detiene en el primer error

Los escenarios 2 y 3 provocan un error a propósito. En psql, el tramo del `INSERT` inválido va con `ON_ERROR_STOP` apagado, así el mismo archivo sigue y ejecuta la recuperación.

Si el cliente aborta el script en cuanto ve el error (pgAdmin, DBeaver o un psql que no llegue a esas líneas):

1. No cierre la conexión. Al cerrarla, PostgreSQL deshace la transacción abierta y se pierde la variable `invoice_id`.
2. En el escenario 2 ejecute desde el comentario `BLOQUE DE RECUPERACION`. Empieza en `ROLLBACK` y después consulta esa clave en `invoice` e `invoice_line`.
3. En el escenario 3 ejecute desde su `BLOQUE DE RECUPERACION`. Empieza en `ROLLBACK TO SAVEPOINT antes_detalle_riesgo`, inserta el detalle corregido, recalcula el total y termina en `COMMIT`.

Un `COMMIT` lanzado mientras la transacción está abortada no guarda la venta: PostgreSQL la revierte. El script usa `ROLLBACK` o `ROLLBACK TO SAVEPOINT`, que es lo que corresponde.

## Parámetros

| Variable de psql | Dónde | Valor por defecto | Para qué |
| --- | --- | --- | --- |
| `marca` | 01, 02 y 03 | `PRACTICA-ESCENARIO-1`, `2` o `3` | `billing_address` de la venta nueva |
| `modo_visibilidad` | 01 | no definida | Si existe, espera antes del `COMMIT` |
| `fase` | 04 | no definida | `antes` o `despues`; omite el resto de validaciones |
| `marca` | 04, junto con `fase` | obligatoria en ese modo | La misma marca que está usando A |

No hay que sustituir identificadores a mano. `invoice_id` sale de `RETURNING`.

Sustituciones de entorno, solo si no usa los valores de `.env.example`:

- usuario: `POSTGRES_USER`
- puerto del host: `POSTGRES_PORT` (5433)
- base de la práctica: `chinook_serial` (la fija el script oficial; no se renombra)
- base desde la que se importa: `postgres`

Para conectarse desde Windows hace falta el cliente `psql` y la clave de `.env`:

```powershell
psql -h 127.0.0.1 -p 5433 -U chinook -d chinook_serial
```

Los comandos de esta guía no necesitan eso: `docker compose exec` entra por el socket local del contenedor.

## Qué no hacen estos scripts

- No usan `MAX(id) + 1` para generar claves.
- No desactivan restricciones.
- No borran ni modifican facturas originales. El único `UPDATE` cambia el `total` de la factura recién insertada, identificada por la clave que devolvió `RETURNING`.
- No esconden `COMMIT` dentro de procedimientos. El bloque `DO` de `04_validaciones.sql` solo lee y, si algo no cuadra, lanza un error.
- No crean tablas de inventario ni de saldos.

Las ventas de práctica se reconocen porque `billing_address` empieza por `PRACTICA-`.

## Archivos

| Archivo | Uso |
| --- | --- |
| `01_venta_exitosa.sql` | Venta confirmada y, con variables, la mitad A de la visibilidad |
| `02_rollback_total.sql` | Error de FK y `ROLLBACK` total |
| `03_savepoint.sql` | `SAVEPOINT`, error, recuperación, corrección y `COMMIT` |
| `04_validaciones.sql` | Integridad de la copia y consultas de la sesión B |
| `compose.yaml` | PostgreSQL 18.6, solo en localhost |
| `.env.example` | Plantilla sin la clave real |
| `datos/Chinook_PostgreSql_SerialPKs.sql` | Script oficial revisado, con su aviso de copyright |
| `scripts/demo_visibilidad.py` | Coordinación de las dos sesiones |

## Cómo repetir las pruebas

1. `docker compose up -d`
2. Si el volumen es nuevo o se borró, importar otra vez.
3. Ejecutar 01, 02, 03 y 04 en ese orden.
4. Para la visibilidad, usar una marca nueva (`PRACTICA-VISIBILIDAD-2`, etc.) o volver a importar si quiere la base tal como vino.
5. `python scripts/demo_visibilidad.py` repite solo el paso de las dos sesiones. La marca por defecto es `PRACTICA-VISIBILIDAD`; si esa venta ya está confirmada, pase otra: `python scripts/demo_visibilidad.py PRACTICA-VISIBILIDAD-2`.
