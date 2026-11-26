# ==============================================================================
# demo_failover.tcl -- Dynamic relay failover testbed            [Task B1.1/B1.3]
# ==============================================================================
# Usage:
#   ns demo_failover.tcl mode=<static|flooding|uwndr> [fail_time=200] \
#        [depart=teleport|drift] [drift_speed=2.0] [stoptime=905] [seed=1] ...
#
# Topology (same as compare_routing.tcl, single-hop range ~1250 m):
#   Node 0 (IP1) (   0,   0,-50)  source        --> flow to Node 3
#   Node 1 (IP2) (1000,   0,-50)  PRIMARY relay  (leaves at fail_time)
#   Node 2 (IP3) (2000,   0,-50)  relay
#   Node 3 (IP4) (3000,   0,-50)  destination
#   Node 4 (IP5) (1000, 700,-50)  BACKUP relay   (~1220 m to Node 0 and Node 2)
#
# At t = fail_time Node 1 leaves the field:
#   depart=teleport : jumps to (1000,-6000) -- abrupt loss (surfacing / fault)
#   depart=drift    : cruises to (1000,-6000) at drift_speed m/s
# Static routes are frozen through Node 1, so StaticRouting must drop to 0%
# after the failure. A dynamic protocol must re-converge through Node 4.
#
# Extra result columns:
#   fail_time, max_gap_s (largest delivery gap after the failure; equals
#   time-to-end-of-run if nothing arrives again), recovery_s (max_gap_s minus
#   the nominal CBR spacing), recovered (1 if any packet arrives after the
#   failure), pre_pdr_pct / post_pdr_pct (PDR before / after fail_time).
# ==============================================================================

set uw_script_dir [file dirname [file normalize [info script]]]
source [file join $uw_script_dir lib uwndr_common.tcl]

uw_defaults
set opt(stoptime)    905.0
set opt(fail_time)   200.0
set opt(depart)      teleport
set opt(drift_speed) 2.0
set opt(tag)         failover
uw_parse_args $argv
uw_load_libs
uw_init_sim

set nn 5
set coords {
    {0     0   -50}
    {1000  0   -50}
    {2000  0   -50}
    {3000  0   -50}
    {1000  700 -50}
}
for {set i 0} {$i < $nn} {incr i} {
    uw_create_node $i [uw_make_position static [lindex $coords $i]]
}
uw_add_flow 0 0 3
uw_finalize $nn

# --- relay departure ----------------------------------------------------------
proc relay_depart {} {
    global opt position
    if {$opt(depart) eq "drift"} {
        $position(1) setdest 1000 -6000 $opt(drift_speed)
    } else {
        $position(1) setX_ 1000
        $position(1) setY_ -6000
    }
}
$ns at $opt(fail_time) "relay_depart"

# snapshot counters at fail_time for pre/post PDR
proc snap {} {
    global cbr_tx cbr_rx snap_sent snap_recv
    set snap_sent [$cbr_tx(0) getsentpkts]
    set snap_recv [$cbr_rx(0) getrecvpkts]
}
$ns at $opt(fail_time) "snap"

proc failover_metrics {} {
    global opt arrivals cbr_tx cbr_rx snap_sent snap_recv
    set tf $opt(fail_time)
    set end [expr {$opt(stoptime) + 30.0}]
    # last delivery at/before the failure
    set prev $tf
    foreach t $arrivals(0) { if {$t <= $tf} { set prev $t } }
    set max_gap 0.0
    foreach t $arrivals(0) {
        if {$t <= $tf} continue
        set g [expr {$t - $prev}]
        if {$g > $max_gap} { set max_gap $g }
        set prev $t
    }
    # Recovered = deliveries continue until the end of the run (the last CBR
    # packet leaves at stoptime, the run ends 30 s later). Otherwise the
    # trailing silence is the outage.
    set tail [expr {$end - $prev}]
    set recovered [expr {$tail <= 2 * $opt(cbr_period) + 30.0}]
    if {!$recovered && $tail > $max_gap} { set max_gap $tail }
    set rec_s [expr {$max_gap - $opt(cbr_period)}]
    if {$rec_s < 0} { set rec_s 0.0 }
    set s_all [$cbr_tx(0) getsentpkts]
    set r_all [$cbr_rx(0) getrecvpkts]
    set pre  [expr {$snap_sent > 0 ? 100.0 * $snap_recv / $snap_sent : 0.0}]
    set ps   [expr {$s_all - $snap_sent}]
    set post [expr {$ps > 0 ? 100.0 * ($r_all - $snap_recv) / $ps : 0.0}]
    return [list {fail_time depart max_gap_s recovery_s recovered pre_pdr_pct post_pdr_pct} \
                 [list $tf $opt(depart) [format %.1f $max_gap] [format %.1f $rec_s] $recovered \
                       [format %.2f $pre] [format %.2f $post]]]
}

uw_run $nn failover_metrics
