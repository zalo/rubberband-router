# Rubberband Topological Router

A TypeScript port of [Stefan Salewski's rubberband topological PCB router](https://www.ssalewski.de/Router.html.en), with an interactive browser-based interface.

The algorithm is based on the region concept described in [Tal Dayan's 1997 PhD thesis](http://www.delorie.com/archives/browse.cgi?p=geda-user/2015/10/11/08:56:15) for generating rubber band sketches that connect terminal points without crossing.

**[Live Demo](https://zalo.github.io/rubberband-router/)**

## How it works

1. **Constrained Delaunay Triangulation** builds the routing graph from terminal positions using [cdt2d](https://github.com/mikolalysenko/cdt2d)
2. **Dijkstra shortest path search** with inner/outer lane tracking finds non-crossing routes through the triangulation, using [robust-predicates](https://github.com/mourner/robust-predicates) for exact geometric decisions
3. **Region splitting** divides the graph along each routed trace, topologically preventing future traces from crossing existing ones
4. **Rubberband optimization** (sort, prepare, nubly) tightens traces and collapses concave bends using weighted convex hull computation
5. **Crossing pair mitigation** post-processes any remaining geometric overlaps by swapping radial ordering at shared vertices

## Features

- Place terminals and obstacles by clicking
- Connect terminals to define nets
- 5 built-in presets (parallel, crossing, star, 4x4 grid, 6x6 grid)
- Random layout generation with configurable pin/net counts
- Adjustable trace width, clearance, and pin radius
- Delaunay triangulation overlay
- Ruby reference output for comparison
- Keyboard shortcuts (1-4 for tools, R to route, G to generate, T to toggle triangulation)

## Algorithm details

The router implements the full Salewski algorithm:

- **NetDesc / Step / Region / Cut** data structures matching the original Ruby
- **qbors()** directional neighbor filtering with idirs/odirs constraints
- **Full Dijkstra** with squeeze strength cost, inner/outer lane tracking, blocking vertex relaxation, and distance shortcut optimization
- **Region splitting** with offset computation for split region identification
- **sortAttachedNets** with group-based fine sorting by trace following
- **nubly** rubberband optimization with concave collapse via Apollonius convex hull
- **Tangent-based rendering** with arc segments at waypoint vertices

## Development

```bash
npm install
npm run dev      # Start dev server
npm run build    # Production build
```

## Original work

The original Ruby implementation is by [Dr. Stefan Salewski](https://www.ssalewski.de/Router.html.en) (Version 0.21, 29-DEC-2015). It uses CGAL for constrained Delaunay triangulation and Apollonius graphs, and Boost for Fibonacci queues. This TypeScript port replaces those C++ dependencies with pure JavaScript equivalents.

Key references:
- [Tal Dayan, "The Rubberband Approach to Topological Routing" (PhD thesis, 1997)](http://www.delorie.com/archives/browse.cgi?p=geda-user/2015/10/11/08:56:15)
- [Stefan Salewski, "PCB Routing"](https://www.ssalewski.de/Router.html.en)
- [gEDA PCB Toporouter](https://github.com/bert/pcb/wiki/Autorouters:-gEDA-pcb-Toporouter) (Anthony Blake's C implementation based on the same thesis)

## License

GPL-2.0 (same as the original Ruby implementation)
