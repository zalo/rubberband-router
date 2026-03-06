#!/usr/bin/env ruby
# End-to-end test of Dijkstra + region splitting WITHOUT C extensions
# Creates a manual triangulation and routes nets through it
require 'json'
require 'set'

# Minimal reimplementation of key classes (no CGAL/Boost dependencies)

module RBR
  MBD = (2 ** 30 - 2 ** 24)
  AVD = 5000
  ATW = 1000
  Trace_Width = 1200
  Clearance = 800
  Pin_Radius = 1000

  def self.boolean_really_smart_cross_product_2d_with_offset(ax, ay, bx, by, ox, oy)
    ax -= ox; ay -= oy; bx -= ox; by -= oy
    if (p = ax * by - ay * bx) != 0
      p > 0
    else
      ax != bx ? ax < bx : ay < by
    end
  end

  # xboolean: uses rx/ry for a,b and vertex.x/y for o
  def self.xboolean(arx, ary, brx, bry, ox, oy)
    boolean_really_smart_cross_product_2d_with_offset(arx, ary, brx, bry, ox, oy)
  end

  class Vertex
    attr_accessor :id, :x, :y, :name, :cid, :core, :radius, :separation
    attr_accessor :neighbors, :incident_nets, :attached_nets, :num_inets
    @@next_id = 0
    def initialize(x, y, r = Pin_Radius, c = Clearance)
      @id = @@next_id; @@next_id += 1
      @x = x; @y = y; @core = r; @radius = r; @separation = c
      @cid = -1; @name = ''; @num_inets = 0
      @neighbors = []; @incident_nets = []; @attached_nets = []
    end
    def self.reset; @@next_id = 0; end
    def xy; [x, y]; end
  end

  class Region
    attr_accessor :vertex, :neighbors, :incident, :outer, :g, :ox, :oy, :rx, :ry
    attr_accessor :lr_turn, :idirs, :odirs, :region_id
    @@next_rid = 0
    def initialize(v)
      @region_id = @@next_rid; @@next_rid += 1
      @g = 1; @ox = @oy = 0; @vertex = v; @rx = v.x; @ry = v.y
      @neighbors = []; @incident = true; @outer = false
      @idirs = []; @odirs = []
    end
    def self.reset; @@next_rid = 0; end

    def qbors(old)
      if old
        ox = self.vertex.x; oy = self.vertex.y
        ax = old.rx - ox; ay = old.ry - oy
        @neighbors.each{|el|
          next if el == old
          bx = el.rx - ox; by = el.ry - oy
          turn = RBR::xboolean(old.rx, old.ry, el.rx, el.ry, self.vertex.x, self.vertex.y)
          inner = true; outer = self.incident
          unless self.odirs.empty?
            outer = true
            self.odirs.each{|zx, zy|
              if turn
                j = ax * zy >= ay * zx && bx * zy <= by * zx
              else
                j = ax * zy <= ay * zx && bx * zy >= by * zx
              end
              break unless (outer &&= j)
            }
            inner = !outer
          end
          self.idirs.each{|zx, zy|
            if turn
              j = ax * zy >= ay * zx && bx * zy <= by * zx
            else
              j = ax * zy <= ay * zx && bx * zy >= by * zx
            end
            if j
              inner = false
            else
              outer = false
            end
            next unless inner || outer
          }
          yield [el, inner, outer]
        }
      else
        @neighbors.each{|el| yield [el, true, true]}
      end
    end
  end

  class NetDesc
    attr_accessor :id, :t1_name, :t2_name, :trace_width, :trace_clearance, :pri
    @@next_id = 0
    def initialize(t1, t2, tw = Trace_Width, tc = Clearance)
      @id = @@next_id; @@next_id += 1
      @t1_name = t1; @t2_name = t2; @trace_width = tw; @trace_clearance = tc; @pri = 0
    end
  end

  class Cut
    attr_accessor :cap, :free_cap, :cv1, :cv2, :cl
    def initialize(v1, v2)
      @cap = Math.hypot(v1.x - v2.x, v1.y - v2.y)
      @free_cap = @cap - v1.core - v2.core
      @cv1 = Clearance; @cv2 = Clearance; @cl = []
    end
    def squeeze_strength(tw, tc)
      if @cl.empty?
        s = (@cv1 < @cv2 && @cv1 < tc ? @cv2 + tc : (@cv2 < tc ? @cv1 + tc : @cv1 + @cv2))
      else
        @cl.push(tc)
        ll = @cl.length / 2
        hhh = @cl.sort.reverse[0..ll] * 2
        hhh.pop if @cl.length.even?
        hhh.push(@cv1, @cv2); hhh.sort!; hhh.shift(2)
        s = hhh.inject(0){|sum, v| sum + v}
        @cl.pop
      end
      s = @free_cap - tw - s
      s < 0 ? MBD : 10 * AVD * ATW / (ATW + s * 2)
    end
    def use(tw, tc); @free_cap -= tw; @cl << tc; end
  end

  class SymmetricHash < Hash
    def [](a, b)
      a.object_id < b.object_id ? super([a, b]) : super([b, a])
    end
    def []=(a, b, c)
      a.object_id < b.object_id ? super([a, b], c) : super([b, a], c)
    end
    def include?(a, b)
      a.object_id < b.object_id ? super([a, b]) : super([b, a])
    end
  end
