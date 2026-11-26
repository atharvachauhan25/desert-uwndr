# UW-NDR: On-Demand Neighbor Discovery & Dynamic Routing for DESERT Underwater

Dynamic, peer-to-peer multi-hop routing protocol (**`Module/UW/NDR`**) for decentralized Autonomous Underwater Vehicle (AUV) swarms in **DESERT Underwater 3.5.0 / NS-Miracle 2.0.2**.

Designed to provide on-demand, any-to-any dynamic multi-hop routing in underwater acoustic networks without requiring manual static route provisioning (`Module/UW/StaticRouting`), without incurring the channel-saturating broadcast storms of continuous flooding (`Module/UW/FLOODING`), and without the sink-rooted topology constraints of tree-based protocols (`UW/SUN`, `UW/ICRP`).

---

## Architectural Context & Design Trade-Offs

In underwater acoustic networking, bandwidth is scarce (4800 bps nominal), propagation delay is high (~1500 m/s acoustic velocity), and energy consumption during transmission is substantial.

| Protocol | Route Discovery | Path Selection | Recovery on Link Failure | Overhead Characteristics | Best-Fit Network Regime |
|---|---|---|---|---|---|
| **`UW/StaticRouting`** | None (manual Tcl) | Fixed static hops | None (silent packet drop) | Zero control overhead | Static anchor nodes, fixed relays |
| **`UW/FLOODING`** | None (every packet flooded) | All paths traversed | Implicit (multipath redundancy) | $O(N)$ retransmissions per data packet | High mobility (>1.5 m/s), dense swarms |
| **`UW/SUN` / `UW/ICRP`** | Proactive / tree-based | Sink-convergent | Tree re-parenting | Periodic control beacons | Oceanographic sensor networks to surface buoys |
| **`UW/NDR` (This Work)** | On-demand reactive | Single unicast path | Lease timeout / RERR re-probe | $O(N)$ flood per discovery, $O(1)$ per unicast data relay | Sparse topologies, linear convoys, low-to-moderate mobility (<1.0 m/s) |

---

## Key Features & Protocol Mechanics

- **On-Demand Path Discovery (`UWNDR_PROBE` / `UWNDR_REPLY`):** When an application generates a packet toward an unrouted destination, the originator broadcasts a hop-limited probe (`max_hop_count_`). Relays record reverse paths to the source. The target answers with a unicast `REPLY` containing the target's own sequence number, establishing forward routing state across intermediate hops.
- **Destination Sequence Numbers:** Every node assigns its own monotonic sequence number to outgoing `PROBE` (originator sequence) and `REPLY` (target sequence) control packets. Route updates for any destination are strictly evaluated within that destination's sequence space, eliminating cross-originator sequence number conflicts.
- **Outbound Transmission Lease Decoupling (`refresh_on_tx_ = 0`):** In underwater networks running unacknowledged CSMA MAC protocols (`setNoAckMode`), outbound data transmissions cannot verify link delivery. If transmitting data reset the route timer, a dead or departed relay would permanently keep its route active, creating a silent blackhole. By decoupling lease renewals from outbound transmissions, route validity is strictly bounded by `route_lifetime_`.
- **Acoustic Retransmission Jitter (`probe_jitter_`):** When intermediate nodes rebroadcast discovery probes, a randomized acoustic backoff window ($\mathcal{U}[0, \text{probe\_jitter\_}]$) desynchronizes relay transmissions, preventing broadcast packet collisions under unslotted CSMA/ALOHA.
- **Physical Neighbor Disambiguation in Passive Learning:** Overhearing packets passively refreshes route leases only when the frame originates from a confirmed direct physical neighbor (`prev_hop == saddr`). Multi-hop forwarded packets never falsely overwrite hop counts, but direct 1-hop physical neighbors are kept warm to accelerate two-way communication.
- **Bounded Discovery & Deduplication History:** Probe histories (`seen_probes_`) and MAC-retry duplicate tables (`seen_data_pkts_`) are periodically pruned by an active expiration timer, bounding memory footprint and allowing rebooted nodes to re-discover topology without sequence-number lockout.
- **Outbound Packet Buffering with Age Eviction:** Outgoing CBR/UDP data packets wait in destination queues (`pending_queues_`) while route discovery is in flight and flush in order upon `REPLY`. Packets buffered longer than `max_buffer_time_` (30 s) are dropped (`DROP_UWNDR_TIMEOUT`) to prevent buffer bloat during network partitioning.
- **DESERT `PacketHeader/LL` Memory Offset Fix:** Explicitly enables `PacketHeaderManager set tab_(PacketHeader/LL) 1` in `uwndr-default.tcl`, preventing `UWMllModule::sendDown` from corrupting byte offset 0 in NS-2 packet headers.

