# UW-NDR: On-Demand Neighbor Discovery & Dynamic Routing for DESERT Underwater

Dynamic, peer-to-peer multi-hop routing protocol (**`Module/UW/NDR`**) for decentralized Autonomous Underwater Vehicle (AUV) swarms in **DESERT Underwater / NS-Miracle**.

Designed to provide on-demand, any-to-any dynamic multi-hop routing in underwater acoustic networks without requiring manual static route provisioning (`Module/UW/StaticRouting`), without incurring the channel-saturating broadcast storms of continuous flooding (`Module/UW/FLOODING`), and without the sink-rooted topology constraints of tree-based protocols (`UW/SUN`, `UW/ICRP`).

---

## Architectural Context & Design Trade-Offs

In underwater acoustic networking, bandwidth is scarce ($4800\,\text{bps}$ nominal), propagation delay is high ($\approx 1500\,\text{m/s}$ acoustic velocity), and energy consumption during transmission is substantial.

| Protocol | Route Discovery | Path Selection | Recovery on Link Failure | Overhead Characteristics | Best-Fit Network Regime |
|---|---|---|---|---|---|
| **`UW/StaticRouting`** | None (manual Tcl) | Fixed static hops | None (silent packet drop) | Zero control overhead | Static anchor nodes, fixed relays |
| **`UW/FLOODING`** | None (every packet flooded) | All paths traversed | Implicit (multipath redundancy) | $O(N)$ retransmissions per data packet | High mobility (>1.5 m/s), dense swarms |
| **`UW/SUN` / `UW/ICRP`** | Proactive / tree-based | Sink-convergent | Tree re-parenting | Periodic control beacons | Oceanographic sensor networks to surface buoys |
| **`UW/NDR` (This Work)** | On-demand reactive | Single unicast path | Lease timeout / RERR re-probe | $O(1)$ control packets per route lifetime | Sparse topologies, linear convoys, low-to-moderate mobility (<1.0 m/s) |

---

## Key Features & Protocol Mechanics

- **On-Demand Path Discovery (`UWNDR_PROBE` / `UWNDR_REPLY`):** When an application generates a packet toward an unrouted destination, the originator broadcasts a hop-limited probe (`max_hop_count_`). Relays record reverse paths to the source. The target answers with a unicast `REPLY` that establishes forward routing state across intermediate hops.
- **Outbound Transmission Lease Decoupling (`refresh_on_tx_ = 0`):** In underwater networks running unacknowledged CSMA MAC protocols (`setNoAckMode`), outbound data transmissions cannot verify link delivery. If transmitting data reset the route timer, a dead or departed relay would permanently keep its route active, creating a silent blackhole. By decoupling lease renewals from outbound transmissions, route validity is strictly bounded by `route_lifetime_`.
- **Acoustic Retransmission Jitter (`probe_jitter_`):** When intermediate nodes rebroadcast discovery probes, a randomized acoustic backoff window ($\mathcal{U}[0, \text{probe\_jitter\_}]$) desynchronizes relay transmissions, preventing broadcast packet collisions under unslotted CSMA/ALOHA.
- **Physical Neighbor Disambiguation in Passive Learning:** Overhearing packets passively refreshes route leases only when the frame originates from a confirmed direct physical neighbor (`prev_hop == saddr`). Multi-hop forwarded packets never falsely overwrite hop counts.
- **Bounded Discovery & Deduplication History:** Probe histories (`seen_probes_`) and MAC-retry duplicate tables (`seen_data_pkts_`) are periodically pruned by an active expiration timer, bounding memory footprint and allowing rebooted nodes to re-discover topology without sequence-number lockout.
- **Outbound Packet Buffering with Age Eviction:** Outgoing CBR/UDP data packets wait in destination queues (`pending_queues_`) while route discovery is in flight and flush in order upon `REPLY`. Packets buffered longer than `max_buffer_time_` ($30\,\text{s}$) are dropped (`DROP_UWNDR_TIMEOUT`) to prevent buffer bloat during network partitioning.
- **DESERT `PacketHeader/LL` Memory Offset Fix:** Explicitly enables `PacketHeaderManager set tab_(PacketHeader/LL) 1` in `uwndr-default.tcl`, preventing `UWMllModule::sendDown` from corrupting byte offset `0` in NS-2 packet headers.

