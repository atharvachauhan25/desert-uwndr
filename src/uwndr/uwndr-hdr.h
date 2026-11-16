#ifndef HDR_UWNDR_H
#define HDR_UWNDR_H

#include <cstdint>
#include <packet.h>

#define HDR_UWNDR(p) (hdr_uwndr::access(p))

extern packet_t PT_UWNDR;

enum UwNdrPktType : uint8_t {
	UWNDR_PROBE = 1,
	UWNDR_REPLY = 2,
	UWNDR_ERROR = 3
};

/**
 * Header structure for UW-NDR (Underwater Neighbor Discovery and Routing) control packets.
 */
typedef struct hdr_uwndr {
	uint8_t  pkt_type_;    /**< Control packet type: PROBE, REPLY, or ERROR. */
	uint8_t  orig_src_;    /**< IP of node initiating route discovery. */
	uint8_t  target_dst_;  /**< IP of target destination node. */
	uint32_t seq_num_;     /**< Sequence number to prevent broadcast loops. */
	uint16_t hop_count_;   /**< Number of hops traversed so far. */
	double   send_time_;   /**< Simulation timestamp when control packet was created. */

	static int offset_;

	inline static int &
	offset()
	{
		return offset_;
	}

	inline static struct hdr_uwndr *
	access(const Packet *p)
	{
		return (struct hdr_uwndr *) p->access(offset_);
	}
} hdr_uwndr;

#endif // HDR_UWNDR_H
