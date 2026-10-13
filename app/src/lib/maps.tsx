// أدوات وحدة الخرائط: مكوّن خريطة واحد (نقاط مجمّعة، مضلعات، تحرير حدود)، وألوان المندوبين، واختيار متعدد للموظفين.
// المزود المعتمد Google Maps (MAP-013)؛ إلى أن يُضبط مفتاحه تعمل الخريطة على OpenStreetMap عبر Leaflet،
// والعرض الأساسي Roadmap. لا نقطة تخمينية لموقع مفقود (B070).
import { ReactNode, useEffect, useRef, useState } from 'react';
import L from 'leaflet';
import 'leaflet.markercluster';
import 'leaflet/dist/leaflet.css';
import 'leaflet.markercluster/dist/MarkerCluster.css';
import 'leaflet.markercluster/dist/MarkerCluster.Default.css';
import { Emp } from './goals';

export type LatLng = [number, number];
export type Geom = LatLng[][];

export interface MapPoint { id: string | number; lat: number; lng: number; color: string; popup?: () => HTMLElement | string; title?: string; ring?: boolean }
export interface MapPolygon { id: string | number; geom: Geom; color: string; name: string; dashed?: boolean }

// مركز افتراضي: عمّان
const CENTER: LatLng = [31.95, 35.91];

export const PALETTE = ['#1f5fa8', '#2e7d32', '#b3261e', '#6d4c2f', '#7b1fa2', '#00838f', '#ef6c00', '#455a64', '#c2185b', '#827717'];
export const colorOf = (i: number) => PALETTE[((i % PALETTE.length) + PALETTE.length) % PALETTE.length];

