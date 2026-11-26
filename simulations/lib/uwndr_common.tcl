# ==============================================================================
# uwndr_common.tcl -- shared scenario library for the UW-NDR evaluation
# ==============================================================================
# Sourced by demo_failover.tcl, sweep_mobility.tcl, swarm_matrix.tcl and
# replay_farol.tcl. Keeps the protocol stack, PHY/MAC settings and metric
# extraction identical to simulations/compare_routing.tcl so every result is
# comparable with the v0.1 baseline (verified bit-exact on Nov 17).
#
# Arguments are passed as key=value pairs after the script name, e.g.
#   ns sweep_mobility.tcl mode=uwndr speed=1.0 seed=3 stoptime=605
#
# ndr_lib=<path> loads an alternative libuwndr.so (e.g. a Member A feature
# branch build) without touching src/uwndr.
#
# per_target only has an effect with spl_opt=1: DESERT's UW/PHYSICAL uses
# PER_target_ solely to pick the transmit SPL for unicast packets
# (UnderwaterMPhyBpsk::getTxPower). Broadcasts always use MaxTxSPL_dB_.
#
# Modes:
#   static   -- UW/StaticRouting, shortest-hop routes frozen from the t=0
#               geometry (best-case static: an omniscient planner at launch)
#   flooding -- UW/FLOODING
#   uwndr    -- UW/NDR (this project)
#
# Every script prints exactly one RESULT_HDR line and one RESULT_CSV line
# (plus optional ARRIVAL lines) so runners can grep them.
# ==============================================================================

# ------------------------------------------------------------------ arguments
proc uw_defaults {} {
    global opt
    array set opt {
        mode            uwndr
        seed            1
        starttime       5.0
        stoptime        605.0
        pktsize         125
        cbr_period      20.0
        freq            25000.0
        bw              5000.0
        bitrate         4800.0
        txpower         140.0
        per_target      0.01
        windspeed       0.0
        shipping        0.5
        ack_mode        setNoAckMode
        static_range    1250.0
        ndr_max_hops    5
        ndr_probe_to    15.0
        ndr_lifetime    180.0
        ndr_buffer      30
        verbose         0
        sample_dt       1.0
        print_arrivals  0
        tag             -
        ndr_lib         {}
        spl_opt         0
        spl_margin      10.0
    }
}

proc uw_parse_args {argv} {
    global opt
    foreach kv $argv {
        set idx [string first "=" $kv]
        if {$idx < 1} {
            puts stderr "Bad argument '$kv' (expected key=value)"
            exit 1
        }
        set k [string range $kv 0 [expr {$idx - 1}]]
        set v [string range $kv [expr {$idx + 1}] end]
        if {![info exists opt($k)]} {
            puts stderr "Unknown option '$k'. Known: [lsort [array names opt]]"
            exit 1
        }
        set opt($k) $v
    }
    if {[lsearch {static flooding uwndr} $opt(mode)] < 0} {
        puts stderr "mode must be static|flooding|uwndr (got $opt(mode))"
        exit 1
    }
}

# ------------------------------------------------------------------ libraries
proc uw_load_libs {} {
    global opt uw_script_dir
    load libMiracle.so
    load libMiracleBasicMovement.so
    load libmphy.so
    load libUwmStd.so
    load libuwinterference.so
    load libuwphy_clmsgs.so
    load libuwstats_utilities.so
    load libuwphysical.so
    load libuwcsmaaloha.so
    load libuwip.so
    load libuwmll.so
    load libuwudp.so
    load libuwcbr.so
    load libuwgmposition.so
    switch $opt(mode) {
        static   { load libuwstaticrouting.so }
        flooding { load libuwflooding.so }
        uwndr {
            if {$opt(ndr_lib) ne ""} {
                set lib [file normalize $opt(ndr_lib)]
            } else {
                set lib [file normalize [file join $uw_script_dir .. src uwndr libuwndr.so]]
            }
            if {![file exists $lib]} {
                puts stderr "libuwndr.so not found at $lib -- run make in src/uwndr first"
                exit 1
            }
            load $lib
        }
    }
    PacketHeaderManager set tab_(PacketHeader/LL) 1
}

