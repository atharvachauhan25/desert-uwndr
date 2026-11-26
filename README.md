# UW-NDR: On-Demand Neighbor Discovery & Dynamic Routing for DESERT Underwater

Dynamic, peer-to-peer multi-hop routing protocol (**`Module/UW/NDR`**) for decentralized Autonomous Underwater Vehicle (AUV) swarms in **DESERT Underwater / NS-Miracle**.

Designed to replace `Module/UW/StaticRouting` without incurring the broadcast-storm overhead of `Module/UW/FLOODING` or the sink-rooted constraint of `UW/SUN` and `UW/ICRP`.

---

## Key Features & Protocol Innovations
- **ARP-Style On-Demand Route Discovery (`UWNDR_PROBE` / `UWNDR_REPLY`):** Nodes broadcast bounded hop-limited probes (`max_hop_count_`) only when no valid route exists, dynamically learning reverse and forward paths across intermediate AUV relays.
- **Outbound Packet Buffering (`pending_queues_`):** Holds outgoing CBR/UDP data packets while route discovery is in flight and flushes them in order once `REPLY` arrives.
- **Outbound Lease Decoupling (`refresh_on_tx_ = 0`):** Decouples outbound data transmission from lease renewals under unacknowledged CSMA MAC (`setNoAckMode`), strictly bounding route lifetimes to prevent permanent silent routing blackholes when relays depart.
- **Immediate On-Demand RERR Re-probe:** Intercepts Route Errors (`UWNDR_ERROR`) and immediately triggers re-discovery if packets are waiting in queue, slashing route repair latency to $<1.5\,\text{s}$.
- **MAC-Layer Retry Deduplication Cache (`DROP_UWNDR_DUP`):** Evicts duplicate frames within a 30s detection window at Layer 3 to prevent upper-layer application corruption.
- **Buffer Queue-Age Deadline Eviction (`DROP_UWNDR_TIMEOUT`):** Periodically purges stale packets waiting longer than `max_buffer_time_` ($30\,\text{s}$) to prevent buffer bloat during network partitioning.
- **Hardware-Level Control Overhead Counters:** Real-time tracking of `total_ctrl_bytes_` and `total_data_bytes_` with Tcl inspection hooks.
- **DESERT `PacketHeader/LL` Fix:** Explicitly enables `PacketHeaderManager set tab_(PacketHeader/LL) 1` in `uwndr-default.tcl`, preventing `UWMllModule::sendDown` from overwriting byte offset `0` in NS-2 packet headers.

---

## Evaluation Suite & Benchmark Results

### 1. 5-Node 3000 m Multi-Hop Acoustic Baseline
Testbed: 5 nodes across 3000 m (`Node 0` at 0 m $\rightarrow$ `Node 3` at 3000 m, off-path neighbor `Node 4` at `(1000, 700)`, depth `-50 m`, `25 kHz`, `4800 bps`, `MaxTxSPL_dB_ = 140 dB`, `CSMA_ALOHA` `setNoAckMode`, `cbr_period = 20 s`):

| Protocol Mode | Mission 600 s PDR | Mean FTT (s) | MAC TX (600 s) | MAC TX (1800 s) | 1800 s PDR | Manual Routes Needed? |
|---|---|---|---|---|---|---|
| `static_broken` (`UW/StaticRouting` direct) | **0.00%** (0/29) | — | 29 | — | — | Yes (fails at >2 km) |
| `static_oracle` (`UW/StaticRouting` manual) | **100.00%** (29/29) | 3.5924 | 87 | 267 | **100.00%** (89/89) | Yes (3 static hops) |
| `flooding` (`UW/FLOODING` built-in) | **96.55%** (28/29) | 3.8009 | 116 | 356 | **96.63%** (86/89) | No |
| **`uwndr` (`UW/NDR`, Ours)** | **96.55%** (28/29) | 4.6080 | **97** | **277** | **98.88%** (88/89) | **No (11 ctrl pkts total)** |

At 1800 s, `UW/NDR` cuts total MAC transmissions by **22.2%** (`277` vs `356`) and Layer-3 data relays by **33.7%** (`177` vs `267`) compared to `UW/FLOODING`, while maintaining **98.88% PDR** with negligible control overhead.

