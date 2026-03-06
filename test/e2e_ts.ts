// End-to-end test of Dijkstra + region splitting WITHOUT C extensions
// Creates a manual triangulation and routes nets through it
// TypeScript port of e2e_ruby.rb - outputs identical JSON for comparison

import { Vertex, Region, NetDesc, Cut, SymmetricMap, AVD } from '../src/types';
import { booleanCrossProduct2D } from '../src/geometry';

// Reset counters
Vertex.resetIds();
Region._nextId = 0;
NetDesc.resetIds();

// Create 5 vertices in a diamond pattern
//    v2
//   / | \
//  v0-v4-v1
//   \ | /
//    v3
const coords: [number, number][] = [[0, 5000], [10000, 5000], [5000, 0], [5000, 10000], [5000, 5000]];
const v: Vertex[] = [];
coords.forEach(([x, y], i) => {
  const vt = new Vertex(x, y);
  vt.name = `V${i}`;
  v.push(vt);
});

// Set up triangulation edges manually (diamond graph)
const edges: [number, number][] = [[0,2],[0,3],[0,4],[1,2],[1,3],[1,4],[2,4],[3,4]];
edges.forEach(([a, b]) => {
  if (!v[a].neighbors.includes(v[b])) v[a].neighbors.push(v[b]);
  if (!v[b].neighbors.includes(v[a])) v[b].neighbors.push(v[a]);
});

// Create regions
const regions: Region[] = v.map(vt => new Region(vt));

// Set up region neighbors from edges
edges.forEach(([a, b]) => {
  if (!regions[a].neighbors.includes(regions[b])) regions[a].neighbors.push(regions[b]);
  if (!regions[b].neighbors.includes(regions[a])) regions[b].neighbors.push(regions[a]);
});

// Create cuts
const cuts = new SymmetricMap<Cut>();
v.forEach(vi => {
  vi.neighbors.forEach(vj => {
    if (!cuts.has(vi, vj)) cuts.set(vi, vj, new Cut(vi, vj));
  });
});

// xboolean: uses rx/ry for a,b and vertex.x/y for o
function xboolean(arx: number, ary: number, brx: number, bry: number, ox: number, oy: number): boolean {
  return booleanCrossProduct2D(arx, ary, brx, bry, ox, oy);
}

// full_split_neighbor_list
function full_split(a: Region, b: Region, n: Region): [Region[], Region[]] {
  const l: Region[] = [];
  const r: Region[] = [];
  const nx = n.vertex.x;
  const ny = n.vertex.y;
  const v1x = a.rx - nx;
  const v1y = a.ry - ny;
  const v2x = b.rx - nx;
  const v2y = b.ry - ny;
  const turn = xboolean(a.rx, a.ry, b.rx, b.ry, nx, ny);
  for (const el of n.neighbors) {
    if (el === a || el === b) continue;
    const ex = el.rx - nx;
    const ey = el.ry - ny;
    if (turn ? (v1x * ey > v1y * ex && v2x * ey < v2y * ex) : (v1x * ey > v1y * ex || v2x * ey < v2y * ex)) {
      l.push(el);
    } else {
      r.push(el);
    }
  }
  return [r, l];
}

// Dijkstra key type
type DijkstraKey = [Region, Region | null, boolean];

function keyStr(k: DijkstraKey): string {
  return `${k[0].regionId}_${k[1]?.regionId ?? 'null'}_${k[2]}`;
}

