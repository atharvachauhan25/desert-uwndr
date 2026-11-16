# UW-NDR: On-Demand Neighbor Discovery & Dynamic Routing for DESERT Underwater

Dynamic, peer-to-peer multi-hop routing protocol (**`Module/UW/NDR`**) for decentralized Autonomous Underwater Vehicle (AUV) swarms in **DESERT Underwater / NS-Miracle**.

Designed to replace `Module/UW/StaticRouting` without incurring the broadcast-storm overhead of `Module/UW/FLOODING` or the sink-rooted constraint of `UW/SUN` and `UW/ICRP`.

---

## Key Features (v0.1 Prototype)
- **ARP-Style On-Demand Route Discovery (`UWNDR_PROBE` / `UWNDR_REPLY`):** Nodes broadcast bounded hop-limited probes (`max_hop_count_`) only when no valid route exists, dynamically learning reverse and forward paths across intermediate AUV relays.
- **Outbound Packet Buffering (`pending_queues_`):** Holds outgoing CBR/UDP data packets while route discovery is in flight and flushes them in order once `REPLY` arrives.
- **Active Route Lease Renewal & Periodic Expiry (`UwNdrExpireTimer`):** Refreshes `expire_time` when data actively traverses a path while expiring stale entries after `route_lifetime_` seconds.
- **Route Error Propagation (`UWNDR_ERROR`):** Emits hop-by-hop RERR notifications upstream when an intermediate relay encounters a missing/expired route.
- **Standalone Build:** Compiles directly into `libuwndr.so` against the local DESERT `.buildHost` headers without modifying or rebuilding the core `DESERT_Underwater` tree.
- **DESERT `PacketHeader/LL` Fix:** Explicitly enables `PacketHeaderManager set tab_(PacketHeader/LL) 1` in `uwndr-default.tcl`, preventing `UWMllModule::sendDown` from overwriting byte offset `0` in NS-2 packet headers.

---

## Verified Baseline Results (Nov 11, 2026)
Testbed: 5-node 3000 m multi-hop acoustic topology (`Node 0` at 0 m -> `Node 3` at 3000 m, off-path neighbor `Node 4` at `(1000, 700)`, depth `-50 m`, `25 kHz`, `4800 bps`, `MaxTxSPL_dB_ = 140 dB`, `CSMA_ALOHA` `setNoAckMode`, `cbr_period = 20 s`):

| Protocol Mode | Mission 600 s PDR | Mean FTT (s) | MAC TX (600 s) | MAC TX (1800 s) | 1800 s PDR | Manual Routes Needed? |
|---|---|---|---|---|---|---|
| `static_broken` (`UW/StaticRouting` direct) | **0.00%** (0/29) | — | 29 | — | — | Yes (fails at >2 km) |
| `static_oracle` (`UW/StaticRouting` manual) | **100.00%** (29/29) | 3.5924 | 87 | 267 | **100.00%** (89/89) | Yes (3 static hops) |
| `flooding` (`UW/FLOODING` built-in) | **96.55%** (28/29) | 3.8009 | 116 | 356 | **96.63%** (86/89) | No |
| **`uwndr` (`UW/NDR`, Ours)** | **96.55%** (28/29) | 4.6080 | **97** | **277** | **98.88%** (88/89) | **No (11 ctrl pkts total)** |

At 1800 s, `UW/NDR` cuts total MAC transmissions by **22.2%** (`277` vs `356`) and Layer-3 data relays by **33.7%** (`177` vs `267`) compared to `UW/FLOODING`, while exceeding `UW/FLOODING` delivery ratio (`98.88%` vs `96.63%`) using only **11 constant control packets** across the full 30-minute run.

---

## Repository Structure
```text
desert-uwndr/
├── src/uwndr/                  # C++ protocol module & standalone Makefile
│   ├── uwndr-hdr.h             # Control header (PROBE, REPLY, ERROR)
│   ├── uwndr-module.h/.cpp     # UwNdrModule implementation & Tcl commands
│   ├── uwndr-default.tcl       # Default PacketHeaderManager & Tcl bindings
│   ├── initlib.cpp             # Shared library init hook (Uwndr_Init)
│   └── Makefile                # Standalone g++ + tcl2c++ build -> libuwndr.so
├── simulations/
│   ├── demo_uwndr_multihop.tcl # Verbose live 5-node demo printing PROBE/REPLY & routing tables
│   ├── compare_routing.tcl     # Parameterized benchmark across all 4 protocol modes
│   └── run_benchmarks.sh       # Automated runner generating baseline & scaling CSVs
├── scripts/
│   └── plot_nov12_demo.py      # Generates 3-panel matplotlib comparison plot
├── results/                    # Benchmark CSVs & PNG plots
└── simulations/
    ├── compare_routing.tcl     # Parameterized benchmark across all 4 protocol modes
    ├── demo_uwndr_multihop.tcl # Verbose live 5-node demo printing PROBE/REPLY & routing tables
    └── run_benchmarks.sh       # Automated runner generating baseline & scaling CSVs
```

---

## Collaborating on This Repository (2-Person Workflow)
1. Clone cleanly & configure line endings: `git config core.autocrlf input`
2. Build `src/uwndr/libuwndr.so` locally (`make` — binaries remain untracked via `.gitignore`).
3. Work on scoped feature branches (`feat/a-*` for `src/uwndr/`, `feat/b-*` for `simulations/`, `scripts/`).
4. Verify `./simulations/run_benchmarks.sh` before merging Pull Requests into `main`.

---

## Quick Start (WSL + Windows)

```bash
# 1. Build libuwndr.so in WSL
source ../DESERT_Underwater/DESERT_buildCopy_LOCAL/environment
cd desert-uwndr/src/uwndr && make

# 2. Run verbose live demo (shows runtime PROBE/REPLY discovery & routing tables)
cd ../../simulations
ns demo_uwndr_multihop.tcl

# 3. Run full comparison suite (writes results/*.csv)
./run_benchmarks.sh
```

On Windows PowerShell/CMD:
```powershell
python scripts\plot_nov12_demo.py
```