---

## Benchmark Evaluation & Empirical Results

All evaluations were executed in **DESERT Underwater 2.0 / NS-Miracle** using realistic acoustic physical layer parameters:
- **Acoustic Carrier:** $25\,\text{kHz}$, Bandwidth: $4800\,\text{bps}$, Spreading: $1.5$ (practical spreading), Depth: $-50\,\text{m}$.
- **Transducer:** $\text{MaxTxSPL\_dB\_} = 140\,\text{dB}\,\text{re}\,\mu\text{Pa}$, Transmit Power: $3.5\,\text{W}$, Receive Power: $0.8\,\text{W}$, Noise SPD: $50\,\text{dB}$.
- **MAC Layer:** `Module/UW/CSMA_ALOHA` with `setNoAckMode` (unacknowledged transmission).
- **Traffic:** `Module/UW/CBR` ($64\,\text{B}$ payload, $20\,\text{s}$ nominal period).

---

### 1. 5-Node 3000 m Multi-Hop Linear Baseline

Nodes are deployed linearly across $3000\,\text{m}$ (`Node 0` at $0\,\text{m} \rightarrow \text{Node 1} \rightarrow \text{Node 2} \rightarrow \text{Node 3}$ at $3000\,\text{m}$, with off-path neighbor `Node 4` at $(1000, 700)\,\text{m}$):

#### A. Single-Seed Extended Mission Duration ($1800\,\text{s}$ / 89 Packets)
From `results/baseline_comparison.csv` and `results/overhead_scaling.csv`:

| Protocol Mode | Delivered / Sent | PDR (%) | Mean FTT (s) | Goodput (bps) | Layer-3 Relays | Total MAC TX | Control Packets |
|---|---|---|---|---|---|---|---|
| `static_broken` (direct link) | 0 / 29 | **0.00%** | — | 0.00 | 0 | 29 | 0 |
| `static_oracle` (manual 3 hops) | 89 / 89 | **100.00%** | 3.6860 | 49.25 | 178 | 267 | 0 |
| `flooding` (`UW/FLOODING`) | 86 / 89 | **96.63%** | 3.7836 | 47.98 | 267 | 356 | 0 |
| **`uwndr` (`UW/NDR`, Ours)** | 88 / 89 | **98.88%** | 4.0062 | 49.45 | **177** | **277** | **11** |

*Key Result:* In static multi-hop routing, `UW/NDR` reduces Layer-3 data relays by **33.7%** (`177` vs `267`) and total MAC channel transmissions by **22.2%** (`277` vs `356`) compared to `UW/FLOODING`, achieving **98.88% PDR** with only 11 control packets over 30 minutes.

#### B. 10-Seed Monte Carlo Static Performance ($600\,\text{s}$ Duration, 95% Confidence Intervals)
From `results/mobility_summary.csv` at $0.0\,\text{m/s}$:

| Metric | `static_oracle` | `flooding` | `uwndr` (Ours) | Relative Advantage of UW-NDR |
|---|---|---|---|---|
| **Packet Delivery Ratio (PDR)** | $100.00 \pm 0.00\%$ | $94.83 \pm 3.13\%$ | **$99.31 \pm 1.04\%$** | $+4.48\%$ PDR over flooding ($p < 0.01$) |
| **Total MAC Transmissions** | $87.0 \pm 0.0$ | $116.0 \pm 0.0$ | **$94.1 \pm 0.86$** | **$-18.9\%$ MAC channel access** vs flooding |
| **Transmit Energy ($E_{\text{tx}}$)** | $61.73 \pm 0.00\,\text{J}$ | $82.94 \pm 0.00\,\text{J}$ | **$62.57 \pm 0.32\,\text{J}$** | **$-24.6\%$ TX energy** vs flooding |
| **Energy per Received Bit** | $3.595\,\text{mJ/bit}$ | $4.896 \pm 0.174\,\text{mJ/bit}$ | **$3.668 \pm 0.025\,\text{mJ/bit}$** | **$-25.1\%$ energy per bit** vs flooding |
| **Mean End-to-End Latency** | $3.693 \pm 0.038\,\text{s}$ | $3.795 \pm 0.032\,\text{s}$ | $3.984 \pm 0.169\,\text{s}$ | $+0.19\,\text{s}$ due to initial route setup |