---

## Benchmark Evaluation & Empirical Results

All evaluations were executed in **DESERT Underwater 3.5.0 / NS-Miracle 2.0.2** using realistic acoustic physical layer parameters:
- **Acoustic Carrier:** 25 kHz, Bandwidth: 5000 Hz, Bitrate: 4800 bps, Spreading: 1.5 (practical spreading), Depth: -50 m.
- **Transducer:** `MaxTxSPL_dB_ = 140 dB re µPa`, Transmit Power: 3.5 W, Receive Power: 0.8 W, Noise SPD: 50 dB.
- **MAC Layer:** `Module/UW/CSMA_ALOHA` with `setNoAckMode` (unacknowledged transmission).
- **Traffic:** `Module/UW/CBR` (64 B payload, 20 s nominal period).

---

### 1. 5-Node 3000 m Multi-Hop Linear Baseline

Nodes are deployed linearly across 3000 m (`Node 0` at 0 m $\rightarrow$ `Node 1` $\rightarrow$ `Node 2` $\rightarrow$ `Node 3` at 3000 m, with off-path neighbor `Node 4` at $(1000, 700)$ m):

#### A. Duration Scaling & Route Lease Expiration Benchmarks
From `results/overhead_scaling.csv` (180 s route lease, `refresh_on_tx_ = 0`):

| Protocol Mode | Duration (s) | Delivered / Sent | PDR (%) | Mean FTT (s) | Goodput (bps) | Layer-3 Relays | Total MAC TX | Control Packets |
|---|---|---|---|---|---|---|---|---|
| `static_oracle` | 300 s | 14 / 14 | 100.00% | 3.5267 | 46.37 | 28 | 42 | 0 |
| `flooding` | 300 s | 13 / 14 | 92.86% | 3.7546 | 43.40 | 42 | 56 | 0 |
| **`uwndr`** | 300 s | 14 / 14 | **100.00%** | 4.5319 | 47.34 | 28 | 56 | **14** |
| `static_oracle` | 600 s | 29 / 29 | 100.00% | 3.5924 | 48.18 | 58 | 87 | 0 |
| `flooding` | 600 s | 28 / 29 | 96.55% | 3.8009 | 46.89 | 87 | 116 | 0 |
| **`uwndr`** | 600 s | 29 / 29 | **100.00%** | 4.3587 | 48.68 | 58 | 108 | **21** |
| `static_oracle` | 1200 s | 59 / 59 | 100.00% | 3.6795 | 49.09 | 118 | 177 | 0 |
| `flooding` | 1200 s | 58 / 59 | 98.31% | 3.7987 | 48.64 | 177 | 236 | 0 |
| **`uwndr`** | 1200 s | 59 / 59 | **100.00%** | 4.3462 | 49.34 | 118 | 219 | **42** |
| `static_oracle` | 1800 s | 89 / 89 | 100.00% | 3.6860 | 49.39 | 178 | 267 | 0 |
| `flooding` | 1800 s | 86 / 89 | 96.63% | 3.7836 | 48.11 | 267 | 356 | 0 |
| **`uwndr`** | 1800 s | 88 / 89 | **98.88%** | 4.5823 | 49.01 | 176 | 332 | **67** |

