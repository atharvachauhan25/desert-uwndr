// UW-NDR Protocol Implementation - Production Code Freeze v1.0
#include "uwndr-module.h"
#include <rng.h>
#include <cstdlib>

extern packet_t PT_UWNDR;

int hdr_uwndr::offset_ = 0;

static class UwNdrModuleClass : public TclClass
{
public:
	UwNdrModuleClass()
		: TclClass("Module/UW/NDR")
	{
	}

	TclObject *
	create(int, const char *const *)
	{
		return (new UwNdrModule());
	}
} class_module_uwndr;

static class UwNdrPktClass : public PacketHeaderClass
{
public:
	UwNdrPktClass()
		: PacketHeaderClass("PacketHeader/UWNDR", sizeof(hdr_uwndr))
	{
		this->bind();
		bind_offset(&hdr_uwndr::offset_);
	}
} class_uwndr_pkt;

void
UwNdrExpireTimer::expire(Event *)
{
	module_->purgeExpiredRoutes();
	module_->purgeStalePackets();
	resched(5.0);
}

UwNdrModule::UwNdrModule()
	: ipAddr_(0)
	, max_hop_count_(4)
	, probe_timeout_(15.0)
	, probe_jitter_(0.1)
	, route_lifetime_(60.0)
	, max_buffer_pkts_(20)
	, max_buffer_time_(30.0)
	, verbose_(1)
	, refresh_on_tx_(0)
	, seq_num_(0)
	, probes_sent_(0)
	, probes_forwarded_(0)
	, replies_sent_(0)
	, replies_forwarded_(0)
	, errors_sent_(0)
	, data_forwarded_(0)
	, data_dropped_buf_(0)
	, data_dropped_timeout_(0)
	, data_dropped_dup_(0)
	, routes_expired_(0)
	, total_ctrl_bytes_(0)
	, total_data_bytes_(0)
	, expire_timer_(this)
{
	bind("max_hop_count_", &max_hop_count_);
	bind("probe_timeout_", &probe_timeout_);
	bind("probe_jitter_", &probe_jitter_);
	bind("route_lifetime_", &route_lifetime_);
	bind("max_buffer_pkts_", &max_buffer_pkts_);
	bind("max_buffer_time_", &max_buffer_time_);
	bind("verbose_", &verbose_);
	bind("refresh_on_tx_", &refresh_on_tx_);
}

UwNdrModule::~UwNdrModule()
{
	for (auto &kv : pending_queues_) {
		while (!kv.second.empty()) {
			Packet::free(kv.second.front());
			kv.second.pop();
		}
	}
}