// Simple Dijkstra (minimal, no squeeze/blocked checks for clarity)
function simple_dijkstra(
  start_node: Region,
  end_name: string,
  _regions: Region[],
  _cuts: SymmetricMap<Cut>,
  _net_desc: NetDesc
): { path: string[] | null; log: any[]; path_length?: number } {
  // Use simple priority queue
  const q = new Map<string, number>(); // keyStr => distance
  const qKeys = new Map<string, DijkstraKey>(); // keyStr => key
  const parents = new Map<string, DijkstraKey | null>();
  const distances = new Map<string, number>();
  const outer_lane = new Map<string, boolean>();

  const sx = start_node.vertex.x;
  const sy = start_node.vertex.y;

  const startKeyInner: DijkstraKey = [start_node, null, true];
  const startKeyOuter: DijkstraKey = [start_node, null, false];
  distances.set(keyStr(startKeyInner), 0);
  distances.set(keyStr(startKeyOuter), 0);

  start_node.qbors(null, (w, _ui, _uo) => {
    const dist = Math.hypot(w.vertex.x - sx, w.vertex.y - sy);
    const u: DijkstraKey = [w, start_node, false];
    const vk: DijkstraKey = [w, start_node, true];
    const uStr = keyStr(u);
    const vStr = keyStr(vk);
    q.set(uStr, dist); qKeys.set(uStr, u);
    q.set(vStr, dist); qKeys.set(vStr, vk);
    parents.set(uStr, [start_node, null, false]);
    parents.set(vStr, [start_node, null, false]);
  });

  const log: any[] = [];
  let iteration = 0;

  while (q.size > 0) {
    // Find minimum
    let minKey: string | null = null;
    let minDist = Infinity;
    for (const [k, d] of q) {
      if (d < minDist) { minDist = d; minKey = k; }
    }
    if (minKey === null) break;

    const old_distance = q.get(minKey)!;
    q.delete(minKey);
    const min = qKeys.get(minKey)!;
    qKeys.delete(minKey);

    const [vr, uu, prev_rgt] = min;

    if (!uu) continue; // skip nil predecessor entries

    // Check destination
    if (vr.vertex.name === end_name && vr.incident) {
      log.push({ iter: iteration, event: 'found', vertex: vr.vertex.name, dist: old_distance });
      // Reconstruct path
      const path: Region[] = [];
      let p: DijkstraKey | null = min;
      while (p) {
        const pStr = keyStr(p);
        const n = parents.get(pStr) ?? null;
        if (n) {
          n[0].outer = outer_lane.get(pStr) ?? null;
          n[0].lrTurn = p[2] === (outer_lane.get(pStr) ?? false);
        }
        path.push(p[0]);
        p = parents.get(pStr) ?? null;
      }
      return { path: path.map(r => r.vertex.name), log, path_length: path.length };
    }

    distances.set(minKey, old_distance);
    const x = vr.vertex.x;
    const y = vr.vertex.y;

    // Path set for loop prevention
    const path_set = new Set<Region>();
    let p: DijkstraKey | null = min;
    while (p) {
      path_set.add(p[0]);
      p = parents.get(keyStr(p)) ?? null;
    }

    // Explore neighbors
    vr.qbors(uu, (w, use_inner, use_outer) => {
      if (path_set.has(w)) return;

      const lr_turn = xboolean(uu.rx, uu.ry, w.rx, w.ry, vr.vertex.x, vr.vertex.y);
      const cur_rgt = lr_turn;
      const w_v_rgt: DijkstraKey = [w, vr, cur_rgt];
      const w_v_xrgt: DijkstraKey = [w, vr, !cur_rgt];
      const w_v_rgtStr = keyStr(w_v_rgt);
      const w_v_xrgtStr = keyStr(w_v_xrgt);

      const new_distance = old_distance + Math.hypot(w.vertex.x - x, w.vertex.y - y);

      // Inner path
      if (use_inner && !distances.has(w_v_rgtStr)) {
        if (!q.has(w_v_rgtStr) || q.get(w_v_rgtStr)! > new_distance) {
          let nd = new_distance;
          if (cur_rgt !== prev_rgt) nd += AVD;
          q.set(w_v_rgtStr, nd);
          qKeys.set(w_v_rgtStr, w_v_rgt);
          outer_lane.set(w_v_rgtStr, false);
          parents.set(w_v_rgtStr, min);
          log.push({ iter: iteration, event: 'inner', from: vr.vertex.name, to: w.vertex.name, rgt: cur_rgt, dist: nd });
        }
      }

      // Outer path
      if (use_outer && !distances.has(w_v_xrgtStr)) {
        let nd = new_distance;
        if ((!cur_rgt) !== prev_rgt) nd += AVD;
        if (!q.has(w_v_xrgtStr) || q.get(w_v_xrgtStr)! > nd) {
          q.set(w_v_xrgtStr, nd);
          qKeys.set(w_v_xrgtStr, w_v_xrgt);
          outer_lane.set(w_v_xrgtStr, true);
          parents.set(w_v_xrgtStr, min);
          log.push({ iter: iteration, event: 'outer', from: vr.vertex.name, to: w.vertex.name, rgt: !cur_rgt, dist: nd });
        }
      }
    });
    iteration++;
  }

  return { path: null, log };
}

// Run test: route V0->V1
const nd1 = new NetDesc('V0', 'V1');
const result1 = simple_dijkstra(regions[0], 'V1', regions, cuts, nd1);

// Now do region splitting for the first path (if found)
const split_log: any[] = [];
let result2: { path: string[] | null; log: any[]; path_length?: number } | null = null;