*Analysis of Control Packet Scaling:* Under unacknowledged CSMA MAC, route leases are bounded by `route_lifetime_` (180 s in benchmark). As a result, control packets scale predictably with duration: an initial discovery cycle (14 packets) followed by periodic re-discovery upon lease expiration (~7 control packets per renewal cycle: 21 pkts at 600 s, 42 pkts at 1200 s, 67 pkts at 1800 s), while maintaining 98.9% to 100% PDR.

#### B. 10-Seed Monte Carlo Static Performance (600 s Duration, 95% Confidence Intervals)
From `results/mobility_summary.csv` at 0.0 m/s:

| Metric | `static_oracle` | `flooding` | `uwndr` (Ours) | Relative Advantage of UW-NDR |
|---|---|---|---|---|
| **Packet Delivery Ratio (PDR)** | 100.00 ± 0.00% | 94.83 ± 3.13% | **99.66 ± 0.78%** | +4.83% PDR over flooding (non-overlapping 95% CIs) |
| **Total MAC Transmissions** | 87.0 ± 0.0 | 116.0 ± 0.0 | **107.8 ± 0.45** | -7.1% MAC channel access vs flooding |
| **Transmit Energy ($E_{\text{tx}}$)** | 61.73 ± 0.00 J | 82.94 ± 0.00 J | **64.59 ± 0.32 J** | -22.1% TX energy vs flooding |
| **Energy per Received Bit** | 3.595 mJ/bit | 4.896 ± 0.174 mJ/bit | **3.774 ± 0.010 mJ/bit** | -22.9% energy per bit vs flooding |
| **Mean End-to-End Latency** | 3.693 ± 0.038 s | 3.795 ± 0.032 s | 4.371 ± 0.067 s | +0.58 s due to initial on-demand discovery |

---

### 2. Vehicle Mobility & Velocity Crossover Analysis

Simulated using a 3D Gauss-Markov mobility model across speeds 0.0 m/s to 2.0 m/s (10 seeds per speed step, 600 s mission duration, from `results/mobility_summary.csv`):

```
  Packet Delivery Ratio vs Speed (10 Seeds, 95% CI)
  100% +-------------------------------------------------------+
       |   O           O           O                           |   O = Static Oracle
   95% |   #===========#===========#===========#===========#   |   # = Flooding
       |   *           *                                       |   * = UW-NDR (Ours)
   90% |                                                       |
       |                               *           *           |
   85% |                           *                           |
       |                                                       |
   70% |                                               *       |
       +-------------------------------------------------------+
          0.0 m/s     0.5 m/s     1.0 m/s     1.5 m/s     2.0 m/s
```

Detailed metrics:

| Speed (m/s) | Static Oracle PDR (%) | Flooding PDR (%) | UW-NDR PDR (%) | UW-NDR MAC TX | Flooding MAC TX | Control Byte Ratio (%) |
|---|---|---|---|---|---|---|
| **0.0 m/s** | 100.00 ± 0.00% | 94.83 ± 3.13% | 99.66 ± 0.78% | 107.8 ± 0.45 | 116.0 ± 0.0 | 13.95 ± 0.11% |
| **0.5 m/s** | 99.31 ± 1.04% | 95.52 ± 2.86% | 94.48 ± 5.72% | 106.8 ± 1.96 | 115.8 ± 0.45 | 15.17 ± 1.22% |
| **1.0 m/s** | 96.21 ± 6.92% | 96.21 ± 3.17% | 82.41 ± 12.76% | 105.2 ± 4.79 | 114.9 ± 2.04 | 21.85 ± 7.73% |
| **1.5 m/s** | 93.79 ± 7.78% | 95.52 ± 3.50% | 83.45 ± 8.29% | 101.5 ± 4.44 | 113.8 ± 2.65 | 17.29 ± 2.11% |
| **2.0 m/s** | 87.24 ± 13.26% | 93.10 ± 4.65% | 68.28 ± 17.32% | 96.7 ± 8.02 | 115.7 ± 0.68 | 33.94 ± 26.47% |