# ------------------------------------------------------------------ simulator
proc uw_init_sim {} {
    global ns opt defaultRNG channel propagation data_mask tracefile cltracefile
    set ns [new Simulator]
    $ns use-Miracle

    # Independent replications: advance the default RNG to substream <seed>.
    for {set k 1} {$k < $opt(seed)} {incr k} {
        $defaultRNG next-substream
    }

    set tracefile   [open "/dev/null" w]
    set cltracefile [open "/dev/null" w]

    MPropagation/Underwater set windspeed_ $opt(windspeed)
    MPropagation/Underwater set shipping_  $opt(shipping)

    set channel     [new Module/UnderwaterChannel]
    set propagation [new MPropagation/Underwater]
    set data_mask   [new MSpectralMask/Rect]
    $data_mask setFreq      $opt(freq)
    $data_mask setBandwidth $opt(bw)

    Module/UW/CBR set packetSize_        $opt(pktsize)
    Module/UW/CBR set period_            $opt(cbr_period)
    Module/UW/CBR set PoissonTraffic_    0
    Module/UW/CBR set drop_out_of_order_ 0

    switch $opt(mode) {
        flooding {
            Module/UW/FLOODING set ttl_                6
            Module/UW/FLOODING set maximum_cache_time_ 60.0
            Module/UW/FLOODING set optimize_           1
        }
        uwndr {
            Module/UW/NDR set max_hop_count_   $opt(ndr_max_hops)
            Module/UW/NDR set probe_timeout_   $opt(ndr_probe_to)
            Module/UW/NDR set route_lifetime_  $opt(ndr_lifetime)
            Module/UW/NDR set max_buffer_pkts_ $opt(ndr_buffer)
            Module/UW/NDR set verbose_         $opt(verbose)
        }
    }

    Module/UW/CSMA_ALOHA set buffer_pkts_  100
    Module/UW/CSMA_ALOHA set max_tx_tries_ 3

    Module/UW/PHYSICAL set debug_                   0
    Module/UW/PHYSICAL set BitRate_                 $opt(bitrate)
    Module/UW/PHYSICAL set AcquisitionThreshold_dB_ 4.0
    Module/UW/PHYSICAL set RxSnrPenalty_dB_         -10.0
    Module/UW/PHYSICAL set TxSPLMargin_dB_          $opt(spl_margin)
    Module/UW/PHYSICAL set MaxTxSPL_dB_             $opt(txpower)
    Module/UW/PHYSICAL set MinTxSPL_dB_             10
    Module/UW/PHYSICAL set MaxTxRange_              50000
    Module/UW/PHYSICAL set PER_target_              $opt(per_target)
    Module/UW/PHYSICAL set CentralFreqOptimization_ 0
    Module/UW/PHYSICAL set BandwidthOptimization_   0
    Module/UW/PHYSICAL set SPLOptimization_         $opt(spl_opt)
}

# ------------------------------------------------------------------ positions
# kind = static | gm ; xyz = initial position ; speed in m/s for gm
proc uw_make_position {kind xyz {speed 0.0}} {
    if {$kind eq "gm"} {
        set p [new "Position/UWGM"]
        $p bound "REBOUNCE"
        $p speedMean $speed
    } else {
        set p [new "Position/BM"]
    }
    $p setX_ [lindex $xyz 0]
    $p setY_ [lindex $xyz 1]
    $p setZ_ [lindex $xyz 2]
    return $p
}

# Gauss-Markov field configuration (call before uw_make_position gm ...).
# alphaPitch_ = 1 keeps every AUV at its launch depth: in UwGMPosition the
# pitch innovation has unit variance and cannot be scaled, so any alphaPitch<1
# lets depth wander by hundreds of metres. Heading and speed are fully GM.
proc uw_config_gm {xw yw {alpha 0.9} {update 5.0}} {
    Position/UWGM set xFieldWidth_   $xw
    Position/UWGM set yFieldWidth_   $yw
    Position/UWGM set zFieldWidth_   0
    Position/UWGM set alpha_         $alpha
    Position/UWGM set alphaPitch_    1.0
    Position/UWGM set directionMean_ 0
    Position/UWGM set pitchMean_     0
    Position/UWGM set updateTime_    $update
}

