require 'json'
load 'src/router_ruby.rb'
input = JSON.parse(File.read("test/crossing_graph.json"))
r = RBR::Router.new
r.build_from_json(input)
r.netlist.sort_by!{|n| n.pri}
r.netlist.each_with_index{|net, i|
  puts "#{i}: #{net.t1_name}->#{net.t2_name} pri=#{net.pri}"
}
