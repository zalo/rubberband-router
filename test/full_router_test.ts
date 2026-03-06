// Test the FULL router with the 5-vertex diamond
// This uses the actual Router class to find discrepancies with Ruby
import { Router } from '../src/router';
import { Vertex, NetDesc } from '../src/types';

async function main() {
  Vertex.resetIds();
  NetDesc.resetIds();

  const r = new Router(0, 0, 10000, 10000);

  // Insert 5 vertices (same as Ruby test) but NO border vertices
  r.insertVertex('V0', 0, 5000);
  r.insertVertex('V1', 10000, 5000);
  r.insertVertex('V2', 5000, 0);
  r.insertVertex('V3', 5000, 10000);
  r.insertVertex('V4', 5000, 5000);

  await r.finishInit();

  // Check CDT edges
  const verts = r.getVertices();
  console.log('Vertices:', verts.map(v => `${v.name}(${v.id}): neighbors=[${v.neighbors.map(n=>n.name).join(',')}]`));

  // Generate netlist: V0->V1 first, then V2->V3
  r.generateNetlist([
    { from: 'V0', to: 'V1' },
    { from: 'V2', to: 'V3' },
  ]);
  r.sortNetlist();

  console.log('\nNetlist:', r.netlist.map(n => `${n.t1Name}->${n.t2Name}`));

  // Route first net
  const ok1 = r.route(0);
  console.log('\nRoute 0 (V0->V1):', ok1);

  // Check regions after first route
  const regions = r.getRegions();
  console.log('Regions after route 0:', regions.length);
  for (const reg of regions) {
    if (reg.vertex.name === 'V4' || reg.vertex.name === 'V0' || reg.vertex.name === 'V1') {
      console.log(`  ${reg.vertex.name}(rid=${(reg as any).regionId}): incident=${reg.incident}, neighbors=[${reg.neighbors.map(n=>`${n.vertex.name}(${(n as any).regionId})`).join(',')}], idirs=${reg.idirs.length}, rx=${reg.rx.toFixed(1)}, ry=${reg.ry.toFixed(1)}`);
    }
  }

  // Route second net
  const ok2 = r.route(1);
  console.log('\nRoute 1 (V2->V3):', ok2);

  // Generate segments to check for crossings
  const segs = r.generateDrawnSegments();
  const crossings = r.countCrossings();
  console.log('Drawn segments:', segs.length);
  console.log('Crossings:', crossings);

  // Show the paths
  for (const v of verts) {
    for (const inet of v.incidentNets) {
      if (!inet.next) continue;
      const path = [v.name];
      let step = inet.nstep;
      while (step) {
        path.push(step.vertex.name);
        step = step.nstep;
      }
      console.log(`  Net ${inet.id}: ${path.join(' -> ')}`);
    }
  }
}

main().catch(console.error);
