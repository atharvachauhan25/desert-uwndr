# ==============================================================================
# replay_farol.tcl -- Replay ROS/Farol trajectories in DESERT       [Task B3.2]
# ==============================================================================
# Usage:
#   ns replay_farol.tcl mode=<static|flooding|uwndr> \
#        [traj=trajectories/farol_synthetic.tcl] [flows=0>3,3>0] [seed=1] ...
#
# The trajectory file is produced by scripts/import_ros_waypoints.py
# (vehicle mvectorK -> node K -> IP K+1, ENU with z <= 0). Each node is a
# Position/BM that is re-anchored on every waypoint and then cruises to the
# next one at the speed implied by the waypoint spacing (piece-wise linear
# replay; depth is stepped at each waypoint).
#
# Default flows: node 0 -> node N-1 and back (end-to-end across the formation).
# stoptime defaults to the trajectory duration minus 5 s.
# ==============================================================================

set uw_script_dir [file dirname [file normalize [info script]]]
source [file join $uw_script_dir lib uwndr_common.tcl]

uw_defaults
set opt(traj)     trajectories/farol_synthetic.tcl
set opt(flows)    auto
set opt(stoptime) auto
set opt(tag)      farol
uw_parse_args $argv

set tfile $opt(traj)
if {[file pathtype $tfile] ne "absolute"} {
    set tfile [file join $uw_script_dir $tfile]
}
if {![file exists $tfile]} { puts stderr "trajectory file not found: $tfile"; exit 1 }
source $tfile
set nn $traj_nn
if {$opt(stoptime) eq "auto"} { set opt(stoptime) [expr {$traj_duration - 5.0}] }

uw_load_libs
uw_init_sim

for {set i 0} {$i < $nn} {incr i} {
    uw_create_node $i [uw_make_position static [lrange [lindex $traj($i) 0] 1 3]]
}

if {$opt(flows) eq "auto"} { set opt(flows) "0>[expr {$nn - 1}],[expr {$nn - 1}]>0" }
set fid 0
foreach f [split $opt(flows) ,] {
    lassign [split $f >] s d
    uw_add_flow $fid $s $d
    incr fid
}
uw_finalize $nn

# --- waypoint replay ------------------------------------------------------------
proc wp_leg {i x y z nx ny speed} {
    global position
    $position($i) setX_ $x
    $position($i) setY_ $y
    $position($i) setZ_ $z
    $position($i) setdest $nx $ny $speed
}
set legs 0
for {set i 0} {$i < $nn} {incr i} {
    set pts $traj($i)
    for {set k 0} {$k < [llength $pts] - 1} {incr k} {
        lassign [lindex $pts $k] t x y z
        lassign [lindex $pts [expr {$k + 1}]] t2 nx ny nz
        set dt [expr {$t2 - $t}]
        if {$dt <= 0} continue
        set sp [expr {hypot($nx - $x, $ny - $y) / $dt}]
        # BM ignores setdest at t <= 0
        set at [expr {max($t, 0.001)}]
        $ns at $at "wp_leg $i $x $y $z $nx $ny $sp"
        incr legs
    }
}

# mean / max neighbour distance along the replay (formation sanity check)
set d_sum 0.0; set d_n 0; set d_max 0.0
proc track_formation {} {
    global ns opt nn d_sum d_n d_max
    for {set i 0} {$i < $nn - 1} {incr i} {
        set d [uw_dist $i [expr {$i + 1}]]
        set d_sum [expr {$d_sum + $d}]; incr d_n
        if {$d > $d_max} { set d_max $d }
    }
    if {[$ns now] < $opt(stoptime)} { $ns at [expr {[$ns now] + 10.0}] "track_formation" }
}
$ns at 1.0 "track_formation"

proc farol_metrics {} {
    global opt d_sum d_n d_max legs
    return [list {traj legs mean_neighbour_m max_neighbour_m} \
                 [list [file tail $opt(traj)] $legs [format %.0f [expr {$d_sum / max($d_n,1)}]] \
                       [format %.0f $d_max]]]
}

uw_run $nn farol_metrics