if (result1.path) {
  const path_regions = result1.path.map(name => regions.find(r => r.vertex.name === name)!);

  const first = path_regions[path_regions.length - 1];
  const last = path_regions[0];

  if (path_regions.length > 2) {
    first.idirs.push([
      path_regions[path_regions.length - 2].rx - first.vertex.x,
      path_regions[path_regions.length - 2].ry - first.vertex.y
    ]);
    last.idirs.push([
      path_regions[1].rx - last.vertex.x,
      path_regions[1].ry - last.vertex.y
    ]);
    split_log.push({ first_idirs: first.idirs.length, last_idirs: last.idirs.length });
  }

  // Split intermediate regions
  let r1: Region | null = null;
  let r2: Region | null = null;
  const reversed = [...path_regions].reverse();

  for (let idx = 0; idx < reversed.length - 2; idx++) {
    const prv = reversed[idx];
    const cur = reversed[idx + 1];
    const nxt = reversed[idx + 2];

    const [ne, ne_comp] = full_split(prv, nxt, cur);
    ne.push(nxt);
    ne_comp.push(nxt);
    if (r1) {
      const r2Idx = ne.indexOf(r2!);
      if (r2Idx !== -1) ne.splice(r2Idx, 1);
      const r1Idx = ne_comp.indexOf(r1);
      if (r1Idx !== -1) ne_comp.splice(r1Idx, 1);
    } else {
      ne.push(prv);
      ne_comp.push(prv);
    }

    // Remove cur from regions
    const curIdx = regions.indexOf(cur);
    if (curIdx !== -1) regions.splice(curIdx, 1);

    r1 = new Region(cur.vertex);
    r2 = new Region(cur.vertex);
    r1.idirs = [...cur.idirs.map(d => [...d] as [number, number])];
    r2.idirs = [...cur.idirs.map(d => [...d] as [number, number])];
    r1.odirs = [...cur.odirs.map(d => [...d] as [number, number])];
    r2.odirs = [...cur.odirs.map(d => [...d] as [number, number])];
    r1.incident = cur.incident;
    r2.incident = cur.incident;

    // Offset computation for first/last split
    let dx1 = 0, dy1 = 0, dx2 = 0, dy2 = 0;
    if (prv === reversed[0]) { // first in reversed = first of original
      dx2 = cur.rx - prv.rx;
      dy2 = cur.ry - prv.ry;
      const h = Math.hypot(dx2, dy2);
      dx2 /= h;
      dy2 /= h;
    }
    if (nxt === reversed[reversed.length - 1]) { // last in reversed
      dx1 = nxt.rx - cur.rx;
      dy1 = nxt.ry - cur.ry;
      const h = Math.hypot(dx1, dy1);
      dx1 /= h;
      dy1 /= h;
    }
    if (prv === reversed[0] || nxt === reversed[reversed.length - 1]) {
      r1.g = r2.g = cur.g * 0.5;
      const dy = dx1 + dx2;
      const dx = -(dy1 + dy2);
      const h = Math.hypot(dx, dy) / cur.g;
      if (h > 0) {
        const dxn = dx / h;
        const dyn = dy / h;
        r1.ox = cur.ox + dxn;
        r1.oy = cur.oy + dyn;
        r2.ox = cur.ox - dxn;
        r2.oy = cur.oy - dyn;
      } else {
        r1.ox = cur.ox; r1.oy = cur.oy;
        r2.ox = cur.ox; r2.oy = cur.oy;
      }
      r1.rx = r1.vertex.x + r1.ox;
      r1.ry = r1.vertex.y + r1.oy;
      r2.rx = r2.vertex.x + r2.ox;
      r2.ry = r2.vertex.y + r2.oy;
    } else {
      r1.ox = cur.ox; r1.oy = cur.oy;
      r2.ox = cur.ox; r2.oy = cur.oy;
      r1.rx = cur.rx; r1.ry = cur.ry;
      r2.rx = cur.rx; r2.ry = cur.ry;
    }

    regions.push(r1, r2);
    for (const el of cur.neighbors) {
      const idx2 = el.neighbors.indexOf(cur);
      if (idx2 !== -1) el.neighbors.splice(idx2, 1);
    }
    for (const el of ne) {
      el.neighbors.push(r1);
      r1.neighbors.push(el);
    }
    for (const el of ne_comp) {
      el.neighbors.push(r2);
      r2.neighbors.push(el);
    }

    if (cur.lrTurn !== cur.outer) {
      r1.incident = false;
    } else {
      r2.incident = false;
    }

    split_log.push({
      split_vertex: cur.vertex.name,
      r1_id: r1.regionId,
      r1_neighbors: r1.neighbors.map(r => `${r.vertex.name}(${r.regionId})`),
      r2_id: r2.regionId,
      r2_neighbors: r2.neighbors.map(r => `${r.vertex.name}(${r.regionId})`),
      r1_incident: r1.incident,
      r2_incident: r2.incident,
      r1_rx: Math.round(r1.rx * 100) / 100,
      r1_ry: Math.round(r1.ry * 100) / 100,
      r2_rx: Math.round(r2.rx * 100) / 100,
      r2_ry: Math.round(r2.ry * 100) / 100,
    });
  }

  // Now route V2->V3 (should go around the first trace)
  const startRegion = regions.find(r => r.incident && r.vertex.name === 'V2');
  if (startRegion) {
    const nd2 = new NetDesc('V2', 'V3');
    result2 = simple_dijkstra(startRegion, 'V3', regions, cuts, nd2);
    split_log.push({ second_route_path: result2.path, second_route_length: result2.path_length });
  }
}

const output = {
  vertices: v.map(vt => ({ id: vt.id, name: vt.name, x: vt.x, y: vt.y })),
  first_route: result1,
  split_log,
  total_regions: regions.length,
  region_details: regions.map(r => ({
    rid: r.regionId,
    vertex: r.vertex.name,
    incident: r.incident,
    neighbors: r.neighbors.map(n => `${n.vertex.name}(${n.regionId})`),
    idirs: r.idirs.length,
    rx: Math.round(r.rx * 100) / 100,
    ry: Math.round(r.ry * 100) / 100,
  })),
};

console.log(JSON.stringify(output, null, 2));
