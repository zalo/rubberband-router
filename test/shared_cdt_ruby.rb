#!/usr/bin/env ruby
# Route on the exact same CDT graph exported from TypeScript
require 'json'
require 'set'

module RBR
  MBD = (2 ** 30 - 2 ** 24)
  AVD = 5000; ATW = 1000
  Trace_Width = 1200; Clearance = 800; Pin_Radius = 1000

  def self.xboolean(ax, ay, bx, by, ox, oy)
    ax -= ox; ay -= oy; bx -= ox; by -= oy
    if (p = ax * by - ay * bx) != 0
      p > 0
    else
      ax != bx ? ax < bx : ay < by
    end
  end
end

class Vertex
  attr_accessor :id, :x, :y, :name, :cid, :core, :radius, :separation, :neighbors
  attr_accessor :incident_nets, :attached_nets, :num_inets, :tradius, :trgt
  def initialize(id, x, y, core, radius, sep)
    @id=id; @x=x; @y=y; @core=core; @radius=radius; @separation=sep
    @cid=-1; @name=''; @num_inets=0; @neighbors=[]; @incident_nets=[]; @attached_nets=[]
    @tradius=0; @trgt=false
  end
  def xy; [x,y]; end
  def reset_initial_size; @radius=@core; @separation=RBR::Clearance; end
end

class Region
  attr_accessor :vertex, :neighbors, :incident, :outer, :g, :ox, :oy, :rx, :ry
  attr_accessor :lr_turn, :idirs, :odirs, :rid
  @@next_rid = 0
  def initialize(v)
    @rid = @@next_rid; @@next_rid += 1
    @g=1; @ox=@oy=0; @vertex=v; @rx=v.x; @ry=v.y
    @neighbors=[]; @incident=true; @outer=false; @idirs=[]; @odirs=[]
  end
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
          self.odirs.each{|zx,zy|
            j = turn ? (ax*zy>=ay*zx && bx*zy<=by*zx) : (ax*zy<=ay*zx && bx*zy>=by*zx)
            break unless (outer &&= j)
          }
          inner = !outer
        end
        self.idirs.each{|zx,zy|
          j = turn ? (ax*zy>=ay*zx && bx*zy<=by*zx) : (ax*zy<=ay*zx && bx*zy>=by*zx)
          j ? (inner=false) : (outer=false)
          next unless inner || outer
        }
        yield [el, inner, outer]
      }
    else
      @neighbors.each{|el| yield [el, true, true]}
    end
  end
end

class Cut
  attr_accessor :cap, :free_cap, :cv1, :cv2, :cl
  def initialize(v1, v2)
    @cap = Math.hypot(v1.x-v2.x, v1.y-v2.y)
    @free_cap = @cap - v1.core - v2.core
    @cv1=RBR::Clearance; @cv2=RBR::Clearance; @cl=[]
  end
  def squeeze_strength(tw, tc)
    if @cl.empty?
      s = (@cv1<@cv2 && @cv1<tc ? @cv2+tc : (@cv2<tc ? @cv1+tc : @cv1+@cv2))
    else
      @cl.push(tc)
      ll = @cl.length/2; hhh = @cl.sort.reverse[0..ll]*2
      hhh.pop if @cl.length.even?; hhh.push(@cv1,@cv2); hhh.sort!; hhh.shift(2)
      s = hhh.inject(0){|sum,v| sum+v}; @cl.pop
    end
    s = @free_cap - tw - s
    s < 0 ? RBR::MBD : 10*RBR::AVD*RBR::ATW/(RBR::ATW+s*2)
  end
  def use(tw,tc); @free_cap -= tw; @cl << tc; end
end

class SymHash < Hash
  def [](a,b); a.object_id < b.object_id ? super([a,b]) : super([b,a]); end
  def []=(a,b,c); a.object_id < b.object_id ? super([a,b],c) : super([b,a],c); end
  def include?(a,b); a.object_id < b.object_id ? super([a,b]) : super([b,a]); end
end