int
UwNdrModule::command(int argc, const char *const *argv)
{
	Tcl &tcl = Tcl::instance();

	if (argc == 2) {
		if (strcasecmp(argv[1], "initialize") == 0) {
			expire_timer_.resched(5.0);
			return TCL_OK;
		} else if (strcasecmp(argv[1], "printroutes") == 0) {
			printRoutingTable();
			return TCL_OK;
		} else if (strcasecmp(argv[1], "getprobessent") == 0) {
			tcl.resultf("%lu", probes_sent_);
			return TCL_OK;
		} else if (strcasecmp(argv[1], "getprobesforwarded") == 0) {
			tcl.resultf("%lu", probes_forwarded_);
			return TCL_OK;
		} else if (strcasecmp(argv[1], "getrepliessent") == 0) {
			tcl.resultf("%lu", replies_sent_);
			return TCL_OK;
		} else if (strcasecmp(argv[1], "getrepliesforwarded") == 0) {
			tcl.resultf("%lu", replies_forwarded_);
			return TCL_OK;
		} else if (strcasecmp(argv[1], "geterrorssent") == 0) {
			tcl.resultf("%lu", errors_sent_);
			return TCL_OK;
		} else if (strcasecmp(argv[1], "getdataforwarded") == 0) {
			tcl.resultf("%lu", data_forwarded_);
			return TCL_OK;
		} else if (strcasecmp(argv[1], "getdatadroppedbuf") == 0) {
			tcl.resultf("%lu", data_dropped_buf_);
			return TCL_OK;
		} else if (strcasecmp(argv[1], "getdatadroppedtimeout") == 0) {
			tcl.resultf("%lu", data_dropped_timeout_);
			return TCL_OK;
		} else if (strcasecmp(argv[1], "getdatadroppeddup") == 0) {
			tcl.resultf("%lu", data_dropped_dup_);
			return TCL_OK;
		} else if (strcasecmp(argv[1], "getctrlbytes") == 0) {
			tcl.resultf("%lu", total_ctrl_bytes_);
			return TCL_OK;
		} else if (strcasecmp(argv[1], "getdatabytes") == 0) {
			tcl.resultf("%lu", total_data_bytes_);
			return TCL_OK;
		} else if (strcasecmp(argv[1], "getoverheadratio") == 0) {
			tcl.resultf("%.4f", getOverheadRatio());
			return TCL_OK;
		} else if (strcasecmp(argv[1], "getrouteexpirycount") == 0) {
			tcl.resultf("%lu", routes_expired_);
			return TCL_OK;
		} else if (strcasecmp(argv[1], "getndrheadersize") == 0) {
			tcl.resultf("%d", static_cast<int>(sizeof(hdr_uwndr)));
			return TCL_OK;
		}
	} else if (argc == 3) {
		if (strcasecmp(argv[1], "addr") == 0) {
			int addr = std::atoi(argv[2]);
			if (addr <= 0 || addr > 254) {
				tcl.result("Invalid UW-NDR IP address (must be 1..254)");
				return TCL_ERROR;
			}
			ipAddr_ = static_cast<uint8_t>(addr);
			return TCL_OK;
		}
	}

	return Module::command(argc, argv);
}

