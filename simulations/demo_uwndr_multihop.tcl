# ==============================================================================
# UW-NDR Multi-Hop Dynamic Routing Demo (DESERT Underwater / NS-Miracle)
# ==============================================================================
# Demonstrates ARP-style on-demand Neighbor Discovery & Dynamic Routing (UW-NDR)
# over a 5-node AUV topology where Node 0 (1) and Node 3 (4) are 3000 m apart
# (out of direct acoustic range) and NO static routes are configured.
#
# Topology (Z = -50 m, nominal range ~1300-1500 m):
#   Node 0 (IP 1): (   0,   0, -50)  -- Source AUV
#   Node 1 (IP 2): (1000,   0, -50)  -- Relay AUV 1
#   Node 2 (IP 3): (2000,   0, -50)  -- Relay AUV 2
#   Node 3 (IP 4): (3000,   0, -50)  -- Destination AUV / Leader
#   Node 4 (IP 5): (1000, 700, -50)  -- Off-path Neighbor AUV
# ==============================================================================

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
load $uwndr_lib

set ns [new Simulator]
$ns use-Miracle

set opt(nn)           5
set opt(starttime)    5.0
set opt(stoptime)     605.0
set opt(pktsize)      125
set opt(cbr_period)   20.0
set opt(freq)         25000.0
set opt(bw)           5000.0
set opt(bitrate)      4800.0
set opt(txpower)      140.0
set opt(ack_mode)     "setNoAckMode"

set tracefile   [open "/dev/null" w]
set cltracefile [open "/dev/null" w]

set channel     [new Module/UnderwaterChannel]
set propagation [new MPropagation/Underwater]
set data_mask   [new MSpectralMask/Rect]
$data_mask setFreq      $opt(freq)
$data_mask setBandwidth $opt(bw)

Module/UW/CBR set packetSize_         $opt(pktsize)
Module/UW/CBR set period_             $opt(cbr_period)
Module/UW/CBR set PoissonTraffic_     0
Module/UW/CBR set drop_out_of_order_  0

Module/UW/NDR set max_hop_count_      5
Module/UW/NDR set probe_timeout_      15.0
Module/UW/NDR set route_lifetime_     180.0
Module/UW/NDR set max_buffer_pkts_    30
Module/UW/NDR set verbose_            1

Module/UW/CSMA_ALOHA set buffer_pkts_ 100
Module/UW/CSMA_ALOHA set max_tx_tries_ 3

Module/UW/PHYSICAL set debug_                    0
Module/UW/PHYSICAL set BitRate_                  $opt(bitrate)
Module/UW/PHYSICAL set AcquisitionThreshold_dB_  4.0
Module/UW/PHYSICAL set RxSnrPenalty_dB_          -10.0
Module/UW/PHYSICAL set TxSPLMargin_dB_           10.0
Module/UW/PHYSICAL set MaxTxSPL_dB_              $opt(txpower)
Module/UW/PHYSICAL set MinTxSPL_dB_              10
Module/UW/PHYSICAL set MaxTxRange_               50000
Module/UW/PHYSICAL set PER_target_               0.01
Module/UW/PHYSICAL set CentralFreqOptimization_  0
Module/UW/PHYSICAL set BandwidthOptimization_    0
Module/UW/PHYSICAL set SPLOptimization_          0

for {set id 0} {$id < $opt(nn)} {incr id} {
    set node($id) [$ns create-M_Node $tracefile $cltracefile]

    set cbr($id)  [new Module/UW/CBR]
    set udp($id)  [new Module/UW/UDP]
    set ipr($id)  [new Module/UW/NDR]
    set ipif($id) [new Module/UW/IP]
    set mll($id)  [new Module/UW/MLL]
    set mac($id)  [new Module/UW/CSMA_ALOHA]
    set phy($id)  [new Module/UW/PHYSICAL]

    $node($id) addModule 7 $cbr($id)  0 "CBR"
    $node($id) addModule 6 $udp($id)  0 "UDP"
    $node($id) addModule 5 $ipr($id)  0 "NDR"
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
    $ipr($id)  addr $ip_addr
    $ipr($id)  initialize

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

# Populate MLL ARP entries (MAC <-> IP mapping)
for {set i 0} {$i < $opt(nn)} {incr i} {
    for {set j 0} {$j < $opt(nn)} {incr j} {
        $mll($i) addentry [$ipif($j) addr] [$mac($j) addr]
    }
}

# 5-node multi-hop geometry (Node 0 and Node 3 are 3000m apart -> 3 hops minimum)
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

# Traffic Flow: Node 0 (IP 1) -> Node 3 (IP 4), NO manual addRoute anywhere!
$cbr(0) set destAddr_ [$ipif(3) addr]
$cbr(0) set destPort_ $portnum(3)

$ns at $opt(starttime) "$cbr(0) start"
$ns at $opt(stoptime)  "$cbr(0) stop"

proc finish {} {
    global ns opt cbr ipr tracefile cltracefile
    puts "\n======================================================================"
    puts "UW-NDR DYNAMIC ROUTING TABLES (Auto-Discovered at Runtime)"
    puts "======================================================================"
    for {set i 0} {$i < $opt(nn)} {incr i} {
        $ipr($i) printroutes
    }

    set sent [$cbr(0) getsentpkts]
    set recv [$cbr(3) getrecvpkts]
    set pdr [expr {$sent > 0 ? (100.0 * $recv / $sent) : 0.0}]
    set thr [$cbr(3) getthr]
    set ftt [$cbr(3) getftt]

    set total_probes 0
    set total_probe_fwd 0
    set total_replies 0
    set total_reply_fwd 0
    set total_data_fwd 0
    for {set i 0} {$i < $opt(nn)} {incr i} {
        set total_probes    [expr $total_probes + [$ipr($i) getprobessent]]
        set total_probe_fwd [expr $total_probe_fwd + [$ipr($i) getprobesforwarded]]
        set total_replies   [expr $total_replies + [$ipr($i) getrepliessent]]
        set total_reply_fwd [expr $total_reply_fwd + [$ipr($i) getrepliesforwarded]]
        set total_data_fwd  [expr $total_data_fwd + [$ipr($i) getdataforwarded]]
    }
    set ctrl_pkts [expr $total_probes + $total_probe_fwd + $total_replies + $total_reply_fwd]

    puts "\n======================================================================"
    puts "UW-NDR MULTI-HOP SUMMARY (Node 0 -> Node 3 over 3000m, 0 static routes)"
    puts "======================================================================"
    puts [format "  Sent Packets         : %d" $sent]
    puts [format "  Received Packets     : %d" $recv]
    puts [format "  Packet Delivery (PDR): %.2f %%" $pdr]
    puts [format "  Mean Latency (FTT)   : %.4f s" $ftt]
    puts [format "  Goodput              : %.2f bps" $thr]
    puts [format "  DATA Relays (Unicast): %d" $total_data_fwd]
    puts [format "  Control Packets      : %d (probes=%d, probe_fwd=%d, replies=%d, reply_fwd=%d)" \
          $ctrl_pkts $total_probes $total_probe_fwd $total_replies $total_reply_fwd]
    puts "======================================================================"

    $ns flush-trace
    close $tracefile
    close $cltracefile
}

$ns at [expr $opt(stoptime) + 30.0] "finish; $ns halt"
$ns run
