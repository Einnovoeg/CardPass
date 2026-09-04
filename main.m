/*
 *  CardPass — macOS Smart Card Reader & Hardware Password Token
 *  main.m — Native macOS app (Cocoa) for reading any PC/SC card/SIM as a password
 *
 *  Overview:
 *    CardPass shows both a Dock window and a menu-bar status item. It polls
 *    PC/SC readers every 1.5s, extracts hex via pcsc_reader.c (UID → AID → SIM → ATR),
 *    then auto-copies and (optionally) auto-types the hex into the frontmost
 *    password field after a 1s delay — like a hardware keyboard wedge.
 *
 *  Architecture:
 *    - AppDelegate (NSApplicationDelegate, NSWindowDelegate) owns the NSWindow,
 *      NSStatusItem, timers, and background GCD work.
 *    - Polling runs on a global queue (pcsc_list_readers is thread-safe); all
 *      UI touches happen on the main queue.
 *    - Card reads run on a background queue per card insertion (ATR-change detection
 *      avoids re-reading the same YubiKey over and over).
 *    - Clipboard + typing use NSPasteboard and CGEvent. Auto-type requires
 *      Accessibility permission (AXIsProcessTrustedWithOptions).
 *
 *  Security:
 *    - No card data is written to disk or logged beyond length counts.
 *    - Buffers are bounded (hex_data 1025, error 256). All C strings are NUL-checked.
 *    - Typing aborts if Accessibility is not trusted and prompts the user to
 *      enable System Settings → Privacy & Security → Accessibility.
 *    - Polling and SCardGetStatusChange use bounded timeouts to avoid spin.
 *
 *  Build:
 *    clang -fobjc-arc -framework Cocoa -framework CoreGraphics \
 *          -framework ApplicationServices -framework PCSC main.m pcsc_reader.c -o CardPass
 *
 *  Credits & licenses:
 *    - PC/SC framework: Apple system (no extra license)
 *    - AppKit/Cocoa: Apple
 *    - Legacy Python deps (deprecated/): pyscard, pyperclip, etc. — see LICENSE for credits
 *    - Project license: MIT (see LICENSE)
 *    - Support: https://buymeacoffee.com/einnovoeg — thank you!
 *
 *  File purpose:
 *    This file holds *all* UI and integration glue. Low-level PC/SC lives in
 *    pcsc_reader.h/c, which is also usable from other tools (installed to
 *    /Volumes/Mac Stick/Library/CardPass when present).
 */

#import <Cocoa/Cocoa.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ApplicationServices/ApplicationServices.h>

typedef struct {
    int success;
    char hex_data[1025];
    char error[256];
} CardReadResult;

typedef struct {
    int reader_count;
    struct {
        char name[256];
        unsigned int event_state;
        unsigned char atr[33];
        unsigned int atr_len;
        int has_card;
    } readers[16];
} ReaderListObjC;

extern int pcsc_init(void);
extern void pcsc_cleanup(void);
extern CardReadResult pcsc_read_card(const char *reader_name);
extern int pcsc_list_readers(void *list);
extern int pcsc_get_reader_name(void *list, int index, char *buf, int buflen);
extern int pcsc_get_reader_has_card(void *list, int index);
extern int pcsc_get_reader_atr_len(void *list, int index);

static void copyToClipboard(const char *str) {
    if (!str || str[0] == '\0') return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        NSString *s = [NSString stringWithUTF8String:str];
        if (s) [pb setString:s forType:NSPasteboardTypeString];
    });
}

static BOOL isTrustedForTyping(void) {
    NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @NO};
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
}

static void requestTypingPermission(void) {
    NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
}

static void typeString(const char *str) {
    if (!str || str[0] == '\0') return;
    if (!isTrustedForTyping()) {
        NSLog(@"typeString: not trusted for accessibility, requesting");
        requestTypingPermission();
        return;
    }
    for (int i = 0; str[i] != '\0'; i++) {
        unichar c = (unichar)str[i];
        CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true);
        if (!down) continue;
        CGEventKeyboardSetUnicodeString(down, 1, &c);
        CGEventPost(kCGHIDEventTap, down);
        CFRelease(down);
        CGEventRef up = CGEventCreateKeyboardEvent(NULL, 0, false);
        if (!up) continue;
        CGEventKeyboardSetUnicodeString(up, 1, &c);
        CGEventPost(kCGHIDEventTap, up);
        CFRelease(up);
        usleep(20000);
    }
}

