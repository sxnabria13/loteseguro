/**
 * LoteSeguro · Tablero de indicadores — versión Google Apps Script
 * 1. script.google.com > Nuevo proyecto > pega este archivo como Code.gs
 * 2. Archivo > Nuevo > HTML, nómbralo "Tablero" y pega Tablero.html
 * 3. Configuración del proyecto > Propiedades de la secuencia de comandos:
 *      SUPABASE_URL      = https://xxxx.supabase.co
 *      SUPABASE_ANON_KEY = (la clave anon public)
 * 4. Implementar > Nueva implementación > Aplicación web
 *      Ejecutar como: Yo · Quién tiene acceso: Cualquier usuario
 * 5. Copia la URL /exec y ponla en el informe (9.2) y en la página web (iframe opcional).
 */

const UMBRALES = { I1: 0.10, I2: 0.02, I3: 0.20, I4: 0.70 };

function doGet() {
  return HtmlService.createHtmlOutputFromFile('Tablero')
    .setTitle('LoteSeguro · Tablero')
    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL); // permite incrustarlo en la página web
}

/** Lee la vista v_inventario desde la API REST de Supabase. */
function leerInventario_() {
  const p = PropertiesService.getScriptProperties();
  const url = p.getProperty('SUPABASE_URL') + '/rest/v1/v_inventario?select=fecha_corte,estado,valor_stock,canje_solicitado&order=fecha_corte';
  const key = p.getProperty('SUPABASE_ANON_KEY');
  const res = UrlFetchApp.fetch(url, {
    headers: { apikey: key, Authorization: 'Bearer ' + key, Range: '0-9999' },
    muteHttpExceptions: true
  });
  if (res.getResponseCode() >= 300) throw new Error('Supabase respondió ' + res.getResponseCode() + ': ' + res.getContentText());
  return JSON.parse(res.getContentText());
}

/** Calcula los 4 indicadores por fecha de corte (misma lógica que Excel y DAX). */
function getIndicadores() {
  const filas = leerInventario_();
  const porCorte = {};
  filas.forEach(f => (porCorte[f.fecha_corte] = porCorte[f.fecha_corte] || []).push(f));
  const salida = Object.keys(porCorte).sort().map(corte => {
    const r = porCorte[corte];
    const pv = r.filter(x => x.estado === 'Por vencer');
    const ve = r.filter(x => x.estado === 'Vencido');
    const valor = r.reduce((s, x) => s + Number(x.valor_stock), 0);
    const riesgo = r.filter(x => x.estado !== 'Vigente').reduce((s, x) => s + Number(x.valor_stock), 0);
    const canje = pv.filter(x => x.canje_solicitado === 'Sí').length;
    return {
      corte: corte,
      registros: r.length,
      I1: { n: pv.length, d: r.length, v: r.length ? pv.length / r.length : null },
      I2: { n: ve.length, d: r.length, v: r.length ? ve.length / r.length : null },
      I3: { n: round2_(riesgo), d: round2_(valor), v: valor ? riesgo / valor : null },
      I4: { n: canje, d: pv.length, v: pv.length ? canje / pv.length : null }
    };
  });
  return { meses: salida, umbrales: UMBRALES, total: filas.length, leidoEn: new Date().toISOString() };
}

function round2_(x) { return Math.round(x * 100) / 100; }
