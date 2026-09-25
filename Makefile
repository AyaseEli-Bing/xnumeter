BIN     := xnumeter
APP     := XnumeterApp.app
APP_BIN := $(APP)/Contents/MacOS/xnumeter-gui
PLIST   := Sources/XnumeterApp/Info.plist

SRC     := $(wildcard Sources/Xnumeter/*.swift)
# The app target shares the sampling layer with the CLI rather than duplicating it,
# and deliberately leaves main.swift and Render.swift out of its build.
APP_SRC := $(wildcard Sources/XnumeterApp/*.swift) \
           Sources/Xnumeter/Sampler.swift Sources/Xnumeter/Snapshot.swift Sources/Xnumeter/Format.swift

SWIFTC ?= swiftc
# Swift 6 language mode, not just the 6.x toolchain: v5 mode would let a cross-isolation
# data race compile silently, which is the thing `nonisolated(unsafe)` is there to audit.
SWIFTFLAGS := -O -swift-version 6

all: $(BIN) $(APP_BIN)

$(BIN): $(SRC)
	$(SWIFTC) $(SWIFTFLAGS) $(SRC) -o $(BIN)

app: $(APP_BIN)

$(APP_BIN): $(APP_SRC) $(PLIST)
	@mkdir -p $(APP)/Contents/MacOS
	$(SWIFTC) $(SWIFTFLAGS) $(APP_SRC) -o $@
	cp $(PLIST) $(APP)/Contents/Info.plist
	@codesign --force --sign - $(APP) 2>/dev/null || echo "xnumeter: ad-hoc codesign skipped"

run: $(BIN)
	./$(BIN)

once: $(BIN)
	./$(BIN) --once

runapp: app
	open $(APP)

test: $(BIN)
	./scripts/selftest.sh

clean:
	rm -f $(BIN)
	rm -rf $(APP)

.PHONY: all app run runapp once test clean