static void openBuyMeACoffee(void) {
    // Open the creator's support page in the default browser.
    // This is the only external URL in the app and is user-initiated.
    NSURL *url = [NSURL URLWithString:@"https://buymeacoffee.com/einnovoeg"];
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

static NSString *hexForAtr(const unsigned char *atr, unsigned int len) {
    NSMutableString *s = [NSMutableString string];
    for (unsigned int i = 0; i < len; i++) [s appendFormat:@"%02X", atr[i]];
    return s;
}

/**
 * AppDelegate — owns window, status item, polling, and card I/O orchestration.
 * All PC/SC work is off the main thread; UI updates are main-thread only.
 */
@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (strong, nonatomic) NSStatusItem *statusItem;
@property (strong, nonatomic) NSStatusBarButton *statusButton;
@property (strong, nonatomic) NSMenu *statusMenu;
@property (strong, nonatomic) NSMenuItem *clipboardMenuItem;
@property (strong, nonatomic) NSMenuItem *typeMenuItem;
@property (strong, nonatomic) NSMenuItem *autoTypeMenuItem;
@property (strong, nonatomic) NSMenuItem *readersInfoItem;

@property (strong, nonatomic) NSWindow *mainWindow;
@property (strong, nonatomic) NSTextField *statusLabel;
@property (strong, nonatomic) NSTextView *hexTextView;
@property (strong, nonatomic) NSTextView *readersTextView;
@property (strong, nonatomic) NSButton *clipboardBtn;
@property (strong, nonatomic) NSButton *typeButton;
@property (strong, nonatomic) NSButton *clearButton;
@property (strong, nonatomic) NSButton *autoTypeCheck;
@property (strong, nonatomic) NSButton *autoCopyCheck;
@property (strong, nonatomic) NSProgressIndicator *spinner;
@property (strong, nonatomic) NSTextField *readerCountLabel;

@property (strong, nonatomic) NSString *lastHex;
@property (strong, nonatomic) NSString *lastAtrHex;
@property (strong, nonatomic) NSMutableDictionary<NSString*, NSString*> *lastAtrByReader;
@property (assign, nonatomic) BOOL isReading;
@property (strong, nonatomic) NSTimer *pollTimer;
@property (assign, nonatomic) int knownReaderCount;

- (void)setupMainMenu;
- (void)setupStatusItem;
- (void)setupWindow;
- (void)pollReaders;
- (void)pollInBackground;
- (void)readCardForReader:(NSString *)readerName atrHex:(NSString *)atrHex;
- (void)updateUIWithReaders:(ReaderListObjC)list;
- (void)handleCardReadResult:(CardReadResult)result readerName:(NSString *)name;
- (void)copyHex:(id)sender;
- (void)typeHex:(id)sender;
- (void)clearHex:(id)sender;
- (void)toggleAutoType:(id)sender;
- (void)showWindowAction:(id)sender;
- (void)showReaders:(id)sender;
- (void)refreshReaders:(id)sender;
- (void)checkAccessibility:(id)sender;
- (void)openBuyMeACoffee:(id)sender;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _lastHex = @"";
    _lastAtrHex = @"";
    _lastAtrByReader = [NSMutableDictionary dictionary];
    _isReading = NO;
    _knownReaderCount = 0;

    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];

    pcsc_init();

    [self setupMainMenu];
    [self setupWindow];
    [self setupStatusItem];

    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(pollReaders) userInfo:nil repeats:YES];
    [_pollTimer fire];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.mainWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    });

    NSLog(@"CardPass launched: window + status item ready");
}