end

# Create a simple 5-vertex test case:
#    v2
#   / | \
#  v0-v4-v1
#   \ | /
#    v3
# Two nets: v0->v1 and v2->v3 (they must cross or go around)

RBR::Vertex.reset
RBR::Region.reset

v = []
# 5 vertices in a diamond pattern
coords = [[0, 5000], [10000, 5000], [5000, 0], [5000, 10000], [5000, 5000]]
coords.each_with_index{|(x, y), i|
  vt = RBR::Vertex.new(x, y)
  vt.name = "V#{i}"
  v << vt
}

# Set up triangulation edges manually (diamond graph)
edges = [[0,2],[0,3],[0,4],[1,2],[1,3],[1,4],[2,4],[3,4]]
edges.each{|a, b|
  v[a].neighbors << v[b] unless v[a].neighbors.include?(v[b])
  v[b].neighbors << v[a] unless v[b].neighbors.include?(v[a])
}

# Create regions
regions = v.map{|vt| RBR::Region.new(vt)}

# Set up region neighbors from edges
edges.each{|a, b|
  regions[a].neighbors << regions[b] unless regions[a].neighbors.include?(regions[b])
  regions[b].neighbors << regions[a] unless regions[b].neighbors.include?(regions[a])
}

# Create cuts
cuts = RBR::SymmetricHash.new
v.each{|vi| vi.neighbors.each{|vj| cuts[vi, vj] = RBR::Cut.new(vi, vj) unless cuts.include?(vi, vj)}}

# Helper: get tangents
def get_tangents(x1, y1, r1, l1, x2, y2, r2, l2)
  d = Math.hypot(x1-x2, y1-y2)
  return [x1,y1,x2,y2] if d == 0
  vx = (x2-x1)/d; vy = (y2-y1)/d
  r2 *= (l1 == l2 ? 1 : -1)
  c = (r1-r2)/d; h = [1-c**2, 0].max
  h = Math.sqrt(h) * (l1 ? -1 : 1)
  nx = vx*c - h*vy; ny = vy*c + h*vx
  [x1+r1*nx, y1+r1*ny, x2+r2*nx, y2+r2*ny]
end

def normal_dist_sq(bx, by, cx, cy, px, py, mbd)
  mx=cx-bx; my=cy-by; hx=px-bx; hy=py-by
  t0 = (mx*hx+my*hy).fdiv(mx**2+my**2)
  t0 > 0 && t0 < 1 ? (hx-t0*mx)**2+(hy-t0*my)**2 : mbd
end

# new_bor_list
def new_bor_list(a, b, n)
  av, bv, nv = a.vertex, b.vertex, n.vertex
  ax = av.x - nv.x; ay = av.y - nv.y
  bx = bv.x - nv.x; by = bv.y - nv.y
  turn = RBR::xboolean(a.rx, a.ry, b.rx, b.ry, nv.x, nv.y)
  nv.neighbors.select{|el|
    next false if el == av || el == bv
    ex = el.x - nv.x; ey = el.y - nv.y
    turn ? (ax*ey > ay*ex && ex*by > ey*bx) : (ax*ey < ay*ex && ex*by < ey*bx)
  }
end