---

### 2. Vehicle Mobility & Velocity Crossover Analysis

Simulated using a 3D Gauss-Markov mobility model across speeds $0.0\,\text{m/s}$ to $2.0\,\text{m/s}$ (10 seeds per speed step, $600\,\text{s}$ mission duration):

```
  Packet Delivery Ratio vs Speed (10 Seeds, 95% CI)
  100% +-------------------------------------------------------+
       |   O           O                                       |   O = Static Oracle
   95% |   #===========#===========#===========#===========#   |   # = Flooding
       |   *-----------*                                       |   * = UW-NDR (Ours)
   90% |                           *                           |
       |                                       *               |
   85% |                                                       |
       |                                                       |
   70% |                                               *       |
       +-------------------------------------------------------+
          0.0 m/s     0.5 m/s     1.0 m/s     1.5 m/s     2.0 m/s
```

Detailed metrics from `results/mobility_summary.csv`:

| Speed (m/s) | Static Oracle PDR (%) | Flooding PDR (%) | UW-NDR PDR (%) | UW-NDR MAC TX | Flooding MAC TX | Control Byte Ratio (%) |
|---|---|---|---|---|---|---|
| **$0.0\,\text{m/s}$** | $100.00 \pm 0.00\%$ | $94.83 \pm 3.13\%$ | **$99.31 \pm 1.04\%$** | $94.1 \pm 0.86$ | $116.0 \pm 0.0$ | $4.94 \pm 0.65\%$ |
| **$0.5\,\text{m/s}$** | $99.31 \pm 1.04\%$ | $95.52 \pm 2.86\%$ | **$97.59 \pm 3.30\%$** | $93.3 \pm 0.96$ | $115.8 \pm 0.45$ | $4.76 \pm 0.18\%$ |
| **$1.0\,\text{m/s}$** | $96.21 \pm 6.92\%$ | $96.21 \pm 3.17\%$ | **$94.14 \pm 8.47\%$** | $92.3 \pm 2.46$ | $114.9 \pm 2.04$ | $5.02 \pm 0.63\%$ |
| **$1.5\,\text{m/s}$** | $93.79 \pm 7.78\%$ | $95.52 \pm 3.50\%$ | **$86.21 \pm 10.40\%$** | $89.5 \pm 3.10$ | $113.8 \pm 2.65$ | $5.53 \pm 0.74\%$ |
| **$2.0\,\text{m/s}$** | $87.24 \pm 13.26\%$ | $93.10 \pm 4.65\%$ | **$68.97 \pm 16.81\%$** | $86.4 \pm 5.63$ | $115.7 \pm 0.68$ | $9.83 \pm 4.45\%$ |

#### Scientific Findings:
- **The $1.0\,\text{m/s}$ Operational Crossover:** At typical AUV survey velocities ($\le 1.0\,\text{m/s}$ / $\approx 2\,\text{knots}$), `UW/NDR` delivers **$94.1\%\text{--}99.3\%$ PDR**, closely matching the static oracle while saving $\approx 20\%$ channel access attempts and transmit power over flooding.
- **High-Velocity Breakdown:** Beyond $1.0\,\text{m/s}$ (at $1.5\,\text{m/s}$ and $2.0\,\text{m/s}$), node displacement outpaces on-demand route discovery and lease expiration. Under fast vehicle motion, `UW/NDR` PDR declines to $69.0\%$, whereas `UW/FLOODING` maintains $>93\%$ PDR through continuous multipath dissemination.