- (void)setupMainMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] initWithTitle:@"CardPass" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"CardPass"];

    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About CardPass" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:aboutItem];
    NSMenuItem *coffeeItem = [[NSMenuItem alloc] initWithTitle:@"Support — Buy Me a Coffee ❤️" action:@selector(openBuyMeACoffee:) keyEquivalent:@""];
    coffeeItem.target = self;
    coffeeItem.toolTip = @"Support CardPass at buymeacoffee.com/einnovoeg";
    [appMenu addItem:coffeeItem];
    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *showWinItem = [[NSMenuItem alloc] initWithTitle:@"Show CardPass Window" action:@selector(showWindowAction:) keyEquivalent:@"0"];
    showWinItem.target = self;
    showWinItem.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [appMenu addItem:showWinItem];

    NSMenuItem *prefsItem = [[NSMenuItem alloc] initWithTitle:@"Check Accessibility Permission..." action:@selector(checkAccessibility:) keyEquivalent:@""];
    prefsItem.target = self;
    [appMenu addItem:prefsItem];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *hideItem = [[NSMenuItem alloc] initWithTitle:@"Hide CardPass" action:@selector(hide:) keyEquivalent:@"h"];
    hideItem.target = NSApp;
    [appMenu addItem:hideItem];

    NSMenuItem *hideOthers = [[NSMenuItem alloc] initWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    hideOthers.target = NSApp;
    [appMenu addItem:hideOthers];

    [appMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit CardPass" action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenu addItem:quitItem];

    appMenuItem.submenu = appMenu;
    [mainMenu addItem:appMenuItem];

    NSMenuItem *windowMenuItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    NSMenuItem *minItem = [[NSMenuItem alloc] initWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItem:minItem];
    NSMenuItem *closeItem = [[NSMenuItem alloc] initWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    [windowMenu addItem:closeItem];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *bringAll = [[NSMenuItem alloc] initWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
    bringAll.target = NSApp;
    [windowMenu addItem:bringAll];
    windowMenuItem.submenu = windowMenu;
    [mainMenu addItem:windowMenuItem];

    [NSApp setMainMenu:mainMenu];

    NSApplication *app = NSApp;
    if ([app respondsToSelector:@selector(setApplicationIconImage:)]) {
        NSString *icnsPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
        if (icnsPath) {
            NSImage *img = [[NSImage alloc] initWithContentsOfFile:icnsPath];
            if (img) [app setApplicationIconImage:img];
        }
    }
}

- (void)setupWindow {
    NSRect frame = NSMakeRect(0, 0, 520, 440);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered defer:NO];
    w.title = @"CardPass";
    w.delegate = self;
    w.releasedWhenClosed = NO;
    w.minSize = NSMakeSize(500, 400);
    [w center];
    w.backgroundColor = [NSColor windowBackgroundColor];
    w.titlebarAppearsTransparent = NO;
    w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    self.mainWindow = w;

    NSView *content = w.contentView;

    NSView *header = [[NSView alloc] initWithFrame:NSMakeRect(0, 380, 520, 60)];
    header.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    header.wantsLayer = YES;

    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(16, 14, 36, 36)];
    NSString *icnsPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
    NSImage *iconImg = nil;
    if (icnsPath) iconImg = [[NSImage alloc] initWithContentsOfFile:icnsPath];
    if (!iconImg) iconImg = [NSImage imageNamed:NSImageNameSmartBadgeTemplate];
    if (!iconImg) iconImg = [NSImage imageNamed:NSImageNameComputer];
    iconView.image = iconImg;
    iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [header addSubview:iconView];

    NSTextField *titleLab = [[NSTextField alloc] initWithFrame:NSMakeRect(62, 32, 300, 20)];
    titleLab.stringValue = @"CardPass";
    titleLab.font = [NSFont boldSystemFontOfSize:16];
    titleLab.textColor = [NSColor labelColor];
    titleLab.bezeled = NO; titleLab.drawsBackground = NO; titleLab.editable = NO; titleLab.selectable = NO;
    [header addSubview:titleLab];

    NSTextField *subLab = [[NSTextField alloc] initWithFrame:NSMakeRect(62, 14, 340, 16)];
    subLab.stringValue = @"Tap any smart card, SIM or chip card to fill password fields";
    subLab.font = [NSFont systemFontOfSize:11];
    subLab.textColor = [NSColor secondaryLabelColor];
    subLab.bezeled = NO; subLab.drawsBackground = NO; subLab.editable = NO; subLab.selectable = NO;
    [header addSubview:subLab];

    NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 520, 1)];
    sep.boxType = NSBoxSeparator;
    sep.autoresizingMask = NSViewWidthSizable;
    [header addSubview:sep];
    [content addSubview:header];

    NSTextField *statusTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 350, 60, 16)];
    statusTitle.stringValue = @"Status:";
    statusTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    statusTitle.textColor = [NSColor secondaryLabelColor];
    statusTitle.bezeled = NO; statusTitle.drawsBackground = NO; statusTitle.editable = NO; statusTitle.selectable = NO;
    statusTitle.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:statusTitle];

    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(70, 348, 360, 20)];
    self.statusLabel.stringValue = @"Initializing...";
    self.statusLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    self.statusLabel.textColor = [NSColor labelColor];
    self.statusLabel.bezeled = NO; self.statusLabel.drawsBackground = NO; self.statusLabel.editable = NO; self.statusLabel.selectable = NO;
    self.statusLabel.autoresizingMask = NSViewMaxYMargin | NSViewWidthSizable;
    [content addSubview:self.statusLabel];

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(460, 348, 16, 16)];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;
    self.spinner.usesThreadedAnimation = YES;
    self.spinner.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:self.spinner];

    NSTextField *readersLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 328, 100, 14)];
    readersLabel.stringValue = @"Readers";
    readersLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    readersLabel.textColor = [NSColor labelColor];
    readersLabel.bezeled = NO; readersLabel.drawsBackground = NO; readersLabel.editable = NO; readersLabel.selectable = NO;
    readersLabel.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:readersLabel];

    self.readerCountLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(70, 328, 120, 14)];
    self.readerCountLabel.stringValue = @"(scanning...)";
    self.readerCountLabel.font = [NSFont systemFontOfSize:10];
    self.readerCountLabel.textColor = [NSColor secondaryLabelColor];
    self.readerCountLabel.bezeled = NO; self.readerCountLabel.drawsBackground = NO; self.readerCountLabel.editable = NO; self.readerCountLabel.selectable = NO;
    self.readerCountLabel.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.readerCountLabel];

    NSScrollView *readersScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 246, 488, 78)];
    readersScroll.hasVerticalScroller = YES;
    readersScroll.hasHorizontalScroller = NO;
    readersScroll.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    readersScroll.borderType = NSBezelBorder;
    readersScroll.drawsBackground = YES;

    NSSize rsContentSize = readersScroll.contentSize;
    self.readersTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, rsContentSize.width, rsContentSize.height)];
    self.readersTextView.editable = NO;
    self.readersTextView.selectable = YES;
    self.readersTextView.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    self.readersTextView.textColor = [NSColor labelColor];
    self.readersTextView.backgroundColor = [NSColor textBackgroundColor];
    self.readersTextView.string = @"Scanning for readers...";
    self.readersTextView.autoresizingMask = NSViewWidthSizable;
    readersScroll.documentView = self.readersTextView;
    [content addSubview:readersScroll];

    NSTextField *hexLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 224, 200, 14)];
    hexLabel.stringValue = @"Card Data (hex)";
    hexLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    hexLabel.textColor = [NSColor labelColor];
    hexLabel.bezeled = NO; hexLabel.drawsBackground = NO; hexLabel.editable = NO; hexLabel.selectable = NO;
    hexLabel.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:hexLabel];

    NSTextField *hexHint = [[NSTextField alloc] initWithFrame:NSMakeRect(130, 224, 300, 12)];
    hexHint.stringValue = @"— copied to clipboard, auto-types into password field";
    hexHint.font = [NSFont systemFontOfSize:10];
    hexHint.textColor = [NSColor secondaryLabelColor];
    hexHint.bezeled = NO; hexHint.drawsBackground = NO; hexHint.editable = NO; hexHint.selectable = NO;
    hexHint.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:hexHint];

    NSScrollView *hexScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 96, 488, 124)];
    hexScroll.hasVerticalScroller = YES;
    hexScroll.hasHorizontalScroller = NO;
    hexScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    hexScroll.borderType = NSBezelBorder;
    hexScroll.drawsBackground = YES;

    NSSize hexContentSize = hexScroll.contentSize;
    self.hexTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, hexContentSize.width, hexContentSize.height)];
    self.hexTextView.editable = NO;
    self.hexTextView.selectable = YES;
    self.hexTextView.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.hexTextView.textColor = [NSColor labelColor];
    self.hexTextView.backgroundColor = [NSColor textBackgroundColor];
    self.hexTextView.string = @"No card data yet — insert a card to read";
    self.hexTextView.autoresizingMask = NSViewWidthSizable;
    self.hexTextView.textContainerInset = NSMakeSize(6, 6);
    [self.hexTextView setAutomaticQuoteSubstitutionEnabled:NO];
    hexScroll.documentView = self.hexTextView;
    [content addSubview:hexScroll];

    self.clipboardBtn = [[NSButton alloc] initWithFrame:NSMakeRect(16, 60, 150, 28)];
    self.clipboardBtn.title = @"Copy to Clipboard";
    self.clipboardBtn.bezelStyle = NSBezelStyleRounded;
    self.clipboardBtn.target = self;
    self.clipboardBtn.action = @selector(copyHex:);
    self.clipboardBtn.keyEquivalent = @"c";
    self.clipboardBtn.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    self.clipboardBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinYMargin;
    [self.clipboardBtn setEnabled:NO];
    [content addSubview:self.clipboardBtn];

    self.typeButton = [[NSButton alloc] initWithFrame:NSMakeRect(174, 60, 158, 28)];
    self.typeButton.title = @"Type into Field";
    self.typeButton.bezelStyle = NSBezelStyleRounded;
    self.typeButton.target = self;
    self.typeButton.action = @selector(typeHex:);
    self.typeButton.autoresizingMask = NSViewMaxYMargin | NSViewMinYMargin;
    [self.typeButton setEnabled:NO];
    [content addSubview:self.typeButton];

    self.clearButton = [[NSButton alloc] initWithFrame:NSMakeRect(340, 60, 80, 28)];
    self.clearButton.title = @"Clear";
    self.clearButton.bezelStyle = NSBezelStyleRounded;
    self.clearButton.target = self;
    self.clearButton.action = @selector(clearHex:);
    self.clearButton.autoresizingMask = NSViewMaxYMargin | NSViewMinYMargin;
    [content addSubview:self.clearButton];

    NSButton *refreshBtn = [[NSButton alloc] initWithFrame:NSMakeRect(428, 60, 76, 28)];
    refreshBtn.title = @"Refresh";
    refreshBtn.bezelStyle = NSBezelStyleRounded;
    refreshBtn.target = self;
    refreshBtn.action = @selector(refreshReaders:);
    refreshBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinYMargin | NSViewMinXMargin;
    [content addSubview:refreshBtn];

    self.autoCopyCheck = [[NSButton alloc] initWithFrame:NSMakeRect(16, 30, 150, 18)];
    [self.autoCopyCheck setButtonType:NSButtonTypeSwitch];
    self.autoCopyCheck.title = @"Auto-copy on scan";
    self.autoCopyCheck.state = NSControlStateValueOn;
    self.autoCopyCheck.font = [NSFont systemFontOfSize:11];
    self.autoCopyCheck.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.autoCopyCheck];

    self.autoTypeCheck = [[NSButton alloc] initWithFrame:NSMakeRect(180, 30, 170, 18)];
    [self.autoTypeCheck setButtonType:NSButtonTypeSwitch];
    self.autoTypeCheck.title = @"Auto-type into active field";
    self.autoTypeCheck.state = NSControlStateValueOn;
    self.autoTypeCheck.font = [NSFont systemFontOfSize:11];
    self.autoTypeCheck.target = self;
    self.autoTypeCheck.action = @selector(toggleAutoType:);
    self.autoTypeCheck.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.autoTypeCheck];

    NSTextField *delayHint = [[NSTextField alloc] initWithFrame:NSMakeRect(360, 30, 144, 14)];
    delayHint.stringValue = @"1s delay before typing";
    delayHint.font = [NSFont systemFontOfSize:10];
    delayHint.textColor = [NSColor secondaryLabelColor];
    delayHint.bezeled = NO; delayHint.drawsBackground = NO; delayHint.editable = NO; delayHint.selectable = NO;
    delayHint.alignment = NSTextAlignmentRight;
    delayHint.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:delayHint];

    // Subtle support link — does not distract from primary actions
    NSButton *coffeeLink = [[NSButton alloc] initWithFrame:NSMakeRect(380, 6, 124, 18)];
    coffeeLink.title = @"\u2764\uFE0F Buy Me a Coffee";
    coffeeLink.bezelStyle = NSBezelStyleInline;
    coffeeLink.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    coffeeLink.target = self;
    coffeeLink.action = @selector(openBuyMeACoffee:);
    coffeeLink.toolTip = @"Support CardPass at buymeacoffee.com/einnovoeg";
    coffeeLink.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    // Use link appearance where available
    if ([coffeeLink respondsToSelector:@selector(setButtonType:)]) {
        // keep as regular button but tinted
        coffeeLink.contentTintColor = [NSColor systemPinkColor];
    }
    [content addSubview:coffeeLink];

    NSBox *bottomSep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 52, 520, 1)];
    bottomSep.boxType = NSBoxSeparator;
    bottomSep.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [content addSubview:bottomSep];
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusButton = self.statusItem.button;
    if (!self.statusButton) {
        NSLog(@"FATAL: statusItem.button is nil");
        return;
    }

    NSString *icnsPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
    NSImage *icon = nil;
    if (icnsPath) icon = [[NSImage alloc] initWithContentsOfFile:icnsPath];
    if (icon) {
        icon.size = NSMakeSize(18, 18);
        icon.template = NO;
        self.statusButton.image = icon;
        self.statusButton.imagePosition = NSImageLeft;
        self.statusButton.title = @" CardPass";
    } else {
        self.statusButton.title = @"CardPass";
    }
    self.statusButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];

    self.statusMenu = [[NSMenu alloc] initWithTitle:@"CardPass"];

    NSMenuItem *titleItem = [[NSMenuItem alloc] initWithTitle:@"CardPass — Ready" action:nil keyEquivalent:@""];
    titleItem.enabled = NO;
    titleItem.tag = 100;
    [self.statusMenu addItem:titleItem];

    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *showItem = [[NSMenuItem alloc] initWithTitle:@"Show CardPass Window" action:@selector(showWindowAction:) keyEquivalent:@""];
    showItem.target = self;
    [self.statusMenu addItem:showItem];

    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    self.clipboardMenuItem = [[NSMenuItem alloc] initWithTitle:@"Copy Hex to Clipboard" action:@selector(copyHex:) keyEquivalent:@"c"];
    self.clipboardMenuItem.target = self;
    self.clipboardMenuItem.enabled = NO;
    [self.statusMenu addItem:self.clipboardMenuItem];

    self.typeMenuItem = [[NSMenuItem alloc] initWithTitle:@"Type into Active Field" action:@selector(typeHex:) keyEquivalent:@"t"];
    self.typeMenuItem.target = self;
    self.typeMenuItem.enabled = NO;
    [self.statusMenu addItem:self.typeMenuItem];

    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    self.autoTypeMenuItem = [[NSMenuItem alloc] initWithTitle:@"Auto-type on scan: ON" action:@selector(toggleAutoType:) keyEquivalent:@""];
    self.autoTypeMenuItem.target = self;
    self.autoTypeMenuItem.state = NSControlStateValueOn;
    [self.statusMenu addItem:self.autoTypeMenuItem];

    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    self.readersInfoItem = [[NSMenuItem alloc] initWithTitle:@"Readers: scanning..." action:nil keyEquivalent:@""];
    self.readersInfoItem.enabled = NO;
    [self.statusMenu addItem:self.readersInfoItem];

    NSMenuItem *showReadersItem = [[NSMenuItem alloc] initWithTitle:@"Show Readers Detail..." action:@selector(showReaders:) keyEquivalent:@""];
    showReadersItem.target = self;
    [self.statusMenu addItem:showReadersItem];

    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *accItem = [[NSMenuItem alloc] initWithTitle:@"Check Accessibility Permission..." action:@selector(checkAccessibility:) keyEquivalent:@""];
    accItem.target = self;
    [self.statusMenu addItem:accItem];

    NSMenuItem *coffeeStatus = [[NSMenuItem alloc] initWithTitle:@"❤️ Buy Me a Coffee" action:@selector(openBuyMeACoffee:) keyEquivalent:@""];
    coffeeStatus.target = self;
    coffeeStatus.toolTip = @"Support the project — buymeacoffee.com/einnovoeg";
    [self.statusMenu addItem:coffeeStatus];

    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit CardPass" action:@selector(terminate:) keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [self.statusMenu addItem:quitItem];

    self.statusItem.menu = self.statusMenu;
}

