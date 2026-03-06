#!/usr/bin/env ruby
# file: router_ruby.rb
# Self-contained pure-Ruby rubberband topological router.
# Ported from Stefan Salewski's original router.rb / rsupport.rb.
# No C extensions (CGAL, Boost, Cairo) required.
# Input/output via JSON.
#
# Usage:
#   ruby router_ruby.rb < input.json > output.json
#
# Input JSON format:
# {
#   "vertices": [
#     { "id": 0, "name": "U1_1", "x": 1000, "y": 2000, "core": 500, "radius": 500,
#       "separation": 800, "cid": -1, "neighbors": [1, 2, 3] }
#   ],
#   "nets": [
#     { "from": "U1_1", "to": "U1_2", "trace_width": 1200, "trace_clearance": 800 }
#   ],
#   "edges_in_cluster": [[0, 1], [2, 3]]   // optional
# }
#
# Output JSON format:
# {
#   "routed": [true, false, ...],
#   "paths": [
#     {
#       "net_index": 0,
#       "vertices": [{"id":5,"x":...,"y":...}, ...],
#       "segments": [{"x1":..,"y1":..,"x2":..,"y2":..,"width":..}],
#       "arcs": [{"cx":..,"cy":..,"r":..,"startAngle":..,"endAngle":..,"width":..}]
#     }
#   ]
# }

require 'json'
require 'set'

$glob = 0

module RBR

@@one = 1
@@two = 2

Maximum_Board_Diagonal = MBD = (2 ** 30 - 2 ** 24)
Average_Via_Diameter = AVD = 50_00
Average_Trace_Width = ATW = 10_00
Board_Size = 800

PCB_Size = 140000
Points = 64
Pin_Radius = 1000
Trace_Width = 1200
Clearance = 800
MinCutSize = 6000

	def self.init_seed
		seed = (ARGV[0] ? ARGV[0].to_i : rand(1000))
		srand(seed)
		seed
	end

	#       b
	#      ^
	#     /
	# o/--------> a
	#
	def self.boolean_really_smart_cross_product_2d_with_offset(a, b, o)
		a = a.vertex if a.is_a? RBR::Region
		b = b.vertex if b.is_a? RBR::Region
		o = o.vertex if o.is_a? RBR::Region
		ax = a.x
		ay = a.y
		bx = b.x
		by = b.y
		ox = o.x
		oy = o.y
		fail if ax == bx && ay == by
		ax -= ox
		ay -= oy
		bx -= ox
		by -= oy
		fail if (ax == 0 && ay == 0) || (bx == 0 && by == 0)
		if (p = ax * by - ay * bx) != 0
			p > 0
		else
			ax != bx ? ax < bx : ay < by
		end
	end

	def self.xboolean_really_smart_cross_product_2d_with_offset(a, b, o)
		ax = a.vertex.x + a.ox
		ay = a.vertex.y + a.oy
		bx = b.vertex.x + b.ox
		by = b.vertex.y + b.ox # NOTE: original has b.ox here (likely bug preserved)
		ox = o.vertex.x
		oy = o.vertex.y
		fail if ax == bx && ay == by
		ax -= ox
		ay -= oy
		bx -= ox
		by -= oy
		fail if (ax == 0 && ay == 0) || (bx == 0 && by == 0)
		if (p = ax * by - ay * bx) != 0
			p > 0
		else
			ax != bx ? ax < bx : ay < by
		end
	end

	def self.boolean_really_smart_cross_product_2d(ax, ay, bx, by)
		fail if ax == bx && ay == by
		fail if (ax == 0 && ay == 0) || (bx == 0 && by == 0)
		if (p = ax * by - ay * bx) != 0
			p > 0
		else
			ax != bx ? ax < bx : ay < by
		end
	end

# --- Priority Queue replacement for BOOST::Fibonacci_Queue ---
class MinPQ
	def initialize; @h = {}; end
	def []=(k, v); @h[k] = v; end
	def [](k); @h[k]; end
	def inc?(k, v)
		if !@h.include?(k) || v < @h[k]
			@h[k] = v; true
		else; false; end
	end
	def pop
		return nil, nil if @h.empty?
		k = @h.min_by{|_,v| v}[0]
		v = @h.delete(k)
		[k, v]
	end
	def empty?; @h.empty?; end
end

# --- Support ---
module RouterSupport
	class Hash_with_ordered_array_index < Hash
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

# Net connecting two terminals (2Net)
class NetDesc
	@@id = 0
	attr_accessor :t1_name, :t2_name
	attr_accessor :style_name
	attr_accessor :trace_width
	attr_accessor :trace_clearance
	attr_accessor :id
	attr_accessor :pri
	attr_accessor :flag
	def initialize(t1_name, t2_name, trace_width = Trace_Width, trace_clearance = Clearance)
		@id = @@id += 1
		@pri = 0
		@t1_name, @t2_name = t1_name, t2_name
		@trace_width, @trace_clearance = trace_width, trace_clearance
	end
	def self.reset_id; @@id = 0; end
end

class NetDescList < Array
end

# Incident or attached net of a terminal
class Step
	attr_accessor :id
	attr_accessor :net_desc
	attr_accessor :vertex
	attr_accessor :prev, :next
	attr_accessor :pstep, :nstep
	attr_accessor :a, :b, :d, :g, :dir
	attr_accessor :radius
	attr_accessor :score
	attr_accessor :index
	attr_accessor :ref
	attr_accessor :rgt
	attr_accessor :outer
	attr_accessor :xt
	attr_accessor :lr_turn

	def initialize(prev, nxt, id)
		@prev, @next, @id = prev, nxt, id
		@radius = 0
		@outer = false
	end
end

class Tex
	attr_accessor :x, :y
	def initialize(x, y)
		@x, @y = x, y
	end
end

