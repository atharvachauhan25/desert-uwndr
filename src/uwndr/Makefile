DESERT_ROOT = /mnt/c/Users/athar/Desktop/Project/DESERT_Underwater
BUILD_HOST  = $(DESERT_ROOT)/DESERT_buildCopy_LOCAL/.buildHost
DESERT_SRC  = $(DESERT_ROOT)/DESERT_Framework/DESERT
INSTALL_LIB = $(DESERT_ROOT)/DESERT_buildCopy_LOCAL/lib
TCL2CPP     = $(BUILD_HOST)/tclcl-1.20/tcl2c++

CXX         = g++
CXXFLAGS    = -std=c++11 -fPIC -Wall -Wextra -Wno-write-strings -O2 -ggdb3

INCLUDES    = -I. \
              -I$(DESERT_SRC)/network/uwip \
              -isystem $(BUILD_HOST)/nsmiracle-2.0.2/nsmiracle \
              -isystem $(BUILD_HOST)/nsmiracle-2.0.2/ip \
              -isystem $(BUILD_HOST)/include \
              -isystem $(BUILD_HOST)/ns-2-uwsignet-2.34-sa.1 \
              -isystem $(BUILD_HOST)/ns-2-uwsignet-2.34-sa.1/common \
              -isystem $(BUILD_HOST)/ns-2-uwsignet-2.34-sa.1/tools \
              -isystem $(BUILD_HOST)/ns-2-uwsignet-2.34-sa.1/mac \
              -isystem $(BUILD_HOST)/ns-2-uwsignet-2.34-sa.1/trace \
              -isystem $(BUILD_HOST)/tclcl-1.20 \
              -isystem $(BUILD_HOST)/otcl-1.14

LDFLAGS     = -shared -L$(INSTALL_LIB) -lMiracle -luwip

TARGET      = libuwndr.so
SRCS        = initlib.cpp uwndr-module.cpp InitTcl.cc

all: $(TARGET)

InitTcl.cc: uwndr-default.tcl
	cat uwndr-default.tcl | $(TCL2CPP) UwNdrInitTclCode > InitTcl.cc

$(TARGET): $(SRCS) uwndr-hdr.h uwndr-module.h
	$(CXX) $(CXXFLAGS) $(INCLUDES) $(SRCS) -o $(TARGET) $(LDFLAGS)

clean:
	rm -f $(TARGET) InitTcl.cc *.o

.PHONY: all clean
