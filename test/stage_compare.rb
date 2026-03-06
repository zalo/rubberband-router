#!/usr/bin/env ruby
# Stage-by-stage routing comparison
# Outputs segments after each stage to identify where crossings appear
require 'json'
require 'timeout'
load 'src/router_ruby.rb'

input = JSON.parse(File.read(ARGV[0] || 'test/shared_graph.json'))
r = RBR::Router.new
r.build_from_json(input)

def count_crossings(segments)
  lines = segments.select{|s| s[:type] == 'line'}
  crossings = 0
  lines.each_with_index{|a, i|
    lines[(i+1)..-1].each{|b|
      next if a[:net] == b[:net]
      # Segment intersection test
      ax1,ay1,ax2,ay2 = a[:x1],a[:y1],a[:x2],a[:y2]
      bx1,by1,bx2,by2 = b[:x1],b[:y1],b[:x2],b[:y2]
      # Skip shared endpoints
      next if (ax1==bx1&&ay1==by1)||(ax1==bx2&&ay1==by2)||(ax2==bx1&&ay2==by1)||(ax2==bx2&&ay2==by2)
      d1 = (bx2-bx1)*(ay1-by1)-(by2-by1)*(ax1-bx1)
      d2 = (bx2-bx1)*(ay2-by1)-(by2-by1)*(ax2-bx1)
      d3 = (ax2-ax1)*(by1-ay1)-(ay2-ay1)*(bx1-ax1)
      d4 = (ax2-ax1)*(by2-ay1)-(ay2-ay1)*(bx2-ax1)
      crossings += 1 if d1*d2 < 0 && d3*d4 < 0
    }
  }
  crossings
end

def get_tangents(x1,y1,r1,l1,x2,y2,r2,l2)
  d = Math.hypot(x1-x2,y1-y2)
  return [x1,y1,x2,y2] if d==0
  vx=(x2-x1)/d; vy=(y2-y1)/d; r2*=(l1==l2?1:-1)
  c=(r1-r2)/d; h=[1-c**2,0].max; h=Math.sqrt(h)*(l1?-1:1)
  nx=vx*c-h*vy; ny=vy*c+h*vx
  [x1+r1*nx, y1+r1*ny, x2+r2*nx, y2+r2*ny]
end

def extract_segments(router)
  segs = []
  router.vertices.each{|vert|
    vert.incident_nets.each{|n|
      next unless n.next
      thi = n.net_desc.trace_width
      lr = 0; lastx = lasty = nil
      to = n.next; to_net = n.nstep
      while to && to_net
        last_net = to_net.pstep
        break unless last_net
        last = last_net.vertex
        radius = to_net.radius
        unless last.x == to.x && last.y == to.y
          t = get_tangents(last.x, last.y, lr, last_net.rgt, to.x, to.y, radius, to_net.rgt)
          segs << {type: 'line', x1: t[0], y1: t[1], x2: t[2], y2: t[3], width: thi, net: n.id}
          if lr > 0
            segs << {type: 'arc', cx: last.x, cy: last.y, r: lr,
              startAngle: Math.atan2(lasty-last.y, lastx-last.x),
              endAngle: Math.atan2(t[1]-last.y, t[0]-last.x),
              width: thi, net: n.id}
          end
          lastx = t[2]; lasty = t[3]
        end
        lr = radius; to_net = to_net.nstep
        to = to_net ? to_net.vertex : nil
      end
    }
  }
  segs
end

stages = {}

# Stage 0: Route all nets (no rubberband)
r.netlist.each_with_index{|net, i| r.route(i)}
r.prepare_steps
segs = extract_segments(r)
stages['0_after_routing'] = {segments: segs.length, crossings: count_crossings(segs), data: segs}

# Stage 1: sort + prepare + nubly(false)
r.sort_attached_nets; r.prepare_steps; r.nubly; r.prepare_steps
segs = extract_segments(r)
stages['1_after_nubly1'] = {segments: segs.length, crossings: count_crossings(segs), data: segs}

# Stage 2: sort + prepare + nubly(false) again
r.sort_attached_nets; r.prepare_steps; r.nubly; r.prepare_steps
segs = extract_segments(r)
stages['2_after_nubly2'] = {segments: segs.length, crossings: count_crossings(segs), data: segs}

# Stage 3: sort + prepare
r.sort_attached_nets; r.prepare_steps
segs = extract_segments(r)
stages['3_after_sort'] = {segments: segs.length, crossings: count_crossings(segs), data: segs}

# Stage 4: nubly(true) collapse - skip if it hangs
begin
  Timeout.timeout(3) { r.nubly(true) }
  r.sort_attached_nets; r.prepare_steps
  segs = extract_segments(r)
  stages['4_after_collapse'] = {segments: segs.length, crossings: count_crossings(segs), data: segs}
rescue Timeout::Error
  stages['4_after_collapse'] = {segments: 0, crossings: -1, data: []}
end

# Summary
summary = stages.map{|k,v| {stage: k, segments: v[:segments], crossings: v[:crossings]}}
output = {summary: summary, stages: stages.transform_values{|v| v[:data]}}
puts JSON.generate(output)