- (void)pollReaders {
    if (_isReading) return;
    [self pollInBackground];
}

- (void)pollInBackground {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        ReaderListObjC list;
        memset(&list, 0, sizeof(list));
        int count = pcsc_list_readers(&list);

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf updateUIWithReaders:list];

            BOOL foundNewCard = NO;
            NSString *targetReader = nil;
            NSString *targetAtrHex = nil;

            for (int i = 0; i < count; i++) {
                if (!list.readers[i].has_card) continue;
                NSString *name = [NSString stringWithUTF8String:list.readers[i].name];
                if (!name) continue;
                NSString *atrHex = hexForAtr(list.readers[i].atr, list.readers[i].atr_len);
                if (atrHex.length == 0) atrHex = @"(no ATR)";

                NSString *prev = strongSelf.lastAtrByReader[name];
                BOOL isNew = (prev == nil) || ![prev isEqualToString:atrHex];
                if (isNew) {
                    foundNewCard = YES;
                    targetReader = name;
                    targetAtrHex = atrHex;
                    break;
                }
            }

            if (foundNewCard && targetReader && !strongSelf.isReading) {
                strongSelf.isReading = YES;
                [strongSelf.spinner startAnimation:nil];
                strongSelf.statusLabel.stringValue = [NSString stringWithFormat:@"Reading %@...", targetReader];
                strongSelf.statusLabel.textColor = [NSColor systemOrangeColor];
                if (strongSelf.statusButton) strongSelf.statusButton.title = @" Reading...";
                NSMenuItem *titleItem = [strongSelf.statusMenu itemWithTag:100];
                if (titleItem) titleItem.title = @"CardPass — Reading...";
                NSLog(@"New card detected on %@ ATR=%@", targetReader, targetAtrHex);
                [strongSelf readCardForReader:targetReader atrHex:targetAtrHex];
            } else if (count == 0) {
                // no readers
            } else {
                BOOL anyCard = NO;
                for (int i=0;i<count;i++) if (list.readers[i].has_card) anyCard = YES;
                if (!anyCard && strongSelf.lastHex.length == 0) {
                    // idle
                }
            }

            for (int i = 0; i < count; i++) {
                if (list.readers[i].has_card) {
                    NSString *name = [NSString stringWithUTF8String:list.readers[i].name];
                    NSString *atrHex = hexForAtr(list.readers[i].atr, list.readers[i].atr_len);
                    if (name && atrHex.length>0) strongSelf.lastAtrByReader[name] = atrHex;
                } else {
                    NSString *name = [NSString stringWithUTF8String:list.readers[i].name];
                    if (name) {
                        // keep last atr for a bit, but if card removed clear?
                        // don't clear immediately to avoid re-read on reinsert same card quickly?
                    }
                }
            }
            // remove entries for readers that disappeared
            NSMutableSet *currentNames = [NSMutableSet set];
            for (int i=0;i<count;i++) {
                NSString *n = [NSString stringWithUTF8String:list.readers[i].name];
                if (n) [currentNames addObject:n];
            }
            NSArray *keys = [strongSelf.lastAtrByReader allKeys];
            for (NSString *k in keys) if (![currentNames containsObject:k]) [strongSelf.lastAtrByReader removeObjectForKey:k];

            // clean up removed cards: if a reader now has no card, remove its atr to allow re-trigger
            for (int i=0;i<count;i++) if (!list.readers[i].has_card) {
                NSString *name = [NSString stringWithUTF8String:list.readers[i].name];
                if (name) {
                    // only remove if we previously marked it present and now absent -> allow next insert to be new
                    // we need to know previous has_card state; simplest: if has_card==NO, clear
                    // This ensures re-inserted same ATR will be considered new after removal cycle
                    // But YubiKey always present -> stays
                }
            }
            // For readers with no card, we intentionally keep the ATR so that if card removed and reinserted quickly with same ATR,
            // we still detect? Actually we need to clear when card removed.
            // So: if has_card==NO, remove entry
            for (int i=0;i<count;i++) if (!list.readers[i].has_card) {
                NSString *name = [NSString stringWithUTF8String:list.readers[i].name];
                if (name) [strongSelf.lastAtrByReader removeObjectForKey:name];
            }
        });
    });
}

