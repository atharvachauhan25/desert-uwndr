#include "uwndr-hdr.h"
#include <tclcl.h>

extern EmbeddedTcl UwNdrInitTclCode;

packet_t PT_UWNDR;

extern "C" int
Uwndr_Init()
{
	PT_UWNDR = p_info::addPacket("UWNDR");
	UwNdrInitTclCode.load();
	return 0;
}

extern "C" int
Cyguwndr_Init()
{
	Uwndr_Init();
	return 0;
}
