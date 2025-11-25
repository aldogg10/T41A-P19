-- sql/02_insert_data.sql
-- Datos iniciales y de prueba para el entorno CI.

-- Configuración de IDs para consistencia en la prueba
SELECT setval('roles_rol_id_seq', 10, false);
SELECT setval('materia_prima_materia_prima_id_seq', 10, false);
SELECT setval('productos_producto_id_seq', 10, false);
SELECT setval('piezas_pieza_id_seq', 10, false);
SELECT setval('optimizacion_corte_opt_corte_id_seq', 10, false);
SELECT setval('piezas_colocadas_pieza_colocada_id_seq', 10, false);

-- 1. Roles de Aplicación
INSERT INTO roles (rol_id, nombre) VALUES (1, 'Administrador'), (2, 'Operador')
ON CONFLICT (rol_id) DO UPDATE SET nombre = EXCLUDED.nombre;

-- 2. Materia Prima (MP) - 1000x500. Restricción de orilla: 10.0
INSERT INTO materia_prima (materia_prima_id, numero_parte, dimension_largo, dimension_ancho, distancia_min_piezas, distancia_min_orilla)
VALUES (1, 'MP-TEST-001', 1000.0, 500.0, 5.0, 10.0);

-- 3. Productos y Piezas (PZ)
INSERT INTO productos (producto_id, numero_parte, descripcion, materia_prima_base_id)
VALUES (1, 'PROD-TEST-001', 'Pieza de prueba para corte', 1);

INSERT INTO piezas (pieza_id, producto_id, nombre_pieza, cantidad_elementos, geometria_original)
VALUES (1, 1, 'Pieza Cuadrada A', 1, 'POLYGON((0 0, 100 0, 100 100, 0 100, 0 0))');

-- 4. Inicio de Optimización (OC)
INSERT INTO optimizacion_corte (opt_corte_id, materia_prima_id, estado)
VALUES (1, 1, 'En curso');

-- 5. Pieza Colocada Inicialmente (PC) - Posición válida (10.0, 10.0)
-- Dispara el trigger: Utilización = 2.0%
INSERT INTO piezas_colocadas (pieza_colocada_id, opt_corte_id, pieza_id, geometria_actual, rotacion_grados, posicion_x, posicion_y)
VALUES (1, 1, 1, 'GEOMETRIA_INICIAL_1', 0.0, 10.0, 10.0);