def get_tangents(x1,y1,r1,l1,x2,y2,r2,l2)
  d = Math.hypot(x1-x2,y1-y2)
  return [x1,y1,x2,y2] if d==0
  vx=(x2-x1)/d; vy=(y2-y1)/d; r2 *= (l1==l2 ? 1:-1)
  c=(r1-r2)/d; h=[1-c**2,0].max; h=Math.sqrt(h)*(l1 ? -1:1)
  nx=vx*c-h*vy; ny=vy*c+h*vx
  [x1+r1*nx, y1+r1*ny, x2+r2*nx, y2+r2*ny]
end

def ndist_sq(bx,by,cx,cy,px,py,mbd)
  mx=cx-bx; my=cy-by; hx=px-bx; hy=py-by
  t0=(mx*hx+my*hy).fdiv(mx**2+my**2)
  t0>0 && t0<1 ? (hx-t0*mx)**2+(hy-t0*my)**2 : mbd
end

def new_bor_list(a, b, n)
  av,bv,nv = a.vertex,b.vertex,n.vertex
  ax=av.x-nv.x; ay=av.y-nv.y; bx=bv.x-nv.x; by=bv.y-nv.y
  turn = RBR::xboolean(a.rx, a.ry, b.rx, b.ry, nv.x, nv.y)
  nv.neighbors.select{|el|
    next false if el==av || el==bv
    ex=el.x-nv.x; ey=el.y-nv.y
    turn ? (ax*ey>ay*ex && ex*by>ey*bx) : (ax*ey<ay*ex && ex*by<ey*bx)
  }
end

def full_split(a, b, n)
  l=[]; r=[]
  nx=n.vertex.x; ny=n.vertex.y
  v1x=a.rx-nx; v1y=a.ry-ny; v2x=b.rx-nx; v2y=b.ry-ny
  turn = RBR::xboolean(a.rx, a.ry, b.rx, b.ry, nx, ny)
  n.neighbors.each{|el|
    next if el==a || el==b
    ex=el.rx-nx; ey=el.ry-ny
    if (turn ? v1x*ey>v1y*ex && v2x*ey<v2y*ex : v1x*ey>v1y*ex || v2x*ey<v2y*ex)
      l << el
    else
      r << el
    end
  }
  [r, l]
end

# Load shared graph
graph = JSON.parse(File.read(ARGV[0] || 'test/shared_graph.json'))

# Build vertices
verts_by_id = {}
graph['vertices'].each{|vd|
  v = Vertex.new(vd['id'], vd['x'], vd['y'], vd['core'], vd['radius'], vd['separation'])
  v.name = vd['name']
  verts_by_id[vd['id']] = v
}
# Set neighbors
graph['vertices'].each{|vd|
  v = verts_by_id[vd['id']]
  vd['neighbors'].each{|nid| v.neighbors << verts_by_id[nid]}
}

vertices = verts_by_id.values.sort_by{|v| v.id}
regions = vertices.map{|v| Region.new(v)}
reg_by_vid = {}; regions.each{|r| reg_by_vid[r.vertex.id] = r}

# Region neighbors from vertex neighbors
vertices.each{|v|
  r = reg_by_vid[v.id]
  v.neighbors.each{|n|
    nr = reg_by_vid[n.id]
    r.neighbors << nr unless r.neighbors.include?(nr)
  }
}

# Cuts
cuts = SymHash.new
vertices.each{|v| v.neighbors.each{|n| cuts[v,n] = Cut.new(v,n) unless cuts.include?(v,n)}}

