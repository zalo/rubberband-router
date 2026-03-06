import { Router } from '../src/router';
import { Vertex, NetDesc, SymmetricMap, Cut } from '../src/types';
import { readFileSync } from 'fs';

async function main() {
  const graph = JSON.parse(readFileSync('test/crossing_graph.json', 'utf8'));
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

  // Same nets with pri
  r.generateNetlist(graph.nets.map((n: any) => ({
    from: n.from, to: n.to, traceWidth: 1200, traceClearance: 800
  })));
  r.sortNetlist();

  console.log('Sorted nets:');
  for (let i = 0; i < r.netlist.length; i++) {
    console.log(`  ${i}: ${r.netlist[i].t1Name}->${r.netlist[i].t2Name} pri=${r.netlist[i].pri}`);
  }

  for (let i = 0; i < r.netlist.length; i++) {
    const ok = r.route(i);
    // Extract path
    const nd = r.netlist[i];
    let pathStr = '';
    for (const vert of verts) {
      for (const inet of vert.incidentNets) {
        if (inet.id !== i || !inet.next) continue;
        const parts = [vert.name];
        let step = inet.nstep;
        while (step) {
          parts.push(`${step.vertex.name}(r=${Math.round(step.radius)},rgt=${step.rgt})`);
          step = step.nstep;
        }
        pathStr = parts.join(' -> ');
      }
    }
    console.log(`Net ${i}: ${nd.t1Name}->${nd.t2Name} = ${ok} path=${pathStr}`);
  }
}

main().catch(console.error);