export function MapView({ points = [], polygons = [], cluster = true, selected, onSelect, editGeom, onEditGeom, height = 520, fitKey, children }: {
  points?: MapPoint[]; polygons?: MapPolygon[]; cluster?: boolean; selected?: string | number | null; onSelect?: (id: string | number) => void;
  editGeom?: Geom | null; onEditGeom?: (g: Geom) => void; height?: number | string; fitKey?: string; children?: ReactNode;
}) {
  const el = useRef<HTMLDivElement>(null);
  const map = useRef<L.Map | null>(null);
  const layers = useRef<{ pts?: L.LayerGroup; polys?: L.LayerGroup; edit?: L.LayerGroup; markers: Map<string, L.CircleMarker> }>({ markers: new Map() });
  const editRef = useRef<{ geom: Geom | null | undefined; on?: (g: Geom) => void }>({ geom: editGeom, on: onEditGeom });
  editRef.current = { geom: editGeom, on: onEditGeom };
  const [ready, setReady] = useState(false);

  useEffect(() => {
    if (!el.current || map.current) return;
    const m = L.map(el.current, { center: CENTER, zoom: 9, preferCanvas: true });
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19, attribution: '© OpenStreetMap' }).addTo(m);
    m.on('click', (e: L.LeafletMouseEvent) => {
      const { geom, on } = editRef.current;
      if (!on || !geom) return;
      const g = geom.length ? geom.map((r) => [...r]) : [[]];
      g[g.length - 1].push([round6(e.latlng.lat), round6(e.latlng.lng)]);
      on(g);
    });
    map.current = m;
    // الحاوية قد تتغير أبعادها بعد الإنشاء (شبكة، نافذة، طي الفلاتر)
    const ro = new ResizeObserver(() => m.invalidateSize({ animate: false }));
    ro.observe(el.current);
    setReady(true);
    return () => { ro.disconnect(); m.off(); m.stop(); m.remove(); map.current = null; };
  }, []);

  // النقاط
  useEffect(() => {
    const m = map.current;
    if (!m) return;
    layers.current.pts?.remove();
    layers.current.markers.clear();
    const group: L.LayerGroup = cluster ? L.markerClusterGroup({ showCoverageOnHover: false, maxClusterRadius: 40 }) : L.layerGroup();
    for (const p of points) {
      const mk = L.circleMarker([p.lat, p.lng], { radius: 7, color: '#ffffff', weight: 1.5, fillColor: p.color, fillOpacity: 0.9 });
      if (p.title) mk.bindTooltip(p.title);
      if (p.popup) mk.bindPopup(() => p.popup!());
      mk.on('click', () => onSelect?.(p.id));
      group.addLayer(mk);
      layers.current.markers.set(String(p.id), mk);
    }
    group.addTo(m);
    layers.current.pts = group;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ready, points, cluster]);

  // المضلعات
  useEffect(() => {
    const m = map.current;
    if (!m) return;
    layers.current.polys?.remove();
    const g = L.layerGroup();
    for (const p of polygons) {
      L.polygon(p.geom, { color: p.color, weight: 2, fillOpacity: 0.12, dashArray: p.dashed ? '6 4' : undefined }).bindTooltip(p.name).addTo(g);
    }
    g.addTo(m);
    layers.current.polys = g;
  }, [ready, polygons]);

  // ملاءمة العرض مرة لكل مفتاح، عند وصول بيانات المفتاح الجديد (لا عند كل تحديث لنفس البيانات)
  const fitted = useRef<string | null>(null);
  useEffect(() => {
    const m = map.current;
    if (!m) return;
    const key = fitKey ?? '';
    if (fitted.current === key) return;
    const ll: L.LatLngExpression[] = [...points.map((p) => [p.lat, p.lng] as LatLng), ...polygons.flatMap((p) => p.geom.flat())];
    if (!ll.length) return;
    fitted.current = key;
    m.fitBounds(L.latLngBounds(ll), { padding: [24, 24], maxZoom: 15, animate: false });
  }, [ready, fitKey, points, polygons]);

  // إبراز المختار
  useEffect(() => {
    const m = map.current;
    if (!m || selected === null || selected === undefined) return;
    const mk = layers.current.markers.get(String(selected));
    if (!mk) return;
    const grp = layers.current.pts as L.MarkerClusterGroup | undefined;
    const open = () => { m.setView(mk.getLatLng(), Math.max(m.getZoom(), 14)); mk.openPopup?.(); mk.setStyle({ radius: 11, weight: 3, color: '#000' }); };
    if (grp && 'zoomToShowLayer' in grp) grp.zoomToShowLayer(mk as unknown as L.Marker, open); else open();
    return () => { mk.setStyle({ radius: 7, weight: 1.5, color: '#ffffff' }); };
  }, [selected]);

  // تحرير الحدود: نقاط قابلة للسحب، والنقر المزدوج على نقطة يحذفها
  useEffect(() => {
    const m = map.current;
    if (!m) return;
    layers.current.edit?.remove();
    if (!editGeom) { m.getContainer().style.cursor = ''; return; }
    m.getContainer().style.cursor = 'crosshair';
    const g = L.layerGroup();
    editGeom.forEach((ring, ri) => {
      if (ring.length >= 2) L.polygon(ring, { color: '#ef6c00', weight: 2, fillOpacity: 0.15 }).addTo(g);
      ring.forEach((pt, pi) => {
        const mk = L.marker(pt, { draggable: true, icon: L.divIcon({ className: 'vertex', iconSize: [12, 12] }) }).addTo(g);
        mk.on('dragend', () => {
          const ll = mk.getLatLng();
          const n = editGeom.map((r) => [...r]);
          n[ri][pi] = [round6(ll.lat), round6(ll.lng)];
          editRef.current.on?.(n);
        });
        mk.on('dblclick', (e) => {
          L.DomEvent.stop(e);
          const n = editGeom.map((r, i) => (i === ri ? r.filter((_, j) => j !== pi) : [...r]));
          editRef.current.on?.(n);
        });
      });
    });
    g.addTo(m);
    layers.current.edit = g;
  }, [ready, editGeom]);

  return (
    <div className="map-wrap" style={{ height }} data-points={points.length} data-polygons={polygons.length}>
      <div ref={el} className="map" role="region" aria-label="الخريطة" />
      {children}
    </div>
  );
}

const round6 = (v: number) => Math.round(v * 1e6) / 1e6;

/** محتوى نافذة نقطة: صفوف «تسمية: قيمة» وروابط */
export function popupEl(title: string, rows: [string, string | null | undefined][], links: { text: string; href?: string; onClick?: () => void }[] = []): HTMLElement {
  const d = document.createElement('div');
  d.className = 'map-pop';
  d.dir = 'rtl';
  const h = document.createElement('b');
  h.textContent = title;
  d.appendChild(h);
  for (const [k, v] of rows) {
    if (v === null || v === undefined || v === '') continue;
    const r = document.createElement('div');
    const s = document.createElement('span');
    s.className = 'muted';
    s.textContent = k + ': ';
    r.appendChild(s);
    r.appendChild(document.createTextNode(v));
    d.appendChild(r);
  }
  if (links.length) {
    const r = document.createElement('div');
    r.className = 'map-pop-links';
    for (const l of links) {
      const a = document.createElement('a');
      a.textContent = l.text;
      if (l.href) a.href = l.href;
      else { a.href = '#'; a.onclick = (e) => { e.preventDefault(); l.onClick?.(); }; }
      r.appendChild(a);
    }
    d.appendChild(r);
  }
  return d;
}

