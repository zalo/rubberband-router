// Canvas renderer for the rubberband router
import { Router } from './router';
import type { DrawnSegment } from './router';
import { Vertex } from './types';
import type { DebugSnapshot } from './debug';

export const NET_COLORS = [
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

  drawPolygonObstacles(polygons: { x: number; y: number }[][]): void {
    const ctx = this.ctx;
    for (const poly of polygons) {
      if (poly.length < 3) continue;
      ctx.beginPath();
      const [sx, sy] = this.toScreen(poly[0].x, poly[0].y);
      ctx.moveTo(sx, sy);
      for (let i = 1; i < poly.length; i++) {
        const [px, py] = this.toScreen(poly[i].x, poly[i].y);
        ctx.lineTo(px, py);
      }
      ctx.closePath();
      ctx.fillStyle = 'rgba(180, 50, 50, 0.25)';
      ctx.fill();
      ctx.strokeStyle = 'rgba(220, 60, 60, 0.7)';
      ctx.lineWidth = 2;
      ctx.stroke();
    }
  }

  drawBoxPreview(x1: number, y1: number, x2: number, y2: number): void {
    const ctx = this.ctx;
    const [sx1, sy1] = this.toScreen(Math.min(x1, x2), Math.min(y1, y2));
    const [sx2, sy2] = this.toScreen(Math.max(x1, x2), Math.max(y1, y2));
    ctx.setLineDash([6, 4]);
    ctx.strokeStyle = 'rgba(255, 100, 100, 0.8)';
    ctx.lineWidth = 2;
    ctx.strokeRect(sx1, sy1, sx2 - sx1, sy2 - sy1);
    ctx.fillStyle = 'rgba(180, 50, 50, 0.15)';
    ctx.fillRect(sx1, sy1, sx2 - sx1, sy2 - sy1);
    ctx.setLineDash([]);
  }

  /**
   * Full render of the current state
   */
  render(
    router: Router,
    obstacles: Set<string>,
    connections: { from: string; to: string }[],
    showTriangulation: boolean = true,
    polygonObstacles: { x: number; y: number }[][] = []
  ): void {
    this.updateTransform();
    this.clear();
    this.drawPolygonObstacles(polygonObstacles);
    if (showTriangulation) this.drawTriangulation(router);
    this.drawNetConnections(connections, router.getVertices());
    this.drawVertices(router, obstacles);

    const segments = router.generateDrawnSegments();
    this.drawRoutes(segments);
  }

  /**
   * Draw a debug snapshot with annotations
   */
  drawDebugSnapshot(snapshot: DebugSnapshot, showTriangulation: boolean = true): void {
    this.updateTransform();
    this.clear();

    const ctx = this.ctx;

    // Draw CDT edges
    if (showTriangulation && snapshot.edges) {
      ctx.strokeStyle = 'rgba(100, 100, 140, 0.15)';
      ctx.lineWidth = 0.5;
      for (const e of snapshot.edges) {
        const [x1, y1] = this.toScreen(e.x1, e.y1);
        const [x2, y2] = this.toScreen(e.x2, e.y2);
        ctx.beginPath();
        ctx.moveTo(x1, y1);
        ctx.lineTo(x2, y2);
        ctx.stroke();
      }
    }

    // Draw filled triangles to show the CDT structure
    if (snapshot.triangles && snapshot.triangles.length > 0) {
      for (let i = 0; i < snapshot.triangles.length; i++) {
        const tri = snapshot.triangles[i];
        const [ax, ay] = this.toScreen(tri.x1, tri.y1);
        const [bx, by] = this.toScreen(tri.x2, tri.y2);
        const [cx, cy] = this.toScreen(tri.x3, tri.y3);
        // Alternate colors for adjacent triangles
        const hue = (i * 37) % 360;
        ctx.fillStyle = `hsla(${hue}, 40%, 25%, 0.15)`;
        ctx.beginPath();
        ctx.moveTo(ax, ay);
        ctx.lineTo(bx, by);
        ctx.lineTo(cx, cy);
        ctx.closePath();
        ctx.fill();
      }
    }

    // Draw cut capacities as colored edges
    if (snapshot.cuts && snapshot.cuts.length > 0) {
      for (const cut of snapshot.cuts) {
        const [x1, y1] = this.toScreen(cut.x1, cut.y1);
        const [x2, y2] = this.toScreen(cut.x2, cut.y2);
        const ratio = cut.cap > 0 ? Math.max(0, cut.freeCap / cut.cap) : 0;
        // Green = open, yellow = getting tight, red = nearly full/overloaded
        const r = ratio < 0.5 ? 255 : Math.round(255 * 2 * (1 - ratio));
        const g = ratio > 0.5 ? 255 : Math.round(255 * 2 * ratio);
        const alpha = cut.usage > 0 ? 0.7 : 0.25;
        const width = cut.usage > 0 ? 3 : 1;
        ctx.strokeStyle = `rgba(${r}, ${g}, 40, ${alpha})`;
        ctx.lineWidth = width;
        ctx.beginPath();
        ctx.moveTo(x1, y1);
        ctx.lineTo(x2, y2);
        ctx.stroke();

        // Show capacity bar at midpoint for used cuts
        if (cut.usage > 0) {
          const mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
          // Draw a small capacity bar
          const barW = 20, barH = 4;
          ctx.fillStyle = 'rgba(0,0,0,0.6)';
          ctx.fillRect(mx - barW/2, my - barH/2 - 6, barW, barH);
          ctx.fillStyle = `rgb(${r}, ${g}, 40)`;
          ctx.fillRect(mx - barW/2, my - barH/2 - 6, barW * ratio, barH);
          // Usage label
          ctx.fillStyle = '#fff';
          ctx.font = 'bold 8px monospace';
          ctx.textAlign = 'center';
          ctx.fillText(`${cut.usage}t`, mx, my + 6);
        }
      }
    }

    // Draw vertices
    if (snapshot.vertices) {
      for (const v of snapshot.vertices) {
        if (v.name === 'border' || v.name === 'corner') continue;
        const [sx, sy] = this.toScreen(v.x, v.y);
        const sr = v.radius * this.scale;

        if (v.isObstacle) {
          ctx.fillStyle = 'rgba(180, 50, 50, 0.6)';
          ctx.strokeStyle = '#e74c3c';
        } else if (v.name && v.name !== '' && v.name !== 'no') {
          ctx.fillStyle = 'rgba(150, 150, 170, 0.4)';
          ctx.strokeStyle = 'rgba(180, 180, 200, 0.5)';
        } else {
          ctx.fillStyle = 'rgba(100, 100, 120, 0.3)';
          ctx.strokeStyle = 'rgba(120, 120, 140, 0.3)';
        }

        ctx.beginPath();
        ctx.arc(sx, sy, Math.max(sr, 2), 0, Math.PI * 2);
        ctx.fill();
        ctx.lineWidth = 1;
        ctx.stroke();
      }
    }

    // Draw routed segments
    if (snapshot.segments && snapshot.segments.length > 0) {
      this.drawRoutes(snapshot.segments);
    }

    // Draw region markers with offset arrows
    if (snapshot.regions) {
      for (const r of snapshot.regions) {
        const [sx, sy] = this.toScreen(r.rx, r.ry);
        const [vx, vy] = this.toScreen(r.x, r.y);

        // Draw offset arrow from vertex to region position (if offset is significant)
        const offsetDist = Math.hypot(sx - vx, sy - vy);
        if (offsetDist > 2) {
          ctx.beginPath();
          ctx.moveTo(vx, vy);
          ctx.lineTo(sx, sy);
          ctx.strokeStyle = r.incident ? 'rgba(88, 166, 255, 0.4)' : 'rgba(255, 100, 100, 0.4)';
          ctx.lineWidth = 1;
          ctx.stroke();
        }

        // Region dot
        ctx.beginPath();
        ctx.arc(sx, sy, r.incident ? 5 : 3, 0, Math.PI * 2);
        ctx.fillStyle = r.incident ? 'rgba(88, 166, 255, 0.6)' : 'rgba(255, 100, 100, 0.4)';
        ctx.fill();
        ctx.strokeStyle = r.incident ? '#58a6ff' : '#f85149';
        ctx.lineWidth = 1;
        ctx.stroke();

        // Region label (only for non-border vertices with interesting state)
        if (r.name && r.name !== 'border' && r.name !== 'corner' && r.name !== 'obstacle_boundary') {
          ctx.fillStyle = r.incident ? '#8db9ff' : '#ff8888';
          ctx.font = '8px monospace';
          ctx.textAlign = 'center';
          ctx.fillText(r.name, sx, sy - 8);
          // Show neighbor count
          ctx.fillStyle = '#666';
          ctx.fillText(`n:${r.neighborCount}`, sx, sy + 12);
        }
      }
    }

    // Draw highlight overlay
    if (snapshot.highlight) {
      // Highlighted path
      if (snapshot.highlight.path && snapshot.highlight.path.length > 1) {
        ctx.beginPath();
        const [sx, sy] = this.toScreen(snapshot.highlight.path[0].x, snapshot.highlight.path[0].y);
        ctx.moveTo(sx, sy);
        for (let i = 1; i < snapshot.highlight.path.length; i++) {
          const [px, py] = this.toScreen(snapshot.highlight.path[i].x, snapshot.highlight.path[i].y);
          ctx.lineTo(px, py);
        }
        ctx.strokeStyle = '#ffeb3b';
        ctx.lineWidth = 3;
        ctx.setLineDash([8, 4]);
        ctx.globalAlpha = 0.9;
        ctx.stroke();
        ctx.setLineDash([]);
        ctx.globalAlpha = 1;
      }

      // Highlighted edges
      if (snapshot.highlight.edges) {
        for (const e of snapshot.highlight.edges) {
          const [x1, y1] = this.toScreen(e.x1, e.y1);
          const [x2, y2] = this.toScreen(e.x2, e.y2);
          ctx.beginPath();
          ctx.moveTo(x1, y1);
          ctx.lineTo(x2, y2);
          ctx.strokeStyle = e.color;
          ctx.lineWidth = 2;
          ctx.globalAlpha = 0.8;
          ctx.stroke();
          ctx.globalAlpha = 1;
        }
      }

      // Highlighted vertices
      if (snapshot.highlight.vertices) {
        for (const v of snapshot.highlight.vertices) {
          const [sx, sy] = this.toScreen(v.x, v.y);
          ctx.beginPath();
          ctx.arc(sx, sy, 6, 0, Math.PI * 2);
          ctx.fillStyle = v.color;
          ctx.globalAlpha = 0.9;
          ctx.fill();
          ctx.globalAlpha = 1;

          if (v.label) {
            ctx.fillStyle = '#ffffff';
            ctx.font = 'bold 11px monospace';
            ctx.textAlign = 'center';
            ctx.fillText(v.label, sx, sy - 10);
          }
        }
      }
    }

    // Draw step label
    this.drawStepLabel(snapshot.description, snapshot.step, snapshot.type);
  }

  drawStepLabel(text: string, step: number, type: string): void {
    const ctx = this.ctx;
    const w = this.canvas.width;

    // Background bar
    ctx.fillStyle = 'rgba(22, 27, 34, 0.85)';
    ctx.fillRect(0, 0, w, 32);

    // Type badge
    const typeColors: Record<string, string> = {
      cdt: '#58a6ff',
      dijkstra_found: '#ffeb3b',
      dijkstra_start: '#f0883e',
      region_split: '#a371f7',
      sort_attached: '#7ee787',
      prepare_steps: '#79c0ff',
      nubly: '#f778ba',
      fix_crossings: '#ffa657',
      done: '#3fb950',
    };
    const badgeColor = typeColors[type] || '#8b949e';

    ctx.fillStyle = badgeColor;
    ctx.font = 'bold 11px monospace';
    ctx.textAlign = 'left';
    ctx.fillText(`[${type}]`, 10, 20);

    // Description text
    ctx.fillStyle = '#e6edf3';
    ctx.font = '12px system-ui, sans-serif';
    const badgeWidth = ctx.measureText(`[${type}]`).width;
    ctx.fillText(text, 10 + badgeWidth + 10, 20);
  }
}