# Terminal - pure Ruby replacement for CGAL::Vertex
class Vertex
	@@id = @@cid = 0
	attr_accessor :id
	attr_accessor :cid
	attr_accessor :vis_flag
	attr_accessor :core
	attr_accessor :radius
	attr_accessor :separation
	attr_accessor :neighbors
	attr_accessor :incident_nets
	attr_accessor :attached_nets
	attr_accessor :name
	attr_accessor :tradius, :trgt
	attr_accessor :outer
	attr_accessor :lr_turn
	attr_accessor :via
	attr_accessor :num_inets
	attr_accessor :x, :y

	def initialize(x = 0, y = 0, r = Pin_Radius, c = Clearance)
		@x, @y = x, y
		@num_inets = 0
		@via = false
		@tradius = 0
		@vis_flag = 0
		@id = @@id
		@cid = -1
		@@id += 1
		@radius = @core = r
		@separation = c
		@name = ''
		@neighbors = Array.new
		@incident_nets = Array.new
		@attached_nets = Array.new
	end

	def self.reset_class
		@@id = @@cid = 0
	end

	def self.begin_new_cluster
		@@cid += 1
	end

	def add_to_current_cluster
		@cid = @@cid
	end

	def xy
		return x, y
	end

	def reset_initial_size
		@radius, @separation = @core, Clearance
	end

	def resize
		reset_initial_size
		attached_nets.each{|step|
			net = step.net_desc
			trace_sep = [@separation, net.trace_clearance].max
			@radius += trace_sep + net.trace_width
			step.radius = @radius - net.trace_width * 0.5
			@separation = net.trace_clearance
		}
	end

	def unfriendly_resize
		cl = attached_nets.map{|step| step.net_desc.trace_clearance}
		@radius = @core + attached_nets.map{|step| step.net_desc.trace_width}.inject(0){|sum, el| sum + el}
		@radius += cl.permutation.map{|el| (el.push(@separation))}.map{|el| s = 0; el.each_cons(2){|a, b| s += [a,b].max}; s}.max
		@separation = cl.push(@separation).max
	end

	def update(s)
		net = s.net_desc
		trace_sep = [@separation, net.trace_clearance].max
		@radius += trace_sep + net.trace_width
		s.radius = @radius - net.trace_width * 0.5
		@separation = net.trace_clearance
	end

	def net(id)
		incident_nets.each{|s| return s if s.id == id}
		attached_nets.each{|s| return s if s.id == id}
		return nil
	end

	def new_delete_net(step)
		incident_nets.delete_if{|s| step == s}
		attached_nets.delete_if{|s| step == s}
		resize
	end

	def _full_angle(s)
		return nil unless s.next && s.prev
		v = s.vertex
		d = Math.atan2(s.next.y - v.y, s.next.x - v.x) - Math.atan2(v.y - s.prev.y, v.x - s.prev.x)
		if d < -Math::PI
			d += 2 * Math::PI
		elsif d > Math::PI
			d -= 2 * Math::PI
		end
		return d
	end

	def sort_attached_nets
		unless attached_nets.length < 2
			attached_nets.each{|n|
				fail unless n.vertex == self
				n.index = _full_angle(n) * (n.rgt ? 1 : -1)
			}
			attached_nets.sort_by!{|n| n.index}
			attached_nets.each_with_index{|n, i| n.index = i}
			shash = Hash.new
			attached_nets.each{|n|
				l = n.prev
				r = n.next
				n.net_desc.flag = 1
				if shash.has_key?([l, r])
					shash[[l, r]] << n
				elsif shash.has_key?([r, l])
					n.net_desc.flag = -1
					shash[[r, l]] << n
				else
					shash[[l, r]] = [n]
				end
			}
			shash.each_value{|group|
				if group.length > 1
					group.reverse!
					group.each{|el| el.ref = el}
					indices = Array.new
					group.each{|el| indices << el.index}
					indices.sort!
					rel = Hash.new
					[-1, 1].each{|direction|
						gr = group.dup
						final = true
						while gr.length > 1
							gr.map!{|el| (el.net_desc.flag == direction ? el.pstep : el.nstep)}
							gr.each{|el| el.ref = (el.net_desc.flag == direction ? el.nstep.ref : el.pstep.ref)}
							gr.each{|el| el.score = _full_angle(el)}
							unresolved_combinations = false
							gr.combination(2).each{|el|
								a, b = *el
								relation = rel[[a.ref, b.ref]]
								if !relation || relation.abs < 2
									if !a.score
										c = ((b.rgt == b.ref.rgt) ? 1 : -1)
									elsif !b.score
										c = ((a.rgt == a.ref.rgt) ? -1 : 1)
									else
										if (a.score * a.net_desc.flag - b.score * b.net_desc.flag).abs < 1e-6
											c = 0
										else
											c = ((a.score * (a.ref.rgt ? 1 : -1)) <=> (b.score * (b.ref.rgt ? 1 : -1)))
										end
									end
									if c != 0
										if final
											c *= 2
										end
										rel[[a.ref, b.ref]] = c
										rel[[b.ref, a.ref]] = -c
									else
										unresolved_combinations = true
									end
								end
							}
							break unless unresolved_combinations
							gr.keep_if{|el| el.next && el.prev}
						end
						fail if unresolved_combinations
						break if final
					}
					group.sort!{|a, b| rel[[a, b]]}
					group.each{|el| el.index = indices.shift}
				end
			}
			attached_nets.sort_by!{|el| -el.index}
		end
	end
end

