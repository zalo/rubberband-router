require 'json'
load 'src/router_ruby.rb'
input = JSON.parse(File.read("test/crossing_graph.json"))
r = RBR::Router.new
r.build_from_json(input)
r.netlist.sort_by!{|n| n.pri}
puts "Sorted nets:"
r.netlist.each_with_index{|net, i|
  puts "  #{i}: #{net.t1_name}->#{net.t2_name} pri=#{net.pri}"
}
r.netlist.each_with_index{|net, i|
  ok = r.route(i)
  # Extract path
  path_parts = []
  r.vertices.each{|vert|
    vert.incident_nets.each{|n|
      next unless n.id == net.id && n.next
      path_parts = [vert.name]
      step = n.nstep
      while step
        path_parts << "#{step.vertex.name}(r=#{step.radius.round},rgt=#{step.rgt})"
        step = step.nstep
      end
    }
  }
  puts "Net #{i}: #{net.t1_name}->#{net.t2_name} = #{ok} path=#{path_parts.join(' -> ')}"
}
