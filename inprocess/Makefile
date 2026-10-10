SOURCES = probe.m offline.m movement.m command.m discovery.m
FLAGS = -fobjc-arc -Wall -Wextra -dynamiclib -framework Foundation -framework AppKit -framework CloudKit

all: libFFProbe-arm64e.dylib libFFProbe.dylib

libFFProbe-arm64e.dylib: $(SOURCES)
	xcrun clang -arch arm64e $(FLAGS) $(SOURCES) -o $@

libFFProbe.dylib: $(SOURCES)
	xcrun clang -arch arm64 $(FLAGS) $(SOURCES) -o $@