void
UwNdrModule::recv(Packet *p)
{
	hdr_cmn *ch = HDR_CMN(p);
	hdr_uwip *iph = HDR_UWIP(p);

	if (ch->direction() == hdr_cmn::UP) {
		if (ch->error()) {
			Packet::free(p);
			return;
		}

		if (ch->ptype() == PT_UWNDR) {
			handleControlPacket(p);
			return;
		}

		// Task A1.3: MAC retry packet deduplication cache
		int uid = ch->uid();
		uint8_t src = static_cast<uint8_t>(iph->saddr());
		if (src != 0 && src != ipAddr_) {
			auto &src_cache = seen_data_pkts_[src];
			auto d_it = src_cache.find(uid);
			if (d_it != src_cache.end() && (NOW - d_it->second) < 30.0) {
				if (verbose_) {
					std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
							  << " dropped DUPLICATE DATA (uid=" << uid
							  << " from Node " << (int) src << ")" << std::endl;
				}
				data_dropped_dup_++;
				drop(p, 1, DROP_UWNDR_DUP);
				return;
			}
			src_cache[uid] = NOW;
		}

		// Standard data packet arriving from lower layer
		if (iph->daddr() == ipAddr_ || iph->daddr() == UWIP_BROADCAST) {
			// Passive reverse route refresh from incoming data traffic
			if (ch->prev_hop_ != 0 && iph->saddr() != 0 && iph->saddr() != ipAddr_) {
				uint8_t prev_hop = static_cast<uint8_t>(ch->prev_hop_);
				UwNdrRoutingEntry existing;
				if (getValidRoute(iph->saddr(), existing)) {
					if (existing.next_hop == prev_hop) {
						// Confirmed active link: refresh reverse route lease
						routing_table_[iph->saddr()].last_updated = NOW;
						routing_table_[iph->saddr()].expire_time = NOW + route_lifetime_;
					}
				} else if (prev_hop == static_cast<uint8_t>(iph->saddr())) {
					// Only install a direct 1-hop route if received directly from originator
					updateRoute(iph->saddr(), prev_hop, 1, 0);
				}
			}
			total_data_bytes_ += ch->size();
			sendUp(p);
			return;
		}

		// Data packet meant for another node -> forward along dynamic route
		if (ch->prev_hop_ != 0 && iph->saddr() != 0 && iph->saddr() != ipAddr_) {
			uint8_t prev_hop = static_cast<uint8_t>(ch->prev_hop_);
			UwNdrRoutingEntry rev_entry;
			if (getValidRoute(iph->saddr(), rev_entry)) {
				if (rev_entry.next_hop == prev_hop) {
					routing_table_[iph->saddr()].last_updated = NOW;
					routing_table_[iph->saddr()].expire_time = NOW + route_lifetime_;
				}
			} else if (prev_hop == static_cast<uint8_t>(iph->saddr())) {
				// Only install a direct 1-hop route if received directly from originator
				updateRoute(iph->saddr(), prev_hop, 1, 0);
			}
		}

		UwNdrRoutingEntry entry;
		if (getValidRoute(iph->daddr(), entry, true)) {
			if (verbose_) {
				std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
						  << " forwarding DATA (src=" << (int) iph->saddr()
						  << " -> dst=" << (int) iph->daddr()
						  << ") via next_hop=" << (int) entry.next_hop << std::endl;
			}
			ch->direction() = hdr_cmn::DOWN;
			ch->prev_hop_ = ipAddr_;
			ch->next_hop() = entry.next_hop;
			data_forwarded_++;
			total_data_bytes_ += ch->size();
			sendDown(p);
		} else {
			if (verbose_) {
				std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
						  << " has NO route to dst=" << (int) iph->daddr()
						  << ", emitting RERR to Node " << (int) iph->saddr() << std::endl;
			}
			sendRouteError(iph->saddr(), iph->daddr());
			drop(p, 1, DROP_UWNDR_NO_ROUTE);
		}
		return;
	}

	// Outbound packet from upper layer (direction == DOWN)
	if (iph->saddr() == 0) {
		iph->saddr() = ipAddr_;
	}

	if (iph->daddr() == UWIP_BROADCAST) {
		ch->prev_hop_ = ipAddr_;
		ch->next_hop() = UWIP_BROADCAST;
		total_data_bytes_ += ch->size();
		sendDown(p);
		return;
	}

	UwNdrRoutingEntry entry;
	// Task A1.1: Fix originator lease refresh. Decouple relay confirmation
	// from outbound transmissions under unacknowledged MAC (setNoAckMode).
	// An originator must not artificially prolong its own route lease simply
	// by transmitting data; the lease must be bounded by route_lifetime_
	// unless explicitly confirmed or refresh_on_tx_ is explicitly requested.
	bool refresh_lease = (refresh_on_tx_ != 0);
	if (getValidRoute(iph->daddr(), entry, refresh_lease)) {
		ch->prev_hop_ = ipAddr_;
		ch->next_hop() = entry.next_hop;
		total_data_bytes_ += ch->size();
		sendDown(p);
	} else {
		// Buffer outbound data packet and trigger on-demand route discovery
		std::queue<Packet *> &q = pending_queues_[iph->daddr()];
		if (static_cast<int>(q.size()) >= max_buffer_pkts_) {
			data_dropped_buf_++;
			drop(p, 1, DROP_UWNDR_BUF_FULL);
		} else {
			q.push(p);
		}

		auto it = last_probe_sent_.find(iph->daddr());
		if (it == last_probe_sent_.end() || (NOW - it->second) >= probe_timeout_) {
			sendRouteProbe(iph->daddr());
		}
	}
}