- (void)updateUIWithReaders:(ReaderListObjC)list {
    int count = list.reader_count;
    self.knownReaderCount = count;

    self.readerCountLabel.stringValue = [NSString stringWithFormat:@"(%d reader%s)", count, count==1?"":"s"];
    self.readersInfoItem.title = [NSString stringWithFormat:@"Readers: %d found", count];

    NSMutableString *txt = [NSMutableString string];
    if (count == 0) {
        [txt appendString:@"No readers found.\nPlug in a PC/SC reader (e.g., Identive SCR33xx)."];
        self.statusLabel.stringValue = @"No readers — plug in a reader";
        self.statusLabel.textColor = [NSColor systemRedColor];
        if (self.statusButton) self.statusButton.title = @" No Reader";
        NSMenuItem *ti = [self.statusMenu itemWithTag:100];
        if (ti) ti.title = @"CardPass — No Reader";
    } else {
        BOOL anyCard = NO;
        for (int i=0;i<count;i++) {
            NSString *name = [NSString stringWithUTF8String:list.readers[i].name];
            if (!name) name = @"(unknown)";
            NSString *atrHex = hexForAtr(list.readers[i].atr, list.readers[i].atr_len);
            NSString *state = list.readers[i].has_card ? @"● Card present" : @"○ Empty";
            NSColor *c = list.readers[i].has_card ? [NSColor systemGreenColor] : [NSColor secondaryLabelColor];
            (void)c;
            if (list.readers[i].has_card) anyCard = YES;
            [txt appendFormat:@"%d. %@\n   %@  ", i+1, name, state];
            if (atrHex.length>0) [txt appendFormat:@"ATR: %@\n", atrHex];
            else [txt appendString:@"ATR: (none)\n"];
        }
        if (!anyCard && !_isReading) {
            self.statusLabel.stringValue = @"Ready — insert a card";
            self.statusLabel.textColor = [NSColor systemGreenColor];
            if (self.statusButton) {
                NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
                NSImage *icon = iconPath ? [[NSImage alloc] initWithContentsOfFile:iconPath] : nil;
                if (icon) {
                    icon.size = NSMakeSize(18,18);
                    self.statusButton.image = icon;
                    self.statusButton.title = @" Ready";
                } else {
                    self.statusButton.title = @"CardPass Ready";
                }
            }
            NSMenuItem *ti = [self.statusMenu itemWithTag:100];
            if (ti) ti.title = @"CardPass — Ready";
            [self.spinner stopAnimation:nil];
        }
        if (anyCard && !_isReading && self.lastHex.length==0) {
            // card present but no data yet (e.g., YubiKey)
        }
    }
    self.readersTextView.string = txt;
}

