#!/usr/bin/env ruby
require 'json'

# Port of circles_touching_convex_hull from geometry.rb
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

def distance_line_point_squared(x1, y1, x2, y2, x0, y0)
  x12 = x2-x1; y12 = y2-y1
  ((x12*(y1-y0)-(x1-x0)*y12)**2).fdiv(x12**2+y12**2)
end

# Simplified test with 4 circles
circles = [
  {x: 0, y: 0, r: 100},
  {x: 500, y: 0, r: 50},
  {x: 250, y: 250, r: 80},
  {x: 250, y: -100, r: 30},
]

# Step 1: Remove fully overlapping
inner = []
circles.combination(2){|a, b|
  if (a[:x]-b[:x])**2 + (a[:y]-b[:y])**2 < (b[:r]-a[:r])**2
    inner << (a[:r] < b[:r] ? a : b)
  end
}
verts = circles - inner
verts.sort!{|a,b| a[:x] != b[:x] ? a[:x] <=> b[:x] : a[:y] <=> b[:y]}

# Step 2: Monotone chain hull of centers
hull = []
verts.each{|v|
  while hull.length > 1
    x1, y1 = hull[-2][:x], hull[-2][:y]
    x2, y2 = hull[-1][:x], hull[-1][:y]
    break unless (x2-x1)*(v[:y]-y2) < (y2-y1)*(v[:x]-x2)
    hull.pop
  end
  hull.push(v)
}
lower = []
verts.reverse_each{|v|
  while lower.length > 1
    x1, y1 = lower[-2][:x], lower[-2][:y]
    x2, y2 = lower[-1][:x], lower[-1][:y]
    break unless (x2-x1)*(v[:y]-y2) < (y2-y1)*(v[:x]-x2)
    lower.pop
  end
  lower.push(v)
}
hull.pop; lower.pop
hull += lower

puts JSON.generate({
  input: circles.map{|c| [c[:x], c[:y], c[:r]]},
  after_overlap_removal: verts.map{|c| [c[:x], c[:y], c[:r]]},
  center_hull: hull.map{|c| [c[:x], c[:y], c[:r]]},
})