---

### 3. Dynamic Relay Failover & Link Recovery

Evaluated on a 5-node topology where the primary relay (Node 1) leaves acoustic range at $t = 200\,\text{s}$ (10 seeds, $800\,\text{s}$ duration):
- **Drift Failure:** Node 1 gradually drifts out of acoustic communication range ($0.5\,\text{m/s}$).
- **Teleport Failure:** Node 1 abruptly disappears (simulating catastrophic vehicle shutdown).

Detailed metrics from `results/failover_summary.csv`:

| Failure Mode | Protocol Mode | Overall PDR (%) | Post-Failure PDR (%) | Total MAC TX | Control Ratio (%) | Recovery Mechanism |
|---|---|---|---|---|---|---|
| **Drift** | `static` | $71.14 \pm 2.18\%$ | $63.71 \pm 2.73\%$ | $108.5 \pm 1.69$ | $0.0\%$ | None (permanent loss) |
| **Drift** | `flooding` | $96.14 \pm 1.72\%$ | $96.00 \pm 2.20\%$ | $165.8 \pm 1.21$ | $0.0\%$ | Autonomous multipath detour |
| **Drift** | **`uwndr` (Ours)** | **$73.41 \pm 5.89\%$** | **$67.14 \pm 7.96\%$** | **$117.5 \pm 5.05$** | **$4.45 \pm 0.66\%$** | Dynamic re-probe to secondary relay |
| **Teleport** | `static` | $20.45 \pm 0.00\%$ | $0.00 \pm 0.00\%$ | $62.0 \pm 0.00$ | $0.0\%$ | None ($100\%$ loss after $t=200\text{s}$) |
| **Teleport** | `flooding` | $95.91 \pm 2.40\%$ | $95.72 \pm 2.41\%$ | $139.0 \pm 1.07$ | $0.0\%$ | Autonomous multipath detour |
| **Teleport** | **`uwndr` (Ours)** | **$27.72 \pm 17.03\%$** | **$9.71 \pm 21.97\%$** | **$75.9 \pm 14.87$** | **$14.91 \pm 3.91\%$** | Passive lease timeout before re-probe |

#### Physical Protocol Constraints under Unacknowledged MAC:
- In unacknowledged CSMA (`setNoAckMode`), a departing or failing relay cannot transmit a MAC ACK or a Route Error (`RERR`).
- Therefore, link failure is detected **passively** through route lease expiration ($24\text{--}47\,\text{s}$ gap in successful runs). During this detection window, in-flight packets are buffered or lost.
- While `UW/FLOODING` inherently routes around broken nodes without route reconfiguration (at the cost of $41\%$ higher channel transmissions), `UW/NDR` must wait for route lease expiration before initiating fresh discovery. In scenarios where nodes drift gradually, `UW/NDR` retains $67.1\%$ post-failure delivery.

---

### 4. Swarm Matrix: Node Density & Traffic Load Scaling

Evaluated on multi-hop swarms varying from $4$ to $10$ nodes under multiple CBR packet generation periods ($10\,\text{s}$, $20\,\text{s}$, $40\,\text{s}$; 10 seeds each, $1200\,\text{s}$ duration, from `results/swarm_summary.csv`):

