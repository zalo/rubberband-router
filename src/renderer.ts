// Canvas renderer for the rubberband router
import { Router } from './router';
import type { DrawnSegment } from './router';
import { Vertex } from './types';

const NET_COLORS = [
  '#e6194b', '#3cb44b', '#4363d8', '#f58231', '#911eb4',
  '#42d4f4', '#f032e6', '#bfef45', '#fabed4', '#469990',
  '#dcbeff', '#9A6324', '#800000', '#aaffc3', '#808000',
  '#000075', '#a9a9a9'
];

export class Renderer {
  private canvas: HTMLCanvasElement;
  private ctx: CanvasRenderingContext2D;
  private scale: number = 1;
  private offsetX: number = 0;
  private offsetY: number = 0;
  private boardX1: number = 0;
  private boardY1: number = 0;
  private boardX2: number = 1;
  private boardY2: number = 1;

  constructor(canvas: HTMLCanvasElement) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d')!;
  }

  setBoardBounds(x1: number, y1: number, x2: number, y2: number): void {
    this.boardX1 = x1;
    this.boardY1 = y1;
    this.boardX2 = x2;
    this.boardY2 = y2;
    this.updateTransform();
  }

  private updateTransform(): void {
    const w = this.canvas.width;
    const h = this.canvas.height;
    const bw = this.boardX2 - this.boardX1;
    const bh = this.boardY2 - this.boardY1;
    const margin = 0.1;
    this.scale = Math.min(w, h) * (1 - 2 * margin) / Math.max(bw, bh, 1);
    this.offsetX = (w - bw * this.scale) / 2 - this.boardX1 * this.scale;
    this.offsetY = (h - bh * this.scale) / 2 - this.boardY1 * this.scale;
  }

  toScreen(x: number, y: number): [number, number] {
    return [x * this.scale + this.offsetX, y * this.scale + this.offsetY];
  }

  fromScreen(sx: number, sy: number): [number, number] {
    return [(sx - this.offsetX) / this.scale, (sy - this.offsetY) / this.scale];
  }

  clear(): void {
    const ctx = this.ctx;
    ctx.fillStyle = '#1a1a2e';
    ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);

    // Draw board area
    const [x1, y1] = this.toScreen(this.boardX1, this.boardY1);
    const [x2, y2] = this.toScreen(this.boardX2, this.boardY2);
    ctx.fillStyle = '#16213e';
    ctx.fillRect(x1, y1, x2 - x1, y2 - y1);
    ctx.strokeStyle = '#0f3460';
    ctx.lineWidth = 2;
    ctx.strokeRect(x1, y1, x2 - x1, y2 - y1);
  }

  drawTriangulation(router: Router): void {
    const ctx = this.ctx;
    const vertices = router.getVertices();

    // Draw edges
    ctx.strokeStyle = 'rgba(100, 100, 140, 0.15)';
    ctx.lineWidth = 0.5;
    for (const v of vertices) {
      for (const n of v.neighbors) {
        if (v.id < n.id) {
          const [x1, y1] = this.toScreen(v.x, v.y);
          const [x2, y2] = this.toScreen(n.x, n.y);
          ctx.beginPath();
          ctx.moveTo(x1, y1);
          ctx.lineTo(x2, y2);
          ctx.stroke();
        }
      }
    }
  }

  drawVertices(router: Router, obstacles: Set<string>): void {
    const ctx = this.ctx;
    const vertices = router.getVertices();

    for (const v of vertices) {
      if (v.name === 'border' || v.name === 'corner') continue;

      const [sx, sy] = this.toScreen(v.x, v.y);
      const sr = v.core * this.scale;

      if (obstacles.has(v.name)) {
        // Obstacle
        ctx.fillStyle = 'rgba(180, 50, 50, 0.6)';
        ctx.strokeStyle = '#e74c3c';
      } else if (v.incidentNets.length > 0 || v.numInets > 0) {
        // Terminal with nets
        ctx.fillStyle = 'rgba(50, 200, 100, 0.7)';
        ctx.strokeStyle = '#2ecc71';
      } else {
        // Regular pin
        ctx.fillStyle = 'rgba(150, 150, 170, 0.4)';
        ctx.strokeStyle = 'rgba(180, 180, 200, 0.5)';
      }

      ctx.beginPath();
      ctx.arc(sx, sy, Math.max(sr, 3), 0, Math.PI * 2);
      ctx.fill();
      ctx.lineWidth = 1;
      ctx.stroke();

      // Draw name label for terminals
      if (v.name && v.name !== '' && v.name !== 'no' && v.numInets > 0) {
        ctx.fillStyle = '#e0e0e0';
        ctx.font = '10px monospace';
        ctx.textAlign = 'center';
        ctx.fillText(v.name, sx, sy - Math.max(sr, 3) - 4);
      }
    }
  }

  drawRoutes(segments: DrawnSegment[]): void {
    const ctx = this.ctx;

    for (const seg of segments) {
      const color = NET_COLORS[seg.netId % NET_COLORS.length];
      ctx.strokeStyle = color;
      ctx.lineWidth = Math.max(seg.width * this.scale, 1.5);
      ctx.lineCap = 'round';
      ctx.globalAlpha = 0.8;

      if (seg.type === 'line') {
        const [x1, y1] = this.toScreen(seg.x1, seg.y1);
        const [x2, y2] = this.toScreen(seg.x2, seg.y2);
        ctx.beginPath();
        ctx.moveTo(x1, y1);
        ctx.lineTo(x2, y2);
        ctx.stroke();
      } else if (seg.type === 'arc' && seg.cx !== undefined && seg.cy !== undefined) {
        const [cx, cy] = this.toScreen(seg.cx, seg.cy);
        const r = seg.r! * this.scale;
        if (r > 0.5) {
          ctx.beginPath();
          const start = seg.startAngle!;
          const end = seg.endAngle!;
          // Determine if we should go clockwise or counterclockwise
          // by choosing the shorter arc
          let diff = end - start;
          if (diff > Math.PI) diff -= 2 * Math.PI;
          if (diff < -Math.PI) diff += 2 * Math.PI;
          const counterclockwise = diff < 0;
          ctx.arc(cx, cy, r, start, end, counterclockwise);
          ctx.stroke();
        }
      }
    }
    ctx.globalAlpha = 1;
  }

  drawNetConnections(connections: { from: string; to: string }[], vertices: Vertex[]): void {
    const ctx = this.ctx;
    ctx.setLineDash([4, 4]);

    for (let i = 0; i < connections.length; i++) {
      const conn = connections[i];
      const v1 = vertices.find(v => v.name === conn.from);
      const v2 = vertices.find(v => v.name === conn.to);
      if (!v1 || !v2) continue;

      const color = NET_COLORS[i % NET_COLORS.length];
      ctx.strokeStyle = color;
      ctx.globalAlpha = 0.3;
      ctx.lineWidth = 1;

      const [x1, y1] = this.toScreen(v1.x, v1.y);
      const [x2, y2] = this.toScreen(v2.x, v2.y);
      ctx.beginPath();
      ctx.moveTo(x1, y1);
      ctx.lineTo(x2, y2);
      ctx.stroke();
    }

    ctx.setLineDash([]);
    ctx.globalAlpha = 1;
  }

  /**
   * Draw raw segments/arcs from Ruby reference data
   */
  drawRubyRoutes(routes: { segments: any[]; arcs: any[] }[]): void {
    const ctx = this.ctx;
    for (let netId = 0; netId < routes.length; netId++) {
      const route = routes[netId];
      const color = NET_COLORS[netId % NET_COLORS.length];
      ctx.strokeStyle = color;
      ctx.lineCap = 'round';
      ctx.globalAlpha = 0.8;

      for (const seg of (route.segments || [])) {
        ctx.lineWidth = Math.max((seg.width || 1200) * this.scale, 1.5);
        const [x1, y1] = this.toScreen(seg.x1, seg.y1);
        const [x2, y2] = this.toScreen(seg.x2, seg.y2);
        ctx.beginPath();
        ctx.moveTo(x1, y1);
        ctx.lineTo(x2, y2);
        ctx.stroke();
      }

      for (const arc of (route.arcs || [])) {
        ctx.lineWidth = Math.max((arc.width || 1200) * this.scale, 1.5);
        const [cx, cy] = this.toScreen(arc.cx, arc.cy);
        const r = arc.r * this.scale;
        if (r > 0.5) {
          ctx.beginPath();
          let diff = arc.endAngle - arc.startAngle;
          if (diff > Math.PI) diff -= 2 * Math.PI;
          if (diff < -Math.PI) diff += 2 * Math.PI;
          ctx.arc(cx, cy, r, arc.startAngle, arc.endAngle, diff < 0);
          ctx.stroke();
        }
      }
    }
    ctx.globalAlpha = 1;
  }

  /**
   * Full render of the current state
   */
  render(
    router: Router,
    obstacles: Set<string>,
    connections: { from: string; to: string }[],
    showTriangulation: boolean = true,
    rubyRoutes?: { segments: any[]; arcs: any[] }[]
  ): void {
    this.updateTransform();
    this.clear();
    if (showTriangulation) this.drawTriangulation(router);
    this.drawNetConnections(connections, router.getVertices());
    this.drawVertices(router, obstacles);

    if (rubyRoutes) {
      this.drawRubyRoutes(rubyRoutes);
    } else {
      const segments = router.generateDrawnSegments();
      this.drawRoutes(segments);
    }
  }
}
