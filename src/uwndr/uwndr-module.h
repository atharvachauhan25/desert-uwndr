#ifndef UWNDR_MODULE_H
#define UWNDR_MODULE_H

#include "uwndr-hdr.h"
#include <uwip-module.h>
#include <module.h>
#include <packet.h>
#include <timer-handler.h>
#include <tclcl.h>

#include <cstdint>
#include <iostream>
#include <map>
#include <queue>

#define DROP_UWNDR_BUF_FULL "UBF"
#define DROP_UWNDR_NO_ROUTE "UNR"
#define DROP_UWNDR_TIMEOUT  "UTO"
#define DROP_UWNDR_DUP      "UDP"

class UwNdrModule;

/**
 * Periodic timer to purge expired dynamic routing table entries.
 */
class UwNdrExpireTimer : public TimerHandler
{
public:
	explicit UwNdrExpireTimer(UwNdrModule *m)
		: TimerHandler()
		, module_(m)
	{
	}

protected:
	virtual void expire(Event *e) override;
	UwNdrModule *module_;
};

/**
 * Dynamic routing table entry stored per destination IP.
 */
struct UwNdrRoutingEntry {
	uint8_t  next_hop;
	uint16_t hop_count;
	uint32_t seq_num;
	double   last_updated;
	double   expire_time;
	bool     is_valid;
};

/**
 * UwNdrModule implements UW-NDR: an on-demand, ARP-inspired neighbor discovery
 * and dynamic multi-hop routing protocol for underwater acoustic networks.
 */
class UwNdrModule : public Module
{
	friend class UwNdrExpireTimer;

public:
	UwNdrModule();
	virtual ~UwNdrModule();

	virtual int command(int argc, const char *const *argv) override;
	virtual void recv(Packet *p) override;

protected:
	void sendRouteProbe(uint8_t target_dst);
	void sendRouteReply(uint8_t orig_src, uint8_t target_dst, uint8_t next_hop, uint32_t seq_num);
	void sendRouteError(uint8_t orig_src, uint8_t broken_dst);

	void handleControlPacket(Packet *p);
	void handleProbe(Packet *p);
	void handleReply(Packet *p);
	void handleError(Packet *p);

	void updateRoute(uint8_t dst, uint8_t next_hop, uint16_t hops, uint32_t seq);
	bool getValidRoute(uint8_t dst, UwNdrRoutingEntry &entry, bool refresh_lease = false);
	void flushPendingQueue(uint8_t dst, uint8_t next_hop);
	void purgeExpiredRoutes();
	void purgeStalePackets();
	void printRoutingTable() const;

	double getOverheadRatio() const;
	unsigned long getTotalCtrlBytes() const { return total_ctrl_bytes_; }
	unsigned long getTotalDataBytes() const { return total_data_bytes_; }

private:
	uint8_t ipAddr_;
	int max_hop_count_;
	double probe_timeout_;
	double probe_jitter_; /**< Maximum random acoustic backoff (s) when relaying PROBEs to prevent broadcast storms. */
	double route_lifetime_;
	int max_buffer_pkts_;
	double max_buffer_time_; /**< Maximum time (s) a packet can wait in pending_queues_ before eviction (DROP_UWNDR_TIMEOUT). */
	int verbose_;
	int refresh_on_tx_;   /**< If 0 (default), outbound transmissions do not prolong lease (prevents blackholes under setNoAckMode). */

	uint32_t seq_num_;

	// Protocol statistics
	unsigned long probes_sent_;
	unsigned long probes_forwarded_;
	unsigned long replies_sent_;
	unsigned long replies_forwarded_;
	unsigned long errors_sent_;
	unsigned long data_forwarded_;
	unsigned long data_dropped_buf_;
	unsigned long data_dropped_timeout_;
	unsigned long data_dropped_dup_;
	unsigned long routes_expired_;
	unsigned long total_ctrl_bytes_;
	unsigned long total_data_bytes_;

	std::map<uint8_t, UwNdrRoutingEntry> routing_table_;
	std::map<uint8_t, std::queue<Packet *> > pending_queues_;
	std::map<uint8_t, double> last_probe_sent_;
	std::map<uint8_t, std::map<uint32_t, double> > seen_probes_;
	std::map<uint8_t, std::map<int, double> > seen_data_pkts_; /**< Dedup cache for MAC-level duplicate data retries. */

	UwNdrExpireTimer expire_timer_;
};

#endif // UWNDR_MODULE_H