void
UwNdrModule::sendRouteProbe(uint8_t target_dst)
{
	Packet *probe = Packet::alloc();
	hdr_cmn *ch = HDR_CMN(probe);
	hdr_uwip *iph = HDR_UWIP(probe);
	hdr_uwndr *ndrh = HDR_UWNDR(probe);

	seq_num_++;
	ch->ptype() = PT_UWNDR;
	ch->direction() = hdr_cmn::DOWN;
	ch->size() = sizeof(hdr_uwndr);
	ch->timestamp() = NOW;
	ch->prev_hop_ = ipAddr_;
	ch->next_hop() = UWIP_BROADCAST;

	iph->saddr() = ipAddr_;
	iph->daddr() = UWIP_BROADCAST;

	ndrh->pkt_type_ = UWNDR_PROBE;
	ndrh->orig_src_ = ipAddr_;
	ndrh->target_dst_ = target_dst;
	ndrh->seq_num_ = seq_num_;
	ndrh->hop_count_ = 0;
	ndrh->send_time_ = NOW;

	seen_probes_[ipAddr_][seq_num_] = NOW;
	last_probe_sent_[target_dst] = NOW;
	probes_sent_++;
	total_ctrl_bytes_ += sizeof(hdr_uwndr);

	if (verbose_) {
		std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
				  << " NO ROUTE to Node " << (int) target_dst
				  << " -> Broadcasting PROBE (seq=" << seq_num_ << ")" << std::endl;
	}

	sendDown(probe);
}

void
UwNdrModule::sendRouteReply(uint8_t orig_src, uint8_t target_dst, uint8_t next_hop, uint32_t seq_num)
{
	Packet *reply = Packet::alloc();
	hdr_cmn *ch = HDR_CMN(reply);
	hdr_uwip *iph = HDR_UWIP(reply);
	hdr_uwndr *ndrh = HDR_UWNDR(reply);

	ch->ptype() = PT_UWNDR;
	ch->direction() = hdr_cmn::DOWN;
	ch->size() = sizeof(hdr_uwndr);
	ch->timestamp() = NOW;
	ch->prev_hop_ = ipAddr_;
	ch->next_hop() = next_hop;

	iph->saddr() = ipAddr_;
	iph->daddr() = orig_src;

	ndrh->pkt_type_ = UWNDR_REPLY;
	ndrh->orig_src_ = orig_src;
	ndrh->target_dst_ = target_dst;
	ndrh->seq_num_ = seq_num;
	ndrh->hop_count_ = 0;
	ndrh->send_time_ = NOW;

	replies_sent_++;
	total_ctrl_bytes_ += sizeof(hdr_uwndr);

	if (verbose_) {
		std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
				  << " (TARGET) sending unicast REPLY to Node " << (int) orig_src
				  << " via next_hop=" << (int) next_hop << std::endl;
	}

	sendDown(reply);
}

void
UwNdrModule::handleControlPacket(Packet *p)
{
	hdr_uwndr *ndrh = HDR_UWNDR(p);

	if (ndrh->pkt_type_ == UWNDR_PROBE) {
		handleProbe(p);
	} else if (ndrh->pkt_type_ == UWNDR_REPLY) {
		handleReply(p);
	} else if (ndrh->pkt_type_ == UWNDR_ERROR) {
		handleError(p);
	} else {
		Packet::free(p);
	}
}

void
UwNdrModule::handleProbe(Packet *p)
{
	hdr_cmn *ch = HDR_CMN(p);
	hdr_uwndr *ndrh = HDR_UWNDR(p);

	uint8_t prev_hop = static_cast<uint8_t>(ch->prev_hop_);
	uint8_t orig_src = ndrh->orig_src_;
	uint8_t target_dst = ndrh->target_dst_;
	uint32_t seq = ndrh->seq_num_;

	if (orig_src == ipAddr_) {
		Packet::free(p);
		return;
	}

	// Duplicate probe detection
	auto src_it = seen_probes_.find(orig_src);
	if (src_it != seen_probes_.end()) {
		if (src_it->second.find(seq) != src_it->second.end()) {
			Packet::free(p);
			return;
		}
	}
	seen_probes_[orig_src][seq] = NOW;

	uint16_t new_hops = ndrh->hop_count_ + 1;
	updateRoute(orig_src, prev_hop, new_hops, seq);

	if (ipAddr_ == target_dst) {
		if (verbose_) {
			std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
					  << " received PROBE from Node " << (int) orig_src
					  << " via Node " << (int) prev_hop
					  << " (hops=" << new_hops << ")" << std::endl;
		}
		sendRouteReply(orig_src, target_dst, prev_hop, seq);
		Packet::free(p);
		return;
	}

	// Intermediate node: rebroadcast if within hop limit
	if (static_cast<int>(new_hops) < max_hop_count_) {
		ndrh->hop_count_ = new_hops;
		ch->direction() = hdr_cmn::DOWN;
		ch->prev_hop_ = ipAddr_;
		ch->next_hop() = UWIP_BROADCAST;
		probes_forwarded_++;
		total_ctrl_bytes_ += sizeof(hdr_uwndr);

		if (verbose_) {
			std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
					  << " learned reverse route to Node " << (int) orig_src
					  << " via Node " << (int) prev_hop
					  << "; relaying PROBE for Node " << (int) target_dst << std::endl;
		}
		if (probe_jitter_ > 0.0) {
			double jitter = RNG::defaultrng()->uniform_double() * probe_jitter_;
			sendDown(p, jitter);
		} else {
			sendDown(p);
		}
	} else {
		Packet::free(p);
	}
}

