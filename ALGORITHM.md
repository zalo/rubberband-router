# Rubberband Topological Router: Algorithm Deep Dive

This document provides an exhaustive description of the rubberband topological routing algorithm implemented in this repository. The algorithm is a TypeScript port of Stefan Salewski's Ruby implementation (2015), which is itself based on the region concept from Tal Dayan's 1997 PhD thesis, "The Rubberband Approach to Topological Routing."

## Table of Contents

1. [Overview and Motivation](#1-overview-and-motivation)
2. [Data Structures](#2-data-structures)
3. [Phase 1: Graph Construction (CDT)](#3-phase-1-graph-construction-cdt)
4. [Phase 2: Path Finding (Modified Dijkstra)](#4-phase-2-path-finding-modified-dijkstra)
5. [Phase 3: Region Splitting](#5-phase-3-region-splitting)
6. [Phase 4: Rubberband Optimization](#6-phase-4-rubberband-optimization)
7. [Phase 5: Crossing Pair Mitigation](#7-phase-5-crossing-pair-mitigation)
8. [Phase 6: Trace Rendering](#8-phase-6-trace-rendering)
9. [Polygonal Obstacles](#9-polygonal-obstacles)
10. [Key Geometric Primitives](#10-key-geometric-primitives)
11. [Correctness Guarantees and Limitations](#11-correctness-guarantees-and-limitations)

---

## 1. Overview and Motivation

### The Problem

Given a set of terminal points (pins) on a PCB board and a netlist specifying which pairs of terminals must be connected, find paths for copper traces such that:

- Every net is connected
- No two traces from different nets cross each other
- Traces avoid obstacles
- The total wire length is minimized
- Traces maintain minimum clearance from each other and from pins

### The Topological Approach

Unlike geometric routers that work on a fixed grid, a **topological router** reasons about the *order* in which traces pass around obstacles and each other. Two routes that are geometrically different but topologically equivalent (they go around the same obstacles in the same order) are considered the same solution. This abstraction is powerful because:

1. It separates the "which side do we go around?" decision from the "exactly where does the trace go?" decision
2. It guarantees non-crossing by construction: once the topological ordering is fixed, the rubberband optimization pulls traces taut without introducing crossings
3. It naturally handles the interdependency between traces: routing one trace constrains where future traces can go

### Algorithm Pipeline

```
Terminals + Nets + Obstacles
        |
        v
  [1] Constrained Delaunay Triangulation
        |
        v
  [2] Modified Dijkstra (per net, sequentially)
        |
        v
  [3] Region Splitting (after each net)
        |
        v
  [4] Rubberband Optimization (global)
        |
        v
  [5] Crossing Pair Mitigation
        |
        v
  [6] Tangent-based Trace Rendering
```

---

## 2. Data Structures

### Vertex

A terminal point on the board. Each vertex has:

- **Position** `(x, y)` in board coordinates
- **Core radius** (`core`): the physical copper radius of the pin itself
- **Radius** (`radius`): the effective radius including all attached traces (grows as nets are routed through this vertex)
- **Separation** (`separation`): the clearance required from neighboring copper
- **Cluster ID** (`cid`): groups vertices that belong to the same pad/component (-1 for standalone pins)
- **Neighbors**: vertices connected by edges in the Delaunay triangulation
- **Incident nets**: nets that start or end at this vertex
- **Attached nets**: nets that pass through this vertex as an intermediate waypoint

### Region

The fundamental unit of the topological graph. Initially, there is one Region per Vertex. As traces are routed, regions are **split** into left/right halves.

- **Vertex**: the underlying terminal this region represents
- **Neighbors**: adjacent regions in the topological graph
- **Incident flag**: whether this region can serve as a net endpoint
- **Offset** `(ox, oy)`: a small perpendicular displacement used to distinguish split regions that share the same vertex. The "real" position is `(rx, ry) = (vertex.x + ox, vertex.y + oy)`
- **idirs**: "incident directions" — vectors recording which directions existing traces enter/leave this region's vertex. Used by `qbors()` to determine which neighbors are reachable
- **odirs**: "outer directions" — similar vectors for the outer lane

### Step

One waypoint in a routed trace. A trace is a linked list of Steps: `incident_start <-> attached_1 <-> attached_2 <-> ... <-> incident_end`.

- **prev/next**: the Vertex before/after this step in the trace
- **pstep/nstep**: links to the previous/next Step in the chain
- **vertex**: the Vertex at this waypoint
- **radius**: the concentric ring radius at which this trace passes the vertex
- **rgt** (right): which tangent side the trace uses when wrapping around this vertex. Two traces sharing a vertex with different `rgt` values pass on opposite sides
- **outer**: whether this step uses the outer lane (outside all inner traces)
- **xt**: whether the tangents from prev and next cross at this vertex (concave bend)

### NetDesc

Description of a 2-terminal net: two terminal names plus trace width and clearance.

### Cut

The "capacity" between two adjacent vertices in the triangulation. Tracks:

- **cap**: Euclidean distance between the vertices
- **free_cap**: remaining space after subtracting pin copper and routed traces
- **Squeeze strength**: a cost metric that increases as the cut gets tighter. Returns `MBD` (effectively infinity) when no space remains.

### SymmetricMap

A hash map keyed by unordered pairs of objects. `map.get(a, b)` and `map.get(b, a)` return the same value. Used for cuts (keyed by vertex pairs) and cluster edge detection.

---

## 3. Phase 1: Graph Construction (CDT)

### Constrained Delaunay Triangulation

The routing graph is built from a **Constrained Delaunay Triangulation** (CDT) of all terminal positions. The CDT provides:

1. **Edges** between nearby terminals that form the routing graph. The Dijkstra search explores paths along these edges.
2. **Triangle quality**: the Delaunay property (maximizing minimum angles) ensures well-shaped triangles, giving good routing options in all directions.
3. **Constraint support**: polygon obstacle boundaries can be inserted as constrained edges, preventing the triangulation from creating edges that cross obstacle walls.

The implementation uses the `cdt2d` library (pure JavaScript, from the same ecosystem as `robust-predicates`).

### Border Vertices

Virtual vertices are placed around the board perimeter to ensure the triangulation extends to the edges. Without these, terminals near the board edge would have poor connectivity. Border vertices are penalized with `MBD` cost in the Dijkstra to discourage routing through them.

### From CDT to Region Graph

After triangulation:

1. One **Region** is created per vertex
2. Region neighbors mirror the CDT edges
3. A **Cut** is created for each CDT edge, measuring the available space between the two vertices

```
CDT edges:         Region graph:
  A---B              R_A---R_B
  |\ /|              |  \ /  |
  | X |     --->     |   X   |
  |/ \|              |  / \  |
  C---D              R_C---R_D
```

---

## 4. Phase 2: Path Finding (Modified Dijkstra)

### Why Not Standard Dijkstra?

Standard Dijkstra finds the shortest path in a weighted graph. But our routing problem has additional constraints:

1. The cost to reach a vertex depends on **which direction you came from** (inner vs outer lane)
2. Whether you can **continue** to a neighbor depends on the turn direction (left/right)
3. Previously routed traces **block** certain transitions through their split regions
4. The squeeze (available space) at each cut must be sufficient for the trace

### The Triple Key: `[vertex, predecessor, rgt]`

Instead of keying the priority queue by just a vertex, we use a triple:

- **vertex**: the current Region
- **predecessor**: the Region we came from
- **rgt**: whether we're on the right tangent side at the current vertex

This means the same physical vertex can appear multiple times in the queue with different predecessors and sides. This is essential because:

- The set of reachable next hops depends on where we came from (via `qbors()`)
- The cost depends on whether we switch sides (AVD penalty for lane switching)

### The `qbors()` Function

For each region, `qbors(old)` yields the qualified neighbors — those reachable from the given predecessor `old`. It performs directional filtering:

```
Given: old -> self -> ?
For each neighbor el of self (except old):
  1. Compute the turn direction (left/right) from old through self to el
  2. Check idirs: if an existing trace's direction falls between
     old and el, the inner lane is blocked
  3. Check odirs: similar check for the outer lane
  4. Yield (el, useInner, useOuter)
```

The cross product test uses `orient2d` from `robust-predicates` for exact arithmetic, matching the original Ruby's integer exactness.

### Inner and Outer Lanes

At each vertex, a trace can pass on the **inner lane** (closer to the vertex center, between existing traces) or the **outer lane** (outside all existing traces).

- **Inner lane**: Requires that the cut between the current vertex and each neighbor in the inner angle has sufficient capacity (squeeze check). Ensures traces don't physically overlap.
- **Outer lane**: Used when the inner lane is blocked (e.g., by an incident net or a cluster corner). Has different squeeze checks against the outer-angle neighbors.

When a trace switches from inner to outer (or vice versa) between consecutive vertices, it must cross the line segment between those vertices, which costs additional space.

### Cost Function

The path cost includes:

1. **Euclidean distance**: `hypot(w.x - v.x, w.y - v.y)`
2. **Squeeze penalty**: sum of squeeze strengths for all cuts in the inner (or outer) angle. A tight cut adds cost; an impossibly tight cut returns `MBD` (blocking the path)
3. **Lane switch penalty**: `AVD` (5000 units) added when `curRgt != prevRgt` (the trace switches sides)
4. **Border penalty**: `MBD` for routing through border or obstacle boundary vertices
5. **Distance shortcut**: if a shorter path through a nearby vertex exists, the cost is reduced (heuristic to help Dijkstra find better paths)

### Destination Check

When a vertex matching the destination terminal is popped from the queue:

1. Verify the tangent line from the predecessor doesn't touch any nearby vertex (collision check)
2. Reject overly long paths: if `distance > maxDetourFactor * directDistance`, return null
3. The path is accepted and reconstructed by backtracking through the `parents` map

### Path Reconstruction

Walking back from destination to source through the parents map:

```
For each step p in the path (dest -> ... -> source):
  parent = parents[p]
  parent.region.outer = outerLane[p]
  parent.region.lrTurn = (p.rgt == outerLane[p])
```

This records, for each intermediate region, which lane the trace used and which direction it turned. These values are critical for the subsequent region splitting.

---

## 5. Phase 3: Region Splitting

This is the core topological mechanism that prevents future traces from crossing the current one.

### The Concept

When a trace passes through an intermediate vertex, that vertex's region is split into two halves:

```
Before:           After splitting along trace A->C->B:
                        /D
  D    E            r1(C)   E
   \  /              /  \  /
    C       --->    /    r2(C)
   / \             /      \
  A   B           A        B
```

- **r1** gets the neighbors on one side of the path (e.g., D)
- **r2** gets the neighbors on the other side (e.g., E)
- Both r1 and r2 keep connections to the previous and next vertices in the path (A and B)
- One of r1/r2 is marked as non-incident (can't serve as an endpoint)

### The `full_split_neighbor_list` Function

Determines which neighbors go to which side:

```
Given path: prv -> cur -> nxt
For each neighbor el of cur (except prv and nxt):
  Compute cross products to determine if el is on the
  left or right of the directed path prv->cur->nxt
  Left neighbors -> ne_comp (go to r2)
  Right neighbors -> ne (go to r1)
```

### Offset Computation

When a region is split, the two halves share the same underlying vertex position. To distinguish them in future cross-product tests, each half gets a small perpendicular offset:

```
Path direction: prv -> cur -> nxt
Perpendicular: rotate direction 90 degrees
r1.offset = cur.offset + perpendicular * (g/2)
r2.offset = cur.offset - perpendicular * (g/2)
```

The offset magnitude `g` halves with each successive split, ensuring offsets don't grow unbounded.

### Direction Recording (idirs/odirs)

At the first and last vertices of the path (which are NOT split, since they're endpoints):

```
first.idirs.push(direction from first toward second vertex)
last.idirs.push(direction from last toward second-to-last vertex)
```

These recorded directions tell future `qbors()` calls that certain angular ranges are occupied by existing traces.

### Incident Flag

After splitting, one half is marked non-incident. The choice depends on `lrTurn` and `outer`:

```
if (cur.lrTurn != cur.outer):
    r1.incident = false   // r1 is on the trace's side
else:
    r2.incident = false   // r2 is on the trace's side
```

This prevents future nets from terminating in a region that's "behind" an existing trace.

### Cut Usage

After path reconstruction, the cuts along the path are "used" — their free capacity is reduced:

```
For each intermediate vertex v in the path:
  For each neighbor in the inner (or outer) angle:
    cut[v, neighbor].use(traceWidth, traceClearance)
```

This ensures future squeeze calculations account for the space occupied by this trace.

---

## 6. Phase 4: Rubberband Optimization

After all nets are routed topologically, the traces follow the CDT edges through intermediate vertices. The rubberband optimization **tightens** these traces by:

1. Computing proper tangent lines between circles at each waypoint
2. Adjusting the concentric ring radii for overlapping traces
3. Collapsing unnecessary concave bends

### `sortAttachedNets`

At each vertex with multiple attached traces, the traces are sorted by their angular direction. Traces that overlap (share the same prev/next vertices) are fine-sorted by "walking" along their paths and comparing the turn angles at successive waypoints. This determines the concentric ring ordering.

The fine sort uses a relation map keyed by unique Step UIDs (not path IDs, which can collide) to track pairwise ordering between overlapping traces.

### `prepareSteps`

Computes the radius for each step at each vertex:

```
For each vertex with attached nets:
  Reset to core radius
  For each attached step (convex first, then concave):
    traceSep = max(vertex.separation, net.traceClearance)
    vertex.radius += traceSep + net.traceWidth
    step.radius = vertex.radius - net.traceWidth / 2
    vertex.separation = net.traceClearance
```

Each successive trace gets a larger radius, forming concentric rings.

### `nubly` (Rubberband)

The main rubberband function. Iterates until no more changes:

**Without collapse** (`nubly(false)`):
- For each attached step, check if the radius difference to adjacent steps is consistent with the distance. If a step's radius is too small relative to its neighbors, increase it.
- Compute `convex_kkk`: check if the tangent lines from prev and next cross. If they do, mark the step as concave (`xt = true`).

**With collapse** (`nubly(true)`):
- For concave steps (where tangents cross), the step can be removed. The trace is rerouted to connect prev directly to next.
- The collapse uses the Apollonius convex hull to find replacement vertices: vertices in the collapse region that the trace must go around due to their physical size.
- `smartReplace` removes the old step and inserts the replacement vertices as new steps.

### `convex_kkk`

Tests whether the incoming and outgoing tangent lines at a step cross each other:

```
Tangent 1: from prev to current vertex (using prev's radius and rgt)
Tangent 2: from current vertex to next (using next's radius and rgt)
If these two line segments intersect: the bend is concave and can be collapsed
```

---

## 7. Phase 5: Crossing Pair Mitigation

Even with correct topological routing, the geometric rendering can produce visual crossings due to the tangent-line geometry. The `fixCrossingPairs` post-processor addresses this:

For each vertex with multiple attached traces:
1. Compute all tangent segments for each pair of traces
2. Count segment-segment intersections between traces from different nets
3. If crossings exist, try swapping the radii (ring positions) of the two traces
4. If the swap reduces crossings, keep it; otherwise revert
5. Iterate until no more improvements

This is purely a geometric fix — it doesn't change the topological ordering, only the concentric ring assignment. It resolves cases where the `sortAttachedNets` fine-sort produces a suboptimal ordering.

---

## 8. Phase 6: Trace Rendering

### Tangent Lines Between Circles

Each trace segment between two waypoints is rendered as a **tangent line between two circles**:

```
Circle 1: center = prev vertex, radius = prev step's radius
Circle 2: center = next vertex, radius = next step's radius
Tangent type determined by rgt flags of both steps
```

The `getTangents` function computes the external or internal tangent line:

```
d = distance between centers
vx, vy = unit vector from center1 to center2
r2 *= (l1 == l2) ? 1 : -1    // external vs internal tangent
c = (r1 - r2) / d
h = sqrt(1 - c^2) * (l1 ? -1 : 1)
nx = vx*c - h*vy
ny = vy*c + h*vx
Result: [x1+r1*nx, y1+r1*ny, x2+r2*nx, y2+r2*ny]
```

### Arc Segments

At each intermediate vertex, an arc connects the endpoint of the incoming tangent to the start of the outgoing tangent:

```
startAngle = atan2(incoming tangent end - center)
endAngle = atan2(outgoing tangent start - center)
If rgt is false: swap start and end angles
Draw the shorter arc between these angles
```

---

## 9. Polygonal Obstacles

### Box Drawing and Merging

Users can draw rectangular obstacles. Overlapping rectangles are merged into complex polygons using the `@flatten-js/core` library's boolean union operation:

```
merged = box1 UNION box2 UNION box3 ...
```

The result is a set of non-overlapping polygons with holes.

### Boundary Sampling

Each polygon edge is sampled with vertices at regular intervals (~5000 units). These boundary vertices are:

1. Inserted into the CDT with a shared cluster ID
2. Connected by CDT constraint edges along the polygon boundary
3. Named `obstacle_boundary` and penalized with `MBD` cost in Dijkstra

### Interior Edge Blocking

After CDT triangulation, edges that fall inside constrained polygons are marked in `edgesInCluster`. The Dijkstra skips these edges (line: `if (edgesInCluster.has(v.vertex, w.vertex)) return`), preventing traces from routing through obstacle interiors.

### Pin Projection

If a terminal pin falls inside a polygon obstacle, it's automatically projected to the nearest point on the polygon boundary (plus a small outward offset) so the router can still reach it.

---

## 10. Key Geometric Primitives

### Cross Product with Exact Arithmetic

The most critical geometric test. Uses `orient2d` from `robust-predicates` for exact results:

```
orient2d(ox, oy, ax, ay, bx, by)
```

Returns positive if `o->a->b` is counterclockwise, negative if clockwise, zero if collinear. The sign convention is inverted from the Ruby original's `(a-o) x (b-o)`, so we check `< 0` instead of `> 0`.

For collinear points, a consistent tiebreaker is used: `(ax-ox) < (bx-ox)` or `(ay-oy) < (by-oy)`.

### Squeeze Strength

Measures how tight a cut (gap between two adjacent vertices) is:

```
If no traces pass through this cut:
  space = freeCap - traceWidth - clearance_sum
If traces already pass:
  Compute worst-case clearance arrangement
  space = freeCap - traceWidth - total_clearances

If space < 0: return MBD (blocked)
Else: return 10 * AVD * ATW / (ATW + space * 2)
```

The result approaches 0 for wide-open cuts and MBD for impossibly tight ones.

### Normal Distance (Line Segment to Point)

Used to check if a trace's tangent line passes too close to a vertex:

```
Project point onto line segment
If projection falls within segment: return squared distance
Else: return MBD (not a normal intersection)
```

---

## 11. Correctness Guarantees and Limitations

### What the Algorithm Guarantees

1. **Topological non-crossing**: If the Dijkstra finds a path, the region splitting ensures future traces cannot cross it. This is guaranteed by construction: split regions have disjoint neighbor sets, so future paths are forced to one side or the other.

2. **Physical clearance**: The squeeze strength calculation ensures traces have sufficient space in each cut they pass through.

3. **Rubberband optimality**: After optimization, traces are locally taut — they follow the shortest path that respects the topological constraints.

### Limitations

1. **Net ordering sensitivity**: The order in which nets are routed affects the result. Shorter nets are routed first (by distance), but this heuristic isn't globally optimal. A net routed early may block a better arrangement for later nets.

2. **No rip-up and retry**: Once a net is routed, it's permanent. The original Salewski code has a basic retry mechanism (retry failed nets with a higher detour factor), but doesn't rip up successful routes to make room for failed ones.

3. **Rubberband collapse precision**: The `nubly(true)` collapse removes concave waypoints. Without the full CGAL Apollonius graph, the replacement vertex selection is approximate, which can occasionally produce suboptimal results.

4. **Geometric vs topological crossings**: The tangent-line rendering can produce visual crossings even when the topological paths don't cross. The `fixCrossingPairs` post-processor mitigates this but doesn't eliminate all cases.

5. **Single-layer**: This implementation handles a single routing layer. The original Salewski code includes layer assignment for multi-layer PCBs, which is not ported here.

---

## References

1. **Tal Dayan**, "The Rubberband Approach to Topological Routing" (PhD thesis, UC Santa Cruz, 1997)
2. **Stefan Salewski**, [PCB Routing](https://www.ssalewski.de/Router.html.en) (Ruby implementation, 2015)
3. **Anthony Blake**, gEDA PCB Toporouter (C implementation based on Dayan's thesis, Google Summer of Code)
4. **Jonathan Richard Shewchuk**, [Robust Predicates for Computational Geometry](https://www.cs.cmu.edu/~quake/robust.html) (used via `robust-predicates` npm package)
5. **Mikola Lysenko**, [cdt2d](https://github.com/mikolalysenko/cdt2d) (Constrained Delaunay Triangulation)
6. **Alex Bol**, [@flatten-js/core](https://github.com/nicknash/flatten-js) (Boolean operations for polygon merging)
