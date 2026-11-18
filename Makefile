REPO := $(CURDIR)

.PHONY: all install app install-app dmg clean reload test-live-hud test-native test-editing test-recognition test-pause test-api test-updates

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

test-live-hud:
	bash scripts/test-live-hud.sh

test-native:
	bash scripts/test-native.sh

test-editing:
	bash scripts/test-editing.sh

test-recognition:
	bash scripts/test-recognition.sh

test-updates:
	bash scripts/test-updates.sh

test-api:
	bash scripts/test-api.sh

test-pause:
	bash scripts/test-pause.sh

install-app: app
	./scripts/install-app.sh

# Установочные DMG: отдельно для Apple Silicon и Intel
dmg: app
	./scripts/make-dmg.sh

clean:
	rm -f bin/pastev bin/dictatehud
	rm -rf .build dist

reload:
	-pkill -f 'Runvoice.app/Contents/Resources/whisper/bin/whisper-server'
