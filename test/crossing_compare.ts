// Generate shared graph for crossing preset and compare Ruby vs TS
import { Router } from '../src/router';
import { Vertex, NetDesc, SymmetricMap, Cut } from '../src/types';
import { segmentIntersects } from '../src/geometry';
import { writeFileSync } from 'fs';

const BOARD_SIZE = 140000;

async function main() {
  Vertex.resetIds(); NetDesc.resetIds();
  const r = new Router(0, 0, BOARD_SIZE, BOARD_SIZE);
  r.insertBorder();

  // Crossing preset: 6 left pins, 6 right pins (reversed), 3 obstacles
  const n = 6, spacing = BOARD_SIZE / (n + 1);
  const pins: {name: string, x: number, y: number, isObs: boolean}[] = [];
  for (let i = 0; i < n; i++) {
    pins.push({name: `L${i}`, x: BOARD_SIZE * 0.15, y: spacing * (i + 1), isObs: false});
  }
  for (let i = 0; i < n; i++) {
    pins.push({name: `R${i}`, x: BOARD_SIZE * 0.85, y: spacing * (n - i), isObs: false});
  }
  for (let i = 0; i < 3; i++) {
    pins.push({name: `O${i}`, x: BOARD_SIZE * 0.5, y: BOARD_SIZE * (0.3 + i * 0.2), isObs: true});
  }

  for (const p of pins) {
    r.insertVertex(p.name, p.x, p.y, p.isObs ? 2000 : 1000, 800);
  }
  await r.finishInit();

  // Export graph for Ruby
  const verts = r.getVertices();
  const nets: {from: string, to: string}[] = [];
  for (let i = 0; i < n; i++) {
    nets.push({from: `L${i}`, to: `R${i}`});
  }

  const graph = {
    vertices: verts.map(v => ({
      id: v.id, name: v.name, x: v.x, y: v.y,
      core: v.core, radius: v.radius, separation: v.separation,
      neighbors: v.neighbors.map(n => n.id)
    })),
    nets,
    board: {x1: 0, y1: 0, x2: BOARD_SIZE, y2: BOARD_SIZE}
  };
  writeFileSync('test/crossing_graph.json', JSON.stringify(graph));

  // Now route in TS with same graph
  r.generateNetlist(nets.map(n => ({from: n.from, to: n.to, traceWidth: 1200, traceClearance: 800})));
  for (let i = 0; i < r.netlist.length; i++) r.route(i);
  r.prepareSteps();

  // Extract paths
  console.log('=== TypeScript paths (stage 0) ===');
  for (const vert of verts) {
    for (const inet of vert.incidentNets) {
      if (!inet.next) continue;
      const parts = [vert.name];
      let step = inet.nstep;
      while (step) {
        parts.push(`${step.vertex.name}(r=${Math.round(step.radius)},rgt=${step.rgt},xt=${step.xt})`);
        step = step.nstep;
      }
      console.log(`  Net ${inet.id}: ${parts.join(' -> ')}`);
    }
  }

  const segs0 = r.generateDrawnSegments();
  const lines0 = segs0.filter(s => s.type === 'line');
  let cross0 = 0;
  const crossPairs: string[] = [];
  for (let i = 0; i < lines0.length; i++) {
    for (let j = i + 1; j < lines0.length; j++) {
      const a = lines0[i], b = lines0[j];
      if (a.netId !== b.netId && segmentIntersects(a.x1,a.y1,a.x2,a.y2, b.x1,b.y1,b.x2,b.y2)) {
        cross0++;
        crossPairs.push(`net${a.netId} x net${b.netId}`);
      }
    }
  }
  console.log(`\nStage 0: ${segs0.length} segs, ${cross0} crossings: ${crossPairs.join(', ')}`);

  // Rubberband
  r.sortAttachedNets(); r.prepareSteps(); r.nubly(); r.prepareSteps();
  r.sortAttachedNets(); r.prepareSteps(); r.nubly(); r.prepareSteps();
  r.sortAttachedNets(); r.prepareSteps(); r.nubly(true); r.sortAttachedNets(); r.prepareSteps();

  const segsRb = r.generateDrawnSegments();
  const linesRb = segsRb.filter(s => s.type === 'line');
  let crossRb = 0;
  const crossPairsRb: string[] = [];
  for (let i = 0; i < linesRb.length; i++) {
    for (let j = i + 1; j < linesRb.length; j++) {
      const a = linesRb[i], b = linesRb[j];
      if (a.netId !== b.netId && segmentIntersects(a.x1,a.y1,a.x2,a.y2, b.x1,b.y1,b.x2,b.y2)) {
        crossRb++;
        crossPairsRb.push(`net${a.netId} x net${b.netId}`);
      }
    }
  }
  console.log(`Stage 4: ${segsRb.length} segs, ${crossRb} crossings: ${crossPairsRb.join(', ')}`);
}

main().catch(console.error);