| Nodes | Period (s) | `flooding` PDR (%) | `uwndr` PDR (%) | `uwndr` MAC TX | `flooding` MAC TX | `uwndr` Control Byte Ratio (%) |
|---|---|---|---|---|---|---|
| **4** | 10 s | $70.26 \pm 13.79\%$ | **$80.59 \pm 3.92\%$** | $338.6 \pm 6.39$ | $315.4 \pm 15.93$ | $2.43 \pm 0.12\%$ |
| **4** | 20 s | $81.38 \pm 2.45\%$ | **$78.62 \pm 3.64\%$** | $170.1 \pm 4.27$ | $161.4 \pm 2.14$ | $4.94 \pm 0.28\%$ |
| **4** | 40 s | $70.71 \pm 13.77\%$ | **$68.57 \pm 6.46\%$** | $86.2 \pm 3.18$ | $74.9 \pm 3.98$ | $12.68 \pm 1.96\%$ |
| **6** | 10 s | $87.06 \pm 2.85\%$ | **$58.76 \pm 6.52\%$** | $389.4 \pm 14.10$ | $787.4 \pm 13.10$ | $4.11 \pm 0.70\%$ |
| **6** | 20 s | $82.99 \pm 5.85\%$ | **$52.07 \pm 9.62\%$** | $196.0 \pm 8.66$ | $384.9 \pm 14.10$ | $9.60 \pm 2.43\%$ |
| **8** | 10 s | $89.16 \pm 4.16\%$ | **$49.49 \pm 9.42\%$** | $393.7 \pm 19.41$ | $1113.7 \pm 28.43$ | $6.86 \pm 1.77\%$ |
| **8** | 40 s | $91.19 \pm 1.98\%$ | **$59.05 \pm 5.49\%$** | $122.5 \pm 9.46$ | $268.0 \pm 5.77$ | $27.81 \pm 9.51\%$ |
| **10** | 10 s | $95.88 \pm 2.36\%$ | **$56.44 \pm 6.08\%$** | $400.6 \pm 29.36$ | $1489.5 \pm 29.68$ | $7.45 \pm 1.07\%$ |
| **10** | 40 s | $94.53 \pm 2.41\%$ | **$61.19 \pm 8.27\%$** | $126.9 \pm 9.29$ | $350.9 \pm 5.93$ | $28.61 \pm 4.25\%$ |

#### Swarm Scaling Takeaway:
- In small networks ($N=4$), `UW/NDR` operates efficiently with negligible control overhead ($2.4\%$) and high PDR ($\approx 80\%$).
- In dense, concurrent swarms ($N=8\text{--}10$), flooding's brute-force redundancy achieves $95\%\text{--}97\%$ PDR by utilizing all available paths, but consumes **$3.7\times$ more MAC transmissions** ($1489$ vs $400$ packets). `UW/NDR` caps transmission count at the expense of lower PDR ($56\%\text{--}61\%$) due to probe collisions in unslotted CSMA and single-path bottlenecks.

---

### 5. Cooperative AUV Survey Trajectory Replay

Evaluated using synthetic 4-AUV cooperative survey lawnmower trajectories derived from Farol / DSOR ROS survey geometry (`farol_synthetic.csv`, 10 seeds, $1800\,\text{s}$ duration, from `results/farol_summary.csv`):

| Protocol Mode | PDR Mean (%) | 95% Confidence Interval | Mean FTT (s) | Total MAC TX | Control Ratio (%) | Energy per Bit (mJ/bit) |
|---|---|---|---|---|---|---|
| `static` | $79.54\%$ | $\pm 3.34\%$ | $4.020 \pm 0.038\,\text{s}$ | $241.8 \pm 3.69$ | $0.0\%$ | $3.586 \pm 0.096$ |
| `flooding` | $80.00\%$ | $\pm 2.71\%$ | $4.030 \pm 0.038\,\text{s}$ | $242.5 \pm 3.24$ | $0.0\%$ | $3.602 \pm 0.079$ |
| **`uwndr` (Ours)** | **$81.14\%$** | **$\pm 2.24\%$** | $4.159 \pm 0.052\,\text{s}$ | $255.3 \pm 3.07$ | $3.05 \pm 0.32\%$ | $3.587 \pm 0.058$ |

*Result:* All three protocols deliver statistically comparable PDR ($\approx 80\%\text{--}81\%$) across mobile survey trajectories. However, `UW/NDR` operates **autonomously** without requiring pre-computed static waypoint schedules.

---

### 6. Physical Layer Sensitivities (Noise & PER)

