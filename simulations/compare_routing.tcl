# ==============================================================================
# DESERT Routing Protocol Benchmark: Static vs Flooding vs UW-NDR
# ==============================================================================
# Usage: ns compare_routing.tcl <mode>
#   mode in { static_broken, static_oracle, flooding, uwndr }
#
# Fixed 5-node 3000m multi-hop acoustic topology (Z = -50m, txpower = 140 dB):
#   Node 0 (IP 1): (   0,   0, -50)  -- Source AUV (Flow -> IP 4)
#   Node 1 (IP 2): (1000,   0, -50)  -- Relay AUV 1
#   Node 2 (IP 3): (2000,   0, -50)  -- Relay AUV 2
#   Node 3 (IP 4): (3000,   0, -50)  -- Destination AUV
#   Node 4 (IP 5): (1000, 700, -50)  -- Off-path Neighbor AUV
# ==============================================================================

if {$argc < 1} {
    puts "Usage: ns compare_routing.tcl <static_broken|static_oracle|flooding|uwndr> \[stoptime=605.0\]"
    exit 1
}
set mode [lindex $argv 0]
set opt_stoptime 605.0
if {$argc >= 2} {
    set opt_stoptime [lindex $argv 1]
}

set script_dir [file dirname [file normalize [info script]]]
set uwndr_lib  [file normalize [file join $script_dir .. src uwndr libuwndr.so]]

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

if {$mode eq "static_broken" || $mode eq "static_oracle"} {
    load libuwstaticrouting.so
} elseif {$mode eq "flooding"} {
    load libuwflooding.so
} elseif {$mode eq "uwndr"} {
    load $uwndr_lib
} else {
    puts "Unknown mode: $mode"
    exit 1
}

PacketHeaderManager set tab_(PacketHeader/LL) 1

set ns [new Simulator]
$ns use-Miracle

set opt(nn)          5
set opt(starttime)   5.0
set opt(stoptime)    $opt_stoptime
set opt(pktsize)     125
set opt(cbr_period)  20.0
set opt(freq)        25000.0
set opt(bw)          5000.0
set opt(bitrate)     4800.0
set opt(txpower)     140.0
set opt(ack_mode)    "setNoAckMode"

set tracefile   [open "/dev/null" w]
set cltracefile [open "/dev/null" w]

set channel     [new Module/UnderwaterChannel]
set propagation [new MPropagation/Underwater]
set data_mask   [new MSpectralMask/Rect]
$data_mask setFreq      $opt(freq)
$data_mask setBandwidth $opt(bw)

Module/UW/CBR set packetSize_        $opt(pktsize)
Module/UW/CBR set period_            $opt(cbr_period)
Module/UW/CBR set PoissonTraffic_    0
Module/UW/CBR set drop_out_of_order_ 0

if {$mode eq "flooding"} {
    Module/UW/FLOODING set ttl_                      6
    Module/UW/FLOODING set maximum_cache_time_       60.0
    Module/UW/FLOODING set optimize_                 1
} elseif {$mode eq "uwndr"} {
    Module/UW/NDR set max_hop_count_    5
    Module/UW/NDR set probe_timeout_    15.0
    Module/UW/NDR set route_lifetime_   180.0
    Module/UW/NDR set max_buffer_pkts_  30
    Module/UW/NDR set verbose_          0
}

Module/UW/CSMA_ALOHA set buffer_pkts_  100
Module/UW/CSMA_ALOHA set max_tx_tries_ 3

Module/UW/PHYSICAL set debug_                   0
Module/UW/PHYSICAL set BitRate_                 $opt(bitrate)
Module/UW/PHYSICAL set AcquisitionThreshold_dB_ 4.0
Module/UW/PHYSICAL set RxSnrPenalty_dB_         -10.0
Module/UW/PHYSICAL set TxSPLMargin_dB_          10.0
Module/UW/PHYSICAL set MaxTxSPL_dB_             $opt(txpower)
Module/UW/PHYSICAL set MinTxSPL_dB_             10
Module/UW/PHYSICAL set MaxTxRange_              50000
Module/UW/PHYSICAL set PER_target_              0.01
Module/UW/PHYSICAL set CentralFreqOptimization_ 0
Module/UW/PHYSICAL set BandwidthOptimization_   0
Module/UW/PHYSICAL set SPLOptimization_         0