void
UwNdrModule::handleReply(Packet *p)
{
	hdr_cmn *ch = HDR_CMN(p);
	hdr_uwndr *ndrh = HDR_UWNDR(p);

	uint8_t prev_hop = static_cast<uint8_t>(ch->prev_hop_);
	uint8_t orig_src = ndrh->orig_src_;
	uint8_t target_dst = ndrh->target_dst_;
	uint16_t new_hops = ndrh->hop_count_ + 1;

	updateRoute(target_dst, prev_hop, new_hops, ndrh->seq_num_);

	if (ipAddr_ == orig_src) {
		if (verbose_) {
			std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
					  << " ROUTE ESTABLISHED -> dst=" << (int) target_dst
					  << " via next_hop=" << (int) prev_hop
					  << " (hops=" << new_hops << ")" << std::endl;
		}
		flushPendingQueue(target_dst, prev_hop);
		Packet::free(p);
		return;
	}

	// Intermediate node: forward reply along stored reverse route
	UwNdrRoutingEntry rev_entry;
	if (getValidRoute(orig_src, rev_entry)) {
		ndrh->hop_count_ = new_hops;
		ch->direction() = hdr_cmn::DOWN;
		ch->prev_hop_ = ipAddr_;
		ch->next_hop() = rev_entry.next_hop;
		replies_forwarded_++;
		total_ctrl_bytes_ += sizeof(hdr_uwndr);

		if (verbose_) {
			std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
					  << " learned forward route to Node " << (int) target_dst
					  << " via Node " << (int) prev_hop
					  << "; forwarding REPLY to Node " << (int) rev_entry.next_hop << std::endl;
		}
		sendDown(p);
	} else {
		Packet::free(p);
	}
}

void
UwNdrModule::updateRoute(uint8_t dst, uint8_t next_hop, uint16_t hops, uint32_t seq)
{
	auto it = routing_table_.find(dst);
	bool should_update = false;

	if (it == routing_table_.end() || !it->second.is_valid) {
		should_update = true;
	} else if (seq > 0 && it->second.seq_num > 0) {
		if (seq > it->second.seq_num) {
			should_update = true;
		} else if (seq == it->second.seq_num && hops < it->second.hop_count) {
			should_update = true;
		}
	} else if (hops < it->second.hop_count) {
		should_update = true;
	}

	if (should_update) {
		UwNdrRoutingEntry entry;
		entry.next_hop = next_hop;
		entry.hop_count = hops;
		entry.seq_num = (seq > 0) ? seq : (it != routing_table_.end() ? it->second.seq_num : 0);
		entry.last_updated = NOW;
		entry.expire_time = NOW + route_lifetime_;
		entry.is_valid = true;
		routing_table_[dst] = entry;
	} else if (it->second.next_hop == next_hop) {
		it->second.last_updated = NOW;
		it->second.expire_time = NOW + route_lifetime_;
	}
}

