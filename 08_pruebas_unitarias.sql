-- PRUEBA 1: Verificar el cálculo de utilización inicial
DO $$
DECLARE
    v_utilizacion NUMERIC;
BEGIN
    SELECT utilizacion_porcentaje INTO v_utilizacion
    FROM optimizacion_corte WHERE opt_corte_id = 1;

    -- Esperado: 2.0%
    IF ABS(v_utilizacion - 2.0) > 0.001 THEN
        RAISE EXCEPTION 'SQL TEST FAIL: Utilización inicial. Esperado 2.0, Obtenido %', v_utilizacion;
    END IF;
    RAISE NOTICE 'SQL TEST PASS: Utilización inicial correcta.';
END $$;


-- PRUEBA 2: sp_rotar_posicionar_figuras (Ejecución exitosa y registro JSON)
DO $$
DECLARE
    v_evento JSONB := '{"test_case": "rotacion_exitosa", "motivo": "algoritmo_A"}';
BEGIN
    -- Rotar pieza ID 1 a 90 grados y posicionarla en (50.0, 50.0)
    CALL sp_rotar_posicionar_figuras(1, 90.0, 50.0, 50.0, v_evento);

    -- Verificar que el evento se registró
    IF (SELECT COUNT(*) FROM eventos_optimizacion WHERE pieza_colocada_id = 1 AND tipo_evento = 'ROTACION_POSICIONAMIENTO') <> 1 THEN
        RAISE EXCEPTION 'SQL TEST FAIL: Evento JSON no registrado.';
    END IF;

    RAISE NOTICE 'SQL TEST PASS: Rotación, Posicionamiento y Evento exitosos.';
END $$;


-- PRUEBA 3: Trigger de Validación (Falla por posición_x demasiado cerca del borde. Mínimo 10.0)
DO $$
DECLARE
    v_evento JSONB := '{"test_case": "fallo_validacion", "motivo": "borde"}';
BEGIN
    BEGIN
        -- Intento de inserción inválido (Posicion X = 5.0, menos del mínimo de 10.0)
        INSERT INTO piezas_colocadas (opt_corte_id, pieza_id, geometria_actual, rotacion_grados, posicion_x, posicion_y)
        VALUES (1, 1, 'GEOMETRIA_INICIAL_2', 0.0, 5.0, 50.0);

        RAISE EXCEPTION 'SQL TEST FAIL: El trigger de validación FALLÓ en lanzar la excepción de borde.';
    EXCEPTION
        WHEN raise_exception THEN
            IF SQLERRM LIKE '%demasiado cerca del borde%' THEN
                RAISE NOTICE 'SQL TEST PASS: Trigger de validación (borde) exitoso (excepción esperada).';
            ELSE
                 RAISE EXCEPTION 'SQL TEST FAIL: Excepción de trigger incorrecta: %', SQLERRM;
            END IF;
    END;
END $$;

-- PRUEBA 4: Trigger de actualización de utilización (UPDATE)
DO $$
DECLARE
    v_utilizacion_antes NUMERIC;
    v_utilizacion_despues NUMERIC;
BEGIN
    -- Obtener utilización actual
    SELECT utilizacion_porcentaje
    INTO v_utilizacion_antes
    FROM optimizacion_corte
    WHERE opt_corte_id = 1;

    -- Hacer un UPDATE que NO cambie el área (solo mover dentro de los límites)
    UPDATE piezas_colocadas
    SET posicion_x = 20.0, posicion_y = 20.0
    WHERE pieza_colocada_id = 1;

    -- Obtener nueva utilización
    SELECT utilizacion_porcentaje
    INTO v_utilizacion_despues
    FROM optimizacion_corte
    WHERE opt_corte_id = 1;

    -- Deben ser iguales
    IF ABS(v_utilizacion_antes - v_utilizacion_despues) > 0.001 THEN
        RAISE EXCEPTION
            'SQL TEST FAIL: Trigger de actualización falló en UPDATE. Antes %, Después %',
            v_utilizacion_antes, v_utilizacion_despues;
    END IF;

    RAISE NOTICE 'SQL TEST PASS: Trigger actualizar utilización funciona en UPDATE.';
END $$;


-- PRUEBA 5: Verificación de Trigger tras DELETE (se debe recalcular la utilización)
DO $$
DECLARE
    v_utilizacion NUMERIC;