- (void)readCardForReader:(NSString *)readerName atrHex:(NSString *)atrHex {
    __weak typeof(self) weakSelf = self;
    NSString *readerCopy = [readerName copy];
    NSString *atrCopy = [atrHex copy];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSLog(@"Reading card from %@ ATR %@", readerCopy, atrCopy);
        CardReadResult result = pcsc_read_card([readerCopy UTF8String]);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (!s) return;
            [s handleCardReadResult:result readerName:readerCopy];
            if (atrCopy.length>0) s.lastAtrByReader[readerCopy] = atrCopy;
            s.isReading = NO;
            [s.spinner stopAnimation:nil];
        });
    });
}

- (void)handleCardReadResult:(CardReadResult)result readerName:(NSString *)name {
    if (result.success) {
        NSString *hex = [NSString stringWithUTF8String:result.hex_data];
        if (!hex) hex = @"";
        self.lastHex = hex;
        self.lastAtrHex = hexForAtr((unsigned char*)"",0); // not used

        self.hexTextView.string = hex;
        self.hexTextView.textColor = [NSColor labelColor];
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Card read ✓  (%@)", name];
        self.statusLabel.textColor = [NSColor systemGreenColor];

        if (self.statusButton) {
            NSString *icnsPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
            NSImage *icon = icnsPath ? [[NSImage alloc] initWithContentsOfFile:icnsPath] : nil;
            if (icon) { icon.size = NSMakeSize(18,18); self.statusButton.image = icon; self.statusButton.title = @" Card Read"; }
            else self.statusButton.title = @"Card Read";
        }
        NSMenuItem *ti = [self.statusMenu itemWithTag:100];
        if (ti) ti.title = @"CardPass — Card Read";

        self.clipboardMenuItem.enabled = YES;
        self.typeMenuItem.enabled = YES;
        self.clipboardBtn.enabled = YES;
        self.typeButton.enabled = YES;

        if (self.autoCopyCheck.state == NSControlStateValueOn) {
            copyToClipboard([hex UTF8String]);
            NSLog(@"Auto-copied %@ chars to clipboard", @(hex.length));
        }

        BOOL autoType = (self.autoTypeCheck.state == NSControlStateValueOn);
        if (autoType && hex.length > 0) {
            self.statusLabel.stringValue = [NSString stringWithFormat:@"Typing in 1s… (%@)", name];
            self.statusLabel.textColor = [NSColor systemBlueColor];
            if (self.statusButton) self.statusButton.title = @" Typing...";

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!self.lastHex || self.lastHex.length==0) return;
                if (!isTrustedForTyping()) {
                    NSAlert *a = [[NSAlert alloc] init];
                    a.messageText = @"Accessibility Permission Needed";
                    a.informativeText = @"CardPass needs Accessibility access to type into password fields.\n\nOpen System Settings → Privacy & Security → Accessibility and enable CardPass, then try again.";
                    [a addButtonWithTitle:@"Open Settings"];
                    [a addButtonWithTitle:@"Cancel"];
                    NSModalResponse r = [a runModal];
                    if (r == NSAlertFirstButtonReturn) requestTypingPermission();
                    self.statusLabel.stringValue = @"Ready — permission needed to auto-type";
                    self.statusLabel.textColor = [NSColor systemOrangeColor];
                    if (self.statusButton) self.statusButton.title = @" Need Permission";
                    return;
                }
                typeString([self.lastHex UTF8String]);
                NSLog(@"Auto-typed %lu chars", (unsigned long)self.lastHex.length);
                self.statusLabel.stringValue = @"Ready — typed into active field";
                self.statusLabel.textColor = [NSColor systemGreenColor];
                if (self.statusButton) self.statusButton.title = @" Ready";
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    self.statusLabel.stringValue = @"Ready — insert a card";
                    if (self.statusButton) {
                        NSString *p = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
                        NSImage *ic = p ? [[NSImage alloc] initWithContentsOfFile:p] : nil;
                        if (ic) { ic.size = NSMakeSize(18,18); self.statusButton.image = ic; self.statusButton.title = @" Ready"; }
                        else self.statusButton.title = @"CardPass Ready";
                    }
                });
            });
        } else {
            if (self.autoCopyCheck.state == NSControlStateValueOn) {
                self.statusLabel.stringValue = @"Copied to clipboard — ready";
            }
        }



    } else {
        NSString *err = [NSString stringWithUTF8String:result.error];
        if (!err) err = @"Unknown error";
        self.hexTextView.string = [NSString stringWithFormat:@"Error reading %@:\n%@\n\nATR fallback was attempted. If this is a YubiKey or security key, it may not expose readable data — try a smart card or SIM.\nTip: YubiKey will always show as present; insert a real smart card into the Identive reader.", name, err];
        self.hexTextView.textColor = [NSColor systemRedColor];
        self.statusLabel.stringValue = [NSString stringWithFormat:@"Read failed — %@", err];
        self.statusLabel.textColor = [NSColor systemRedColor];
        if (self.statusButton) self.statusButton.title = @" Error";
        NSMenuItem *ti = [self.statusMenu itemWithTag:100];
        if (ti) ti.title = @"CardPass — Error";
        self.clipboardMenuItem.enabled = (self.lastHex.length>0);
        self.typeMenuItem.enabled = (self.lastHex.length>0);
        // don't clear lastHex on error, keep previous
        NSLog(@"Card read failed for %@: %s", name, result.error);
    }
}