bool
UwNdrModule::getValidRoute(uint8_t dst, UwNdrRoutingEntry &entry, bool refresh_lease)
{
	auto it = routing_table_.find(dst);
	if (it != routing_table_.end()) {
		if (it->second.is_valid && NOW <= it->second.expire_time) {
			if (refresh_lease) {
				it->second.last_updated = NOW;
				it->second.expire_time = NOW + route_lifetime_;
			}
			entry = it->second;
			return true;
		}
		if (it->second.is_valid && NOW > it->second.expire_time) {
			it->second.is_valid = false;
			routes_expired_++;
		}
	}
	return false;
}

void
UwNdrModule::sendRouteError(uint8_t orig_src, uint8_t broken_dst)
{
	UwNdrRoutingEntry rev_entry;
	uint8_t next_hop = UWIP_BROADCAST;
	if (orig_src != 0 && getValidRoute(orig_src, rev_entry)) {
		next_hop = rev_entry.next_hop;
	}

	Packet *err = Packet::alloc();
	hdr_cmn *ch = HDR_CMN(err);
	hdr_uwip *iph = HDR_UWIP(err);
	hdr_uwndr *ndrh = HDR_UWNDR(err);

	ch->ptype() = PT_UWNDR;
	ch->direction() = hdr_cmn::DOWN;
	ch->size() = sizeof(hdr_uwndr);
	ch->timestamp() = NOW;
	ch->prev_hop_ = ipAddr_;
	ch->next_hop() = next_hop;

	iph->saddr() = ipAddr_;
	iph->daddr() = (orig_src != 0) ? orig_src : UWIP_BROADCAST;

	ndrh->pkt_type_ = UWNDR_ERROR;
	ndrh->orig_src_ = orig_src;
	ndrh->target_dst_ = broken_dst;
	ndrh->seq_num_ = 0;
	ndrh->hop_count_ = 1;
	ndrh->send_time_ = NOW;

	errors_sent_++;
	total_ctrl_bytes_ += sizeof(hdr_uwndr);
	sendDown(err);
}

void
UwNdrModule::handleError(Packet *p)
{
	hdr_cmn *ch = HDR_CMN(p);
	hdr_uwndr *ndrh = HDR_UWNDR(p);

	uint8_t prev_hop = static_cast<uint8_t>(ch->prev_hop_);
	uint8_t orig_src = ndrh->orig_src_;
	uint8_t broken_dst = ndrh->target_dst_;

	auto it = routing_table_.find(broken_dst);
	if (it != routing_table_.end() && it->second.is_valid && it->second.next_hop == prev_hop) {
		it->second.is_valid = false;
		if (verbose_) {
			std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
					  << " invalidated route to Node " << (int) broken_dst
					  << " via broken next_hop=" << (int) prev_hop << std::endl;
		}
	}

	if (ipAddr_ == orig_src || orig_src == 0) {
		// Task A1.2: If this node is the originator and has buffered packets waiting for broken_dst,
		// trigger an immediate route probe to rediscover/repair the route via an alternative relay!
		auto q_it = pending_queues_.find(broken_dst);
		if (q_it != pending_queues_.end() && !q_it->second.empty()) {
			auto pr_it = last_probe_sent_.find(broken_dst);
			if (pr_it == last_probe_sent_.end() || (NOW - pr_it->second) >= 1.0) {
				if (verbose_) {
					std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
							  << " triggering IMMEDIATE RE-PROBE for Node " << (int) broken_dst
							  << " after RERR (buffered pkts=" << q_it->second.size() << ")" << std::endl;
				}
				sendRouteProbe(broken_dst);
			}
		}
		Packet::free(p);
		return;
	}

	UwNdrRoutingEntry rev_entry;
	if (getValidRoute(orig_src, rev_entry)) {
		ch->direction() = hdr_cmn::DOWN;
		ch->prev_hop_ = ipAddr_;
		ch->next_hop() = rev_entry.next_hop;
		total_ctrl_bytes_ += sizeof(hdr_uwndr);
		sendDown(p);
	} else {
		Packet::free(p);
	}
}