for {set id 0} {$id < $opt(nn)} {incr id} {
    set node($id) [$ns create-M_Node $tracefile $cltracefile]

    set cbr($id)  [new Module/UW/CBR]
    set udp($id)  [new Module/UW/UDP]
    if {$mode eq "static_broken" || $mode eq "static_oracle"} {
        set ipr($id) [new Module/UW/StaticRouting]
    } elseif {$mode eq "flooding"} {
        set ipr($id) [new Module/UW/FLOODING]
    } else {
        set ipr($id) [new Module/UW/NDR]
    }
    set ipif($id) [new Module/UW/IP]
    set mll($id)  [new Module/UW/MLL]
    set mac($id)  [new Module/UW/CSMA_ALOHA]
    set phy($id)  [new Module/UW/PHYSICAL]

    $node($id) addModule 7 $cbr($id)  0 "CBR"
    $node($id) addModule 6 $udp($id)  0 "UDP"
    $node($id) addModule 5 $ipr($id)  0 "IPR"
    $node($id) addModule 4 $ipif($id) 0 "IPF"
    $node($id) addModule 3 $mll($id)  0 "MLL"
    $node($id) addModule 2 $mac($id)  0 "MAC"
    $node($id) addModule 1 $phy($id)  0 "PHY"

    $node($id) setConnection $cbr($id)  $udp($id)  0
    $node($id) setConnection $udp($id)  $ipr($id)  0
    $node($id) setConnection $ipr($id)  $ipif($id) 0
    $node($id) setConnection $ipif($id) $mll($id)  0
    $node($id) setConnection $mll($id)  $mac($id)  0
    $node($id) setConnection $mac($id)  $phy($id)  0
    $node($id) addToChannel  $channel   $phy($id)  0

    set portnum($id) [$udp($id) assignPort $cbr($id)]
    set ip_addr [expr $id + 1]
    $ipif($id) addr $ip_addr
    if {$mode eq "flooding"} {
        $ipr($id) addr $ip_addr
    } elseif {$mode eq "uwndr"} {
        $ipr($id) addr $ip_addr
        $ipr($id) initialize
    }

    set position($id) [new "Position/BM"]
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

for {set i 0} {$i < $opt(nn)} {incr i} {
    for {set j 0} {$j < $opt(nn)} {incr j} {
        $mll($i) addentry [$ipif($j) addr] [$mac($j) addr]
    }
}

set coords {
    {0     0   -50}
    {1000  0   -50}
    {2000  0   -50}
    {3000  0   -50}
    {1000  700 -50}
}
for {set i 0} {$i < $opt(nn)} {incr i} {
    set xyz [lindex $coords $i]
    $position($i) setX_ [lindex $xyz 0]
    $position($i) setY_ [lindex $xyz 1]
    $position($i) setZ_ [lindex $xyz 2]
}

if {$mode eq "static_broken"} {
    # Misconfigured / direct static assumption (3000m out of range)
    $ipr(0) addRoute [$ipif(3) addr] [$ipif(3) addr]
} elseif {$mode eq "static_oracle"} {
    # Hand-coded omniscient multi-hop static path 1 -> 2 -> 3 -> 4
    $ipr(0) addRoute [$ipif(3) addr] [$ipif(1) addr]
    $ipr(1) addRoute [$ipif(3) addr] [$ipif(2) addr]
    $ipr(2) addRoute [$ipif(3) addr] [$ipif(3) addr]
}

$cbr(0) set destAddr_ [$ipif(3) addr]
$cbr(0) set destPort_ $portnum(3)

$ns at $opt(starttime) "$cbr(0) start"
$ns at $opt(stoptime)  "$cbr(0) stop"

proc finish {} {
    global ns opt mode cbr ipr mac tracefile cltracefile

    set sent [$cbr(0) getsentpkts]
    set recv [$cbr(3) getrecvpkts]
    set pdr  [expr {$sent > 0 ? (100.0 * $recv / $sent) : 0.0}]
    set thr  [$cbr(3) getthr]
    set ftt  [$cbr(3) getftt]

    set mac_tx_total 0
    for {set i 0} {$i < $opt(nn)} {incr i} {
        set mac_tx_total [expr $mac_tx_total + [$mac($i) getDataPktsTx]]
    }

    set data_fwd 0
    set ctrl_pkts 0
    if {$mode eq "flooding"} {
        for {set i 0} {$i < $opt(nn)} {incr i} {
            set data_fwd [expr $data_fwd + [$ipr($i) getpacketsforwarded]]
        }
    } elseif {$mode eq "uwndr"} {
        for {set i 0} {$i < $opt(nn)} {incr i} {
            set data_fwd  [expr $data_fwd + [$ipr($i) getdataforwarded]]
            set ctrl_pkts [expr $ctrl_pkts + [$ipr($i) getprobessent] + \
                                [$ipr($i) getprobesforwarded] + \
                                [$ipr($i) getrepliessent] + \
                                [$ipr($i) getrepliesforwarded] + \
                                [$ipr($i) geterrorssent]]
        }
    } elseif {$mode eq "static_oracle"} {
        # Each MAC TX at relays (nodes 1 and 2) represents a forwarded packet
        set data_fwd [expr [$mac(1) getDataPktsTx] + [$mac(2) getDataPktsTx]]
    }

    puts [format "RESULT_CSV,%s,%.0f,%d,%d,%.2f,%.4f,%.2f,%d,%d,%d" \
          $mode [expr $opt(stoptime) - $opt(starttime)] $sent $recv $pdr $ftt $thr $data_fwd $ctrl_pkts $mac_tx_total]

    $ns flush-trace
    close $tracefile
    close $cltracefile
}

$ns at [expr $opt(stoptime) + 30.0] "finish; $ns halt"
$ns run