/** قراءة حدود من GeoJSON أو KML إلى مضلعات [lat, lng] */
export function parseBoundary(text: string, fileName: string): Geom {
  const out: Geom = [];
  if (/\.kml$/i.test(fileName) || /^\s*</.test(text)) {
    const doc = new DOMParser().parseFromString(text, 'application/xml');
    doc.querySelectorAll('Polygon outerBoundaryIs coordinates, Polygon > outerBoundaryIs > LinearRing > coordinates').forEach((c) => {
      const ring = (c.textContent ?? '').trim().split(/\s+/).map((t) => t.split(',').map(Number)).filter((x) => x.length >= 2 && x.every(Number.isFinite))
        .map(([lng, lat]) => [lat, lng] as LatLng);
      if (ring.length >= 3) out.push(dropClosing(ring));
    });
  } else {
    const j = JSON.parse(text);
    const geoms: { type: string; coordinates: unknown }[] = [];
    const walk = (o: Record<string, unknown>) => {
      if (!o) return;
      if (o.type === 'FeatureCollection') (o.features as Record<string, unknown>[]).forEach(walk);
      else if (o.type === 'Feature') walk(o.geometry as Record<string, unknown>);
      else if (o.type === 'GeometryCollection') (o.geometries as Record<string, unknown>[]).forEach(walk);
      else geoms.push(o as { type: string; coordinates: unknown });
    };
    walk(j);
    for (const g of geoms) {
      const polys = g.type === 'Polygon' ? [g.coordinates as number[][][]] : g.type === 'MultiPolygon' ? (g.coordinates as number[][][][]) : [];
      for (const p of polys) if (p[0]?.length >= 3) out.push(dropClosing(p[0].map(([lng, lat]) => [lat, lng] as LatLng)));
    }
  }
  if (!out.length) throw new Error('لم يُعثر على مضلع في الملف');
  return out;
}
const dropClosing = (r: LatLng[]) => (r.length > 3 && r[0][0] === r[r.length - 1][0] && r[0][1] === r[r.length - 1][1] ? r.slice(0, -1) : r);

/** اختيار عدة موظفين ضمن المسموح، مع «الكل» و«مسح» (MAP-010) */
export function EmpMulti({ emps, value, onChange, label = 'المندوبون' }: { emps: Emp[]; value: number[]; onChange: (v: number[]) => void; label?: string }) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState('');
  const shown = emps.filter((e) => !q || e.name.includes(q) || e.emp_number === q.trim());
  return (
    <div className="multi">
      <button type="button" className="input multi-btn" aria-expanded={open} aria-label={label} onClick={() => setOpen(!open)}>
        {value.length === 0 ? `${label}: كل المسموح` : `${label}: ${value.length}`}
      </button>
      {open && (
        <div className="pop multi-pop">
          <input className="input" placeholder="بحث" value={q} onChange={(e) => setQ(e.target.value)} aria-label={'بحث ' + label} />
          <div className="actions"><button type="button" className="btn link" onClick={() => onChange(emps.map((e) => Number(e.id)))}>اختيار الكل</button>
            <button type="button" className="btn link" onClick={() => onChange([])}>مسح</button></div>
          <div className="multi-list">{shown.map((e) => (
            <label key={e.id} className="check"><input type="checkbox" checked={value.includes(Number(e.id))}
              onChange={(ev) => onChange(ev.target.checked ? [...value, Number(e.id)] : value.filter((x) => x !== Number(e.id)))} /> {e.emp_number} — {e.name}</label>
          ))}</div>
        </div>
      )}
    </div>
  );
}

export interface Region { id: number; name: string; color: string }
export const LOC_LABEL: Record<string, string> = { ok: 'صالح', missing: 'مفقود', invalid: 'غير صالح' };
export const REGION_STATE_LABEL: Record<string, string> = { in: 'داخل منطقة', assigned: 'مسند صراحة', none: 'بلا منطقة', no_location: 'بلا موقع', conflict: 'يحتاج تحديد منطقة' };

/** فترة: أسبوع السبت–الجمعة (B070) والشهر */
export function weekOf(iso: string): [string, string] {
  const d = new Date(iso + 'T00:00:00Z');
  const back = (d.getUTCDay() + 1) % 7;      // السبت = 6
  const s = new Date(d.getTime() - back * 86400000);
  const e = new Date(s.getTime() + 6 * 86400000);
  return [s.toISOString().slice(0, 10), e.toISOString().slice(0, 10)];
}
export function monthRange(iso: string): [string, string] {
  const [y, m] = iso.split('-').map(Number);
  const e = new Date(Date.UTC(y, m, 0));
  return [`${y}-${String(m).padStart(2, '0')}-01`, e.toISOString().slice(0, 10)];
}
export function shiftDays(iso: string, n: number): string {
  return new Date(new Date(iso + 'T00:00:00Z').getTime() + n * 86400000).toISOString().slice(0, 10);
}
