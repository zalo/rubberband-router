// Generate a CDT from our TypeScript code and export it as JSON
// for feeding into both TS and Ruby routers
import { Router } from '../src/router';
import { Vertex, NetDesc } from '../src/types';

async function main() {
  Vertex.resetIds();
  NetDesc.resetIds();

  // Use the star preset: center + 12 outer pins + 6 obstacles
  const BOARD_SIZE = 140000;
  const r = new Router(0, 0, BOARD_SIZE, BOARD_SIZE);
  r.insertBorder();

  const cx = BOARD_SIZE / 2, cy = BOARD_SIZE / 2, rad = BOARD_SIZE * 0.35;
  const n = 12;

  // Center pin
  r.insertVertex('P0', cx, cy);

  // Outer ring
  for (let i = 0; i < n; i++) {
    const angle = (i / n) * Math.PI * 2;
    r.insertVertex(`P${i+1}`, cx + rad * Math.cos(angle), cy + rad * Math.sin(angle));
  }

  // Obstacles
  for (let i = 0; i < 6; i++) {
    const angle = ((i + 0.5) / 6) * Math.PI * 2;
    r.insertVertex(`O${i+13}`, cx + rad * 0.5 * Math.cos(angle), cy + rad * 0.5 * Math.sin(angle), 2000, 800);
  }

  await r.finishInit();

  // Export the graph
  const verts = r.getVertices();
  const vertexData = verts.map(v => ({
    id: v.id, name: v.name, x: v.x, y: v.y,
    core: v.core, radius: v.radius, separation: v.separation,
    neighbors: v.neighbors.map(n => n.id)
  }));

  // Nets: center to each outer pin
  const nets: {from: string, to: string}[] = [];
  for (let i = 1; i <= n; i++) {
    nets.push({ from: 'P0', to: `P${i}` });
  }

  const output = {
    vertices: vertexData,
    nets: nets,
    board: { x1: 0, y1: 0, x2: BOARD_SIZE, y2: BOARD_SIZE }
  };

  console.log(JSON.stringify(output));
}

main().catch(console.error);
