-- sql/01_create_tables.sql
-- Creación de Tipos, Tablas, Funciones, Procedimientos y Triggers.

-- -------------------------------------------------------------------------
-- 0. CONFIGURACIÓN Y SEGURIDAD
-- -------------------------------------------------------------------------

-- Instala la extensión pgcrypto para el hashing seguro de contraseñas (Requisito de Seguridad)
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- -------------------------------------------------------------------------
-- 1. CREACIÓN DE TABLAS
-- -------------------------------------------------------------------------

-- Tablas de Seguridad
CREATE TABLE roles (
  rol_id SERIAL PRIMARY KEY,
  nombre VARCHAR(50) UNIQUE NOT NULL,
    descripcion TEXT -- Columna añadida para consistencia con SPs
);

CREATE TABLE usuarios (
  usuario_id SERIAL PRIMARY KEY,
  username VARCHAR(100) UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  rol_id INTEGER NOT NULL REFERENCES roles(rol_id),
    activo BOOLEAN NOT NULL DEFAULT TRUE -- Estado de actividad
);

-- Tablas de Materia Prima y Productos
CREATE TABLE materia_prima (
  materia_prima_id SERIAL PRIMARY KEY,
  numero_parte VARCHAR(100) UNIQUE NOT NULL,
  descripcion TEXT,
  dimension_largo NUMERIC NOT NULL CHECK (dimension_largo > 0),
  dimension_ancho NUMERIC NOT NULL CHECK (dimension_ancho > 0),
  distancia_min_piezas NUMERIC NOT NULL DEFAULT 0,
  distancia_min_orilla NUMERIC NOT NULL DEFAULT 0
);

CREATE TABLE productos (
  producto_id SERIAL PRIMARY KEY,
  numero_parte VARCHAR(100) UNIQUE NOT NULL,
  descripcion TEXT,
  materia_prima_base_id INTEGER NOT NULL REFERENCES materia_prima(materia_prima_id)
);

-- Tablas de Piezas y Optimización
CREATE TABLE piezas (
  pieza_id SERIAL PRIMARY KEY,
  producto_id INTEGER NOT NULL REFERENCES productos(producto_id),
  nombre_pieza VARCHAR(100) NOT NULL,
  cantidad_elementos INTEGER NOT NULL DEFAULT 1 CHECK (cantidad_elementos >= 1),
  geometria_original TEXT NOT NULL
);

CREATE TABLE optimizacion_corte (
  opt_corte_id BIGSERIAL PRIMARY KEY,
  materia_prima_id INTEGER NOT NULL REFERENCES materia_prima(materia_prima_id),
  estado VARCHAR(50) NOT NULL DEFAULT 'En curso',
  fecha_creacion TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
  utilizacion_porcentaje NUMERIC DEFAULT 0.0 CHECK (utilizacion_porcentaje >= 0 AND utilizacion_porcentaje <= 100)
);

CREATE TABLE piezas_colocadas (
  pieza_colocada_id BIGSERIAL PRIMARY KEY,
  opt_corte_id BIGINT NOT NULL REFERENCES optimizacion_corte(opt_corte_id),
  pieza_id INTEGER NOT NULL REFERENCES piezas(pieza_id),
  geometria_actual TEXT NOT NULL,
  rotacion_grados NUMERIC DEFAULT 0.0,
  posicion_x NUMERIC DEFAULT 0.0,
  posicion_y NUMERIC DEFAULT 0.0
);

