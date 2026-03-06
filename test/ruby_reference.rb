#!/usr/bin/env ruby
# Extract and test pure-Ruby functions from the original router
# Output JSON for comparison with TypeScript

require 'json'

# From router.rb - the cross product functions
def boolean_really_smart_cross_product_2d_with_offset(ax, ay, bx, by, ox, oy)
  ax -= ox; ay -= oy; bx -= ox; by -= oy
  if (p = ax * by - ay * bx) != 0
    p > 0
  else
    ax != bx ? ax < bx : ay < by
  end
end

# xboolean version (uses rx/ry for a,b and vertex.x/y for o)
# Note: original line 113 has bug (b.ox instead of b.oy), we use correct version
def xboolean_cross_product(arx, ary, brx, bry, ox, oy)
  boolean_really_smart_cross_product_2d_with_offset(arx, ary, brx, bry, ox, oy)
end

# get_tangents from router.rb line 1643
def get_tangents(x1, y1, r1, l1, x2, y2, r2, l2)
  d = Math.hypot(x1 - x2, y1 - y2)
  return [x1, y1, x2, y2] if d == 0
  vx = (x2 - x1) / d
  vy = (y2 - y1) / d
  r2 *= (l1 == l2  ? 1 : -1)
  c = (r1 - r2) / d
  h = 1 - c ** 2
  h = 0 if h < 0
  h = Math.sqrt(h) * (l1  ? -1 : 1)
  nx = vx * c - h * vy
  ny = vy * c + h * vx
  [x1 + r1 * nx, y1 + r1 * ny, x2 + r2 * nx,  y2 + r2 * ny]
end

# normal_distance_line_segment_point_squared from router.rb line 891
def normal_distance_line_segment_point_squared(bx, by, cx, cy, px, py, mbd)
  mx = cx - bx; my = cy - by
  hx = px - bx; hy = py - by
  t0 = (mx * hx + my * hy).fdiv(mx ** 2 + my ** 2)
  if t0 > 0 && t0 < 1
    (hx - t0 * mx) ** 2 + (hy - t0 * my) ** 2
  else
    mbd
  end
end

# new_bor_list logic - given vertex positions, which neighbors are in the inner angle?
def new_bor_list_test(ax, ay, bx, by, nx, ny, neighbors)
  # a,b,n are vertex coordinates
  dax = ax - nx; day = ay - ny
  dbx = bx - nx; dby = by - ny
  turn = boolean_really_smart_cross_product_2d_with_offset(ax, ay, bx, by, nx, ny)
  neighbors.select{|ex, ey|
    dex = ex - nx; dey = ey - ny
    if turn
      dax * dey > day * dex && dex * dby > dey * dbx
    else
      dax * dey < day * dex && dex * dby < dey * dbx
    end
  }
end

# full_split_neighbor_list logic
def full_split_test(arx, ary, brx, bry, nvx, nvy, neighbors_rx_ry)
  v1x = arx - nvx; v1y = ary - nvy
  v2x = brx - nvx; v2y = bry - nvy
  turn = boolean_really_smart_cross_product_2d_with_offset(arx, ary, brx, bry, nvx, nvy)
  l = []; r = []
  neighbors_rx_ry.each{|erx, ery|
    ex = erx - nvx; ey = ery - nvy
    if (turn ? v1x * ey > v1y * ex && v2x * ey < v2y * ex : v1x * ey > v1y * ex || v2x * ey < v2y * ex)
      l << [erx, ery]
    else
      r << [erx, ery]
    end
  }
  [r, l]  # returns [right, left]
end

results = {}

# Test 1: Cross product with various inputs
test_cases_cp = [
  [100, 0, 0, 100, 0, 0],    # simple CCW
  [0, 100, 100, 0, 0, 0],    # simple CW
  [100, 0, 200, 0, 0, 0],    # collinear
  [50, 50, 100, 100, 0, 0],  # collinear same direction
  [100, 50, 50, 100, 75, 75], # with offset
  [-50, 30, 40, -60, 10, 20], # negative coords
  [1000, 500, 500, 1000, 750, 750], # larger coords
]
results['cross_product'] = test_cases_cp.map{|args| boolean_really_smart_cross_product_2d_with_offset(*args)}

# Test 2: Tangents
test_cases_tan = [
  [0, 0, 100, true, 500, 0, 100, true],
  [0, 0, 100, false, 500, 0, 100, false],
  [0, 0, 100, true, 500, 0, 100, false],
  [0, 0, 50, true, 300, 400, 50, true],
  [100, 200, 30, false, 400, 100, 60, true],
]
results['tangents'] = test_cases_tan.map{|args| get_tangents(*args)}

# Test 3: new_bor_list
neighbors1 = [[200, 100], [100, 200], [50, 50], [150, 150], [0, 100]]
results['bor_list'] = new_bor_list_test(300, 100, 100, 300, 200, 200, neighbors1)

# Test 4: full_split
neighbors2 = [[150, 50], [50, 150], [250, 250], [50, 50], [200, 100]]
results['full_split'] = full_split_test(100, 0, 0, 100, 100, 100, neighbors2)

# Test 5: normal distance
results['normal_dist'] = [
  normal_distance_line_segment_point_squared(0, 0, 100, 0, 50, 30, 999999),
  normal_distance_line_segment_point_squared(0, 0, 100, 0, 150, 30, 999999),
  normal_distance_line_segment_point_squared(0, 0, 100, 100, 50, 0, 999999),
]

puts JSON.generate(results)