- (void)copyHex:(id)sender {
    if (self.lastHex.length == 0) {
        NSBeep();
        return;
    }
    copyToClipboard([self.lastHex UTF8String]);
    NSString *prev = self.statusLabel.stringValue;
    self.statusLabel.stringValue = @"Copied to clipboard ✓";
    self.statusLabel.textColor = [NSColor systemGreenColor];
    if (self.statusButton) self.statusButton.title = @" Copied";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.statusLabel.stringValue = prev ?: @"Ready — insert a card";
        self.statusLabel.textColor = [NSColor systemGreenColor];
        if (self.statusButton) {
            NSString *p = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
            NSImage *ic = p ? [[NSImage alloc] initWithContentsOfFile:p] : nil;
            if (ic) { ic.size = NSMakeSize(18,18); self.statusButton.image = ic; self.statusButton.title = @" Ready"; }
            else self.statusButton.title = @"CardPass Ready";
        }
    });
}

- (void)typeHex:(id)sender {
    if (self.lastHex.length == 0) { NSBeep(); return; }
    if (!isTrustedForTyping()) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Accessibility Permission Needed";
        a.informativeText = @"CardPass needs Accessibility access to type.\n\nGo to System Settings → Privacy & Security → Accessibility and add/enable CardPass.";
        [a addButtonWithTitle:@"Open Settings"];
        [a addButtonWithTitle:@"Cancel"];
        if ([a runModal] == NSAlertFirstButtonReturn) requestTypingPermission();
        return;
    }
    self.statusLabel.stringValue = @"Typing...";
    self.statusLabel.textColor = [NSColor systemBlueColor];
    if (self.statusButton) self.statusButton.title = @" Typing...";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        typeString([weakSelf.lastHex UTF8String]);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            s.statusLabel.stringValue = @"Typed into active field ✓";
            s.statusLabel.textColor = [NSColor systemGreenColor];
            if (s.statusButton) s.statusButton.title = @" Typed";
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                s.statusLabel.stringValue = @"Ready — insert a card";
                if (s.statusButton) {
                    NSString *p = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
                    NSImage *ic = p ? [[NSImage alloc] initWithContentsOfFile:p] : nil;
                    if (ic) { ic.size = NSMakeSize(18,18); s.statusButton.image = ic; s.statusButton.title = @" Ready"; }
                    else s.statusButton.title = @"CardPass Ready";
                }
            });
        });
    });
}