class Region
	attr_accessor :vertex, :neighbors, :incident, :outer
	attr_accessor :g, :ox, :oy
	attr_accessor :rx, :ry
	attr_accessor :a
	attr_accessor :lr_turn
	attr_accessor :idirs
	attr_accessor :odirs

	def initialize(v)
		@g = 1
		@ox = @oy = 0
		@vertex = v
		@rx = v.x
		@ry = v.y
		@neighbors = Array.new
		@incident = true
		@outer = false
		@idirs = Array.new
		@odirs = Array.new
	end

	def qbors(old)
		if old
			ox = self.vertex.x
			oy = self.vertex.y
			ax = old.rx - ox
			ay = old.ry - oy
			@neighbors.each{|el|
				next if el == old
				bx = el.rx - ox
				by = el.ry - oy
				fail if old.vertex == el.vertex && self.idirs.empty?
				turn = RBR::xboolean_really_smart_cross_product_2d_with_offset(old, el, self)
				bx = el.rx - ox
				by = el.ry - oy
				inner = true
				outer = self.incident
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

	def distance_to(other)
		Math.hypot(@vertex.x - other.vertex.x, @vertex.y - other.vertex.y)
	end
end

class Cut
	attr_accessor :cap
	attr_accessor :free_cap
	attr_accessor :cv1, :cv2
	attr_accessor :cl
	def initialize(v1, v2)
		@cap = Math::hypot(v1.x - v2.x, v1.y - v2.y)
		@free_cap = @cap - v1.core - v2.core
		@cv1 = Clearance
		@cv2 = Clearance
		@cl = Array.new
	end

	def squeeze_strength(trace_width, trace_clearance)
		if @cl.empty?
			s = ((@cv1 < @cv2 && @cv1 < trace_clearance) ? @cv2 + trace_clearance : (@cv2 < trace_clearance ? @cv1 + trace_clearance : @cv1 + @cv2))
		else
			@cl.push(trace_clearance)
			ll = @cl.length / 2
			hhh = @cl.sort.reverse[0..ll] * 2
			hhh.pop if @cl.length.even?
			hhh.push(@cv1)
			hhh.push(@cv2)
			hhh.sort!
			hhh.shift(2)
			s = hhh.inject(0){|sum, v| sum + v}
			@cl.pop
		end
		s = @free_cap - trace_width - s
		s < 0 ? MBD : 10 * AVD * ATW / (ATW + s * 2)
	end

	def use(trace_width, trace_clearance)
		@free_cap -= trace_width
		@cl << trace_clearance
	end
end

class Router
	attr_accessor :filename
	attr_accessor :netlist
	attr_accessor :rstyles
	attr_accessor :edges_in_cluster
	attr_accessor :vertices
	attr_accessor :regions

	def initialize
		Vertex.reset_class
		NetDesc.reset_id
		@edges_in_cluster = RouterSupport::Hash_with_ordered_array_index.new
		@name_id = 0
		@path_ID = 0
		@vertices = Array.new
		@regions = Array.new
		@newcuts = RouterSupport::Hash_with_ordered_array_index.new
		# JSON output collectors
		@output_segments = {} # net_id => [{x1,y1,x2,y2,width}]
		@output_arcs = {}    # net_id => [{cx,cy,r,startAngle,endAngle,width}]
		@output_paths = {}   # net_id => [{id,x,y}]
		@routed = []
	end

	def next_name
		@name_id += 1
		return @name_id.to_s
	end

	# Build from JSON data - vertices already have neighbor info from CDT
	def build_from_json(data)
		verts = data["vertices"]
		nets = data["nets"]
		cluster_edges = data["edges_in_cluster"] || []

		# Create Vertex objects
		id_to_vertex = {}
		verts.each{|vd|
			v = Vertex.new(vd["x"].to_f, vd["y"].to_f, vd["core"].to_f, vd["separation"].to_f)
			# Override auto-assigned id with the one from JSON
			v.instance_variable_set(:@id, vd["id"])
			v.name = vd["name"] || ''
			v.cid = vd["cid"] || -1
			v.radius = vd["radius"].to_f if vd["radius"]
			v.via = vd["via"] || false
			v.num_inets = vd["num_inets"] || 0
			id_to_vertex[vd["id"]] = v
			@vertices << v
		}

		# Ensure Vertex @@id is past the max
		max_id = verts.map{|vd| vd["id"]}.max || 0
		Vertex.class_variable_set(:@@id, max_id + 1)

		# Build regions
		@vertices.each{|v| @regions << Region.new(v)}

		# Build neighbor relationships
		verts.each{|vd|
			v = id_to_vertex[vd["id"]]
			(vd["neighbors"] || []).each{|nid|
				n = id_to_vertex[nid]
				next unless n
				v.neighbors << n unless v.neighbors.include?(n)
			}
		}

		# Build region neighbor relationships and cuts
		@vertices.each{|v|
			r = @regions[find_region_index(v)]
			next unless r
			v.neighbors.each{|n|
				rn = find_region_for_vertex(n)
				next unless rn
				r.neighbors << rn unless r.neighbors.include?(rn)
				unless @newcuts.include?(v, n)
					@newcuts[v, n] = Cut.new(v, n)
				end
			}
		}

		# Store cluster edges
		cluster_edges.each{|pair|
			v1 = id_to_vertex[pair[0]]
			v2 = id_to_vertex[pair[1]]
			@edges_in_cluster[v1, v2] = true if v1 && v2
		}

		# Build netlist
		@netlist = NetDescList.new
		nets.each{|nd|
			net_desc = NetDesc.new(nd["from"], nd["to"],
				(nd["trace_width"] || Trace_Width).to_f,
				(nd["trace_clearance"] || Clearance).to_f)
			net_desc.pri = nd["pri"] || 0
			@netlist << net_desc
		}
	end

	def find_region_index(v)
		@regions.index{|r| r.vertex == v}
	end

	def find_region_for_vertex(v)
		@regions.find{|r| r.vertex == v && r.incident}
	end

	# --- Geometry helpers (from router.rb) ---

	def vertices_in_polygon(p_vertices, test_vertices)
		res = Array.new
		nm1 = p_vertices.length - 1
		test_vertices.each{|tp|
			ty = tp.y
			i = 0
			j = nm1
			c = false
			while i <= nm1
				if ((((p_vertices[i].y <= ty) && (ty < p_vertices[j].y)) ||
						 ((p_vertices[j].y <= ty) && (ty < p_vertices[i].y))) &&
						(tp.x < (p_vertices[j].x - p_vertices[i].x) * (ty - p_vertices[i].y) / (p_vertices[j].y - p_vertices[i].y) + p_vertices[i].x))
					c = !c
				end
				j = i
				i += 1
			end
			res << tp if c
		}
		res
	end

	def distance_line_point(x1, y1, x2, y2, x0, y0)
		x12 = x2 - x1
		y12 = y2 - y1
		(x12 * (y1 - y0) - (x1 - x0) * y12).abs / Math.hypot(x12, y12)
	end

	def distance_line_point_squared(x1, y1, x2, y2, x0, y0)
		x12 = x2 - x1
		y12 = y2 - y1
		(x12 * (y1 - y0) - (x1 - x0) * y12) ** 2 / (x12 ** 2 + y12 ** 2)
	end

	def unused_distance_line_segment_point_squared(bx, by, cx, cy, px, py)
		mx = cx - bx
		my = cy - by
		hx = px - bx
		hy = py - by
		t0 = (mx * hx + my * hy).fdiv(mx ** 2 + my ** 2)
		if t0 <= 0
		elsif t0 < 1
			hx -= t0 * mx
			hy -= t0 * my
		else
			hx -= mx
			hy -= my
		end
		return hx ** 2 + hy ** 2
	end

	def normal_distance_line_segment_point_squared(bx, by, cx, cy, px, py)
		mx = cx - bx
		my = cy - by
		hx = px - bx
		hy = py - by
		t0 = (mx * hx + my * hy).fdiv(mx ** 2 + my ** 2)
		if t0 > 0 && t0 < 1
			(hx - t0 * mx) ** 2 + (hy - t0 * my) ** 2
		else
			Maximum_Board_Diagonal
		end
	end

	def line_line_intersection(x1, y1, x2, y2, x3, y3, x4, y4)
		x2x1 = x2 - x1
		y2y1 = y2 - y1
		return nil if (d = (y4 - y3) * x2x1 - (x4 - x3) * y2y1) == 0
		ua = ((x4 - x3) * (y1 - y3) - (y4 - y3) * (x1 - x3)) / d
		ub = (x2x1 * (y1 - y3) - y2y1 * (x1 - x3)) / d
		[x1 + ua * x2x1, y1 + ua * y2y1, ua, ub]
	end

	P_IN = 1; P_ON = 0; P_OUT = -1; COLLINEAR = -2
	def unused_point_in_triangle(x1, y1, x2, y2, x3, y3, x, y)
		d  =  (y2 - y3) * (x1 - x3) + (x3 - x2) * (y1 - y3)
		return COLLINEAR if d == 0
		l1 = ((y2 - y3) * (x - x3) + (x3 - x2) * (y - y3)) / d
		l2 = ((y3 - y1) * (x - x3) + (x1 - x3) * (y - y3)) / d
		l3 = 1 - l1 - l2
		min, max = [l1, l2, l3].minmax
		if 0 <= min && max <= 1
			0 < min && max < 1 ? P_IN : P_ON
		else
			P_OUT
		end
	end

	# Simplified new_convex_vertices - without Apollonius graph
	# Returns vertices sorted by projection onto tangent line
	def new_convex_vertices(vertices, prev, nxt, hv1, hv2)
		fail if vertices.include?(prev) || vertices.include?(nxt)
		return vertices if vertices.empty?
		x1, y1, x2, y2 = get_tangents(prev.x, prev.y, prev.tradius, prev.trgt, nxt.x, nxt.y, nxt.tradius, nxt.trgt)
		# Sort by projection onto tangent line direction
		dx = x2 - x1
		dy = y2 - y1
		vertices.sort_by{|el| (el.x - x1) * dx + (el.y - y1) * dy}
	end

	# --- Dijkstra ---

	def dijkstra(start_node, end_node_name, net_desc, max_detour_factor = 2)
		fail unless start_node.is_a? RBR::Region
		fail unless end_node_name.is_a? String
		fail unless net_desc.is_a? NetDesc
		fail if end_node_name.empty?
		fail if start_node.vertex.name == end_node_name
		q = MinPQ.new
		distances = Hash.new
		parents = Hash.new
		outer_lane = Hash.new
		distances[[start_node, nil, true]] = 0
		distances[[start_node, nil, false]] = 0
		x, y = start_node.vertex.xy
		start_cid = start_node.vertex.cid
		start_node.qbors(nil) do |w, use_inner, use_outer|
			u = [w, start_node, false]
			v = [w, start_node, true]
			dist = ((start_cid != -1) && (w.vertex.cid == start_cid) ? 0 : Math.hypot(w.vertex.x - x, w.vertex.y - y))
			q.inc?(u, dist)
			q.inc?(v, dist)
			parents[u] = parents[v] = [start_node, nil, false]
		end
		while true do
			min, old_distance = q.pop
			return nil unless min
			fail unless min.length == 3
			v, uu, prev_rgt = *min
			fail unless v && uu
			hhh = (uu == start_node || (uu.vertex.cid == start_cid && start_cid != -1) ? 0 : uu.vertex.radius + [uu.vertex.separation, net_desc.trace_clearance].max + net_desc.trace_width * 0.5)

			pom = parents[min]
			popom = parents[pom]
			popom = popom[0] if popom
			popom = popom.vertex if popom
			if (v.vertex.name == end_node_name) && v.incident
				hhh = get_tangents(*uu.vertex.xy, hhh, prev_rgt, *v.vertex.xy, 0, false)
				blocked = false
				(uu.vertex.neighbors & v.vertex.neighbors).each{|el|
					if el.cid == -1 || (el.cid != uu.vertex.cid && el.cid != v.vertex.cid) && el != popom
						if normal_distance_line_segment_point_squared(*hhh, el.x, el.y) < (el.radius + [el.separation, net_desc.trace_clearance].max + net_desc.trace_width * 0.5) ** 2
							blocked = true
							break
						end
					end
				}
				next if blocked
				if old_distance > 10 * AVD &&
					old_distance > max_detour_factor * Math::hypot(v.vertex.x - start_node.vertex.x, v.vertex.y - start_node.vertex.y)
					return nil
				end
				break
			end
			vcid = v.vertex.cid
			distances[min] = old_distance
			x, y = v.vertex.xy
			pom = parents[min]
			popom = parents[pom]
			popom = popom[0] if popom
			popom = popom.vertex if popom
			u = pom[0]
			fail unless u == uu
			path = Set.new
			p = min
			while p
				path << p[0]
				p = parents[p]
			end
			blocking_vertex = nil
			uv_blocked = [false, true].map{|b|
				blocked = false
				p = get_tangents(*uu.vertex.xy, hhh, prev_rgt, *v.vertex.xy, v.vertex.radius + [v.vertex.separation, net_desc.trace_clearance].max + net_desc.trace_width * 0.5, b)
				(uu.vertex.neighbors & v.vertex.neighbors).each{|el|
					if (el.cid == -1 || (el.cid != uu.vertex.cid && el.cid != v.vertex.cid)) && el != popom
						if normal_distance_line_segment_point_squared(*p, el.x, el.y) < ((el.radius + [el.separation, net_desc.trace_clearance].max + net_desc.trace_width * 0.5)) ** 2
							blocked = true
							if blocking_vertex
								blocking_vertex = nil
							else
								blocking_vertex = el
							end
							break
						end
					end
				}
				blocked
			}
			v.qbors(u) do |w, use_inner, use_outer|
				only_outer = !use_inner
				next if @edges_in_cluster.include?(v.vertex, w.vertex)
				hhh = false
				if false
				else
					next if path.include?(w)
				end
				lcuts = nil
				if false
				else
					lr_turn = RBR::xboolean_really_smart_cross_product_2d_with_offset(u, w, v)
				end
				cur_rgt = lr_turn
				w_v_rgt = [w, v, cur_rgt]
				w_v_xrgt = [w, v, !cur_rgt]
				if (start_cid != -1) && (vcid == start_cid) && (w.vertex.cid == start_cid)
					[w_v_rgt, w_v_xrgt].each{|el|
						unless distances.include?(el)
							if q.inc?(el, old_distance)
								parents[el] = min
							end
						end
					}
					next
				end
				next if only_outer && vcid > -1
				new_distance = old_distance + Math.hypot(w.vertex.x - x, w.vertex.y - y)
				outer_distance = new_distance
				if !(can_out = only_outer) && !distances.include?(w_v_rgt)
					not_blocked = catch(:blocked){
						lcuts = new_bor_list(u, w, v)
						if vcid >= 0
							if lcuts.find{|el| el.cid == vcid} || (u.vertex.cid == vcid && w.vertex.cid == vcid && lcuts.empty?)
								can_out = true
								throw :blocked
							end
						end
						v.vertex.incident_nets.map{|el| el.nstep || el.pstep}.each{|el|
							hhh = lcuts.include?(el.vertex)
							can_out = true if hhh && (vcid == -1)
							throw :blocked if hhh
							throw :blocked if !(el.nstep && el.pstep) && (cur_rgt != prev_rgt) && (el.vertex == u.vertex)
						}
						throw :blocked if uv_blocked[(cur_rgt ? 1 : 0)] && blocking_vertex != w.vertex
						squeeze = lcuts.inject(0){|sum, el| if (h = @newcuts[v.vertex, el].squeeze_strength(net_desc.trace_width, net_desc.trace_clearance)) >= MBD; break h end; sum + h}
						throw :blocked if squeeze >= MBD
						squeeze += @newcuts[v.vertex, u.vertex].squeeze_strength(net_desc.trace_width, net_desc.trace_clearance) if (u != start_node) && (cur_rgt != prev_rgt)
						throw :blocked if squeeze >= MBD
						if hhh = @newcuts[w.vertex, u.vertex]
							nd = (new_distance + distances[pom] + hhh.cap) / 2
							if nd < new_distance
								new_distance = [nd, old_distance].max
							end
						else
							unless lcuts.empty?
								nv = lcuts.min_by{|el| @newcuts[v.vertex, el].cap}
								if unused_point_in_triangle(*u.vertex.xy, *v.vertex.xy, *w.vertex.xy, *nv.xy) >= 0
									nd = Math.hypot(u.vertex.x - nv.x, u.vertex.y - nv.y) + Math.hypot(w.vertex.x - nv.x, w.vertex.y - nv.y)
								else
									nd = Math.hypot(u.vertex.x - w.vertex.x, u.vertex.y - w.vertex.y)
								end
								nd = (new_distance + distances[pom] + nd) / 2
								if nd < new_distance
									new_distance = [nd, old_distance].max
								end
							end
						end
						new_distance += AVD if cur_rgt != prev_rgt
						new_distance += squeeze
						if q.inc?(w_v_rgt, new_distance)
							outer_lane[w_v_rgt] = false
							parents[w_v_rgt] = min
						end
					}
				end
				if use_outer && !distances.include?(w_v_xrgt)
					cur_rgt = !cur_rgt
					new_distance = outer_distance
					not_blocked = catch(:blocked){
						lcuts = v.vertex.neighbors - (lcuts || new_bor_list(u, w, v)) - [u.vertex, w.vertex]
						squeeze = lcuts.inject(0){|sum, el| if (h = @newcuts[v.vertex, el].squeeze_strength(net_desc.trace_width, net_desc.trace_clearance)) >= MBD; break h end; sum + h}
						throw :blocked if squeeze >= MBD
						squeeze += @newcuts[v.vertex, u.vertex].squeeze_strength(net_desc.trace_width, net_desc.trace_clearance) if (u != start_node) && (cur_rgt != prev_rgt)
						throw :blocked if squeeze >= MBD
						throw :blocked if uv_blocked[(cur_rgt ? 1 : 0)] && blocking_vertex != w.vertex
						v.vertex.incident_nets.map{|el| el.nstep || el.pstep}.each{|el|
							throw :blocked if lcuts.include?(el.vertex)
							throw :blocked if !(el.nstep && el.pstep) && (cur_rgt != prev_rgt) && (el.vertex == u.vertex)
						}
						new_distance += AVD if cur_rgt != prev_rgt
						new_distance += squeeze
						if q.inc?(w_v_xrgt, new_distance)
							outer_lane[w_v_xrgt] = true
							parents[w_v_xrgt] = min
						end
					}
				end
			end
		end
		path = Array.new
		p = min
		while p
			if n = parents[p]
				fail unless n[0] == p[1]
				n[0].outer = outer_lane[p]
				n[0].lr_turn = p[2] == outer_lane[p]
			end
			path << p[0]
			p = n
		end
		cid = path.last.vertex.cid
		if cid != -1
			while path[-2].vertex.cid == cid
				path.pop
			end
		end
		dijkstra_use_path(path, net_desc)
		return path
	end

	def dijkstra_use_path(path, net_desc)
		path.each_cons(3){|u, v, w|
			if u.vertex == w.vertex
				lcuts = Array.new
			else
				lcuts = new_bor_list(u, w, v)
			end
			lcuts = v.vertex.neighbors - lcuts - [u.vertex, w.vertex] if v.outer
			lcuts.each{|el| @newcuts[v.vertex, el].use(net_desc.trace_width, net_desc.trace_clearance)}
			if (u != path.first) && ((u.outer == u.lr_turn) != (v.outer == v.lr_turn))
				@newcuts[u.vertex, v.vertex].use(net_desc.trace_width, net_desc.trace_clearance)
			end
		}
		path.first.outer = path.first.lr_turn = path.last.outer = path.last.lr_turn = nil
	end

	def split_neighbor_list(a, b, n)
		fail unless a.is_a? Region
		fail unless b.is_a? Region
		nx = n.vertex.x
		ny = n.vertex.y
		v1x = a.vertex.x + a.ox - nx
		v1y = a.vertex.y + a.oy - ny
		v2x = b.vertex.x + b.ox - nx
		v2y = b.vertex.y + b.oy - ny
		n.neighbors.select{|el|
			if el == a || el == b
				false
			else
				ex = el.vertex.x + el.ox - nx
				ey = el.vertex.y + el.oy - ny
				if RBR::xboolean_really_smart_cross_product_2d_with_offset(a, b, n)
					v1x * ey > v1y * ex && v2x * ey < v2y * ex
				else
					v1x * ey > v1y * ex || v2x * ey < v2y * ex
				end
			end
		}
	end

	def full_split_neighbor_list(a, b, n)
		fail unless a.is_a? Region
		fail unless b.is_a? Region
		l = Array.new
		r = Array.new
		nx = n.vertex.x
		ny = n.vertex.y
		v1x = a.rx - nx
		v1y = a.ry - ny
		v2x = b.rx - nx
		v2y = b.ry - ny
		turn = RBR::xboolean_really_smart_cross_product_2d_with_offset(a, b, n)
		n.neighbors.each{|el|
			if el != a && el != b
				ex = el.rx - nx
				ey = el.ry - ny
				if (turn ? v1x * ey > v1y * ex && v2x * ey < v2y * ex : v1x * ey > v1y * ex || v2x * ey < v2y * ex)
					l << el
				else
					r << el
				end
			end
		}
		return r, l
	end

	def atan2_tangents(a, b, id)
		last_step, cur_step = a.net(id), b.net(id)
		t1 = get_tangents(a.x, a.y, last_step.radius, last_step.rgt, b.x, b.y, cur_step.radius, cur_step.rgt)
		Math.atan2(t1[3] - t1[1], t1[2] - t1[0])
	end

	def new_bor_list(a, b, n)
		aa, bb, nn = a, b, n
		a, b, n = a.vertex, b.vertex, n.vertex
		ax = a.x - n.x
		ay = a.y - n.y
		bx = b.x - n.x
		by = b.y - n.y
		n.neighbors.select{|el|
			if el == a || el == b
				false
			else
				ex = el.x - n.x
				ey = el.y - n.y
				if RBR::xboolean_really_smart_cross_product_2d_with_offset(aa, bb, nn)
					ax * ey > ay * ex && ex * by > ey * bx
				else
					ax * ey < ay * ex && ex * by < ey * bx
				end
			end
		}
	end

	def route(net_id, max_detour_factor = 2)
		fail if net_id > @netlist.length - 1 || net_id < 0
		net_desc = @netlist[net_id]
		from, to = net_desc.t1_name, net_desc.t2_name
		fail unless from && to
		fail if from == to
		fail unless start_node = @regions.find{|r| r.incident && r.vertex.name == from}
		if @rstyles
			net_desc.trace_clearance = @rstyles[net_desc.style_name].trace_clearance
			net_desc.trace_width = @rstyles[net_desc.style_name].trace_width
		end
		if max_detour_factor == 0
			return dijkstra(start_node, to, net_desc, 1.5) != nil
		end

		unless path = dijkstra(start_node, to, net_desc, max_detour_factor)
			return false
		end
		first = path[-1]
		last = path[0]
		fail if first == last
		if path.length > 2
			first.idirs << [path[-2].rx - first.vertex.x, path[-2].ry - first.vertex.y]
			last.idirs << [path[1].rx - last.vertex.x, path[1].ry - last.vertex.y]
		end
		r1 = r2 = nil
		path.reverse.each_cons(3){|prv, cur, nxt|
			fail unless prv && cur && nxt
			ne, ne_comp = full_split_neighbor_list(prv, nxt, cur)
			fail if ne_comp.include?(prv) || ne_comp.include?(nxt)
			fail if ne.include?(prv) || ne.include?(nxt)
			ne << nxt
			ne_comp << nxt
			if r1
				ne.delete(r2)
				ne_comp.delete(r1)
			else
				ne << prv
				ne_comp << prv
			end
			@regions.delete(cur)
			r1 = Region.new(cur.vertex)
			r2 = Region.new(cur.vertex)
			r1.idirs = cur.idirs.dup
			r2.idirs = cur.idirs.dup
			r1.odirs = cur.odirs.dup
			r2.odirs = cur.odirs.dup
			r1.incident = r2.incident = cur.incident

			dx1 = dy1 = dx2 = dy2 = 0
			if prv == first
				dx2 = cur.rx - prv.rx
				dy2 = cur.ry - prv.ry
				h = Math::hypot(dx2, dy2)
				dx2 /= h
				dy2 /= h
			end
			if nxt == last
				dx1 = nxt.rx - cur.rx
				dy1 = nxt.ry - cur.ry
				h = Math::hypot(dx1, dy1)
				dx1 /= h
				dy1 /= h
			end
			if prv == first || nxt == last
				r1.g = r2.g = cur.g * 0.5
				dy = (dx1 + dx2)
				dx = -(dy1 + dy2)
				h = Math::hypot(dx, dy) / cur.g
				dx /= h
				dy /= h
				r1.ox = cur.ox + dx
				r1.oy = cur.oy + dy
				r2.ox = cur.ox - dx
				r2.oy = cur.oy - dy
				r1.rx = r1.vertex.x + r1.ox
				r1.ry = r1.vertex.y + r1.oy
				r2.rx = r2.vertex.x + r2.ox
				r2.ry = r2.vertex.y + r2.oy
			else
				r1.ox = cur.ox
				r1.oy = cur.oy
				r2.ox = cur.ox
				r2.oy = cur.oy
				r1.rx = cur.rx
				r1.ry = cur.ry
				r2.rx = cur.rx
				r2.ry = cur.ry
			end

			if true
				dx1 = nxt.rx - cur.rx
				dy1 = nxt.ry - cur.ry
				h = Math::hypot(dx1, dy1)
				dx1 /= h
				dy1 /= h
				dx2 = cur.rx - prv.rx
				dy2 = cur.ry - prv.ry
				h = Math::hypot(dx2, dy2)
				dx2 /= h
				dy2 /= h
				dy = (dx1 + dx2)
				dx = -(dy1 + dy2)
				h = Math::hypot(dx, dy)
				dx /= h
				dy /= h
			end
			@regions << r1 << r2
			cur.neighbors.each{|el| el.neighbors.delete(cur)}
			ne.each{|el|
				el.neighbors << r1
				r1.neighbors << el
			}
			ne_comp.each{|el|
				el.neighbors << r2
				r2.neighbors << el
			}
			if cur.lr_turn != cur.outer
				r1.incident = false
			else
				r2.incident = false
			end
			if cur.outer && dx
				if cur.lr_turn
					r2.odirs << [dx, dy]
				else
					r1.odirs << [-dx, -dy]
				end
			end
		}

		pstep = nil
		path.each_with_index{|cur, i|
			nxt = (i == path.length - 1 ? nil : path[i + 1])
			prv = (i == 0 ? nil : path[i - 1])
			nv = (nxt ? nxt.vertex : nil)
			pv = (prv ? prv.vertex : nil)
			cv = cur.vertex
			step = Step.new(pv, nv, @path_ID)
			step.outer = cur.outer
			step.lr_turn = !cur.lr_turn
			step.net_desc = net_desc
			step.vertex = cv
			step.pstep = pstep
			pstep = step
			if prv and nxt
				cv.update(step)
				cv.unfriendly_resize
				step.rgt = step.outer != cur.lr_turn
				step.xt = !step.outer
				cv.attached_nets << step
			else
				step.rgt = false
				cv.incident_nets << step
			end
		}
		@path_ID += 1
		while p = pstep.pstep
			p.nstep = pstep
			pstep = p
		end
		return true
	end

	# --- Tangent computation ---
	def get_tangents(x1, y1, r1, l1, x2, y2, r2, l2)
		fail if r1 < 0 || r2 < 0
		d = Math.hypot(x1 - x2, y1 - y2)
		vx = (x2 - x1) / d
		vy = (y2 - y1) / d
		r2 *= (l1 == l2 ? 1 : -1)
		c = (r1 - r2) / d
		h = 1 - c ** 2
		if h < 0
		end
		if h >= 0
			h = 0 if h < 0
			h = Math.sqrt(h) * (l1 ? -1 : 1)
		else
			h = 0
		end
		nx = vx * c - h * vy
		ny = vy * c + h * vx
		[x1 + r1 * nx, y1 + r1 * ny, x2 + r2 * nx, y2 + r2 * ny]
	end

	def smart_replace(step, list)
		if step.prev == step.next
			fail unless list.empty?
			step.pstep.nstep = step.nstep.nstep
			step.pstep.next = step.nstep.next
			step.nstep.nstep.pstep = step.pstep
			step.nstep.nstep.prev = step.prev
			step.next.new_delete_net(step.nstep)
		elsif list.empty?
			ps = step.pstep
			ns = step.nstep
			ps.next = step.next
			ns.prev = step.prev
			ps.nstep = ns
			ns.pstep = ps
		else
			pstep = step.pstep
			pv = step.prev
			list.each{|v|
				n = Step.new(pv, nil, step.id)
				n.net_desc = step.net_desc
				n.vertex = v
				n.pstep = pstep
				pstep.nstep = n
				pstep.next = v
				pstep = n
				pv = v
				n.rgt = !step.rgt
				n.xt = true
				n.outer = true
				v.update(n)
				v.attached_nets << n
			}
			pstep.next = step.next
			pstep.nstep = step.nstep
			pstep.nstep.prev = pv
			pstep.nstep.pstep = pstep
		end
		step.vertex.new_delete_net(step)
	end

	# --- Rubberband optimization ---

	def sort_attached_nets
		@vertices.each{|vert| vert.sort_attached_nets}
	end

	def prepare_steps
		@vertices.each{|vert|
			next if vert.attached_nets.empty?
			vert.reset_initial_size
			[true, false].each{|b|
				vert.attached_nets.each{|step|
					next if step.xt == b
					net = step.net_desc
					trace_sep = [vert.separation, net.trace_clearance].max
					vert.radius += trace_sep + net.trace_width
					step.radius = vert.radius - net.trace_width * 0.5
					vert.separation = net.trace_clearance
				}
			}
		}
	end

	def convex_kkk(prev_step, step, nxt_step)
		pv, cv, nv = step.prev, step.vertex, step.next
		x1, y1, x2, y2 = get_tangents(pv.x, pv.y, prev_step.radius, prev_step.rgt, cv.x, cv.y, step.radius, step.rgt)
		x3, y3, x4, y4 = get_tangents(cv.x, cv.y, step.radius, step.rgt, nv.x, nv.y, nxt_step.radius, nxt_step.rgt)
		x2, y2, x3, y3 = line_line_intersection(x1, y1, x2, y2, x3, y3, x4, y4)
		if (x2 != nil) && ((x3 > 0 && x3 < 1) || (y3 > 0 && y3 < 1))
			return x2, y2
		else
			return nil
		end
	end

	def nubly(collapse = false)
		replaced = true
		rep_c = 0
		while replaced do
			replaced = false
			rep_c += 1
			break if rep_c > 100 # safety limit
			@vertices.each{|cv|
				cv.attached_nets.reverse_each{|step|
					prev_step, nxt_step = step.pstep, step.nstep

					pv, nv = step.prev, step.next
					d = Math::hypot(cv.x - pv.x, cv.y - pv.y) - (prev_step.radius - step.radius).abs * 1.02
					if d < 0
						if step.radius < prev_step.radius
							step.radius -= d
							replaced = true
						end
						next
					end
					d = Math::hypot(cv.x - nv.x, cv.y - nv.y) - (nxt_step.radius - step.radius).abs * 1.02
					if d < 0
						if step.radius < nxt_step.radius
							step.radius -= d
							replaced = true
						end
						next
					end

					hx, hy = convex_kkk(prev_step, step, nxt_step)
					step.xt = hx != nil
					if collapse && step.xt
						pv, nv = step.prev, step.next
						hv0 = Vertex.new(hx, hy)

						replaced = true
						pvx = pv.x
						pvy = pv.y
						nvx = nv.x
						nvy = nv.y
						if pp = prev_step.pstep
							hx, hy = convex_kkk(pp, prev_step, step)
						end
						if pp && hx
							ppv = Vertex.new(hx, hy)
						else
							ppv = pv
						end
						if nn = nxt_step.nstep
							hx, hy = convex_kkk(step, nxt_step, nn)
						end
						if nn && hx
							nnv = Vertex.new(hx, hy)
						else
							nnv = nv
						end
						hx = nvx - pvx
						hy = nvy - pvy
						if step.rgt
							vec_x, vec_y = hy, -hx
						else
							vec_x, vec_y = -hy, hx
						end
						hv3 = Vertex.new(pvx + hx * 0.5 + vec_x, pvy + hy * 0.5 + vec_y)
						hx *= 2
						hy *= 2
						vec_x *= 2
						vec_y *= 2
						hv4 = Vertex.new(pvx - hx + vec_x, pvy - hy + vec_y)
						hv5 = Vertex.new(nvx + hx + vec_x, nvy + hy + vec_y)
						rep = vertices_in_polygon([ppv, hv0, nnv, hv3], @vertices) - [pv, nv, ppv, cv, nnv, hv3]
						unless rep.empty?
							net = step.net_desc
							rep.each{|v|
								v.trgt = !step.rgt
								v.tradius = v.radius + [net.trace_clearance, v.separation].max + net.trace_width * 0.5
							}
							pv.trgt = step.pstep.rgt
							pv.tradius = step.pstep.radius
							nv.trgt = step.nstep.rgt
							nv.tradius = step.nstep.radius
							rep = new_convex_vertices(rep, pv, nv, hv4, hv5)
						end
						smart_replace(step, rep)
					end
				}
			}
		end
	end

	# --- Draw routes: output JSON segments and arcs ---

	def draw_routes
		@output_segments = {}
		@output_arcs = {}
		@output_paths = {}

		@vertices.each{|vert|
			vert.incident_nets.each{|n|
				next unless n.next
				net_id = n.net_desc.id
				thi = n.net_desc.trace_width
				sep = n.net_desc.trace_clearance
				@output_segments[net_id] ||= []
				@output_arcs[net_id] ||= []
				@output_paths[net_id] ||= []

				@output_paths[net_id] << {id: vert.id, x: vert.x, y: vert.y, name: vert.name}

				last = vert
				lastx = lasty = nil
				lr = 0
				to = n.next
				to_net = n.nstep
				while to do
					last_net = to_net.pstep
					last = last_net.vertex
					radius = to_net.radius

					@output_paths[net_id] << {id: to_net.vertex.id, x: to_net.vertex.x, y: to_net.vertex.y}

					if last.x == to.x && last.y == to.y
						last.vis_flag = 1
					else
						t = get_tangents(last.x, last.y, lr, last_net.rgt, to.x, to.y, radius, to_net.rgt)
						@output_segments[net_id] << {x1: t[0], y1: t[1], x2: t[2], y2: t[3], width: thi}
						if lr > 0
							start_angle = Math.atan2(lasty - last.y, lastx - last.x)
							end_angle = Math.atan2(t[1] - last.y, t[0] - last.x)
							start_angle, end_angle = end_angle, start_angle unless last_net.rgt
							@output_arcs[net_id] << {cx: last.x, cy: last.y, r: lr,
								startAngle: start_angle, endAngle: end_angle, width: thi}
						end
					end
					lr = radius
					last = to
					to_net = to_net.nstep
					if to_net
						to = to_net.vertex
					else
						to = nil
					end
					lastx = t ? t[2] : nil
					lasty = t ? t[3] : nil
				end

				# Add endpoint
				if n.nstep
					ep = n.nstep
					while ep.nstep; ep = ep.nstep; end
					ev = ep.vertex
					@output_paths[net_id] << {id: ev.id, x: ev.x, y: ev.y, name: ev.name}
				end
			}
		}
	end

	def sort_netlist
		@netlist.sort_by!{|el| el.pri}
	end

	# --- Run full routing pipeline and return JSON ---

	def run_routing
		results = []
		@netlist.each_with_index{|net, i|
			ok = route(i)
			@routed << ok
		}

		# Rubberband optimization (same sequence as original main)
		sort_attached_nets
		prepare_steps
		nubly
		prepare_steps

		sort_attached_nets
		prepare_steps

		nubly
		prepare_steps

		sort_attached_nets
		prepare_steps

		nubly(true)
		sort_attached_nets
		prepare_steps

		# Generate output
		draw_routes

		paths = []
		@netlist.each_with_index{|net, i|
			net_id = net.id
			paths << {
				net_index: i,
				from: net.t1_name,
				to: net.t2_name,
				routed: @routed[i],
				trace_width: net.trace_width,
				trace_clearance: net.trace_clearance,
				vertices: @output_paths[net_id] || [],
				segments: @output_segments[net_id] || [],
				arcs: @output_arcs[net_id] || []
			}
		}

		{
			routed: @routed,
			paths: paths,
			vertices: @vertices.map{|v| {id: v.id, x: v.x, y: v.y, name: v.name,
				core: v.core, radius: v.radius, separation: v.separation, cid: v.cid}}
		}
	end

end # class Router
end # module RBR

# --- Main: read JSON from stdin, route, write JSON to stdout ---
if __FILE__ == $0
	input = JSON.parse($stdin.read)
	router = RBR::Router.new
	router.build_from_json(input)
	router.sort_netlist if input["sort_nets"]
	result = router.run_routing
	puts JSON.generate(result)
end