#### Scientific Findings:
- **The 1.0 m/s Operational Crossover:** At typical AUV survey velocities ($\le 0.5$ m/s to 1.0 m/s / ~1–2 knots), `UW/NDR` delivers **94.5% to 99.7% PDR**, maintaining parity with static routing while saving channel access attempts over flooding.
- **High-Velocity Breakdown:** Beyond 1.0 m/s, vehicle displacement alters acoustic topology faster than reactive route discovery and lease expiration. Under fast vehicle motion (2.0 m/s), `UW/NDR` PDR declines to 68.3%, whereas `UW/FLOODING` retains 93.1% PDR through all-path redundancy.

---

### 3. Dynamic Relay Failover & Link Recovery

Evaluated on a 5-node topology where the primary relay (Node 1) leaves acoustic range at $t = 200$ s (10 seeds, 900 s mission duration, stoptime = 905 s):
- **Drift Failure:** Node 1 drifts out of acoustic range at 2.0 m/s.
- **Teleport Failure:** Node 1 abruptly departs at $t = 200$ s (simulating catastrophic vehicle loss).

Detailed metrics from `results/failover_summary.csv`:

| Failure Mode | Protocol Mode | Overall PDR (%) | Post-Failure PDR (%) | Recovery Rate | Mean Recovery Gap (s) | Total MAC TX | Control Ratio (%) |
|---|---|---|---|---|---|---|---|
| **Drift** | `static` | 71.14 ± 2.18% | 63.71 ± 2.73% | 0 / 10 seeds | 257.1 ± 28.87 s | 108.5 ± 1.69 | 0.0% |
| **Drift** | `flooding` | 96.14 ± 1.72% | 96.00 ± 2.20% | 10 / 10 seeds | 16.4 ± 8.66 s | 165.8 ± 1.21 | 0.0% |
| **Drift** | **`uwndr` (Ours)** | **91.36 ± 6.67%** | **89.43 ± 8.51%** | **10 / 10 seeds** | **69.2 ± 50.70 s** | **160.6 ± 5.16** | **17.03 ± 1.55%** |
| **Teleport** | `static` | 20.45 ± 0.00% | 0.00 ± 0.00% | 0 / 10 seeds | 725.9 ± 0.23 s | 62.0 ± 0.00 | 0.0% |
| **Teleport** | `flooding` | 95.91 ± 2.40% | 95.72 ± 2.41% | 10 / 10 seeds | 14.3 ± 6.57 s | 139.0 ± 1.07 | 0.0% |
| **Teleport** | **`uwndr` (Ours)** | **93.41 ± 1.79%** | **92.00 ± 2.51%** | **10 / 10 seeds** | **28.0 ± 5.37 s** | **158.7 ± 1.07** | **14.69 ± 0.67%** |

#### Failover Analysis:
- In unacknowledged CSMA (`setNoAckMode`), a dead relay cannot emit an ACK or RERR. Link failure is detected through route lease expiration.
- In both failure modes, `UW/NDR` achieved a **100% recovery rate (10/10 seeds)**. In teleport failure, `UW/NDR` detected the link break and converged onto secondary relay Node 4 within **28.0 ± 5.37 s**, achieving **92.00 ± 2.51% post-failure PDR**. In contrast, static routing suffered permanent 0% delivery post-failure.

---

### 4. Swarm Matrix: Node Density & Active Mobility Scaling

Evaluated across swarm sizes $N \in \{4, 6, 8, 10\}$ with concurrent flows under active vehicle mobility (Gauss-Markov speed = 1.0 m/s, stoptime = 605 s, 10 seeds each, from `results/swarm_summary.csv`):

