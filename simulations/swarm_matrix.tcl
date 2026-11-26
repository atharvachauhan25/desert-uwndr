# ==============================================================================
# swarm_matrix.tcl -- Multi-flow AUV swarm scenario                [WP3, B2.1]
# ==============================================================================
# Usage:
#   ns swarm_matrix.tcl mode=<static|flooding|uwndr> nn=<4..10> \
#        [cbr_period=20] [speed=1.0] [seed=1] [stoptime=605] ...
#
# Layout (field 3000 m x 2100 m, depth -50 m, single-hop range ~1250 m):
#   row A  y= 700 : N0 (0)   N1 (1000)  N2 (2000)  N3 (3000)   <- v0.1 chain
#   row B  y=1400 : N6 (0)   N4 (1000)  N5 (2000)  N7 (3000)
#   row C  y=   0 :          N8 (1000)  N9 (2000)
# Nodes are added in index order, so nn=4 is the bare chain and nn=5 is the
# v0.1 testbed (N4 = off-path neighbour at ~1220 m from N0 / N2).
#
# Concurrent CBR flows (planner WP3):  0 -> 3,  3 -> 0,  4 -> 2 (if nn >= 5)
# All nodes follow Position/UWGM at mean speed <speed> (0 = static).
# ==============================================================================

set uw_script_dir [file dirname [file normalize [info script]]]
source [file join $uw_script_dir lib uwndr_common.tcl]

uw_defaults
set opt(nn)       5
set opt(speed)    1.0
set opt(gm_alpha) 0.9
set opt(gm_dt)    5.0
set opt(tag)      swarm
uw_parse_args $argv
if {$opt(nn) < 4 || $opt(nn) > 10} { puts stderr "nn must be 4..10"; exit 1 }
uw_load_libs
uw_init_sim
uw_config_gm 3000.0 2100.0 $opt(gm_alpha) $opt(gm_dt)

set layout {
    {0    700 -50} {1000  700 -50} {2000  700 -50} {3000  700 -50}
    {1000 1400 -50} {2000 1400 -50} {0   1400 -50} {3000 1400 -50}
    {1000    0 -50} {2000    0 -50}
}
set nn $opt(nn)
for {set i 0} {$i < $nn} {incr i} {
    if {$opt(speed) > 0} {
        set p [uw_make_position gm [lindex $layout $i] $opt(speed)]
    } else {
        set p [uw_make_position static [lindex $layout $i]]
    }
    uw_create_node $i $p
}
uw_add_flow 0 0 3
uw_add_flow 1 3 0
if {$nn >= 5} { uw_add_flow 2 4 2 }
uw_finalize $nn

proc swarm_metrics {} {
    global opt uw_flows cbr_tx cbr_rx
    # min per-flow PDR exposes starvation of one flow by another
    set minp 100.0
    foreach fid $uw_flows {
        set s [$cbr_tx($fid) getsentpkts]; set r [$cbr_rx($fid) getrecvpkts]
        set p [expr {$s > 0 ? 100.0 * $r / $s : 0.0}]
        if {$p < $minp} { set minp $p }
    }
    return [list {speed n_flows min_flow_pdr_pct} \
                 [list $opt(speed) [llength $uw_flows] [format %.2f $minp]]]
}

uw_run $nn swarm_metrics
