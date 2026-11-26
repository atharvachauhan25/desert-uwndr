# ==============================================================================
# sweep_mobility.tcl -- 3D Gauss-Markov mobility scenario         [Task B1.2/WP2]
# ==============================================================================
# Usage:
#   ns sweep_mobility.tcl mode=<static|flooding|uwndr> speed=<m/s> [seed=1] \
#        [mobile=all|relays] [stoptime=605] [gm_alpha=0.9] ...
#
# The 5-node v0.1 testbed (0 -> 3 over ~3 km, off-path Node 4) is placed in a
# bounded 3000 m x 1400 m field (translated by +350 m in y so every launch
# point is inside the field) at -50 m depth. Every AUV (or only relays 1, 2, 4
# with mobile=relays) follows DESERT's native Position/UWGM model with mean
# speed <speed> and REBOUNCE walls.
#
# Model notes (see docs/report):
#   * UwGMPosition draws the speed/heading innovations from N(0,1) with no
#     scale parameter, so the stationary speed std is ~1 m/s for any alpha.
#     The sweep therefore varies the MEAN speed, as the planner specifies.
#   * alphaPitch_ = 1 holds each AUV at launch depth (unscaled pitch noise
#     would otherwise drive depth by hundreds of metres).
#   * mode=static installs shortest-hop routes from the t = 0 geometry.
# ==============================================================================

set uw_script_dir [file dirname [file normalize [info script]]]
source [file join $uw_script_dir lib uwndr_common.tcl]

uw_defaults
set opt(speed)    1.0
set opt(mobile)   all
set opt(gm_alpha) 0.9
set opt(gm_dt)    5.0
set opt(tag)      mobility
uw_parse_args $argv
uw_load_libs
uw_init_sim

uw_config_gm 3000.0 1400.0 $opt(gm_alpha) $opt(gm_dt)

set nn 5
set coords {
    {0     350  -50}
    {1000  350  -50}
    {2000  350  -50}
    {3000  350  -50}
    {1000  1050 -50}
}
for {set i 0} {$i < $nn} {incr i} {
    set is_mobile [expr {$opt(mobile) eq "all" || [lsearch {1 2 4} $i] >= 0}]
    if {$is_mobile && $opt(speed) > 0} {
        set p [uw_make_position gm [lindex $coords $i] $opt(speed)]
    } else {
        set p [uw_make_position static [lindex $coords $i]]
    }
    uw_create_node $i $p
}
uw_add_flow 0 0 3
uw_finalize $nn

# Track mean source-destination separation as a sanity check of the mobility.
set sep_sum 0.0; set sep_n 0
proc track_sep {} {
    global ns opt sep_sum sep_n
    set sep_sum [expr {$sep_sum + [uw_dist 0 3]}]
    incr sep_n
    if {[$ns now] < $opt(stoptime)} { $ns at [expr {[$ns now] + 10.0}] "track_sep" }
}
$ns at 1.0 "track_sep"

proc mob_metrics {} {
    global opt sep_sum sep_n
    return [list {speed mobile mean_sd_sep_m} \
                 [list $opt(speed) $opt(mobile) [format %.0f [expr {$sep_sum / max($sep_n,1)}]]]]
}

uw_run $nn mob_metrics
