REPO := $(CURDIR)

.PHONY: all install clean reload

all: bin/pastev bin/dictatehud

bin/pastev: bin/pastev.c
	cc -O2 -framework ApplicationServices -o $@ $<

bin/dictatehud: bin/dictatehud.swift
	swiftc -O -o $@ $<

install: all
	./install.sh

clean:
	rm -f bin/pastev bin/dictatehud

reload:
	skhd --restart-service
	launchctl kickstart -k gui/$$(id -u)/ai.opencode.whisper-server