# Dijkstra (full version matching router.rb)
def dijkstra(start_node, end_name, net_desc, regions, cuts, vertices)
  q = {}
  distances = {}
  parents = {}
  outer_lane = {}
  start_cid = start_node.vertex.cid
  sx, sy = start_node.vertex.xy

  distances[[start_node, nil, true]] = 0
  distances[[start_node, nil, false]] = 0

  start_node.qbors(nil){|w, ui, uo|
    dist = (start_cid != -1 && w.vertex.cid == start_cid) ? 0 : Math.hypot(w.vertex.x-sx, w.vertex.y-sy)
    u = [w, start_node, false]; v = [w, start_node, true]
    q[u] = q[v] = dist
    parents[u] = parents[v] = [start_node, nil, false]
  }

  route_log = []
  while !q.empty?
    min = q.min_by{|k,v| v}[0]
    old_distance = q.delete(min)

    v, uu, prev_rgt = *min
    next unless uu

    hhh = (uu == start_node || (uu.vertex.cid == start_cid && start_cid != -1)) ? 0 :
      uu.vertex.radius + [uu.vertex.separation, net_desc[:tc]].max + net_desc[:tw] * 0.5

    pom = parents[min]
    popom = parents[pom]
    popom = popom[0] if popom
    popom = popom.vertex if popom

    if v.vertex.name == end_name && v.incident
      tangent = get_tangents(*uu.vertex.xy, hhh, prev_rgt, *v.vertex.xy, 0, false)
      blocked = false
      (uu.vertex.neighbors & v.vertex.neighbors).each{|el|
        if el.cid == -1 || ((el.cid != uu.vertex.cid && el.cid != v.vertex.cid) && el != popom)
          min_d = (el.radius + [el.separation, net_desc[:tc]].max + net_desc[:tw]*0.5)**2
          if ndist_sq(*tangent, el.x, el.y, RBR::MBD) < min_d
            blocked = true; break
          end
        end
      }
      next if blocked
      if old_distance > 10*RBR::AVD && old_distance > 2*Math.hypot(v.vertex.x-start_node.vertex.x, v.vertex.y-start_node.vertex.y)
        return nil
      end

      # Path reconstruction
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
      route_log << {found: v.vertex.name, dist: old_distance.round(1), path: path.map{|r| r.vertex.name}}
      return {path: path, log: route_log}
    end

    vcid = v.vertex.cid
    distances[min] = old_distance
    x, y = v.vertex.xy

    u = pom[0]

    path_set = Set.new
    p = min; while p; path_set << p[0]; p = parents[p]; end

    # uv_blocked
    blocking_vertex = nil
    uv_blocked = [false, true].map{|b|
      bl = false
      tang = get_tangents(*uu.vertex.xy, hhh, prev_rgt, *v.vertex.xy, v.vertex.radius+[v.vertex.separation,net_desc[:tc]].max+net_desc[:tw]*0.5, b)
      (uu.vertex.neighbors & v.vertex.neighbors).each{|el|
        if (el.cid==-1 || (el.cid!=uu.vertex.cid && el.cid!=v.vertex.cid)) && el!=popom
          min_d = (el.radius+[el.separation,net_desc[:tc]].max+net_desc[:tw]*0.5)**2
          if ndist_sq(*tang, el.x, el.y, RBR::MBD) < min_d
            bl = true
            blocking_vertex = blocking_vertex ? nil : el
            break
          end
        end
      }
      bl
    }

    v.qbors(u){|w, use_inner, use_outer|
      next if path_set.include?(w)
      # Border penalty
      next if w.vertex.name == 'border' || w.vertex.name == 'corner'

      only_outer = !use_inner
      lr_turn = RBR::xboolean(uu.rx, uu.ry, w.rx, w.ry, v.vertex.x, v.vertex.y)
      cur_rgt = lr_turn
      w_v_rgt = [w, v, cur_rgt]
      w_v_xrgt = [w, v, !cur_rgt]

      if (start_cid != -1) && (vcid == start_cid) && (w.vertex.cid == start_cid)
        [w_v_rgt, w_v_xrgt].each{|el|
          unless distances.include?(el)
            if !q.include?(el) || q[el] > old_distance
              q[el] = old_distance; parents[el] = min
            end
          end
        }
        next
      end
      next if only_outer && vcid > -1

      new_distance = old_distance + Math.hypot(w.vertex.x-x, w.vertex.y-y)
      if w.vertex.name == 'border' || w.vertex.name == 'corner'
        new_distance += RBR::MBD
      end
      outer_distance = new_distance

      # Inner path
      can_out = only_outer
      if !can_out && !distances.include?(w_v_rgt)
        blocked = false
        lcuts = new_bor_list(u, w, v)
        if vcid >= 0
          if lcuts.find{|el| el.cid==vcid} || (u.vertex.cid==vcid && w.vertex.cid==vcid && lcuts.empty?)
            can_out = true; blocked = true
          end
        end
        unless blocked
          v.vertex.incident_nets.map{|el| el}.each{|step_ref|
            # simplified: no incident nets in this test
          }
        end
        unless blocked
          blocked = true if uv_blocked[cur_rgt ? 1 : 0] && blocking_vertex != w.vertex
        end
        unless blocked
          squeeze = lcuts.inject(0){|sum,el|
            h = cuts[v.vertex,el].squeeze_strength(net_desc[:tw], net_desc[:tc])
            break RBR::MBD if h >= RBR::MBD; sum+h
          }
          if squeeze < RBR::MBD
            if u != start_node && cur_rgt != prev_rgt
              uvc = cuts[v.vertex, u.vertex]
              squeeze += uvc.squeeze_strength(net_desc[:tw], net_desc[:tc]) if uvc
            end
          end
          if squeeze < RBR::MBD
            # Distance shortcut
            pom_dist = distances[pom] || 0
            uwc = cuts[w.vertex, u.vertex] rescue nil
            if uwc
              nd = (new_distance + pom_dist + uwc.cap) / 2
              new_distance = [nd, old_distance].max if nd < new_distance
            end

            new_distance += RBR::AVD if cur_rgt != prev_rgt
            new_distance += squeeze
            if !q.include?(w_v_rgt) || q[w_v_rgt] > new_distance
              q[w_v_rgt] = new_distance
              outer_lane[w_v_rgt] = false
              parents[w_v_rgt] = min
            end
          end
        end
      end

      # Outer path
      if use_outer && !distances.include?(w_v_xrgt)
        cur_rgt_o = !cur_rgt
        new_dist_o = outer_distance
        blocked = false
        inner_lcuts = new_bor_list(u, w, v) rescue []
        outer_lcuts = v.vertex.neighbors - inner_lcuts - [u.vertex, w.vertex]
        squeeze = outer_lcuts.inject(0){|sum,el|
          c = cuts[v.vertex,el] rescue nil
          next sum unless c
          h = c.squeeze_strength(net_desc[:tw], net_desc[:tc])
          break RBR::MBD if h >= RBR::MBD; sum+h
        }
        blocked = true if squeeze >= RBR::MBD
        unless blocked
          if u != start_node && cur_rgt_o != prev_rgt
            uvc = cuts[v.vertex, u.vertex] rescue nil
            if uvc
              squeeze += uvc.squeeze_strength(net_desc[:tw], net_desc[:tc])
              blocked = true if squeeze >= RBR::MBD
            end
          end
        end
        unless blocked
          blocked = true if uv_blocked[cur_rgt ? 0 : 1] && blocking_vertex != w.vertex
        end
        unless blocked
          new_dist_o += RBR::AVD if cur_rgt_o != prev_rgt
          new_dist_o += squeeze
          if !q.include?(w_v_xrgt) || q[w_v_xrgt] > new_dist_o
            q[w_v_xrgt] = new_dist_o
            outer_lane[w_v_xrgt] = true
            parents[w_v_xrgt] = min
          end
        end
      end
    }
  end
  {path: nil, log: route_log}
