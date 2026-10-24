APP := build/Voice Clicker.app

.PHONY: app run install quit clean reset-permissions

app:
	./scripts/build-app.sh

run: app quit
	open "$(APP)"

install: app quit
	rm -rf "/Applications/Voice Clicker.app"
	cp -R "$(APP)" /Applications/
	open "/Applications/Voice Clicker.app"

quit:
	pkill -x VoiceClicker || true
	@sleep 1

reset-permissions:
	tccutil reset Accessibility com.codehex.VoiceClicker || true
	tccutil reset ListenEvent com.codehex.VoiceClicker || true

clean:
	rm -rf .build build