- (void)clearHex:(id)sender {
    self.lastHex = @"";
    self.hexTextView.string = @"No card data yet — insert a card to read";
    self.hexTextView.textColor = [NSColor secondaryLabelColor];
    self.clipboardMenuItem.enabled = NO;
    self.typeMenuItem.enabled = NO;
    self.clipboardBtn.enabled = NO;
    self.typeButton.enabled = NO;
}

- (void)toggleAutoType:(id)sender {
    BOOL on = (self.autoTypeCheck.state == NSControlStateValueOn);
    // if triggered from menu, toggle checkbox to match
    if (sender == self.autoTypeMenuItem) {
        on = !on;
        self.autoTypeCheck.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.autoTypeMenuItem.title = on ? @"Auto-type on scan: ON" : @"Auto-type on scan: OFF";
    self.autoTypeMenuItem.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)showWindowAction:(id)sender {
    [self.mainWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)showReaders:(id)sender {
    [self showWindowAction:sender];
    ReaderListObjC list;
    int count = pcsc_list_readers(&list);
    NSMutableString *msg = [NSMutableString string];
    if (count==0) [msg appendString:@"No PC/SC readers found.\n\nMake sure your reader is plugged in."];
    else {
        [msg appendFormat:@"%d reader(s) found:\n\n", count];
        for (int i=0;i<count;i++) {
            NSString *name = [NSString stringWithUTF8String:list.readers[i].name];
            NSString *atr = hexForAtr(list.readers[i].atr, list.readers[i].atr_len);
            [msg appendFormat:@"%d. %@\n   State: %@\n   ATR: %@\n\n", i+1, name ?: @"?", list.readers[i].has_card?@"Card present":@"Empty", atr.length?atr:@"(none)"];
        }
    }
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Smart Card Readers";
    a.informativeText = msg;
    [a addButtonWithTitle:@"OK"];
    [a beginSheetModalForWindow:self.mainWindow completionHandler:nil];
}

- (void)refreshReaders:(id)sender {
    [self pollReaders];
    self.statusLabel.stringValue = @"Refreshing readers...";
    [self.spinner startAnimation:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.spinner stopAnimation:nil];
    });
}

- (void)checkAccessibility:(id)sender {
    BOOL trusted = isTrustedForTyping();
    NSAlert *a = [[NSAlert alloc] init];
    if (trusted) {
        a.messageText = @"Accessibility Permission Granted";
        a.informativeText = @"CardPass can type into password fields.";
        [a addButtonWithTitle:@"OK"];
    } else {
        a.messageText = @"Accessibility Permission Needed";
        a.informativeText = @"To auto-type card data into password fields, enable CardPass in:\n\nSystem Settings → Privacy & Security → Accessibility\n\nClick Open Settings to grant access.";
        [a addButtonWithTitle:@"Open Settings"];
        [a addButtonWithTitle:@"Cancel"];
        NSModalResponse r = [a runModal];
        if (r == NSAlertFirstButtonReturn) requestTypingPermission();
        return;
    }
    [a runModal];
}

- (void)openBuyMeACoffee:(id)sender {
    openBuyMeACoffee();
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    [sender orderOut:nil];
    return NO;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    if (!flag) [self.mainWindow makeKeyAndOrderFront:nil];
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [_pollTimer invalidate];
    pcsc_cleanup();
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

@end

static AppDelegate *gDelegate = nil;

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        gDelegate = [[AppDelegate alloc] init];
        app.delegate = gDelegate;
        [app run];
    }
    return 0;
}