# full_split_neighbor_list
def full_split(a, b, n)
  l = []; r = []
  nx = n.vertex.x; ny = n.vertex.y
  v1x = a.rx-nx; v1y = a.ry-ny; v2x = b.rx-nx; v2y = b.ry-ny
  turn = RBR::xboolean(a.rx, a.ry, b.rx, b.ry, nx, ny)
  n.neighbors.each{|el|
    next if el == a || el == b
    ex = el.rx-nx; ey = el.ry-ny
    if (turn ? v1x*ey > v1y*ex && v2x*ey < v2y*ex : v1x*ey > v1y*ex || v2x*ey < v2y*ex)
      l << el
    else
      r << el
    end
  }
  [r, l]
end

# Simple Dijkstra (minimal, no squeeze/blocked checks for clarity)
def simple_dijkstra(start_node, end_name, regions, cuts, net_desc)
  # Use simple priority queue
  q = {} # key => distance
  parents = {}
  distances = {}
  outer_lane = {}
  key_to_reg = {}

  start_cid = start_node.vertex.cid
  sx, sy = start_node.vertex.xy

  distances[[start_node, nil, true]] = 0
  distances[[start_node, nil, false]] = 0

  start_node.qbors(nil){|w, ui, uo|
    dist = Math.hypot(w.vertex.x - sx, w.vertex.y - sy)
    u = [w, start_node, false]; v = [w, start_node, true]
    q[u] = q[v] = dist
    parents[u] = parents[v] = [start_node, nil, false]
  }

  log = []
  iteration = 0

  while !q.empty?
    min = q.min_by{|k, v| v}[0]
    old_distance = q.delete(min)
    v, uu, prev_rgt = *min

    next unless uu # skip nil predecessor entries

    # Check destination
    if v.vertex.name == end_name && v.incident
      log << {iter: iteration, event: 'found', vertex: v.vertex.name, dist: old_distance}
      # Reconstruct path
      path = []
      p = min
      while p
        if n = parents[p]
          n[0].outer = outer_lane[p]
          n[0].lr_turn = p[2] == outer_lane[p]
        end
        path << p[0]
        p = parents[p]
      end
      return {path: path.map{|r| r.vertex.name}, log: log, path_length: path.length}
    end

    distances[min] = old_distance
    x, y = v.vertex.xy

    # Path set for loop prevention
    path_set = Set.new
    p = min
    while p
      path_set << p[0]
      p = parents[p]
    end

    # Explore neighbors
    v.qbors(uu){|w, use_inner, use_outer|
      next if path_set.include?(w)

      lr_turn = RBR::xboolean(uu.rx, uu.ry, w.rx, w.ry, v.vertex.x, v.vertex.y)
      cur_rgt = lr_turn
      w_v_rgt = [w, v, cur_rgt]
      w_v_xrgt = [w, v, !cur_rgt]

      new_distance = old_distance + Math.hypot(w.vertex.x - x, w.vertex.y - y)

      # Inner path
      if use_inner && !distances.include?(w_v_rgt)
        if !q.include?(w_v_rgt) || q[w_v_rgt] > new_distance
          nd = new_distance
          nd += RBR::AVD if cur_rgt != prev_rgt
          q[w_v_rgt] = nd
          outer_lane[w_v_rgt] = false
          parents[w_v_rgt] = min
          log << {iter: iteration, event: 'inner', from: v.vertex.name, to: w.vertex.name, rgt: cur_rgt, dist: nd}
        end
      end

      # Outer path
      if use_outer && !distances.include?(w_v_xrgt)
        nd = new_distance
        nd += RBR::AVD if !cur_rgt != prev_rgt
        if !q.include?(w_v_xrgt) || q[w_v_xrgt] > nd
          q[w_v_xrgt] = nd
          outer_lane[w_v_xrgt] = true
          parents[w_v_xrgt] = min
          log << {iter: iteration, event: 'outer', from: v.vertex.name, to: w.vertex.name, rgt: !cur_rgt, dist: nd}
        end
      end
    }
    iteration += 1
  end

  {path: nil, log: log}
end

# Run test: route V0->V1
nd1 = RBR::NetDesc.new('V0', 'V1')
result1 = simple_dijkstra(regions[0], 'V1', regions, cuts, nd1)