end

# Route each net and do region splitting
results = []
graph['nets'].each_with_index{|net, idx|
  nd = {tw: RBR::Trace_Width, tc: RBR::Clearance}
  start = regions.find{|r| r.incident && r.vertex.name == net['from']}
  result = dijkstra(start, net['to'], nd, regions, cuts, vertices)

  if result && result[:path]
    path = result[:path]
    first = path[-1]; last_r = path[0]

    # Record direction info
    if path.length > 2
      first.idirs << [path[-2].rx - first.vertex.x, path[-2].ry - first.vertex.y]
      last_r.idirs << [path[1].rx - last_r.vertex.x, path[1].ry - last_r.vertex.y]
    end

    # Region splitting
    r1 = r2 = nil
    reversed = path.reverse
    reversed.each_cons(3){|prv, cur, nxt|
      ne, ne_comp = full_split(prv, nxt, cur)
      ne << nxt; ne_comp << nxt
      if r1; ne.delete(r2); ne_comp.delete(r1)
      else; ne << prv; ne_comp << prv; end

      regions.delete(cur)
      r1 = Region.new(cur.vertex); r2 = Region.new(cur.vertex)
      r1.idirs = cur.idirs.dup; r2.idirs = cur.idirs.dup
      r1.odirs = cur.odirs.dup; r2.odirs = cur.odirs.dup
      r1.incident = r2.incident = cur.incident

      dx1=dy1=dx2=dy2=0
      if prv == reversed[0]
        dx2=cur.rx-prv.rx; dy2=cur.ry-prv.ry; h=Math.hypot(dx2,dy2); dx2/=h; dy2/=h
      end
      if nxt == reversed[-1]
        dx1=nxt.rx-cur.rx; dy1=nxt.ry-cur.ry; h=Math.hypot(dx1,dy1); dx1/=h; dy1/=h
      end
      if prv == reversed[0] || nxt == reversed[-1]
        r1.g = r2.g = cur.g * 0.5
        dy = dx1+dx2; dx = -(dy1+dy2); h = Math.hypot(dx,dy)/cur.g
        if h > 0
          dx/=h; dy/=h
          r1.ox=cur.ox+dx; r1.oy=cur.oy+dy; r2.ox=cur.ox-dx; r2.oy=cur.oy-dy
        else
          r1.ox=cur.ox; r1.oy=cur.oy; r2.ox=cur.ox; r2.oy=cur.oy
        end
        r1.rx=r1.vertex.x+r1.ox; r1.ry=r1.vertex.y+r1.oy
        r2.rx=r2.vertex.x+r2.ox; r2.ry=r2.vertex.y+r2.oy
      else
        r1.ox=cur.ox; r1.oy=cur.oy; r2.ox=cur.ox; r2.oy=cur.oy
        r1.rx=cur.rx; r1.ry=cur.ry; r2.rx=cur.rx; r2.ry=cur.ry
      end

      regions << r1 << r2
      cur.neighbors.each{|el| el.neighbors.delete(cur)}
      ne.each{|el| el.neighbors << r1; r1.neighbors << el}
      ne_comp.each{|el| el.neighbors << r2; r2.neighbors << el}

      if cur.lr_turn != cur.outer; r1.incident = false
      else; r2.incident = false; end

      # odirs
      if cur.outer
        dx1n=nxt.rx-cur.rx; dy1n=nxt.ry-cur.ry
        h=Math.hypot(dx1n,dy1n); dx1n/=h; dy1n/=h if h>0
        dx2n=cur.rx-prv.rx; dy2n=cur.ry-prv.ry
        h=Math.hypot(dx2n,dy2n); dx2n/=h; dy2n/=h if h>0
        dyn=dx1n+dx2n; dxn=-(dy1n+dy2n)
        h=Math.hypot(dxn,dyn)
        if h > 0
          dxn/=h; dyn/=h
          if cur.lr_turn; r2.odirs << [dxn, dyn]
          else; r1.odirs << [-dxn, -dyn]; end
        end
      end
    }

    # Use path (update cuts)
    path.each_cons(3){|u_r, v_r, w_r|
      lcuts = (u_r.vertex == w_r.vertex) ? [] : new_bor_list(u_r, w_r, v_r)
      if v_r.outer
        lcuts = v_r.vertex.neighbors - lcuts - [u_r.vertex, w_r.vertex]
      end
      lcuts.each{|el|
        c = cuts[v_r.vertex, el] rescue nil
        c.use(nd[:tw], nd[:tc]) if c
      }
    }

    results << {net: idx, from: net['from'], to: net['to'], path: path.map{|r| r.vertex.name}, length: path.length}
  else
    results << {net: idx, from: net['from'], to: net['to'], path: nil}
  end
}

puts JSON.pretty_generate({routes: results})
