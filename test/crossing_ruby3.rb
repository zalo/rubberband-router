require 'json'
load 'src/router_ruby.rb'
input = JSON.parse(File.read("test/crossing_graph.json"))
r = RBR::Router.new
r.build_from_json(input)
r.netlist.sort_by!{|n| n.pri}

r.netlist.each_with_index{|net, i|
  ok = r.route(i)
  # Search ALL vertices for this net's incident nets
  found = false
  r.vertices.each{|vert|
    vert.incident_nets.each{|n|
      next unless n.id == net.id
      if n.next
        parts = [vert.name]
        step = n.nstep
        while step
          parts << "#{step.vertex.name}(r=#{step.radius.round},rgt=#{step.rgt})"
          step = step.nstep
        end
        puts "Net #{i}: #{net.t1_name}->#{net.t2_name} = #{ok}  #{parts.join(' -> ')}"
        found = true
      end
    }
  }
  puts "Net #{i}: #{net.t1_name}->#{net.t2_name} = #{ok}  (no path found)" unless found
}
