REPO := $(CURDIR)

.PHONY: all install app install-app clean reload

all: bin/pastev bin/dictatehud

bin/pastev: bin/pastev.c
	cc -O2 -framework ApplicationServices -o $@ $<

bin/dictatehud: bin/dictatehud.swift
	swiftc -O -o $@ $<

# CLI-режим (skhd): помощники + ~/.skhdrc + LaunchAgent
install: all
	./install.sh

# GUI-приложение (menu bar, свои хоткеи)
app:
	./scripts/build-app.sh

install-app: app
	./scripts/install-app.sh

clean:
	rm -f bin/pastev bin/dictatehud
	rm -rf .build dist

reload:
	skhd --restart-service
	launchctl kickstart -k gui/$$(id -u)/ai.opencode.whisper-server