-- Tabla de Eventos (Uso de JSONB)
CREATE TABLE eventos_optimizacion (
  evento_id BIGSERIAL PRIMARY KEY,
  pieza_colocada_id BIGINT REFERENCES piezas_colocadas(pieza_colocada_id),
  opt_corte_id BIGINT NOT NULL REFERENCES optimizacion_corte(opt_corte_id),
  tipo_evento VARCHAR(100) NOT NULL,
  payload JSONB NOT NULL,
  fecha_evento TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- -------------------------------------------------------------------------
-- 2. FUNCIONES Y PROCEDIMIENTOS ALMACENADOS (SPs)
-- -------------------------------------------------------------------------

-- 2.1. Función Geométrica Simulada (Para CI)
CREATE OR REPLACE FUNCTION fn_calcular_area_geom(p_geometria TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
BEGIN
-- Retorna un área fija simulada (100x100 = 10,000) para la prueba CI.
  RETURN 10000.0;
END;
$$;

-- 2.2. Función para Cálculo de Utilización (fn_calcular_utilizacion)
CREATE OR REPLACE FUNCTION fn_calcular_utilizacion(
  p_opt_corte_id BIGINT
)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
  v_area_total_materia NUMERIC;
  v_area_utilizada NUMERIC := 0;
  v_largo NUMERIC;
  v_ancho NUMERIC;
BEGIN
  SELECT mp.dimension_largo, mp.dimension_ancho
  INTO v_largo, v_ancho
  FROM optimizacion_corte oc
  JOIN materia_prima mp ON oc.materia_prima_id = mp.materia_prima_id
  WHERE oc.opt_corte_id = p_opt_corte_id;

  v_area_total_materia := v_largo * v_ancho;

  IF v_area_total_materia = 0 THEN RETURN 0.0; END IF;

  SELECT COALESCE(SUM(fn_calcular_area_geom(pc.geometria_actual)), 0)
  INTO v_area_utilizada
  FROM piezas_colocadas pc
  WHERE pc.opt_corte_id = p_opt_corte_id;
  
  RETURN (v_area_utilizada / v_area_total_materia) * 100.0;
END;
$$;


-- 2.3. Procedimiento para Rotación y Posicionamiento (sp_rotar_posicionar_figuras)
CREATE OR REPLACE PROCEDURE sp_rotar_posicionar_figuras(
  p_pieza_colocada_id BIGINT,
  p_angulo_rotacion NUMERIC,
  p_posicion_x NUMERIC,
  p_posicion_y NUMERIC,
  p_evento_json JSONB
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_opt_corte_id BIGINT;
  v_geometria_original TEXT;
  v_nueva_geometria TEXT;
BEGIN
  SELECT pc.opt_corte_id, p.geometria_original
  INTO v_opt_corte_id, v_geometria_original
  FROM piezas_colocadas pc
  JOIN piezas p ON pc.pieza_id = p.pieza_id
  WHERE pc.pieza_colocada_id = p_pieza_colocada_id;

  IF v_opt_corte_id IS NULL THEN
    RAISE EXCEPTION 'La pieza colocada con ID % no existe.', p_pieza_colocada_id;
  END IF;

  -- Simulación de Transformación:
  v_nueva_geometria := v_geometria_original ||
                       ' [Rot:' || p_angulo_rotacion || ', Pos: ' || p_posicion_x || ',' || p_posicion_y || ']';


  -- Actualizar la posición y rotación
  UPDATE piezas_colocadas
  SET
    geometria_actual = v_nueva_geometria,
    rotacion_grados = p_angulo_rotacion,
    posicion_x = p_posicion_x,
    posicion_y = p_posicion_y
  WHERE pieza_colocada_id = p_pieza_colocada_id;

  -- Registrar el evento JSON
  INSERT INTO eventos_optimizacion (
    pieza_colocada_id, opt_corte_id, tipo_evento, payload
  )
  VALUES (
    p_pieza_colocada_id, v_opt_corte_id, 'ROTACION_POSICIONAMIENTO', p_evento_json
  );
END;
$$;

-- 2.4 Crear roles CRUD
CREATE OR REPLACE PROCEDURE sp_crear_rol(
  p_nombre VARCHAR,
  p_descripcion TEXT
)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO roles (nombre, descripcion)
  VALUES (p_nombre, p_descripcion)
  ON CONFLICT (nombre) DO NOTHING;
END;
$$;

-- 2.5 actualizar roles CRUD
CREATE OR REPLACE PROCEDURE sp_actualizar_rol(
  p_rol_id INT,
  p_nombre VARCHAR,
  p_descripcion TEXT
)
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE roles
  SET nombre = p_nombre,
    descripcion = p_descripcion
   WHERE rol_id = p_rol_id;
END;
$$;

-- 2.6 eliminar roles CRUD
CREATE OR REPLACE PROCEDURE sp_eliminar_rol(
  p_rol_id INT
)
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM roles WHERE rol_id = p_rol_id;
END;
$$;

-- 2.7 Crear usuarios CRUD (Añadido Hashing y rol_id)
CREATE OR REPLACE PROCEDURE sp_crear_usuario(
  p_username VARCHAR,
  p_contraseña TEXT,
    p_rol_id INT
)
LANGUAGE plpgsql AS $$
BEGIN
  -- Usa pgcrypto para hashear la contraseña de forma segura
  INSERT INTO usuarios (username, password_hash, rol_id, activo)
  VALUES (p_username, crypt(p_contraseña, gen_salt('bf')), p_rol_id, TRUE);
END;
$$;

-- 2.8 actualizar usuarios CRUD (Actualización de contraseña opcional y estado 'activo')
CREATE OR REPLACE PROCEDURE sp_actualizar_usuario(
  p_usuario_id INT,
  p_username VARCHAR,
  p_nueva_contraseña TEXT DEFAULT NULL,
  p_activo BOOLEAN DEFAULT TRUE
)
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE usuarios
  SET username = p_username,
    activo = p_activo,
    password_hash = CASE 
                        WHEN p_nueva_contraseña IS NOT NULL THEN crypt(p_nueva_contraseña, gen_salt('bf'))
                        ELSE password_hash
                    END
  WHERE usuario_id = p_usuario_id;
END;
$$;

-- 2.9 eliminar usuarios CRUD
CREATE OR REPLACE PROCEDURE sp_eliminar_usuario(
  p_usuario_id INT
)
LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM usuarios
  WHERE usuario_id = p_usuario_id;
END;
$$;

-- 2.10 asignar rol (Relación N:1)
CREATE OR REPLACE PROCEDURE sp_asignar_rol_usuario(
  p_usuario_id INT,
  p_rol_id INT
)
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE usuarios
  SET rol_id = p_rol_id
  WHERE usuario_id = p_usuario_id;
END;
$$;

-- 2.11 Función para autenticar usuario (Seguridad)
CREATE OR REPLACE FUNCTION fn_autenticar_usuario(
  p_username VARCHAR,
  p_password TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
  v_hash TEXT;
BEGIN
  SELECT password_hash INTO v_hash
  FROM usuarios
  WHERE username = p_username AND activo = TRUE;

  IF v_hash IS NULL THEN
    RETURN FALSE;
  END IF;

  RETURN v_hash = crypt(p_password, v_hash);
END;
$$;


-- 2.12. Procedimiento para dar de alta de Materia Prima
CREATE OR REPLACE PROCEDURE sp_alta_materia_prima(
  p_numero_parte VARCHAR,
  p_dimension_largo NUMERIC,
  p_dimension_ancho NUMERIC,
  p_distancia_min_piezas NUMERIC,
  p_distancia_min_orilla NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO materia_prima (
    numero_parte,
    dimension_largo,
    dimension_ancho,
    distancia_min_piezas,
    distancia_min_orilla
  )
  VALUES (
    p_numero_parte,
    p_dimension_largo,
    p_dimension_ancho,
    p_distancia_min_piezas,
    p_distancia_min_orilla
  );

  RAISE NOTICE 'Materia prima "%" registrada correctamente.', p_numero_parte;
END;
$$;

-- 2.13. Procedimiento para dar de alta de productos
CREATE OR REPLACE PROCEDURE sp_alta_producto(
  p_numero_parte VARCHAR,
  p_descripcion TEXT,
  p_materia_prima_id INT,
  p_nombre_pieza VARCHAR,
  p_cantidad_elementos INT,
  p_geometria TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_producto_id INT;
BEGIN
  -- Insertar producto
  INSERT INTO productos (
    numero_parte,
    descripcion,
    materia_prima_base_id
  )
  VALUES (
    p_numero_parte,
    p_descripcion,
    p_materia_prima_id
  )
  RETURNING producto_id INTO v_producto_id;

   -- Crear la pieza base asociada al producto
  INSERT INTO piezas (
    producto_id,
    nombre_pieza,
    cantidad_elementos,
    geometria_original
  )
  VALUES (
    v_producto_id,
    p_nombre_pieza,
    p_cantidad_elementos,
    p_geometria
  );

  RAISE NOTICE 'Producto "%" y su pieza asociada registrados correctamente.', p_numero_parte;
END;
$$;


-- -------------------------------------------------------------------------
-- 3. TRIGGERS
-- -------------------------------------------------------------------------

-- 3.1. Trigger Function: Actualizar el porcentaje de utilización
CREATE OR REPLACE FUNCTION trg_actualizar_utilizacion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_opt_corte_id BIGINT;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_opt_corte_id := OLD.opt_corte_id;
  ELSE
    v_opt_corte_id := NEW.opt_corte_id;
  END IF;

  UPDATE optimizacion_corte
  SET utilizacion_porcentaje = fn_calcular_utilizacion(v_opt_corte_id)
  WHERE opt_corte_id = v_opt_corte_id;

  RETURN NULL;
END;
$$;

CREATE TRIGGER tr_actualizar_utilizacion
AFTER INSERT OR UPDATE OR DELETE ON piezas_colocadas
FOR EACH ROW
EXECUTE FUNCTION trg_actualizar_utilizacion();


-- 3.2. Trigger Function: Validación de Colocación (Distancia Mínima a Orilla)
CREATE OR REPLACE FUNCTION trg_validar_colocacion()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
  v_distancia_min_orilla NUMERIC;
  v_largo_materia NUMERIC;
  v_ancho_materia NUMERIC;
  v_ancho_pieza NUMERIC := 100.0; -- Bounding box fijo de la pieza de prueba
  v_largo_pieza NUMERIC := 100.0; -- Bounding box fijo de la pieza de prueba
BEGIN
  SELECT mp.distancia_min_orilla, mp.dimension_largo, mp.dimension_ancho
  INTO v_distancia_min_orilla, v_largo_materia, v_ancho_materia
  FROM optimizacion_corte oc
  JOIN materia_prima mp ON oc.materia_prima_id = mp.materia_prima_id
  WHERE oc.opt_corte_id = NEW.opt_corte_id;

  -- VALIDACIÓN 1: Borde inferior/izquierdo
  IF NEW.posicion_x < v_distancia_min_orilla OR NEW.posicion_y < v_distancia_min_orilla THEN
    RAISE EXCEPTION 'Error de validación: La pieza está demasiado cerca del borde. Mínimo requerido: %', v_distancia_min_orilla;
   END IF;
  
  -- VALIDACIÓN 2: Borde superior/derecho
  IF (NEW.posicion_x + v_largo_pieza) > (v_largo_materia - v_distancia_min_orilla) OR
    (NEW.posicion_y + v_ancho_pieza) > (v_ancho_materia - v_distancia_min_orilla) THEN
    RAISE EXCEPTION 'Error de validación: La pieza excede el límite de la materia prima con el margen de orilla.';
  END IF;

  RETURN NEW;
END;
$$;

CREATE TRIGGER tr_validar_colocacion_before
BEFORE INSERT OR UPDATE ON piezas_colocadas
FOR EACH ROW
EXECUTE FUNCTION trg_validar_colocacion();