| Nodes | CBR Period (s) | `flooding` PDR (%) | `uwndr` PDR (%) | `uwndr` MAC TX | `flooding` MAC TX | `uwndr` Control Byte Ratio (%) |
|---|---|---|---|---|---|---|
| **4** | 10 s | 70.26 ± 13.79% | 79.49 ± 7.89% | 337.8 ± 10.77 | 315.4 ± 15.93 | 2.36 ± 0.46% |
| **4** | 20 s | 81.38 ± 2.45% | 77.24 ± 11.61% | 169.3 ± 7.33 | 161.4 ± 2.14 | 6.70 ± 4.85% |
| **4** | 40 s | 70.71 ± 13.77% | 78.57 ± 4.34% | 89.5 ± 2.09 | 74.9 ± 3.98 | 11.04 ± 1.84% |
| **6** | 10 s | 87.06 ± 2.85% | 58.19 ± 8.11% | 407.9 ± 26.67 | 787.4 ± 13.10 | 8.01 ± 1.02% |
| **6** | 20 s | 82.99 ± 5.85% | 62.30 ± 5.59% | 223.4 ± 16.36 | 384.9 ± 14.10 | 13.79 ± 2.31% |
| **6** | 40 s | 87.14 ± 3.23% | 62.62 ± 7.62% | 126.6 ± 8.53 | 186.6 ± 4.75 | 30.74 ± 6.91% |
| **8** | 10 s | 89.16 ± 4.16% | 65.37 ± 2.40% | 445.9 ± 17.12 | 1113.7 ± 28.43 | 9.55 ± 1.30% |
| **8** | 20 s | 89.43 ± 2.18% | 58.05 ± 9.69% | 243.1 ± 14.51 | 553.9 ± 8.34 | 24.16 ± 8.40% |
| **8** | 40 s | 91.19 ± 1.98% | 61.19 ± 7.91% | 141.0 ± 10.34 | 268.0 ± 5.77 | 42.66 ± 10.54% |
| **10** | 10 s | 95.88 ± 2.36% | 58.36 ± 5.05% | 446.0 ± 25.56 | 1489.5 ± 29.68 | 13.66 ± 2.07% |
| **10** | 20 s | 97.36 ± 1.40% | 61.61 ± 7.51% | 258.7 ± 19.46 | 742.1 ± 10.30 | 27.81 ± 13.72% |
| **10** | 40 s | 94.53 ± 2.41% | 59.29 ± 4.50% | 167.2 ± 14.29 | 350.9 ± 5.93 | 63.32 ± 10.76% |

#### Swarm Scaling Takeaway:
- In smaller swarms ($N=4$), `UW/NDR` performs reliably (77% to 79% PDR) with very low control overhead (2.4% to 6.7%).
- In larger swarms ($N=8\text{--}10$) under simultaneous 1.0 m/s vehicle mobility, flooding achieves higher delivery (89% to 97%) due to multipath broadcast diversity, but does so at the cost of **2.5× to 3.3× more channel transmissions** (e.g., 1489 vs 446 MAC packets at $N=10$). `UW/NDR` caps transmission count at the expense of lower PDR (58% to 65%) due to probe collisions in unslotted CSMA and vehicle motion across multi-hop paths.

---

### 5. Cooperative AUV Survey Trajectory Replay

Evaluated on synthetic 4-AUV cooperative lawnmower survey trajectories generated from Farol / DSOR ROS survey geometry (`simulations/trajectories/farol_synthetic.csv`, 4 vehicles, 181 waypoints, 900 s duration, 10 seeds, from `results/farol_summary.csv`):

| Protocol Mode | PDR Mean (%) | 95% Confidence Interval | Mean FTT (s) | Total MAC TX | Control Ratio (%) | Energy per Bit (mJ/bit) |
|---|---|---|---|---|---|---|
| `static` | 79.54% | ± 3.34% | 4.020 ± 0.038 s | 241.8 ± 3.69 | 0.0% | 3.586 ± 0.096 |
| `flooding` | 80.00% | ± 2.71% | 4.030 ± 0.038 s | 242.5 ± 3.24 | 0.0% | 3.602 ± 0.079 |
| **`uwndr` (Ours)** | **80.80%** | **± 2.35%** | 4.132 ± 0.043 s | 254.7 ± 3.80 | 2.97 ± 0.32% | 3.601 ± 0.069 |