# ------------------------------------------------------------------ nodes
proc uw_create_node {id pos} {
    global ns opt node udp ipr ipif mll mac phy position posdb interf
    global channel propagation data_mask tracefile cltracefile

    set node($id) [$ns create-M_Node $tracefile $cltracefile]
    set udp($id)  [new Module/UW/UDP]
    switch $opt(mode) {
        static   { set ipr($id) [new Module/UW/StaticRouting] }
        flooding { set ipr($id) [new Module/UW/FLOODING] }
        uwndr    { set ipr($id) [new Module/UW/NDR] }
    }
    set ipif($id) [new Module/UW/IP]
    set mll($id)  [new Module/UW/MLL]
    set mac($id)  [new Module/UW/CSMA_ALOHA]
    set phy($id)  [new Module/UW/PHYSICAL]

    $node($id) addModule 6 $udp($id)  0 "UDP"
    $node($id) addModule 5 $ipr($id)  0 "IPR"
    $node($id) addModule 4 $ipif($id) 0 "IPF"
    $node($id) addModule 3 $mll($id)  0 "MLL"
    $node($id) addModule 2 $mac($id)  0 "MAC"
    $node($id) addModule 1 $phy($id)  0 "PHY"

    $node($id) setConnection $udp($id)  $ipr($id)  0
    $node($id) setConnection $ipr($id)  $ipif($id) 0
    $node($id) setConnection $ipif($id) $mll($id)  0
    $node($id) setConnection $mll($id)  $mac($id)  0
    $node($id) setConnection $mac($id)  $phy($id)  0
    $node($id) addToChannel  $channel   $phy($id)  0

    set ip_addr [expr {$id + 1}]
    $ipif($id) addr $ip_addr
    if {$opt(mode) ne "static"} {
        $ipr($id) addr $ip_addr
    }
    if {$opt(mode) eq "uwndr"} {
        $ipr($id) initialize
    }

    set position($id) $pos
    $node($id) addPosition $position($id)
    set posdb($id) [new "PlugIn/PositionDB"]
    $node($id) addPlugin $posdb($id) 20 "PDB"
    $posdb($id) addpos [$mac($id) addr] $position($id)

    set interf($id) [new "Module/UW/INTERFERENCE"]
    $interf($id) set maxinterval_ 20.0
    $interf($id) set debug_ 0

    $phy($id) setPropagation  $propagation
    $phy($id) setSpectralMask $data_mask
    $phy($id) setInterference $interf($id)
    $mac($id) $opt(ack_mode)
    $mac($id) initialize
}

# ------------------------------------------------------------------ flows
# Each flow gets its own CBR sender at src and CBR sink at dst so per-flow
# PDR / FTT are exact even when nodes carry several flows.
set uw_flows {}
proc uw_add_flow {fid src dst} {
    global node udp cbr_tx cbr_rx uw_flows flow_src flow_dst ipif
    set cbr_tx($fid) [new Module/UW/CBR]
    set cbr_rx($fid) [new Module/UW/CBR]
    $node($src) addModule 7 $cbr_tx($fid) 0 "CBRTX$fid"
    $node($dst) addModule 7 $cbr_rx($fid) 0 "CBRRX$fid"
    $node($src) setConnection $cbr_tx($fid) $udp($src) 0
    $node($dst) setConnection $cbr_rx($fid) $udp($dst) 0
    set ptx [$udp($src) assignPort $cbr_tx($fid)]
    set prx [$udp($dst) assignPort $cbr_rx($fid)]
    $cbr_tx($fid) set destAddr_ [$ipif($dst) addr]
    $cbr_tx($fid) set destPort_ $prx
    $cbr_rx($fid) set destAddr_ [$ipif($src) addr]
    $cbr_rx($fid) set destPort_ $ptx
    set flow_src($fid) $src
    set flow_dst($fid) $dst
    lappend uw_flows $fid
}

