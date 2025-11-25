# tests/test_logic.py

import pytest
import psycopg2
import json
from psycopg2.errors import RaiseException

# NOTA: La conexión debe coincidir con la configuración del servicio 'postgres' en .github/workflows/postgresql_workflow.yml
DB_HOST = "localhost"
DB_NAME = "test_db"
DB_USER = "postgres"
DB_PASSWORD = "postgres"


@pytest.fixture(scope="module")
def db_conn():
    """Fixture para establecer y configurar la conexión a la base de datos de prueba."""
    try:
        conn = psycopg2.connect(
            host=DB_HOST, database=DB_NAME, user=DB_USER, password=DB_PASSWORD
        )
        conn.autocommit = True
        yield conn
        conn.close()
    except Exception as e:
        pytest.fail(f"No se pudo conectar a la base de datos: {e}")


def ensure_base_fixtures(cur):
    """
    Inserta fixtures mínimos necesarios para las pruebas.
    Usa ON CONFLICT DO NOTHING para no romper si ya existen.
    """
    # Materia prima
    cur.execute("""
    INSERT INTO materia_prima (
      materia_prima_id, numero_parte, dimension_largo, dimension_ancho,
      distancia_min_piezas, distancia_min_orilla
    ) VALUES (1, 'MP-TEST-001', 1000.0, 500.0, 5.0, 10.0)
    ON CONFLICT (materia_prima_id) DO NOTHING;
    """)

    # Producto (referencia a materia_prima_id 1)
    cur.execute("""
    INSERT INTO productos (producto_id, numero_parte, descripcion, materia_prima_base_id)
    VALUES (1, 'PROD-TEST-001', 'Producto prueba pytest', 1)
    ON CONFLICT (producto_id) DO NOTHING;
    """)

    # Pieza (referencia a producto_id 1)
    cur.execute("""
    INSERT INTO piezas (pieza_id, producto_id, nombre_pieza, cantidad_elementos, geometria_original)
    VALUES (1, 1, 'Pieza PyTest A', 1, 'POLYGON((0 0, 100 0, 100 100, 0 100, 0 0))')
    ON CONFLICT (pieza_id) DO NOTHING;
    """)

    # Optimización de corte
    cur.execute("""
    INSERT INTO optimizacion_corte (opt_corte_id, materia_prima_id, estado)
    VALUES (1, 1, 'En curso')
    ON CONFLICT (opt_corte_id) DO NOTHING;
    """)

    # Pieza colocada (referencia a pieza_id 1 y opt_corte_id 1)
    cur.execute("""
    INSERT INTO piezas_colocadas
      (pieza_colocada_id, opt_corte_id, pieza_id, geometria_actual, rotacion_grados, posicion_x, posicion_y)
    VALUES
      (1, 1, 1, 'GEOMETRIA_INICIAL_TEST', 0.0, 10.0, 10.0)
    ON CONFLICT (pieza_colocada_id) DO NOTHING;
    """)

    # Roles y usuario admin mínimo (para pruebas de autenticación/crud)
    cur.execute("""
    INSERT INTO roles (rol_id, nombre)
    VALUES (1, 'Administrador')
    ON CONFLICT (rol_id) DO NOTHING;
    """)

    # Crear usuario ci_admin si no existe (usando sp_crear_usuario si existe)
    # Intentamos crear por username; si ya existe, omitimos.
    cur.execute("""
    INSERT INTO usuarios (usuario_id, username, password_hash, rol_id, activo)
    SELECT 1, 'ci_admin', crypt('Pass4CI!', gen_salt('bf')), 1, TRUE
    WHERE NOT EXISTS (SELECT 1 FROM usuarios WHERE username = 'ci_admin');
    """)
    

# --- PRUEBAS DE FUNCIONES Y TRIGGERS ---


def test_fn_calcular_utilizacion_correct(db_conn):
    """Prueba que la función fn_calcular_utilizacion retorne ~2.0% (basado en fixtures)."""
    with db_conn.cursor() as cur:
        ensure_base_fixtures(cur)
        cur.execute("SELECT fn_calcular_utilizacion(1);")
        result = cur.fetchone()[0]
        # result viene como decimal.Decimal; convertir a float para comparación
        result_f = float(result)
        assert abs(result_f - 2.0) < 0.001, f"Utilización esperada 2.0, obtenida {result_f}"


def test_trigger_validation_raises_exception_for_boundary(db_conn):
    """Prueba que el trigger rechace una posición inválida (X=5.0, Mínimo 10.0)."""
    invalid_x = 5.0
    insert_sql = """
    INSERT INTO piezas_colocadas (opt_corte_id, pieza_id, geometria_actual, rotacion_grados, posicion_x, posicion_y)
    VALUES (1, 1, 'GEOM_TRIGGER_FAIL_PYTHON', 0.0, %s, 50.0);
    """
    with db_conn.cursor() as cur:
        ensure_base_fixtures(cur)
        with pytest.raises(RaiseException, match="demasiado cerca del borde"):
            cur.execute(insert_sql, (invalid_x,))


