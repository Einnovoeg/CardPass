# CardPass — Makefile (macOS, clang, ARC)
# Usage: make           # build CardPass binary
#        make app       # build CardPass.app bundle
#        make install   # copy to ~/Applications
#        make clean

CC      = clang
CFLAGS  = -fobjc-arc -O2 -Wall -Wno-deprecated-declarations
FRAMEWORKS = -framework Cocoa -framework CoreGraphics -framework ApplicationServices -framework PCSC
SRC     = main.m pcsc_reader.c
OUT     = CardPass
APP     = CardPass.app

all: $(OUT)

$(OUT): main.m pcsc_reader.c pcsc_reader.h
	$(CC) $(CFLAGS) $(FRAMEWORKS) main.m pcsc_reader.c -o $(OUT)

app: $(OUT)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(OUT) $(APP)/Contents/MacOS/
	cp Resources/AppIcon.icns $(APP)/Contents/Resources/ 2>/dev/null || cp AppIcon.icns $(APP)/Contents/Resources/ 2>/dev/null || true
	cp Resources/icon.png $(APP)/Contents/Resources/ 2>/dev/null || true
	cp Resources/icon_256.png $(APP)/Contents/Resources/ 2>/dev/null || true
	cp Resources/MenuIcon.png $(APP)/Contents/Resources/ 2>/dev/null || true
	cp Resources/MenuIcon@2x.png $(APP)/Contents/Resources/ 2>/dev/null || true
	cp Info.plist $(APP)/Contents/ 2>/dev/null || cp CardPass.app/Contents/Info.plist $(APP)/Contents/ 2>/dev/null || true
	codesign --force --deep --sign - $(APP) || true

install: app
	cp -R $(APP) ~/Applications/

clean:
	rm -f $(OUT) *.o
	rm -rf $(APP) build

.PHONY: all app install clean
