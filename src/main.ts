// Rubberband Topological Router - Interactive Demo
// Ported from Stefan Salewski's Ruby implementation

import { Router } from './router';
import { Renderer } from './renderer';
import { Vertex, DEFAULT_PIN_RADIUS, DEFAULT_CLEARANCE, DEFAULT_TRACE_WIDTH } from './types';

interface AppState {
  mode: 'place_pin' | 'place_obstacle' | 'connect' | 'delete';
  router: Router | null;
  renderer: Renderer;
  boardSize: number;
  pinCount: number;
  pins: { name: string; x: number; y: number; isObstacle: boolean }[];
  connections: { from: string; to: string }[];
  selectedPin: string | null;
  draggingPin: string | null;
  isRouted: boolean;
  showTriangulation: boolean;
  traceWidth: number;
  clearance: number;
  pinRadius: number;
}

const BOARD_SIZE = 140000;

function createApp(): void {
  const canvas = document.getElementById('canvas') as HTMLCanvasElement;
  const state: AppState = {
    mode: 'place_pin',
    router: null,
    renderer: new Renderer(canvas),
    boardSize: BOARD_SIZE,
    pinCount: 0,
    pins: [],
    connections: [],
    selectedPin: null,
    draggingPin: null,
    isRouted: false,
    showTriangulation: true,
    traceWidth: DEFAULT_TRACE_WIDTH,
    clearance: DEFAULT_CLEARANCE,
    pinRadius: DEFAULT_PIN_RADIUS,
  };

  state.renderer.setBoardBounds(0, 0, BOARD_SIZE, BOARD_SIZE);

  // Resize canvas to fill container
  const resizeCanvas = async () => {
    const container = canvas.parentElement!;
    canvas.width = container.clientWidth;
    canvas.height = container.clientHeight;
    if (state.router) await render();
  };
  resizeCanvas();
  window.addEventListener('resize', resizeCanvas);

  const modeButtons = document.querySelectorAll<HTMLButtonElement>('.mode-btn');
  const clearBtn = document.getElementById('clear-btn') as HTMLButtonElement;
  const routeBtn = document.getElementById('route-btn') as HTMLButtonElement;
  const randomBtn = document.getElementById('random-btn') as HTMLButtonElement;
  const triToggle = document.getElementById('tri-toggle') as HTMLInputElement;
  const statusEl = document.getElementById('status') as HTMLElement;
  const traceWidthInput = document.getElementById('trace-width') as HTMLInputElement;
  const clearanceInput = document.getElementById('clearance') as HTMLInputElement;
  const pinRadiusInput = document.getElementById('pin-radius') as HTMLInputElement;
  const pinCountInput = document.getElementById('pin-count') as HTMLInputElement;
  const netCountInput = document.getElementById('net-count') as HTMLInputElement;
  const presetSelect = document.getElementById('preset-select') as HTMLSelectElement;

  function setStatus(msg: string): void {
    statusEl.textContent = msg;
  }

  function setMode(mode: AppState['mode']): void {
    state.mode = mode;
    modeButtons.forEach(btn => {
      btn.classList.toggle('active', btn.dataset.mode === mode);
    });
    state.selectedPin = null;
    const modeLabels: Record<string, string> = {
      place_pin: 'Click to place terminals',
      place_obstacle: 'Click to place obstacles',
      connect: 'Click two terminals to connect them',
      delete: 'Click a terminal or obstacle to remove it'
    };
    setStatus(modeLabels[mode]);
  }

  modeButtons.forEach(btn => {
    btn.addEventListener('click', () => setMode(btn.dataset.mode as AppState['mode']));
  });

  triToggle.addEventListener('change', async () => {
    state.showTriangulation = triToggle.checked;
    await render();
  });

  async function rebuildRouter(): Promise<void> {
    Vertex.resetIds();
    state.router = new Router(0, 0, BOARD_SIZE, BOARD_SIZE);
    state.router.insertBorder();

    for (const pin of state.pins) {
      state.router.insertVertex(
        pin.name, pin.x, pin.y,
        pin.isObstacle ? state.pinRadius * 2 : state.pinRadius,
        state.clearance
      );
    }

    await state.router.finishInit();

    const validConnections = state.connections.filter(c => {
      const v1 = state.router!.getVertices().find(v => v.name === c.from);
      const v2 = state.router!.getVertices().find(v => v.name === c.to);
      return v1 && v2;
    });

    state.router.generateNetlist(
      validConnections.map(c => ({
        from: c.from,
        to: c.to,
        traceWidth: state.traceWidth,
        traceClearance: state.clearance
      }))
    );
    state.router.sortNetlist();
    state.isRouted = false;
  }

  async function doRoute(): Promise<void> {
    if (!state.router) await rebuildRouter();
    if (!state.router) return;

    if (state.router.netlist.length === 0) {
      setStatus('No nets to route');
      return;
    }

    const t0 = performance.now();
    let routed = 0;
    const total = state.router.netlist.length;

    // Route all nets, then retry failed ones with higher detour factor
    // (matching original pcbtr.rb retry logic)
    const failed: number[] = [];
    for (let i = 0; i < total; i++) {
      if (state.router.route(i)) routed++;
      else failed.push(i);
    }
    for (const i of failed) {
      if (state.router.route(i, 3)) routed++;
    }

    // Rubberband optimization (matching original Ruby sequence)
    state.router.sortAttachedNets();
    state.router.prepareSteps();
    state.router.nubly();
    state.router.prepareSteps();

    state.router.sortAttachedNets();
    state.router.prepareSteps();
    state.router.nubly();
    state.router.prepareSteps();

    state.router.sortAttachedNets();
    state.router.prepareSteps();
    state.router.nubly(true);
    state.router.sortAttachedNets();
    state.router.prepareSteps();

    // Post-process: iteratively fix crossing pairs
    for (let pass = 0; pass < 10; pass++) {
      state.router.fixCrossingPairs();
      state.router.generateDrawnSegments();
      if (state.router.countCrossings() === 0) break;
    }
    const crossings = state.router.countCrossings();

    const elapsed = (performance.now() - t0).toFixed(1);
    state.isRouted = true;
    setStatus(`Routed ${routed}/${total} nets in ${elapsed}ms${crossings > 0 ? `, ${crossings} visual overlaps` : ''}`);
    await render();
  }

  async function render(): Promise<void> {
    if (!state.router) await rebuildRouter();
    if (!state.router) return;

    const obstacles = new Set(state.pins.filter(p => p.isObstacle).map(p => p.name));
    state.renderer.setBoardBounds(0, 0, BOARD_SIZE, BOARD_SIZE);
    state.renderer.render(state.router, obstacles, state.connections, state.showTriangulation);
  }

  function findNearestPin(worldX: number, worldY: number, maxDist: number = BOARD_SIZE * 0.03): string | null {
    let nearest: string | null = null;
    let minDist = maxDist;
    for (const pin of state.pins) {
      const d = Math.hypot(pin.x - worldX, pin.y - worldY);
      if (d < minDist) { minDist = d; nearest = pin.name; }
    }
    return nearest;
  }

  // Drag support: mousedown starts drag or click action, mousemove drags, mouseup ends
  let dragStartX = 0, dragStartY = 0;
  let didDrag = false;
  let dragRafPending = false;

  canvas.addEventListener('pointerdown', (e) => {
    const rect = canvas.getBoundingClientRect();
    const [wx, wy] = state.renderer.fromScreen(e.clientX - rect.left, e.clientY - rect.top);
    dragStartX = wx; dragStartY = wy;
    didDrag = false;

    // Check if we're near a pin to drag
    const nearest = findNearestPin(wx, wy);
    if (nearest) {
      state.draggingPin = nearest;
      canvas.setPointerCapture(e.pointerId);
      canvas.style.cursor = 'grabbing';
    }
  });

  canvas.addEventListener('pointermove', (e) => {
    if (!state.draggingPin) return;
    didDrag = true;
    const rect = canvas.getBoundingClientRect();
    const [wx, wy] = state.renderer.fromScreen(e.clientX - rect.left, e.clientY - rect.top);

    const pin = state.pins.find(p => p.name === state.draggingPin);
    if (pin) {
      pin.x = Math.max(0, Math.min(BOARD_SIZE, wx));
      pin.y = Math.max(0, Math.min(BOARD_SIZE, wy));
    }

    if (!dragRafPending) {
      dragRafPending = true;
      requestAnimationFrame(async () => {
        dragRafPending = false;
        await rebuildRouter();
        if (state.connections.length > 0) {
          await doRoute();
        } else {
          await render();
        }
      });
    }
  });

  canvas.addEventListener('pointerup', async (e) => {
    canvas.style.cursor = 'crosshair';
    if (state.draggingPin && didDrag) {
      // Final reroute after drag
      state.draggingPin = null;
      await rebuildRouter();
      if (state.connections.length > 0) await doRoute();
      else await render();
      return;
    }
    state.draggingPin = null;
    if (didDrag) return; // was a drag, not a click

    // Handle as click
    const rect = canvas.getBoundingClientRect();
    const [wx, wy] = state.renderer.fromScreen(e.clientX - rect.left, e.clientY - rect.top);
    if (wx < 0 || wx > BOARD_SIZE || wy < 0 || wy > BOARD_SIZE) return;

    switch (state.mode) {
      case 'place_pin': {
        const name = `P${state.pinCount++}`;
        state.pins.push({ name, x: wx, y: wy, isObstacle: false });
        await rebuildRouter();
        await render();
        setStatus(`Placed terminal ${name}`);
        break;
      }
      case 'place_obstacle': {
        const name = `O${state.pinCount++}`;
        state.pins.push({ name, x: wx, y: wy, isObstacle: true });
        await rebuildRouter();
        await render();
        setStatus(`Placed obstacle ${name}`);
        break;
      }
      case 'connect': {
        const nearest = findNearestPin(wx, wy);
        if (!nearest) { setStatus('Click near a terminal'); return; }
        if (state.pins.find(p => p.name === nearest)?.isObstacle) {
          setStatus('Cannot connect obstacles'); return;
        }
        if (!state.selectedPin) {
          state.selectedPin = nearest;
          setStatus(`Selected ${nearest} - click another terminal`);
        } else {
          if (state.selectedPin === nearest) { state.selectedPin = null; setStatus('Deselected'); return; }
          const exists = state.connections.some(c =>
            (c.from === state.selectedPin && c.to === nearest) ||
            (c.from === nearest && c.to === state.selectedPin)
          );
          if (!exists) {
            state.connections.push({ from: state.selectedPin, to: nearest });
            setStatus(`Connected ${state.selectedPin} to ${nearest}`);
          }
          state.selectedPin = null;
          await rebuildRouter();
          await render();
        }
        break;
      }
      case 'delete': {
        const nearest = findNearestPin(wx, wy);
        if (nearest) {
          state.pins = state.pins.filter(p => p.name !== nearest);
          state.connections = state.connections.filter(c => c.from !== nearest && c.to !== nearest);
          await rebuildRouter();
          await render();
          setStatus(`Deleted ${nearest}`);
        }
        break;
      }
    }
  });

  routeBtn.addEventListener('click', async () => { await rebuildRouter(); await doRoute(); });

  clearBtn.addEventListener('click', async () => {
    state.pins = [];
    state.connections = [];
    state.pinCount = 0;
    state.selectedPin = null;
    state.isRouted = false;
    await rebuildRouter();
    await render();
    setStatus('Board cleared');
  });

  randomBtn.addEventListener('click', async () => {
    const pinCount = parseInt(pinCountInput.value) || 32;
    const netCount = parseInt(netCountInput.value) || 10;
    state.traceWidth = parseInt(traceWidthInput.value) || DEFAULT_TRACE_WIDTH;
    state.clearance = parseInt(clearanceInput.value) || DEFAULT_CLEARANCE;
    state.pinRadius = parseInt(pinRadiusInput.value) || DEFAULT_PIN_RADIUS;

    state.pins = [];
    state.connections = [];
    state.pinCount = 0;
    Vertex.resetIds();

    state.router = new Router(0, 0, BOARD_SIZE, BOARD_SIZE);
    state.router.insertBorder();
    state.router.generateTestVertices(pinCount);
    await state.router.finishInit();
    state.router.generateRandomNetlist(netCount);

    for (const v of state.router.getVertices()) {
      if (v.name && v.name !== 'border' && v.name !== 'corner' && v.name !== '') {
        state.pins.push({ name: v.name, x: v.x, y: v.y, isObstacle: false });
      }
    }
    for (const nd of state.router.netlist) {
      state.connections.push({ from: nd.t1Name, to: nd.t2Name });
    }

    setStatus(`Generated ${pinCount} pins, ${netCount} nets. Click Route!`);
    await render();
  });

  presetSelect.addEventListener('change', async () => {
    const preset = presetSelect.value;
    if (!preset) return;
    state.pins = [];
    state.connections = [];
    state.pinCount = 0;

    if (preset === 'grid4x4') loadGridPreset(4, 4);
    else if (preset === 'grid6x6') loadGridPreset(6, 6);
    else if (preset === 'star') loadStarPreset();
    else if (preset === 'parallel') loadParallelPreset();
    else if (preset === 'crossing') loadCrossingPreset();

    await rebuildRouter();
    await render();
    presetSelect.value = '';
  });

  function loadGridPreset(rows: number, cols: number): void {
    const spacing = BOARD_SIZE / (Math.max(rows, cols) + 1);
    const offX = (BOARD_SIZE - (cols - 1) * spacing) / 2;
    const offY = (BOARD_SIZE - (rows - 1) * spacing) / 2;
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const name = `P${state.pinCount++}`;
        state.pins.push({ name, x: offX + c * spacing, y: offY + r * spacing, isObstacle: false });
      }
    }
    const half = Math.floor(rows * cols / 2);
    for (let i = 0; i < half; i++) {
      const j = rows * cols - 1 - i;
      if (i < j) state.connections.push({ from: state.pins[i].name, to: state.pins[j].name });
    }
    setStatus(`Grid ${rows}x${cols}: ${state.pins.length} pins, ${state.connections.length} nets`);
  }

  function loadStarPreset(): void {
    const cx = BOARD_SIZE / 2, cy = BOARD_SIZE / 2, r = BOARD_SIZE * 0.35;
    const n = 12;
    const center = `P${state.pinCount++}`;
    state.pins.push({ name: center, x: cx, y: cy, isObstacle: false });
    for (let i = 0; i < n; i++) {
      const angle = (i / n) * Math.PI * 2;
      const name = `P${state.pinCount++}`;
      state.pins.push({ name, x: cx + r * Math.cos(angle), y: cy + r * Math.sin(angle), isObstacle: false });
    }
    for (let i = 1; i <= n; i++) state.connections.push({ from: center, to: state.pins[i].name });
    for (let i = 0; i < 6; i++) {
      const angle = ((i + 0.5) / 6) * Math.PI * 2;
      const name = `O${state.pinCount++}`;
      state.pins.push({ name, x: cx + r * 0.5 * Math.cos(angle), y: cy + r * 0.5 * Math.sin(angle), isObstacle: true });
    }
    setStatus(`Star: ${n} nets, 6 obstacles`);
  }

  function loadParallelPreset(): void {
    const n = 8, spacing = BOARD_SIZE / (n + 1);
    for (let i = 0; i < n; i++) {
      const x = spacing * (i + 1);
      const a = `P${state.pinCount++}`, b = `P${state.pinCount++}`;
      state.pins.push({ name: a, x, y: BOARD_SIZE * 0.2, isObstacle: false });
      state.pins.push({ name: b, x, y: BOARD_SIZE * 0.8, isObstacle: false });
      state.connections.push({ from: a, to: b });
    }
    setStatus(`Parallel: ${n} pairs`);
  }

  function loadCrossingPreset(): void {
    const n = 6, spacing = BOARD_SIZE / (n + 1);
    for (let i = 0; i < n; i++) {
      const name = `L${state.pinCount++}`;
      state.pins.push({ name, x: BOARD_SIZE * 0.15, y: spacing * (i + 1), isObstacle: false });
    }
    for (let i = 0; i < n; i++) {
      const name = `R${state.pinCount++}`;
      state.pins.push({ name, x: BOARD_SIZE * 0.85, y: spacing * (n - i), isObstacle: false });
    }
    for (let i = 0; i < n; i++) state.connections.push({ from: state.pins[i].name, to: state.pins[n + i].name });
    for (let i = 0; i < 3; i++) {
      const name = `O${state.pinCount++}`;
      state.pins.push({ name, x: BOARD_SIZE * 0.5, y: BOARD_SIZE * (0.3 + i * 0.2), isObstacle: true });
    }
    setStatus(`Crossing: ${n} nets, 3 obstacles`);
  }

  traceWidthInput.addEventListener('change', () => { state.traceWidth = parseInt(traceWidthInput.value) || DEFAULT_TRACE_WIDTH; });
  clearanceInput.addEventListener('change', () => { state.clearance = parseInt(clearanceInput.value) || DEFAULT_CLEARANCE; });
  pinRadiusInput.addEventListener('change', () => { state.pinRadius = parseInt(pinRadiusInput.value) || DEFAULT_PIN_RADIUS; });

  document.addEventListener('keydown', (e) => {
    if (e.target instanceof HTMLInputElement || e.target instanceof HTMLSelectElement) return;
    switch (e.key) {
      case '1': setMode('place_pin'); break;
      case '2': setMode('place_obstacle'); break;
      case '3': setMode('connect'); break;
      case '4': setMode('delete'); break;
      case 'r': routeBtn.click(); break;
      case 'g': randomBtn.click(); break;
      case 't': triToggle.checked = !triToggle.checked; triToggle.dispatchEvent(new Event('change')); break;
    }
  });

  setMode('place_pin');
  rebuildRouter().then(() => render());
}

document.addEventListener('DOMContentLoaded', createApp);