BEGIN
    -- Borrar eventos que referencian la pieza, para evitar FK violation
    DELETE FROM eventos_optimizacion WHERE pieza_colocada_id = 1;

    -- Ahora sí podemos borrar la pieza colocada
    DELETE FROM piezas_colocadas WHERE pieza_colocada_id = 1;

    -- La utilización debe recalcularse a 0%
    SELECT utilizacion_porcentaje INTO v_utilizacion
    FROM optimizacion_corte WHERE opt_corte_id = 1;

    IF v_utilizacion <> 0 THEN
        RAISE EXCEPTION 'SQL TEST FAIL: Utilización tras DELETE incorrecta. Esperado 0, obtenido %', v_utilizacion;
    END IF;

    RAISE NOTICE 'SQL TEST PASS: Trigger de actualización tras DELETE correcto.';
END $$;



-- PRUEBA 6: sp_rotar_posicionar_figuras con pieza inexistente
DO $$
DECLARE
    v_evento JSONB := '{"test_case": "error_pieza_inexistente"}';
BEGIN
    BEGIN
        CALL sp_rotar_posicionar_figuras(9999, 0, 0, 0, v_evento);
        RAISE EXCEPTION 'SQL TEST FAIL: No se lanzó excepción para pieza inexistente.';
    EXCEPTION WHEN raise_exception THEN
        IF SQLERRM NOT LIKE '%no existe%' THEN
            RAISE EXCEPTION 'SQL TEST FAIL: Excepción incorrecta: %', SQLERRM;
        END IF;

        RAISE NOTICE 'SQL TEST PASS: Excepción correcta para pieza inexistente.';
    END;
END $$;


-- PRUEBA 7: Función fn_calcular_area_geom
DO $$
DECLARE
    v_area NUMERIC;
BEGIN
    SELECT fn_calcular_area_geom('POLYGON((0 0, 1 0, 1 1, 0 1, 0 0))')
    INTO v_area;

    IF v_area <> 10000 THEN
        RAISE EXCEPTION 'SQL TEST FAIL: Área incorrecta. Esperado 10000, obtenido %', v_area;
    END IF;

    RAISE NOTICE 'SQL TEST PASS: fn_calcular_area_geom correcta.';
END $$;


-- PRUEBA 8: Alta de Materia Prima (ÉXITO)
DO $$
DECLARE
    v_count INT;
BEGIN
    -- Ejecutar SP
    CALL sp_alta_materia_prima(
        'MP-UNIT-001',
        2000.0,
        1000.0,
        5.0,
        10.0
    );

    -- Validar inserción
    SELECT COUNT(*) INTO v_count
    FROM materia_prima
    WHERE numero_parte = 'MP-UNIT-001';

    IF v_count <> 1 THEN
        RAISE EXCEPTION 'SQL TEST FAIL: Materia prima no fue insertada.';
    END IF;

    RAISE NOTICE 'SQL TEST PASS: Alta de materia prima exitosa.';
END $$;

-- PRUEBA 9: Alta de Producto (ÉXITO)
DO $$
DECLARE
    v_mp_id INT;
    v_prod_count INT;
    v_pieza_count INT;
BEGIN
    -- Asegurar que la materia prima existe
    INSERT INTO materia_prima (
        numero_parte, dimension_largo, dimension_ancho,
        distancia_min_piezas, distancia_min_orilla
    )
    VALUES ('MP-PROD-TEST', 1000, 500, 5, 10)
    ON CONFLICT (numero_parte) DO NOTHING;

    -- Obtener ID de materia prima
    SELECT materia_prima_id
    INTO v_mp_id
    FROM materia_prima
    WHERE numero_parte = 'MP-PROD-TEST';

    -- Validación previa
    IF v_mp_id IS NULL THEN
        RAISE EXCEPTION 'SQL TEST FAIL: Materia prima MP-PROD-TEST no existe.';
    END IF;

    -- Ejecutar SP
    CALL sp_alta_producto(
        'PROD-UNIT-001',
        'Producto de prueba',
        v_mp_id,
        'Pieza Base Test',
        1,
        'GEOMETRIA_X'
    );

    -- Verificar producto
    SELECT COUNT(*) INTO v_prod_count
    FROM productos
    WHERE numero_parte = 'PROD-UNIT-001';

    IF v_prod_count <> 1 THEN
        RAISE EXCEPTION 'SQL TEST FAIL: Producto no fue insertado.';
    END IF;

    -- Verificar pieza asociada
    SELECT COUNT(*) INTO v_pieza_count
    FROM piezas p
    JOIN productos pr ON p.producto_id = pr.producto_id
    WHERE pr.numero_parte = 'PROD-UNIT-001';

    IF v_pieza_count <> 1 THEN
        RAISE EXCEPTION 'SQL TEST FAIL: Pieza asociada no generada.';
    END IF;

    RAISE NOTICE 'SQL TEST PASS: Alta de producto exitosa con pieza asociada.';
END $$;