def test_sp_rotar_posicionar_updates_and_logs(db_conn):
    """Prueba el SP sp_rotar_posicionar_figuras y el registro JSONB."""
    pieza_colocada_id = 1
    new_rotation = 45.0
    new_pos_x = 200.0
    event_payload = '{"usuario": "test_operador", "algoritmo": "python_test"}'

    with db_conn.cursor() as cur:
        ensure_base_fixtures(cur)

        # Ejecutar el SP (aseguramos que la pieza_colocada exista)
        cur.execute(
            "CALL sp_rotar_posicionar_figuras(%s, %s, %s, %s, %s::jsonb);",
            (pieza_colocada_id, new_rotation, new_pos_x, 50.0, event_payload)
        )

        # Verificar actualización de posición
        cur.execute(
            "SELECT rotacion_grados, posicion_x FROM piezas_colocadas WHERE pieza_colocada_id = %s;",
            (pieza_colocada_id,)
        )
        row = cur.fetchone()
        assert row is not None, "No se encontró la pieza_colocada después del CALL"
        rotacion, pos_x = row
        # rotacion and pos_x are Decimal (NUMERIC) — convert to float for equality with floats
        assert float(rotacion) == float(new_rotation)
        assert float(pos_x) == float(new_pos_x)

        # Verificar registro del evento JSONB
        cur.execute(
            "SELECT payload FROM eventos_optimizacion WHERE pieza_colocada_id = %s ORDER BY fecha_evento DESC LIMIT 1;",
            (pieza_colocada_id,)
        )
        payload_row = cur.fetchone()
        assert payload_row is not None, "No se encontró evento registrado"
        payload_data = payload_row[0]
        assert "python_test" in str(payload_data), "El evento JSONB no fue registrado correctamente."


# --- PRUEBAS DE CRUD Y SEGURIDAD ---


def test_sp_crud_roles_cycle(db_conn):
    """Prueba el ciclo completo de Crear, Actualizar y Eliminar roles."""
    rol_name = 'Test_ROL_Cycle_Py'
    with db_conn.cursor() as cur:
        ensure_base_fixtures(cur)
        # CREAR
        cur.execute("CALL sp_crear_rol(%s, %s);", (rol_name, 'Rol de prueba python'))
        cur.execute("SELECT rol_id, descripcion FROM roles WHERE nombre = %s;", (rol_name,))
        row = cur.fetchone()
        assert row is not None, "No se creó el rol"
        rol_id, desc = row
        # ELIMINAR
        cur.execute("CALL sp_eliminar_rol(%s);", (rol_id,))
        cur.execute("SELECT rol_id FROM roles WHERE rol_id = %s;", (rol_id,))
        assert cur.fetchone() is None


def test_sp_crud_usuarios_and_auth(db_conn):
    """Prueba la creación, autenticación (seguridad), actualización y eliminación de usuarios."""
    username = 'ci_test_user_py'
    password = 'SecurePasswordPy'
    with db_conn.cursor() as cur:
        ensure_base_fixtures(cur)
        # Asegurar rol 1
        cur.execute("SELECT rol_id FROM roles WHERE nombre = 'Administrador';")
        row = cur.fetchone()
        assert row is not None, "Rol Administrador no existe en la BD de pruebas"
        rol_id = row[0]
        # CREAR USUARIO (HASHING)
        cur.execute("CALL sp_crear_usuario(%s, %s, %s);", (username, password, rol_id))
        cur.execute("SELECT usuario_id FROM usuarios WHERE username = %s;", (username,))
        row = cur.fetchone()
        assert row is not None, "Usuario no fue creado"
        user_id = row[0]

        # AUTENTICACIÓN (fn_autenticar_usuario)
        cur.execute("SELECT fn_autenticar_usuario(%s, %s);", (username, password))
        assert cur.fetchone()[0] is True  # Correcta
        # Actualizar a inactivo
        cur.execute("CALL sp_actualizar_usuario(%s, %s, NULL, FALSE);", (user_id, username))
        # Autenticación debe fallar por inactivo
        cur.execute("SELECT fn_autenticar_usuario(%s, %s);", (username, password))
        assert cur.fetchone()[0] is False
        # ELIMINAR
        cur.execute("CALL sp_eliminar_usuario(%s);", (user_id,))
        cur.execute("SELECT usuario_id FROM usuarios WHERE usuario_id = %s;", (user_id,))
        assert cur.fetchone() is None
