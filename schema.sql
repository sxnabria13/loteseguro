-- =====================================================================
-- LoteSeguro · Botica Santa Rosa
-- Script que crea la base de datos en Supabase (SQL Editor > New query > Run)
-- Después ejecutar seed.sql para cargar los inventarios de mayo a septiembre 2026.
-- =====================================================================

drop function if exists registrar_lote;
drop view if exists v_productos;
drop view if exists v_inventario cascade;
drop table if exists inventario cascade;
drop table if exists lotes;
drop table if exists productos;
drop table if exists laboratorios;

-- Parámetro de negocio: cada laboratorio tiene su propio plazo de canje
-- (cuántos días antes del vencimiento hay que devolver el lote). Sale de Plazos_canje_laboratorio.xlsx
create table laboratorios (
  nombre             text primary key,
  plazo_canje_dias   integer not null check (plazo_canje_dias between 0 and 365)
);

-- Catálogo: sale de las columnas Codigo, Producto, Registro_sanitario, Categoria, Laboratorio y Costo_unit
create table productos (
  codigo              text primary key,
  nombre              text not null,
  registro_sanitario  text,
  categoria           text not null,
  laboratorio         text not null references laboratorios(nombre),
  costo_unit          numeric(10,2) not null check (costo_unit >= 0)
);

-- Cada lote físico que entra a la botica: sale de Lote + Fecha_vencimiento
create table lotes (
  id                 bigint generated always as identity primary key,
  codigo_producto    text not null references productos(codigo),
  lote               text not null,
  fecha_vencimiento  date not null,
  unique (codigo_producto, lote)
);

-- La foto del inventario en cada fecha de corte: sale de Fecha_corte, Stock_und y Canje_solicitado
create table inventario (
  id                bigint generated always as identity primary key,
  lote_id           bigint not null references lotes(id),
  fecha_corte       date not null,
  stock_und         integer not null check (stock_und >= 0),
  canje_solicitado  boolean not null default false,
  registrado_por    text,
  creado_en         timestamptz not null default now(),
  unique (lote_id, fecha_corte)
);

-- REGLA DE NEGOCIO (la que hoy el técnico tiene que recordar de memoria, laboratorio por laboratorio):
--   días para vencer   = fecha de vencimiento - fecha de corte
--   fecha límite canje = fecha de vencimiento - plazo de canje del laboratorio
--   <= 0                       -> Vencido     (retirar a cuarentena, no dispensar)
--   1 .. plazo del laboratorio -> Por vencer  (reportar y devolver por canje)
--   más que el plazo           -> Vigente
create view v_inventario with (security_invoker = true) as
select
  i.id,
  i.fecha_corte,
  to_char(i.fecha_corte, 'YYYY-MM')                    as mes,
  p.codigo,
  p.nombre                                             as producto,
  p.registro_sanitario,
  p.categoria,
  p.laboratorio,
  lab.plazo_canje_dias,
  l.lote,
  l.fecha_vencimiento,
  l.fecha_vencimiento - lab.plazo_canje_dias           as fecha_limite_canje,
  i.stock_und,
  p.costo_unit,
  round(i.stock_und * p.costo_unit, 2)                 as valor_stock,
  case when i.canje_solicitado then 'Sí' else 'No' end as canje_solicitado,
  (l.fecha_vencimiento - i.fecha_corte)                as dias_para_vencer,
  case
    when l.fecha_vencimiento - i.fecha_corte <= 0                    then 'Vencido'
    when l.fecha_vencimiento - i.fecha_corte <= lab.plazo_canje_dias then 'Por vencer'
    else 'Vigente'
  end                                                  as estado,
  i.creado_en,
  i.registrado_por
from inventario i
join lotes l          on l.id = i.lote_id
join productos p      on p.codigo = l.codigo_producto
join laboratorios lab on lab.nombre = p.laboratorio;

-- Lista de productos para el formulario (con el plazo de su laboratorio)
create view v_productos with (security_invoker = true) as
select p.codigo, p.nombre, p.costo_unit, p.laboratorio, lab.plazo_canje_dias
from productos p join laboratorios lab on lab.nombre = p.laboratorio;

-- Lo que llama el formulario web: crea el lote si no existe, registra el inventario
-- y devuelve la fila con la regla ya aplicada.
create or replace function registrar_lote(
  p_codigo text, p_lote text, p_fecha_vencimiento date,
  p_fecha_corte date, p_stock integer, p_canje boolean, p_registrado_por text default null)
returns setof v_inventario
language plpgsql security definer set search_path = public as $$
declare v_lote_id bigint; v_inv_id bigint;
begin
  insert into lotes (codigo_producto, lote, fecha_vencimiento)
  values (p_codigo, upper(trim(p_lote)), p_fecha_vencimiento)
  on conflict (codigo_producto, lote) do update set fecha_vencimiento = excluded.fecha_vencimiento
  returning id into v_lote_id;

  insert into inventario (lote_id, fecha_corte, stock_und, canje_solicitado, registrado_por)
  values (v_lote_id, p_fecha_corte, p_stock, p_canje, p_registrado_por)
  on conflict (lote_id, fecha_corte) do update
     set stock_und = excluded.stock_und, canje_solicitado = excluded.canje_solicitado,
         registrado_por = excluded.registrado_por, creado_en = now()
  returning id into v_inv_id;

  return query select * from v_inventario where id = v_inv_id;
end $$;

-- Seguridad (nivel prototipo): la página usa la clave pública "anon".
-- Puede LEER las tablas y REGISTRAR solo a través de la función.
alter table laboratorios enable row level security;
alter table productos  enable row level security;
alter table lotes      enable row level security;
alter table inventario enable row level security;
create policy "lectura publica laboratorios" on laboratorios for select to anon, authenticated using (true);
create policy "lectura publica productos"  on productos  for select to anon, authenticated using (true);
create policy "lectura publica lotes"      on lotes      for select to anon, authenticated using (true);
create policy "lectura publica inventario" on inventario for select to anon, authenticated using (true);
grant select on v_inventario, v_productos to anon, authenticated;
grant execute on function registrar_lote to anon, authenticated;
