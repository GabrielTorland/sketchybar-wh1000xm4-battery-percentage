BIN     := headphone-battery
SRC     := src/headphone_battery.m
PREFIX  ?= $(HOME)/.local
CACHE   ?= $(HOME)/.cache/headphone-battery.json
LABEL   := io.github.gabrieltorland.headphone-battery
AGENT   := $(HOME)/Library/LaunchAgents/$(LABEL).plist

CFLAGS  := -fobjc-arc -O2 -Wall -Wextra
FRAMEWORKS := -framework Foundation -framework IOBluetooth -framework CoreAudio

.PHONY: all install install-agent uninstall clean

all: bin/$(BIN)

bin/$(BIN): $(SRC) | bin
	clang $(CFLAGS) $(FRAMEWORKS) $< -o $@

bin:
	mkdir -p bin

install: bin/$(BIN) install-agent
	@echo
	@echo "installed $(PREFIX)/bin/$(BIN)"
	@echo "readings appear in $(CACHE)"

install-agent: bin/$(BIN)
	mkdir -p $(PREFIX)/bin $(HOME)/Library/LaunchAgents $(dir $(CACHE))
	install -m 755 bin/$(BIN) $(PREFIX)/bin/$(BIN)
	sed -e 's|__PREFIX__|$(PREFIX)|g' -e 's|__CACHE__|$(CACHE)|g' \
	    sketchybar/$(LABEL).plist > $(AGENT)
	-launchctl bootout gui/$(shell id -u)/$(LABEL) 2>/dev/null
	launchctl bootstrap gui/$(shell id -u) $(AGENT)

uninstall:
	-launchctl bootout gui/$(shell id -u)/$(LABEL) 2>/dev/null
	rm -f $(AGENT) $(PREFIX)/bin/$(BIN) $(CACHE)

clean:
	rm -rf bin