# ------------------------------------------------------------------ routing
proc uw_dist {a b} {
    global position
    set dx [expr {[$position($a) getX_] - [$position($b) getX_]}]
    set dy [expr {[$position($a) getY_] - [$position($b) getY_]}]
    set dz [expr {[$position($a) getZ_] - [$position($b) getZ_]}]
    return [expr {sqrt($dx*$dx + $dy*$dy + $dz*$dz)}]
}

# BFS shortest-hop next hops from the current (t=0) geometry.
proc uw_static_routes {nn} {
    global opt ipr ipif uw_flows flow_src flow_dst
    set installed 0
    foreach fid $uw_flows {
        foreach {s d} [list $flow_src($fid) $flow_dst($fid) $flow_dst($fid) $flow_src($fid)] {
            # BFS from s
            array unset prev
            set prev($s) -1
            set frontier [list $s]
            while {[llength $frontier] > 0 && ![info exists prev($d)]} {
                set next {}
                foreach u $frontier {
                    for {set v 0} {$v < $nn} {incr v} {
                        if {![info exists prev($v)] && [uw_dist $u $v] <= $opt(static_range)} {
                            set prev($v) $u
                            lappend next $v
                        }
                    }
                }
                set frontier $next
            }
            if {![info exists prev($d)]} {
                # Disconnected at t=0: install direct route (will fail, as in static_broken)
                $ipr($s) addRoute [$ipif($d) addr] [$ipif($d) addr]
                continue
            }
            # walk back d -> s, install route at every hop
            set path [list $d]
            set cur $d
            while {$prev($cur) != -1} { set cur $prev($cur); set path [linsert $path 0 $cur] }
            for {set k 0} {$k < [llength $path] - 1} {incr k} {
                set here [lindex $path $k]
                set nh   [lindex $path [expr {$k + 1}]]
                if {![info exists routed($here,$d)]} {
                    $ipr($here) addRoute [$ipif($d) addr] [$ipif($nh) addr]
                    set routed($here,$d) 1
                    incr installed
                }
            }
        }
    }
    return $installed
}

proc uw_finalize {nn} {
    global opt mll ipif mac
    for {set i 0} {$i < $nn} {incr i} {
        for {set j 0} {$j < $nn} {incr j} {
            $mll($i) addentry [$ipif($j) addr] [$mac($j) addr]
        }
    }
    if {$opt(mode) eq "static"} {
        uw_static_routes $nn
    }
}

# ------------------------------------------------------------------ traffic
proc uw_schedule_traffic {} {
    global ns opt uw_flows cbr_tx
    foreach fid $uw_flows {
        # small stagger so concurrent flows do not start in the same slot
        set t0 [expr {$opt(starttime) + 0.37 * $fid}]
        $ns at $t0             "$cbr_tx($fid) start"
        $ns at $opt(stoptime)  "$cbr_tx($fid) stop"
    }
    uw_sampler_start
}

# Periodic sampler: records delivery instants per flow (resolution sample_dt)
# so failover outage / recovery can be measured without trace files.
proc uw_sampler_start {} {
    global ns opt uw_flows arrivals last_recv sent_at
    foreach fid $uw_flows { set arrivals($fid) {}; set last_recv($fid) 0 }
    $ns at $opt(sample_dt) "uw_sample"
}
proc uw_sample {} {
    global ns opt uw_flows cbr_rx arrivals last_recv
    set now [$ns now]
    foreach fid $uw_flows {
        set r [$cbr_rx($fid) getrecvpkts]
        while {$last_recv($fid) < $r} {
            lappend arrivals($fid) $now
            incr last_recv($fid)
        }
    }
    if {$now < $opt(stoptime) + 29.0} {
        $ns at [expr {$now + $opt(sample_dt)}] "uw_sample"
    }
}