- **Acoustic Noise Sweeps (`results/noise_summary.csv`):** Under varying ambient noise ($40\,\text{dB}$ to $70\,\text{dB}\,\text{re}\,\mu\text{Pa}$), `UW/NDR` maintains stable single-path delivery until SNR drops below the reception threshold at $>65\,\text{dB}$.
- **Packet Error Rate (PER) Behavior:** In DESERT, PER sweeps scale unicast transmit power, while broadcast packets (probes and flooding data) transmit at default power levels. Consequently, broadcast-based protocols show invariant curves across PER target sweeps.

---

## Protocol Limitations & Assumptions

1. **Security & Authentication:** The current protocol header does not incorporate cryptographic signatures, message authentication codes (MACs), or nonces. It assumes a closed, cooperative military or oceanographic AUV team. In an untrusted environment, forged `UWNDR_ERROR` or `UWNDR_REPLY` frames could cause route disruption or blackhole redirection.
2. **First-Arrival Path Selection:** Routes are established by the first arriving `PROBE`. In multi-path acoustic channels, the earliest arrival may not always possess the highest SNR or the most stable channel coherence time.
3. **Simulation-Level Deduplication:** Frame deduplication relies on NS-2 packet UID (`ch->uid()`). Deployment on physical acoustic modems (e.g., Evologics, WHOI Micro-Modem) requires a dedicated sequence identifier within the Layer-3 header.

---

## Configuration & Parameter Tuning

Default parameters are declared in `src/uwndr/uwndr-default.tcl` and can be overridden via Tcl:

| Parameter | Type | Default | Benchmark Setting | Description |
|---|---|---|---|---|
| `max_hop_count_` | integer | `4` | `4` – `5` | Maximum acoustic relay hops allowed for PROBE dissemination |
| `probe_timeout_` | double | `15.0 s` | `15.0 s` | Minimum interval before re-probing the same unrouted destination |
| `probe_jitter_` | double | `0.1 s` | `0.1 s` | Randomized acoustic backoff window ($\mathcal{U}[0, \text{jitter}]$) for probe relaying |
| `route_lifetime_` | double | `60.0 s` | `180.0 s` | Routing table entry expiration lease time |
| `refresh_on_tx_` | integer | `0` | `0` | Outbound lease decoupling ($0 = \text{disabled}$ to prevent silent blackholes) |
| `max_buffer_pkts_`| integer | `20` | `20` | Maximum pending data packets held per destination |
| `max_buffer_time_`| double | `30.0 s` | `30.0 s` | Packet queue deadline before stale eviction (`DROP_UWNDR_TIMEOUT`) |

---

## Repository Structure

```text
desert-uwndr/
├── src/uwndr/                          # C++ Protocol Module & Standalone Build
│   ├── uwndr-hdr.h                     # Control header layout (PROBE, REPLY, ERROR)
│   ├── uwndr-module.h/.cpp             # Protocol state machine, timers & routing logic
│   ├── uwndr-default.tcl               # Default PacketHeaderManager & Tcl bindings
│   ├── initlib.cpp                     # Shared library entrypoint (Uwndr_Init)
│   └── Makefile                        # Standalone compilation -> libuwndr.so
├── simulations/
│   ├── demo_uwndr_multihop.tcl         # Live 5-node discovery and forwarding demo
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
    └── figures/                        # Generated vector and raster figures
```

---

## Quick Start (WSL + Linux)

### 1. Build Protocol Shared Library
```bash
source ../DESERT_Underwater/DESERT_buildCopy_LOCAL/environment
cd src/uwndr && make clean && make
```

### 2. Run Interactive Multi-Hop Demo
```bash
cd ../../simulations
ns demo_uwndr_multihop.tcl
```

### 3. Reproduce All Evaluation Benchmarks
```bash
# Smoke test (~20 s):
scripts/reproduce_results.sh --quick

# Full 10-seed Monte Carlo evaluation (~2 min):
scripts/reproduce_results.sh
```