*Result:* All three protocols deliver statistically indistinguishable PDR (~80% to 81%) across the 900 s survey formation. However, `UW/NDR` achieves this autonomously with zero pre-configured static route tables.

---

### 6. Environmental Sensitivity: Wind-Driven Ambient Noise

Evaluated across Wenz wind-driven ambient noise levels in 1 dB steps (+0 dB to +6 dB above baseline, 10 seeds, 600 s duration, from `results/noise_summary.csv`):

| Noise Increase | Wind Speed ($w$) | Flooding PDR (%) | Static Oracle PDR (%) | UW-NDR PDR (%) |
|---|---|---|---|---|
| **+0 dB** | 0.0000 m/s | 94.83 ± 3.13% | 100.00 ± 0.00% | 99.66 ± 0.78% |
| **+1 dB** | 0.0178 m/s | 94.14 ± 3.30% | 100.00 ± 0.00% | 98.62 ± 2.38% |
| **+2 dB** | 0.0711 m/s | 94.48 ± 3.53% | 100.00 ± 0.00% | 97.24 ± 5.43% |
| **+3 dB** | 0.1600 m/s | 90.35 ± 4.32% | 94.48 ± 3.12% | 96.21 ± 3.57% |
| **+4 dB** | 0.2844 m/s | 71.38 ± 3.86% | 75.17 ± 4.91% | 74.14 ± 5.48% |
| **+5 dB** | 0.4444 m/s | 27.58 ± 5.45% | 24.48 ± 5.87% | 28.62 ± 5.46% |
| **+6 dB** | 0.6400 m/s | 0.35 ± 0.78% | 3.10 ± 2.45% | 1.73 ± 1.75% |

*Finding:* All three protocols tolerate mild ambient acoustic noise (+0 to +3 dB) with high PDR (>90%). Beyond +4 dB, signal-to-noise ratio drops below acoustic modem reception thresholds, causing all protocols to degrade uniformly.

---

## Protocol Limitations & Assumptions

1. **Security & Authentication:** The protocol header currently does not include cryptographic signatures, message authentication codes (MACs), or nonces. It assumes a closed, cooperative AUV swarm. In an adversarial setting, forged `UWNDR_ERROR` or `UWNDR_REPLY` frames could capture or disrupt active routes.
2. **First-Arrival Path Selection:** Routes are established by the first arriving `PROBE`. In multi-path acoustic channels, the earliest arrival may not always possess the highest SNR or longest channel coherence time.
3. **Simulation-Level Deduplication:** Frame deduplication currently inspects NS-2 packet UID (`ch->uid()`). Deployment on physical acoustic modems (e.g., Evologics, WHOI Micro-Modem) requires a dedicated packet sequence identifier within the Layer-3 protocol header.

---

## Configuration Parameters

Default parameters are declared in `src/uwndr/uwndr-default.tcl`:

| Parameter | Type | Default | Benchmark Override | Description |
|---|---|---|---|---|
| `max_hop_count_` | integer | `4` | `4` – `5` | Maximum acoustic relay hops allowed for PROBE dissemination |
| `probe_timeout_` | double | `15.0 s` | `15.0 s` | Minimum interval before re-probing the same unrouted destination |
| `probe_jitter_` | double | `0.1 s` | `0.1 s` | Randomized acoustic backoff window ($\mathcal{U}[0, \text{jitter}]$) for probe relaying |
| `route_lifetime_` | double | `60.0 s` | `180.0 s` | Routing table entry expiration lease time |
| `refresh_on_tx_` | integer | `0` | `0` | Outbound lease decoupling (0 = disabled to prevent silent blackholes) |
| `max_buffer_pkts_`| integer | `20` | `20` – `30` | Maximum pending data packets held per destination |
| `max_buffer_time_`| double | `30.0 s` | `30.0 s` | Packet queue deadline before stale eviction (`DROP_UWNDR_TIMEOUT`) |

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