# ------------------------------------------------------------------ metrics
proc uw_ctrl_stats {nn} {
    global opt ipr
    set pkts 0
    if {$opt(mode) eq "uwndr"} {
        for {set i 0} {$i < $nn} {incr i} {
            set pkts [expr {$pkts + [$ipr($i) getprobessent] + [$ipr($i) getprobesforwarded] \
                + [$ipr($i) getrepliessent] + [$ipr($i) getrepliesforwarded] + [$ipr($i) geterrorssent]}]
        }
        set hdr [$ipr(0) getndrheadersize]
    } else {
        set hdr 0
    }
    return [list $pkts [expr {$pkts * $hdr}]]
}

# Common result columns. extra_hdr/extra_vals let scripts append columns.
proc uw_report {nn {extra_hdr {}} {extra_vals {}}} {
    global opt uw_flows cbr_tx cbr_rx mac phy ipr
    set sent 0; set recv 0; set ftt_w 0.0; set per_flow {}
    foreach fid $uw_flows {
        set s [$cbr_tx($fid) getsentpkts]
        set r [$cbr_rx($fid) getrecvpkts]
        set f [$cbr_rx($fid) getftt]
        incr sent $s; incr recv $r
        set ftt_w [expr {$ftt_w + $f * $r}]
        lappend per_flow [format "%d:%d/%d" $fid $r $s]
    }
    set pdr [expr {$sent > 0 ? 100.0 * $recv / $sent : 0.0}]
    set ftt [expr {$recv > 0 ? $ftt_w / $recv : 0.0}]
    set mac_tx 0; set e_tx 0.0; set e_rx 0.0
    for {set i 0} {$i < $nn} {incr i} {
        incr mac_tx [$mac($i) getDataPktsTx]
        set e_tx [expr {$e_tx + [$phy($i) getConsumedEnergyTx]}]
        set e_rx [expr {$e_rx + [$phy($i) getConsumedEnergyRx]}]
    }
    lassign [uw_ctrl_stats $nn] ctrl_pkts ctrl_bytes
    set data_bytes [expr {$recv * $opt(pktsize)}]
    set ctrl_ratio [expr {$data_bytes > 0 ? 100.0 * $ctrl_bytes / $data_bytes : 0.0}]
    set e_bit [expr {$data_bytes > 0 ? ($e_tx + $e_rx) / (8.0 * $data_bytes) : 0.0}]

    set hdr [concat {tag mode seed nn cbr_period duration_s sent recv pdr_pct mean_ftt_s \
                     mac_tx_total ctrl_pkts ctrl_bytes ctrl_byte_ratio_pct energy_tx_j energy_rx_j \
                     energy_per_bit_j per_flow} $extra_hdr]
    set vals [concat [list $opt(tag) $opt(mode) $opt(seed) $nn $opt(cbr_period) \
        [format %.0f [expr {$opt(stoptime) - $opt(starttime)}]] $sent $recv [format %.2f $pdr] \
        [format %.4f $ftt] $mac_tx $ctrl_pkts $ctrl_bytes [format %.3f $ctrl_ratio] \
        [format %.3f $e_tx] [format %.3f $e_rx] [format %.6g $e_bit] [join $per_flow ";"]] $extra_vals]
    puts "RESULT_HDR,[join $hdr ,]"
    puts "RESULT_CSV,[join $vals ,]"
}

proc uw_print_arrivals {} {
    global uw_flows arrivals
    foreach fid $uw_flows {
        puts "ARRIVALS,$fid,[join $arrivals($fid) " "]"
    }
}

proc uw_run {nn {extra_proc {}}} {
    global ns opt tracefile cltracefile
    uw_schedule_traffic
    $ns at [expr {$opt(stoptime) + 30.0}] "uw_finish $nn {$extra_proc}; $ns halt"
    $ns run
}
proc uw_finish {nn extra_proc} {
    global ns opt tracefile cltracefile
    if {$extra_proc ne ""} {
        lassign [$extra_proc] eh ev
        uw_report $nn $eh $ev
    } else {
        uw_report $nn
    }
    if {$opt(print_arrivals)} { uw_print_arrivals }
    $ns flush-trace
    close $tracefile
    close $cltracefile
}
