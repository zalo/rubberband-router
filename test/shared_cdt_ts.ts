// Route on the exact same CDT graph, using our full Router
import { Router } from '../src/router';
import { Vertex, NetDesc } from '../src/types';
import { readFileSync } from 'fs';

async function main() {
  const graph = JSON.parse(readFileSync('test/shared_graph.json', 'utf8'));

  Vertex.resetIds();
  NetDesc.resetIds();

  const r = new Router(0, 0, graph.board.x2, graph.board.y2);

  // Insert vertices with exact same coordinates
  for (const vd of graph.vertices) {
    r.insertVertex(vd.name, vd.x, vd.y, vd.core, vd.separation);
  }

  await r.finishInit();

  // OVERRIDE CDT edges with the exact shared graph edges
  const verts = r.getVertices();
  const vertById = new Map<number, typeof verts[0]>();
  for (const v of verts) vertById.set(v.id, v);

  // Clear all neighbors first
  for (const v of verts) v.neighbors = [];

  // Set exact neighbors from shared graph
  for (const vd of graph.vertices) {
    const v = vertById.get(vd.id);
    if (!v) continue;
    for (const nid of vd.neighbors) {
      const n = vertById.get(nid);
      if (n && !v.neighbors.includes(n)) v.neighbors.push(n);
    }
  }

  // Rebuild region neighbors to match
  const regions = r.getRegions();
  for (const reg of regions) {
    reg.neighbors = [];
  }
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

  // Rebuild cuts
  // Access private newcuts via any cast
  const router = r as any;
  const { SymmetricMap, Cut } = await import('../src/types');
  router.newcuts = new SymmetricMap();
  for (const v of verts) {
    for (const n of v.neighbors) {
      if (!router.newcuts.has(v, n)) {
        router.newcuts.set(v, n, new Cut(v, n));
      }
    }
  }

  console.error('Graph injected: vertices=' + verts.length + ' edges checked');

  // Generate netlist — DON'T sort, use same order as Ruby (graph.nets order)
  r.generateNetlist(graph.nets.map((n: any) => ({
    from: n.from, to: n.to,
    traceWidth: 1200, traceClearance: 800
  })));
  // Don't sort — keep same order as Ruby test

  // Route each net
  const results: any[] = [];
  for (let i = 0; i < r.netlist.length; i++) {
    const nd = r.netlist[i];
    const ok = r.route(i);

    if (ok) {
      // Extract path from steps
      const v = verts.find(v => v.name === nd.t1Name);
      const pathNames: string[] = [];
      if (v) {
        for (const inet of v.incidentNets) {
          if (inet.id === i && inet.next) {
            pathNames.push(v.name);
            let step = inet.nstep;
            while (step) {
              pathNames.push(step.vertex.name);
              step = step.nstep;
            }
            // Path goes from t1 to t2, but internally stored as t2->...->t1
            // The route path in dijkstra goes dest->source
          }
        }
      }
      // Also try from t2 side
      if (pathNames.length === 0) {
        const v2 = verts.find(v => v.name === nd.t2Name);
        if (v2) {
          for (const inet of v2.incidentNets) {
            if (inet.id === i && inet.next) {
              pathNames.push(v2.name);
              let step = inet.nstep;
              while (step) {
                pathNames.push(step.vertex.name);
                step = step.nstep;
              }
            }
          }
        }
      }
      results.push({net: i, from: nd.t1Name, to: nd.t2Name, path: pathNames, length: pathNames.length});
    } else {
      results.push({net: i, from: nd.t1Name, to: nd.t2Name, path: null});
    }
  }

  console.log(JSON.stringify({routes: results}, null, 2));
}

main().catch(console.error);