void
UwNdrModule::flushPendingQueue(uint8_t dst, uint8_t next_hop)
{
	auto it = pending_queues_.find(dst);
	if (it == pending_queues_.end()) {
		return;
	}

	int flushed = 0;
	while (!it->second.empty()) {
		Packet *pkt = it->second.front();
		it->second.pop();
		hdr_cmn *ch = HDR_CMN(pkt);
		ch->direction() = hdr_cmn::DOWN;
		ch->prev_hop_ = ipAddr_;
		ch->next_hop() = next_hop;
		total_data_bytes_ += ch->size();
		sendDown(pkt);
		flushed++;
	}

	if (verbose_ && flushed > 0) {
		std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
				  << " flushed " << flushed << " buffered DATA packet(s) to Node "
				  << (int) dst << " via Node " << (int) next_hop << std::endl;
	}
}

void
UwNdrModule::purgeExpiredRoutes()
{
	for (auto &kv : routing_table_) {
		if (kv.second.is_valid && NOW > kv.second.expire_time) {
			kv.second.is_valid = false;
			routes_expired_++;
			if (verbose_) {
				std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
						  << " route to Node " << (int) kv.first << " EXPIRED." << std::endl;
			}
		}
	}
}

void
UwNdrModule::purgeStalePackets()
{
	for (auto &kv : pending_queues_) {
		std::queue<Packet *> &q = kv.second;
		size_t sz = q.size();
		for (size_t i = 0; i < sz; i++) {
			Packet *pkt = q.front();
			q.pop();
			hdr_cmn *ch = HDR_CMN(pkt);
			if ((NOW - ch->timestamp()) > max_buffer_time_) {
				if (verbose_) {
					std::cout << "[" << NOW << "s] [UWNDR] Node " << (int) ipAddr_
							  << " dropped STALE buffered packet (target dst=" << (int) kv.first
							  << " age=" << (NOW - ch->timestamp()) << "s > max=" << max_buffer_time_ << "s)" << std::endl;
				}
				data_dropped_timeout_++;
				drop(pkt, 1, DROP_UWNDR_TIMEOUT);
			} else {
				q.push(pkt);
			}
		}
	}

	// Purge stale deduplication entries older than 60s
	for (auto &src_kv : seen_data_pkts_) {
		for (auto it = src_kv.second.begin(); it != src_kv.second.end(); ) {
			if ((NOW - it->second) > 60.0) {
				it = src_kv.second.erase(it);
			} else {
				++it;
			}
		}
	}

	// Purge stale seen_probes_ entries older than 2 * route_lifetime_
	// Bounds memory usage and allows rebooted nodes to re-discover routes after sequence reset
	for (auto &src_kv : seen_probes_) {
		for (auto it = src_kv.second.begin(); it != src_kv.second.end(); ) {
			if ((NOW - it->second) > (route_lifetime_ * 2.0)) {
				it = src_kv.second.erase(it);
			} else {
				++it;
			}
		}
	}
}

double
UwNdrModule::getOverheadRatio() const
{
	if (total_data_bytes_ == 0) {
		return 0.0;
	}
	return static_cast<double>(total_ctrl_bytes_) / static_cast<double>(total_data_bytes_);
}

void
UwNdrModule::printRoutingTable() const
{
	std::cout << "  --- Routing Table (Node " << (int) ipAddr_ << ") ---" << std::endl;
	if (routing_table_.empty()) {
		std::cout << "    (empty)" << std::endl;
		return;
	}
	for (const auto &kv : routing_table_) {
		std::cout << "    Dst=" << (int) kv.first
				  << " | NextHop=" << (int) kv.second.next_hop
				  << " | Hops=" << kv.second.hop_count
				  << " | Valid=" << (kv.second.is_valid ? "YES" : "EXPIRED")
				  << " | Expires@" << kv.second.expire_time << "s" << std::endl;
	}
}
