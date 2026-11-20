REPO := $(CURDIR)

.PHONY: all install app test-app test-launch test-keychain-isolation install-app dmg clean reload test-live-hud test-native test-editing test-recognition test-pause test-api test-updates

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

# Тестовая сборка: изолированный Keychain, ad-hoc-подпись, без сертификата.
test-app:
	./scripts/build-app.sh test

test-launch:
	bash scripts/test-app-launch.sh

test-keychain-isolation: test-app
	bash scripts/test-keychain-isolation.sh

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

# install-app.sh сам собирает приложение; отдельный prerequisite `app`
# приводил ко второй полной сборке и повторному копированию лицензий.
install-app:
	./scripts/install-app.sh

# Установочные DMG: отдельно для Apple Silicon и Intel
dmg: app
	./scripts/make-dmg.sh

clean:
	rm -f bin/pastev bin/dictatehud
	rm -rf .build dist

reload:
	-pkill -f 'Runvoice.app/Contents/Resources/whisper/bin/whisper-server'
