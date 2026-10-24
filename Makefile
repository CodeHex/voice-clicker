APP := build/Voice Clicker.app

.PHONY: app run install clean reset-permissions

app:
	./scripts/build-app.sh

run: app
	open "$(APP)"

install: app
	rm -rf "/Applications/Voice Clicker.app"
	cp -R "$(APP)" /Applications/
	open "/Applications/Voice Clicker.app"

reset-permissions:
	tccutil reset Accessibility com.codehex.VoiceClicker || true
	tccutil reset ListenEvent com.codehex.VoiceClicker || true

clean:
	rm -rf .build build
