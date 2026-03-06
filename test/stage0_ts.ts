import { Router } from '../src/router';
import { Vertex, NetDesc, SymmetricMap, Cut } from '../src/types';
import { segmentIntersects } from '../src/geometry';
import { readFileSync } from 'fs';

async function main() {
  const graph = JSON.parse(readFileSync('test/shared_graph.json', 'utf8'));
  Vertex.resetIds(); NetDesc.resetIds();

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
  router.newcuts = new SymmetricMap();
  for (const v of verts) {
    for (const n of v.neighbors) {
      if (!router.newcuts.has(v, n)) router.newcuts.set(v, n, new Cut(v, n));
    }
  }

  // Same net order as Ruby
  r.generateNetlist(graph.nets.map((n: any) => ({
    from: n.from, to: n.to, traceWidth: 1200, traceClearance: 800
  })));

  // Route all nets
  for (let i = 0; i < r.netlist.length; i++) r.route(i);
  r.prepareSteps();

  // Extract segments (stage 0)
  const segs = r.generateDrawnSegments();
  const lines = segs.filter(s => s.type === 'line');

  let crossings = 0;
  for (let i = 0; i < lines.length; i++) {
    for (let j = i + 1; j < lines.length; j++) {
      const a = lines[i], b = lines[j];
      if (a.netId !== b.netId && segmentIntersects(a.x1,a.y1,a.x2,a.y2, b.x1,b.y1,b.x2,b.y2)) {
        crossings++;
      }
    }
  }

  console.log(`Stage 0 (after routing): ${segs.length} segments, ${crossings} crossings`);

  // Now do rubberband
  r.sortAttachedNets(); r.prepareSteps(); r.nubly(); r.prepareSteps();
  r.sortAttachedNets(); r.prepareSteps(); r.nubly(); r.prepareSteps();
  r.sortAttachedNets(); r.prepareSteps(); r.nubly(true); r.sortAttachedNets(); r.prepareSteps();

  const segsRb = r.generateDrawnSegments();
  const linesRb = segsRb.filter(s => s.type === 'line');
  let crossingsRb = 0;
  for (let i = 0; i < linesRb.length; i++) {
    for (let j = i + 1; j < linesRb.length; j++) {
      const a = linesRb[i], b = linesRb[j];
      if (a.netId !== b.netId && segmentIntersects(a.x1,a.y1,a.x2,a.y2, b.x1,b.y1,b.x2,b.y2)) {
        crossingsRb++;
      }
    }
  }
  console.log(`Stage 4 (after rubberband): ${segsRb.length} segments, ${crossingsRb} crossings`);
}

main().catch(console.error);