### 2. Dynamic Relay Failover (`simulations/demo_failover.tcl`)
At $t = 200\,\text{s}$, the primary relay (Node 1) leaves the acoustic cluster (teleporting / drifting out of range). 
- **Static Routing:** Completely fails after $t = 200\,\text{s}$ (**0.00% post-failure PDR**).
- **UW-NDR:** Dynamically detects link failure, re-discovers secondary relay Node 4, and achieves **>90% post-failure PDR** with fast re-convergence.

### 3. Cooperative Multi-AUV Survey Replay (`simulations/replay_farol.tcl`)
Replays realistic 4-AUV cooperative survey lawnmower trajectories derived from the Farol / DSOR ROS stack. UW-NDR dynamically routes telemetry between moving vehicles across changing acoustic topologies, maintaining **>81% PDR** without prior trajectory knowledge.

---

## Repository Structure
```text
desert-uwndr/
├── src/uwndr/                          # C++ Protocol Module & Standalone Makefile
│   ├── uwndr-hdr.h                     # Control header layout (PROBE, REPLY, ERROR)
│   ├── uwndr-module.h/.cpp             # Protocol implementation, state machine & timers
│   ├── uwndr-default.tcl               # Default PacketHeaderManager & Tcl bindings
│   ├── initlib.cpp                     # Shared library initialization hook (Uwndr_Init)
│   └── Makefile                        # Standalone build -> libuwndr.so
├── simulations/
│   ├── demo_uwndr_multihop.tcl         # Live 5-node demo printing PROBE/REPLY discovery
│   ├── compare_routing.tcl             # 4-mode routing benchmark (static/oracle/flooding/uwndr)
│   ├── demo_failover.tcl               # Dynamic relay failure & recovery testbed
│   ├── sweep_mobility.tcl              # 3D Gauss-Markov mobility sweep
│   ├── swarm_matrix.tcl                # Concurrent multi-flow swarm evaluation
│   ├── replay_farol.tcl                # 4-AUV cooperative survey trajectory replay
│   ├── lib/
│   │   └── uwndr_common.tcl            # Shared DESERT scenario configuration library
│   └── trajectories/
│       ├── farol_synthetic.csv         # Synthetic AUV survey waypoints (NED coordinates)
│       └── farol_synthetic.tcl         # Generated DESERT mobility trace
├── scripts/
│   ├── reproduce_results.sh            # Single-command runner reproducing all evaluation figures
│   ├── run_montecarlo.py               # Multi-seed Monte Carlo sweep execution engine
│   ├── plot_sweeps.py                  # Publication-grade error-bar visualizer
│   ├── import_ros_waypoints.py         # ROS/DSOR NED -> DESERT ENU waypoint converter
│   ├── export_failover_timeline.py     # Packet delivery timeline extractor
│   ├── plot_nov12_demo.py              # Baseline comparison plotter
│   └── run_valgrind_audit.sh           # Automated Valgrind memory leak verification
└── results/                            # Benchmark CSVs & Generated Figures
    ├── baseline_comparison.csv
    ├── failover_summary.csv / failover_timeline.csv
    ├── mobility_summary.csv / swarm_summary.csv
    ├── noise_summary.csv / per_summary.csv
    └── figures/                        # Publication figures (PNG & PDF)
        ├── failover_timeline.png
        ├── mobility_pdr_mactx.png
        ├── swarm_matrix.png
        ├── farol_replay.png
        └── uwndr_ctrl_overhead.png
```

---

## Quick Start (WSL + Linux)

### 1. Build Protocol Shared Library
```bash
source ../DESERT_Underwater/DESERT_buildCopy_LOCAL/environment
cd src/uwndr && make
```

### 2. Run Simulations
```bash
cd ../../simulations

# Run verbose live 5-node multi-hop discovery demo
ns demo_uwndr_multihop.tcl

# Run dynamic relay failover simulation
ns demo_failover.tcl mode=uwndr

# Run cooperative AUV survey replay
ns replay_farol.tcl mode=uwndr
```

### 3. Reproduce All Evaluation Benchmarks
```bash
# Single command smoke test (~20s):
scripts/reproduce_results.sh --quick

# Full 10-seed Monte Carlo evaluation (~2 min):
scripts/reproduce_results.sh
```