# Now do region splitting for the first path (if found)
split_log = []
if result1[:path]
  path_regions = result1[:path].map{|name| regions.find{|r| r.vertex.name == name}}

  first = path_regions[-1]
  last = path_regions[0]

  if path_regions.length > 2
    first.idirs << [path_regions[-2].rx - first.vertex.x, path_regions[-2].ry - first.vertex.y]
    last.idirs << [path_regions[1].rx - last.vertex.x, path_regions[1].ry - last.vertex.y]
    split_log << {first_idirs: first.idirs.length, last_idirs: last.idirs.length}
  end

  # Split intermediate regions
  r1 = r2 = nil
  reversed = path_regions.reverse
  reversed.each_cons(3){|prv, cur, nxt|
    ne, ne_comp = full_split(prv, nxt, cur)
    ne << nxt; ne_comp << nxt
    if r1
      ne.delete(r2)
      ne_comp.delete(r1)
    else
      ne << prv; ne_comp << prv
    end

    regions.delete(cur)
    r1 = RBR::Region.new(cur.vertex)
    r2 = RBR::Region.new(cur.vertex)
    r1.idirs = cur.idirs.dup; r2.idirs = cur.idirs.dup
    r1.odirs = cur.odirs.dup; r2.odirs = cur.odirs.dup
    r1.incident = r2.incident = cur.incident

    # Offset computation for first/last split
    dx1 = dy1 = dx2 = dy2 = 0
    if prv == reversed[0]  # first in reversed = first of original
      dx2 = cur.rx - prv.rx; dy2 = cur.ry - prv.ry
      h = Math.hypot(dx2, dy2); dx2 /= h; dy2 /= h
    end
    if nxt == reversed[-1]  # last in reversed
      dx1 = nxt.rx - cur.rx; dy1 = nxt.ry - cur.ry
      h = Math.hypot(dx1, dy1); dx1 /= h; dy1 /= h
    end
    if prv == reversed[0] || nxt == reversed[-1]
      r1.g = r2.g = cur.g * 0.5
      dy = dx1 + dx2; dx = -(dy1 + dy2)
      h = Math.hypot(dx, dy) / cur.g
      if h > 0
        dx /= h; dy /= h
        r1.ox = cur.ox + dx; r1.oy = cur.oy + dy
        r2.ox = cur.ox - dx; r2.oy = cur.oy - dy
      else
        r1.ox = cur.ox; r1.oy = cur.oy; r2.ox = cur.ox; r2.oy = cur.oy
      end
      r1.rx = r1.vertex.x + r1.ox; r1.ry = r1.vertex.y + r1.oy
      r2.rx = r2.vertex.x + r2.ox; r2.ry = r2.vertex.y + r2.oy
    else
      r1.ox = cur.ox; r1.oy = cur.oy; r2.ox = cur.ox; r2.oy = cur.oy
      r1.rx = cur.rx; r1.ry = cur.ry; r2.rx = cur.rx; r2.ry = cur.ry
    end

    regions << r1 << r2
    cur.neighbors.each{|el| el.neighbors.delete(cur)}
    ne.each{|el| el.neighbors << r1; r1.neighbors << el}
    ne_comp.each{|el| el.neighbors << r2; r2.neighbors << el}

    if cur.lr_turn != cur.outer
      r1.incident = false
    else
      r2.incident = false
    end

    split_log << {
      split_vertex: cur.vertex.name,
      r1_id: r1.region_id, r1_neighbors: r1.neighbors.map{|r| "#{r.vertex.name}(#{r.region_id})"},
      r2_id: r2.region_id, r2_neighbors: r2.neighbors.map{|r| "#{r.vertex.name}(#{r.region_id})"},
      r1_incident: r1.incident, r2_incident: r2.incident,
      r1_rx: r1.rx.round(2), r1_ry: r1.ry.round(2),
      r2_rx: r2.rx.round(2), r2_ry: r2.ry.round(2),
    }
  }

  # Now route V2->V3 (should go around the first trace)
  result2 = simple_dijkstra(
    regions.find{|r| r.incident && r.vertex.name == 'V2'},
    'V3', regions, cuts, RBR::NetDesc.new('V2', 'V3')
  )
  split_log << {second_route_path: result2[:path], second_route_length: result2[:path_length]}
end

output = {
  vertices: v.map{|vt| {id: vt.id, name: vt.name, x: vt.x, y: vt.y}},
  first_route: result1,
  split_log: split_log,
  total_regions: regions.length,
  region_details: regions.map{|r| {
    rid: r.region_id, vertex: r.vertex.name, incident: r.incident,
    neighbors: r.neighbors.map{|n| "#{n.vertex.name}(#{n.region_id})"},
    idirs: r.idirs.length, rx: r.rx.round(2), ry: r.ry.round(2)
  }}
}

puts JSON.pretty_generate(output)
