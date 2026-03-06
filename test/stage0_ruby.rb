require 'json'
load 'src/router_ruby.rb'
input = JSON.parse(File.read("test/shared_graph.json"))
r = RBR::Router.new
r.build_from_json(input)

def my_tangents(x1,y1,r1,l1,x2,y2,r2,l2)
  d = Math.hypot(x1-x2,y1-y2)
  return [x1,y1,x2,y2] if d==0
  vx=(x2-x1)/d
  vy=(y2-y1)/d
  r2 *= (l1==l2 ? 1 : -1)
  c=(r1-r2)/d
  h=[1-c**2,0].max
  h=Math.sqrt(h) * (l1 ? -1 : 1)
  nx=vx*c-h*vy
  ny=vy*c+h*vx
  [x1+r1*nx, y1+r1*ny, x2+r2*nx, y2+r2*ny]
end

def extract_segs(router)
  segs = []
  router.vertices.each{|vert|
    vert.incident_nets.each{|n|
      next unless n.next
      lr = 0
      to = n.next
      to_net = n.nstep
      while to && to_net
        last_net = to_net.pstep
        break unless last_net
        last_v = last_net.vertex
        radius = to_net.radius
        unless last_v.x == to.x && last_v.y == to.y
          t = my_tangents(last_v.x, last_v.y, lr, last_net.rgt, to.x, to.y, radius, to_net.rgt)
          segs << {net: n.id, x1: t[0], y1: t[1], x2: t[2], y2: t[3]}
        end
        lr = radius
        to_net = to_net.nstep
        to = to_net ? to_net.vertex : nil
      end
    }
  }
  segs
end

def count_crossings(segs)
  crossings = 0
  segs.each_with_index{|a, i|
    segs[(i+1)..-1].each{|b|
      next if a[:net] == b[:net]
      ax1,ay1,ax2,ay2 = a[:x1],a[:y1],a[:x2],a[:y2]
      bx1,by1,bx2,by2 = b[:x1],b[:y1],b[:x2],b[:y2]
      next if (ax1==bx1 && ay1==by1) || (ax1==bx2 && ay1==by2) ||
              (ax2==bx1 && ay2==by1) || (ax2==bx2 && ay2==by2)
      d1=(bx2-bx1)*(ay1-by1)-(by2-by1)*(ax1-bx1)
      d2=(bx2-bx1)*(ay2-by1)-(by2-by1)*(ax2-bx1)
      d3=(ax2-ax1)*(by1-ay1)-(ay2-ay1)*(bx1-ax1)
      d4=(ax2-ax1)*(by2-ay1)-(ay2-ay1)*(bx2-ax1)
      crossings += 1 if d1*d2 < 0 && d3*d4 < 0
    }
  }
  crossings
end

# Route all nets
r.netlist.each_with_index{|net, i| r.route(i)}
r.prepare_steps
segs0 = extract_segs(r)
puts "Stage 0 (after routing): #{segs0.length} segments, #{count_crossings(segs0)} crossings"

# Stage 1: sort + prepare + nubly(false) + prepare
r.sort_attached_nets
r.prepare_steps
begin
  Timeout.timeout(3) { r.nubly(false) }
  r.prepare_steps
  segs1 = extract_segs(r)
  puts "Stage 1 (nubly false): #{segs1.length} segments, #{count_crossings(segs1)} crossings"
rescue => e
  puts "Stage 1: FAILED (#{e.class})"
end

# Output stage 0 segments as JSON for TS comparison
puts JSON.generate({ruby_stage0: segs0})
