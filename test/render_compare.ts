// Compare rendering output: skip rubberband first, then with rubberband
import { Router } from '../src/router';
import { Vertex, NetDesc } from '../src/types';
import { readFileSync } from 'fs';
import { segmentIntersects } from '../src/geometry';

async function main() {
  const graph = JSON.parse(readFileSync('test/shared_graph.json', 'utf8'));

  Vertex.resetIds();
  NetDesc.resetIds();
  const r = new Router(0, 0, graph.board.x2, graph.board.y2);
  for (const vd of graph.vertices) r.insertVertex(vd.name, vd.x, vd.y, vd.core, vd.separation);
  await r.finishInit();

  // Inject exact shared graph edges
  const verts = r.getVertices();
  const vertById = new Map<number, typeof verts[0]>();
  for (const v of verts) vertById.set(v.id, v);
  for (const v of verts) v.neighbors = [];
  for (const vd of graph.vertices) {
    const v = vertById.get(vd.id);
    if (!v) continue;
    for (const nid of vd.neighbors) {
      const n = vertById.get(nid);
      if (n && !v.neighbors.includes(n)) v.neighbors.push(n);
    }
  }
  const regions = r.getRegions();
  for (const reg of regions) reg.neighbors = [];
  const regByVid = new Map<number, typeof regions[0]>();
  for (const reg of regions) regByVid.set(reg.vertex.id, reg);
  for (const v of verts) {
    const reg = regByVid.get(v.id);
    if (!reg) continue;
    for (const n of v.neighbors) {
      const nreg = regByVid.get(n.id);
      if (nreg && !reg.neighbors.includes(nreg)) reg.neighbors.push(nreg);
    }
  }
  const router = r as any;
  const { SymmetricMap, Cut } = await import('../src/types');
  router.newcuts = new SymmetricMap();
  for (const v of verts) {
    for (const n of v.neighbors) {
      if (!router.newcuts.has(v, n)) router.newcuts.set(v, n, new Cut(v, n));
    }
  }

  // Generate netlist (same order as Ruby)
  r.generateNetlist(graph.nets.map((n: any) => ({
    from: n.from, to: n.to, traceWidth: 1200, traceClearance: 800
  })));

  // Route all nets
  let routed = 0;
  for (let i = 0; i < r.netlist.length; i++) {
    if (r.route(i)) routed++;
  }

  // Generate segments WITHOUT rubberband
  r.prepareSteps();
  const segsNoRb = r.generateDrawnSegments();
  const linesNoRb = segsNoRb.filter(s => s.type === 'line');
  let crossNoRb = 0;
  for (let i = 0; i < linesNoRb.length; i++) {
    for (let j = i + 1; j < linesNoRb.length; j++) {
      const a = linesNoRb[i], b = linesNoRb[j];
      if (a.netId !== b.netId && segmentIntersects(a.x1,a.y1,a.x2,a.y2, b.x1,b.y1,b.x2,b.y2)) {
        crossNoRb++;
      }
    }
  }

  // Now do rubberband
  r.sortAttachedNets();
  r.prepareSteps();
  r.nubly();
  r.prepareSteps();
  r.sortAttachedNets();
  r.prepareSteps();
  r.nubly();
  r.prepareSteps();
  r.sortAttachedNets();
  r.prepareSteps();
  r.nubly(true);
  r.sortAttachedNets();
  r.prepareSteps();

  const segsRb = r.generateDrawnSegments();
  const linesRb = segsRb.filter(s => s.type === 'line');
  let crossRb = 0;
  for (let i = 0; i < linesRb.length; i++) {
    for (let j = i + 1; j < linesRb.length; j++) {
      const a = linesRb[i], b = linesRb[j];
      if (a.netId !== b.netId && segmentIntersects(a.x1,a.y1,a.x2,a.y2, b.x1,b.y1,b.x2,b.y2)) {
        crossRb++;
      }
    }
  }

  console.log(JSON.stringify({
    routed: routed,
    total: r.netlist.length,
    segments_no_rb: segsNoRb.length,
    crossings_no_rb: crossNoRb,
    segments_rb: segsRb.length,
    crossings_rb: crossRb,
  }, null, 2));
}

main().catch(console.error);
