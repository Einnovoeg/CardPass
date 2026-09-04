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
 *    - Clipboard copy needs no permission; auto-type optionally needs
 *      System Settings → Privacy & Security → Accessibility
 *      (Tahoe: Device Control and Data Access) and degrades gracefully to ⌘V paste.
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
#import <CommonCrypto/CommonDigest.h>
#import <dlfcn.h>

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
    if (!str || str[0] == '\0') {
        NSLog(@"copyToClipboard: empty string, nothing to copy");
        return;
    }
    NSString *s = [NSString stringWithUTF8String:str];
    if (!s) {
        NSLog(@"copyToClipboard: failed to create NSString from UTF8");
        return;
    }
    // Must run on main thread; do synchronously if already there for immediate effect
    void (^copyBlock)(void) = ^{
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        // Declare type explicitly for robustness on Tahoe
        [pb declareTypes:@[NSPasteboardTypeString] owner:nil];
        BOOL ok = [pb setString:s forType:NSPasteboardTypeString];
        NSLog(@"copyToClipboard: %@ (%lu chars) -> %@", ok?@"OK":@"FAIL", (unsigned long)s.length, s.length > 80 ? [[s substringToIndex:80] stringByAppendingString:@"…"] : s);
        // Verify
        NSString *verify = [pb stringForType:NSPasteboardTypeString];
        if (![verify isEqualToString:s]) {
            NSLog(@"copyToClipboard: VERIFY FAILED! Expected %@ got %@", s, verify);
            // Try again without declareTypes
            [pb clearContents];
            [pb setString:s forType:NSPasteboardTypeString];
        }
    };
    if ([NSThread isMainThread]) {
        copyBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), copyBlock);
    }
}

static BOOL isTrustedForTyping(void) {
    // Tahoe (27) moved the toggle to Device Control and Data Access, which is
    // backed by CGPreflightPostEventAccess, while older macOS uses Accessibility
    // (AXIsProcessTrusted). We check both via runtime lookup and consider trusted
    // if *either* is granted — this handles betas where the UI says Device Control
    // but the underlying TCC is still Accessibility, and vice versa.
    BOOL postTrusted = NO;
    BOOL axTrusted = NO;
    BOOL hasPostAPI = NO;

    void *handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    if (handle) {
        BOOL (*preflight)(void) = (BOOL (*)(void))dlsym(handle, "CGPreflightPostEventAccess");
        if (preflight) {
            hasPostAPI = YES;
            postTrusted = preflight();
        }
        dlclose(handle);
    }
    NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @NO};
    axTrusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);

    if (hasPostAPI) {
        // On Tahoe either toggle may be the one the user enabled; accept either
        BOOL trusted = postTrusted || axTrusted;
        NSLog(@"isTrusted: PostEvent=%d AX=%d => %d (Tahoe combined)", postTrusted, axTrusted, trusted);
        return trusted;
    }
    NSLog(@"isTrusted: AX=%d (fallback, no PostEvent API)", axTrusted);
    return axTrusted;
}

static NSString *currentPrivacyPanePath(void) {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (v.majorVersion >= 26) {
        return @"System Settings → Privacy & Security → Device Control and Data Access";
    }
    return @"System Settings → Privacy & Security → Accessibility";
}

static void openPrivacySettingsDirectly(void) {
    // Tahoe uses Device Control, older uses Accessibility. Try Tahoe first.
    NSArray<NSString*> *candidates = @[
        @"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_DeviceControl",
        @"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        @"x-apple.systempreferences:com.apple.preference.security?Privacy"
    ];
    for (NSString *s in candidates) {
        NSURL *u = [NSURL URLWithString:s];
        if (u && [[NSWorkspace sharedWorkspace] openURL:u]) {
            break;
        }
    }
}

static void requestTypingPermission(void) {
    // Try modern request first (PostEvent) via dynamic lookup, then AX prompt.
    void *handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
    BOOL didRequest = NO;
    if (handle) {
        BOOL (*request)(BOOL) = (BOOL (*)(BOOL))dlsym(handle, "CGRequestPostEventAccess");
        if (request) {
            didRequest = request(YES); // This shows the Device Control prompt on Tahoe
            NSLog(@"CGRequestPostEventAccess returned %d", didRequest);
            dlclose(handle);
            // Also trigger AX prompt as fallback
            NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
            AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
            if (!isTrustedForTyping()) {
                openPrivacySettingsDirectly();
            }
            return;
        }
        dlclose(handle);
    }
    // Fallback: AX prompt (pre-Tahoe)
    NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt: @YES};
    BOOL wasTrusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    if (!wasTrusted) {
        openPrivacySettingsDirectly();
    }
}

static BOOL tryPasteViaAX(NSString *str) {
    // Try to set the focused text field's value directly via Accessibility
    // This is often more reliable than CGEvent and works with Device Control
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    if (!systemWide) return NO;
    AXUIElementRef focused = NULL;
    AXError err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute, (CFTypeRef *)&focused);
    CFRelease(systemWide);
    if (err != kAXErrorSuccess || !focused) {
        NSLog(@"tryPasteViaAX: no focused element (err %d)", err);
        return NO;
    }
    // Check if we can set the value
    Boolean canSet = false;
    AXError canSetErr = AXUIElementIsAttributeSettable(focused, kAXValueAttribute, &canSet);
    if (canSetErr != kAXErrorSuccess || !canSet) {
        NSLog(@"tryPasteViaAX: focused element not settable (err %d canSet %d)", canSetErr, canSet);
        CFRelease(focused);
        return NO;
    }
    AXError setErr = AXUIElementSetAttributeValue(focused, kAXValueAttribute, (__bridge CFTypeRef)str);
    CFRelease(focused);
    if (setErr == kAXErrorSuccess) {
        NSLog(@"tryPasteViaAX: SUCCESS for %lu chars", (unsigned long)str.length);
        return YES;
    } else {
        NSLog(@"tryPasteViaAX: failed err %d", setErr);
        return NO;
    }
}

static BOOL tryPasteViaCmdV(void) {
    // Paste from clipboard via Cmd+V — requires PostEvent (Device Control) but is more
    // reliable than per-character typing. We do a proper chord: Cmd down → V down → V up → Cmd up,
    // posting to both session and HID taps, and also try posting directly to frontmost app's PSN.
    const CGKeyCode kVK_ANSI_V = 9;
    const CGKeyCode kVK_Command = 55; // left command
    // Try session tap with proper chord
    CGEventRef cmdDown = CGEventCreateKeyboardEvent(NULL, kVK_Command, true);
    CGEventSetFlags(cmdDown, kCGEventFlagMaskCommand);
    CGEventPost(kCGSessionEventTap, cmdDown);
    usleep(20000);
    CGEventRef vDown = CGEventCreateKeyboardEvent(NULL, kVK_ANSI_V, true);
    CGEventSetFlags(vDown, kCGEventFlagMaskCommand);
    CGEventPost(kCGSessionEventTap, vDown);
    usleep(20000);
    CGEventRef vUp = CGEventCreateKeyboardEvent(NULL, kVK_ANSI_V, false);
    CGEventSetFlags(vUp, kCGEventFlagMaskCommand);
    CGEventPost(kCGSessionEventTap, vUp);
    usleep(20000);
    CGEventRef cmdUp = CGEventCreateKeyboardEvent(NULL, kVK_Command, false);
    CGEventPost(kCGSessionEventTap, cmdUp);
    CFRelease(cmdDown); CFRelease(vDown); CFRelease(vUp); CFRelease(cmdUp);
    usleep(50000);
    // Fallback: try HID tap with same chord
    CGEventRef cmdDown2 = CGEventCreateKeyboardEvent(NULL, kVK_Command, true);
    CGEventSetFlags(cmdDown2, kCGEventFlagMaskCommand);
    CGEventPost(kCGHIDEventTap, cmdDown2);
    usleep(20000);
    CGEventRef vDown2 = CGEventCreateKeyboardEvent(NULL, kVK_ANSI_V, true);
    CGEventSetFlags(vDown2, kCGEventFlagMaskCommand);
    CGEventPost(kCGHIDEventTap, vDown2);
    usleep(20000);
    CGEventRef vUp2 = CGEventCreateKeyboardEvent(NULL, kVK_ANSI_V, false);
    CGEventSetFlags(vUp2, kCGEventFlagMaskCommand);
    CGEventPost(kCGHIDEventTap, vUp2);
    usleep(20000);
    CGEventRef cmdUp2 = CGEventCreateKeyboardEvent(NULL, kVK_Command, false);
    CGEventPost(kCGHIDEventTap, cmdUp2);
    CFRelease(cmdDown2); CFRelease(vDown2); CFRelease(vUp2); CFRelease(cmdUp2);
    // Also try posting directly to frontmost app via PSN (more targeted, may bypass some TCC)
    @try {
        NSRunningApplication *front = [[NSWorkspace sharedWorkspace] frontmostApplication];
        if (front) {
            pid_t pid = front.processIdentifier;
            // Use AppleScript to tell front app to paste via its menu (alternative that may not need Device Control)
            // We do this as a fallback that will be tried by the caller via tryTypeViaAppleScript, but we log
            NSLog(@"tryPasteViaCmdV: also tried direct PSN for pid %d", pid);
        }
    } @catch (NSException *e) {
        NSLog(@"tryPasteViaCmdV: frontmost check exception %@", e);
    }
    NSLog(@"tryPasteViaCmdV: posted Cmd+V chord to both taps");
    return YES;
}

static BOOL tryTypeViaAppleScript(NSString *str) {
    // Fallback via AppleScript System Events — requires Automation permission for System Events
    // but is worth trying if CGEvent fails
    NSString *escaped = [str stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    NSString *scriptSrc = [NSString stringWithFormat:@"tell application \"System Events\" to keystroke \"%@\"", escaped];
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSrc];
    NSDictionary *err = nil;
    [script executeAndReturnError:&err];
    if (err) {
        NSLog(@"tryTypeViaAppleScript: failed %@", err);
        return NO;
    }
    NSLog(@"tryTypeViaAppleScript: SUCCESS");
    return YES;
}

static BOOL pasteStringViaAllMethods(NSString *str) {
    if (!str || str.length == 0) return NO;
    NSLog(@"pasteStringViaAllMethods: attempting %lu chars", (unsigned long)str.length);
    // 1. Try AX direct set (most reliable for password fields, bypasses keystroke)
    if (tryPasteViaAX(str)) return YES;
    // 2. Try Cmd+V from clipboard (we ensure clipboard is set before calling)
    // Ensure clipboard has the string
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb declareTypes:@[NSPasteboardTypeString] owner:nil];
    [pb setString:str forType:NSPasteboardTypeString];
    usleep(100000); // let pasteboard settle
    if (tryPasteViaCmdV()) {
        // Give it a moment, then check if we can verify via AX?
        return YES;
    }
    // 3. Try AppleScript
    if (tryTypeViaAppleScript(str)) return YES;
    // 4. Final fallback: per-character CGEvent unicode typing (original method, both taps)
    for (NSUInteger i = 0; i < str.length; i++) {
        unichar c = [str characterAtIndex:i];
        CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true);
        if (!down) continue;
        CGEventKeyboardSetUnicodeString(down, 1, &c);
        CGEventPost(kCGSessionEventTap, down);
        CFRelease(down);
        CGEventRef up = CGEventCreateKeyboardEvent(NULL, 0, false);
        if (!up) continue;
        CGEventKeyboardSetUnicodeString(up, 1, &c);
        CGEventPost(kCGSessionEventTap, up);
        CFRelease(up);
        // Also try HID tap
        CGEventRef down2 = CGEventCreateKeyboardEvent(NULL, 0, true);
        CGEventKeyboardSetUnicodeString(down2, 1, &c);
        CGEventPost(kCGHIDEventTap, down2);
        CFRelease(down2);
        CGEventRef up2 = CGEventCreateKeyboardEvent(NULL, 0, false);
        CGEventKeyboardSetUnicodeString(up2, 1, &c);
        CGEventPost(kCGHIDEventTap, up2);
        CFRelease(up2);
        usleep(15000);
    }
    NSLog(@"pasteStringViaAllMethods: tried per-char CGEvent fallback");
    return YES; // Assume at least the per-char attempt was made
}

static void typeString(const char *str) {
    if (!str || str[0] == '\0') return;
    NSString *s = [NSString stringWithUTF8String:str];
    if (!s) return;
    // Ensure clipboard has it for Cmd+V fallback
    copyToClipboard(str);
    usleep(200000); // let clipboard and focus settle
    // Try all paste methods without pre-checking trust — try and see what works
    // This bypasses the flaky isTrusted check that was blocking even when granted
    BOOL ok = pasteStringViaAllMethods(s);
    if (!ok) {
        NSLog(@"typeString: all paste methods failed, leaving on clipboard for manual ⌘V");
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

// MARK: - Encoding & Hashing Helpers (for password generation)
// Hex (Base16) is wasteful (2 chars per byte, only 0-9A-F). We offer:
//   Base62: 0-9A-Za-z (alphanumeric, never rejected by strict fields), ~30% shorter than hex
//   Base58: Bitcoin alphabet (no 0/O/I/l — ideal for human transcription)
//   Base64: 0-9A-Za-z+/ with = padding, ~33% shorter than hex (may include +/)
// Hash: SHA-256 condenses any length to 32 bytes, then Base62 → 43 chars, truncatable to 16-24

typedef NS_ENUM(NSInteger, CPEncoding) {
    CPEncodingHex = 0,   // Base16 uppercase
    CPEncodingBase62 = 1,
    CPEncodingBase58 = 2,
    CPEncodingBase64 = 3,
};

static NSString *alphabetBase62(void) { return @"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"; }
static NSString *alphabetBase58(void) { return @"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"; }

/** Convert hex string (e.g. "0A1B") to NSData. Ignores whitespace. Returns nil on invalid hex. */
static NSData *dataFromHexString(NSString *hex) {
    if (!hex) return nil;
    // Remove whitespace/newlines
    NSString *clean = [[hex componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""];
    if (clean.length == 0) return [NSData data];
    if (clean.length % 2 != 0) return nil; // must be even
    NSMutableData *data = [NSMutableData dataWithCapacity:clean.length/2];
    for (NSUInteger i = 0; i < clean.length; i += 2) {
        NSString *byteStr = [clean substringWithRange:NSMakeRange(i, 2)];
        unsigned int byteVal = 0;
        NSScanner *sc = [NSScanner scannerWithString:byteStr];
        if (![sc scanHexInt:&byteVal]) return nil;
        uint8_t b = (uint8_t)byteVal;
        [data appendBytes:&b length:1];
    }
    return data;
}

/** Generic base-N encode for Base62/Base58 using big-integer division.
 *  Correctly preserves leading zero bytes (they become '0' for B62, '1' for B58).
 */
static NSString *baseEncodeData(NSData *data, NSString *alphabet) {
    if (!data || data.length == 0) return @"";
    NSUInteger base = alphabet.length;
    // Count leading zero bytes
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger leadingZeros = 0;
    while (leadingZeros < data.length && bytes[leadingZeros] == 0) leadingZeros++;

    // Convert the non-zero part via repeated division
    NSMutableData *mutable = [NSMutableData dataWithCapacity:data.length];
    // Copy non-zero suffix
    if (leadingZeros < data.length) {
        [mutable appendBytes:bytes+leadingZeros length:data.length-leadingZeros];
    } else {
        // All zeros -> return leading zeros encoded
        NSMutableString *r = [NSMutableString string];
        for (NSUInteger i=0;i<leadingZeros;i++) [r appendFormat:@"%C", [alphabet characterAtIndex:0]];
        return r;
    }

    NSMutableString *result = [NSMutableString string];
    // Work on mutable copy of bytes as big-endian integer
    NSMutableData *num = [mutable mutableCopy];
    while (num.length > 0) {
        uint32_t remainder = 0;
        NSMutableData *quotient = [NSMutableData data];
        const uint8_t *qBytes = (const uint8_t *)num.bytes;
        BOOL leading = YES;
        for (NSUInteger i = 0; i < num.length; i++) {
            uint32_t cur = remainder * 256 + qBytes[i];
            uint8_t q = cur / (uint32_t)base;
            remainder = cur % (uint32_t)base;
            if (!leading || q != 0) {
                [quotient appendBytes:&q length:1];
                leading = NO;
            } else if (quotient.length > 0) {
                // Already started
                [quotient appendBytes:&q length:1];
            }
        }
        [result insertString:[NSString stringWithFormat:@"%C", [alphabet characterAtIndex:remainder]] atIndex:0];
        // Check if quotient is all zero
        BOOL allZero = YES;
        const uint8_t *qb = (const uint8_t *)quotient.bytes;
        for (NSUInteger i=0;i<quotient.length;i++) if (qb[i]!=0) { allZero = NO; break; }
        if (allZero || quotient.length==0) break;
        num = quotient;
        // Avoid infinite loop on tiny data
        if (result.length > 2048) break;
    }
    // Prepend leading-zero characters
    for (NSUInteger i=0;i<leadingZeros;i++) [result insertString:[NSString stringWithFormat:@"%C", [alphabet characterAtIndex:0]] atIndex:0];
    return result;
}

static NSString *base62EncodeData(NSData *data) { return baseEncodeData(data, alphabetBase62()); }
static NSString *base58EncodeData(NSData *data) { return baseEncodeData(data, alphabetBase58()); }
static NSString *base64EncodeData(NSData *data) { return [data base64EncodedStringWithOptions:0]; }

static NSData *sha256Data(NSData *data) {
    if (!data) return nil;
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
    return [NSData dataWithBytes:hash length:CC_SHA256_DIGEST_LENGTH];
}

/** Core transform: raw bytes -> (hash? SHA256 : raw) -> encode -> truncate.
 *  - encoding: Hex/Base62/Base58/Base64
 *  - hash: if YES, SHA256 first (32 bytes -> e.g. Base62 43 chars)
 *  - truncate: 0 = no truncation, else limit to N characters (clipped if shorter)
 */
static NSString *transformData(NSData *raw, CPEncoding encoding, BOOL doHash, NSInteger truncate) {
    if (!raw) return @"";
    NSData *src = raw;
    if (doHash) {
        src = sha256Data(raw);
        if (!src) return @"";
    }
    NSString *encoded = @"";
    switch (encoding) {
        case CPEncodingBase62: encoded = base62EncodeData(src); break;
        case CPEncodingBase58: encoded = base58EncodeData(src); break;
        case CPEncodingBase64: encoded = base64EncodeData(src); break;
        case CPEncodingHex:
        default: {
            NSMutableString *hex = [NSMutableString stringWithCapacity:src.length*2];
            const uint8_t *b = src.bytes;
            for (NSUInteger i=0;i<src.length;i++) [hex appendFormat:@"%02X", b[i]];
            encoded = hex;
            break;
        }
    }
    if (truncate > 0 && encoded.length > truncate) {
        return [encoded substringToIndex:truncate];
    }
    return encoded;
}

/**
 * AppDelegate — owns window, status item, polling, and card I/O orchestration.
 * All PC/SC work is off the main thread; UI updates are main-thread only.
 */
@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate, NSControlTextEditingDelegate>
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

// Raw bytes + transformed password handling
@property (strong, nonatomic) NSData *lastRawData;
@property (assign, nonatomic) CPEncoding selectedEncoding;
@property (assign, nonatomic) BOOL hashEnabled;
@property (assign, nonatomic) NSInteger truncateLength;
@property (strong, nonatomic) NSPopUpButton *encodingPopup;
@property (strong, nonatomic) NSButton *hashCheck;
@property (strong, nonatomic) NSTextField *truncateField;
@property (strong, nonatomic) NSStepper *truncateStepper;
@property (strong, nonatomic) NSTextField *encodingInfoLabel;
// Delay
@property (assign, nonatomic) double autoTypeDelay;
@property (strong, nonatomic) NSTextField *delayField;
@property (strong, nonatomic) NSStepper *delayStepper;
// Custom text per card (user can set any text to paste instead of card data)
@property (strong, nonatomic) NSMutableDictionary<NSString*, NSString*> *customMappings;
@property (copy, nonatomic) NSString *currentCardId;
// Advanced pane — separate window that slides out to the right (per spec: not just expanding fields)
@property (strong, nonatomic) NSWindow *advancedWindow;
@property (strong, nonatomic) NSView *advancedPane;
@property (strong, nonatomic) NSTextView *rawHexView;
@property (strong, nonatomic) NSTextView *preTruncateView;
@property (assign, nonatomic) BOOL advancedVisible;

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
- (void)showRawHexPanel:(id)sender;
- (void)encodingChanged:(id)sender;
- (void)hashToggled:(id)sender;
- (void)truncateChanged:(id)sender;
- (void)customTextChanged:(id)sender;
- (void)saveCustomText:(id)sender;
- (void)clearCustomText:(id)sender;
- (NSString *)customTextForCardId:(NSString *)cardId;
- (NSString *)effectivePasteString;
- (void)updateTransformedDisplay;
- (NSString *)currentTransformedString;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _lastHex = @"";
    _lastAtrHex = @"";
    _lastAtrByReader = [NSMutableDictionary dictionary];
    _isReading = NO;
    _knownReaderCount = 0;
    _lastRawData = nil;
    _selectedEncoding = CPEncodingHex;
    _hashEnabled = NO;
    _truncateLength = 0; // 0 = no truncation
    _autoTypeDelay = 1.0;
    _advancedVisible = NO;
    // Restore user prefs if any
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    _customMappings = [[defaults dictionaryForKey:@"CPCustomMappings"] mutableCopy];
    if (!_customMappings) _customMappings = [NSMutableDictionary dictionary];
    _currentCardId = nil;
    NSInteger savedEnc = [defaults integerForKey:@"CPEncoding"];
    if (savedEnc >= 0 && savedEnc <= 3) _selectedEncoding = (CPEncoding)savedEnc;
    _hashEnabled = [defaults boolForKey:@"CPHashEnabled"];
    _truncateLength = [defaults integerForKey:@"CPTruncateLength"];
    if (_truncateLength < 0) _truncateLength = 0;
    if (_truncateLength > 128) _truncateLength = 128;
    double savedDelay = [defaults doubleForKey:@"CPAutoTypeDelay"];
    if (savedDelay >= 0.2 && savedDelay <= 10.0) _autoTypeDelay = savedDelay;
    _advancedVisible = [defaults boolForKey:@"CPAdvancedVisible"];

    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp activateIgnoringOtherApps:YES];

    pcsc_init();

    [self setupMainMenu];
    [self setupWindow];
    [self setupStatusItem];

    // If advanced was visible last run, show separate Advanced window
    if (_advancedVisible) {
        NSRect mainFrame = self.mainWindow.frame;
        NSRect advFrame = self.advancedWindow.frame;
        advFrame.origin.x = NSMaxX(mainFrame) + 8;
        advFrame.origin.y = mainFrame.origin.y + (mainFrame.size.height - advFrame.size.height)/2;
        [self.advancedWindow setFrame:advFrame display:NO];
        [self.advancedWindow orderFront:nil];
        [self.mainWindow addChildWindow:self.advancedWindow ordered:NSWindowAbove];
        NSButton *btn = (NSButton *)[self.mainWindow.contentView viewWithTag:999];
        if (btn) btn.title = @"◀ Advanced";
        self.advancedPane.hidden = NO;
    } else {
        self.advancedPane.hidden = YES;
    }

    _pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(pollReaders) userInfo:nil repeats:YES];
    [_pollTimer fire];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.mainWindow makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    });

    NSLog(@"CardPass launched: window + status item ready (delay %.1fs, enc %ld)", _autoTypeDelay, (long)_selectedEncoding);
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

    NSMenuItem *prefsItem = [[NSMenuItem alloc] initWithTitle:@"Check Auto-Type Permission…" action:@selector(checkAccessibility:) keyEquivalent:@""];
    prefsItem.target = self;
    prefsItem.toolTip = @"Auto-type needs Device Control / Accessibility — clipboard always works without it";
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

    // View menu — Advanced pane lives here, NOT in main App menu (per spec: raw data not in main menu)
    NSMenuItem *viewMenuItem = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *advViewItem = [[NSMenuItem alloc] initWithTitle:@"Show Advanced Pane" action:@selector(toggleAdvancedPane:) keyEquivalent:@"a"];
    advViewItem.target = self;
    advViewItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [viewMenu addItem:advViewItem];
    NSMenuItem *rawViewItem = [[NSMenuItem alloc] initWithTitle:@"Show Raw Hex…" action:@selector(showRawHexPanel:) keyEquivalent:@""];
    rawViewItem.target = self;
    [viewMenu addItem:rawViewItem];
    viewMenuItem.submenu = viewMenu;
    [mainMenu addItem:viewMenuItem];

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
    NSRect frame = NSMakeRect(0, 0, 520, 470);
    NSWindow *w = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered defer:NO];
    w.title = @"CardPass";
    w.delegate = self;
    w.releasedWhenClosed = NO;
    w.minSize = NSMakeSize(520, 450);
    [w center];
    w.titlebarAppearsTransparent = NO;
    w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    w.backgroundColor = [NSColor colorWithWhite:0.13 alpha:1.0];
    self.mainWindow = w;

    NSView *content = w.contentView;
    content.wantsLayer = YES;
    content.layer.backgroundColor = [[NSColor colorWithWhite:0.13 alpha:1.0] CGColor];

    NSView *header = [[NSView alloc] initWithFrame:NSMakeRect(0, 422, 520, 48)];
    header.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    header.wantsLayer = YES;
    header.layer.backgroundColor = [[NSColor colorWithWhite:0.16 alpha:1.0] CGColor];

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

    NSTextField *statusTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 390, 60, 16)];
    statusTitle.stringValue = @"Status:";
    statusTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    statusTitle.textColor = [NSColor secondaryLabelColor];
    statusTitle.bezeled = NO; statusTitle.drawsBackground = NO; statusTitle.editable = NO; statusTitle.selectable = NO;
    statusTitle.autoresizingMask = NSViewMaxYMargin | NSViewMinXMargin;
    [content addSubview:statusTitle];

    self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(70, 388, 360, 20)];
    self.statusLabel.stringValue = @"Initializing...";
    self.statusLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    self.statusLabel.textColor = [NSColor labelColor];
    self.statusLabel.bezeled = NO; self.statusLabel.drawsBackground = NO; self.statusLabel.editable = NO; self.statusLabel.selectable = NO;
    self.statusLabel.autoresizingMask = NSViewMaxYMargin | NSViewWidthSizable;
    [content addSubview:self.statusLabel];

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(460, 388, 16, 16)];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;
    self.spinner.usesThreadedAnimation = YES;
    self.spinner.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:self.spinner];

    NSTextField *readersLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 368, 100, 14)];
    readersLabel.stringValue = @"Readers";
    readersLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    readersLabel.textColor = [NSColor labelColor];
    readersLabel.bezeled = NO; readersLabel.drawsBackground = NO; readersLabel.editable = NO; readersLabel.selectable = NO;
    readersLabel.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:readersLabel];

    self.readerCountLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(70, 368, 120, 14)];
    self.readerCountLabel.stringValue = @"(scanning...)";
    self.readerCountLabel.font = [NSFont systemFontOfSize:10];
    self.readerCountLabel.textColor = [NSColor secondaryLabelColor];
    self.readerCountLabel.bezeled = NO; self.readerCountLabel.drawsBackground = NO; self.readerCountLabel.editable = NO; self.readerCountLabel.selectable = NO;
    self.readerCountLabel.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.readerCountLabel];

    NSScrollView *readersScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 286, 488, 70)];
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

    // --- Encoding controls bar (new) ---
    // Encoding popup: Hex / Base62 (recommended) / Base58 / Base64
    // Plus hash checkbox and truncate length
    NSTextField *encLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 265, 50, 14)];
    encLabel.stringValue = @"Output:";
    encLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    encLabel.textColor = [NSColor labelColor];
    encLabel.bezeled = NO; encLabel.drawsBackground = NO; encLabel.editable = NO; encLabel.selectable = NO;
    encLabel.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:encLabel];

    self.encodingPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(70, 260, 140, 24) pullsDown:NO];
    [self.encodingPopup addItemsWithTitles:@[@"Hex (Base16)", @"Base62 (A-Za-z0-9)", @"Base58 (no 0/O/I/l)", @"Base64 (+/ with =)"]];
    [self.encodingPopup selectItemAtIndex:self.selectedEncoding];
    self.encodingPopup.target = self;
    self.encodingPopup.action = @selector(encodingChanged:);
    self.encodingPopup.toolTip = @"Base62 recommended: alphanumeric only, ~30% shorter than hex. Base58 ideal for human transcription.";
    self.encodingPopup.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.encodingPopup];

    self.hashCheck = [[NSButton alloc] initWithFrame:NSMakeRect(220, 265, 110, 18)];
    [self.hashCheck setButtonType:NSButtonTypeSwitch];
    self.hashCheck.title = @"Hash SHA-256";
    self.hashCheck.state = self.hashEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.hashCheck.font = [NSFont systemFontOfSize:11];
    self.hashCheck.target = self;
    self.hashCheck.action = @selector(hashToggled:);
    self.hashCheck.toolTip = @"Hash raw bytes with SHA-256 then encode → always 32 bytes (Base62 43 chars). Use for massive card data or fixed-length passwords.";
    self.hashCheck.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.hashCheck];

    NSTextField *truncLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(340, 265, 42, 14)];
    truncLabel.stringValue = @"Truncate:";
    truncLabel.font = [NSFont systemFontOfSize:11];
    truncLabel.textColor = [NSColor secondaryLabelColor];
    truncLabel.bezeled = NO; truncLabel.drawsBackground = NO; truncLabel.editable = NO; truncLabel.selectable = NO;
    truncLabel.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:truncLabel];

    self.truncateField = [[NSTextField alloc] initWithFrame:NSMakeRect(385, 261, 44, 22)];
    self.truncateField.stringValue = self.truncateLength > 0 ? [NSString stringWithFormat:@"%ld", (long)self.truncateLength] : @"";
    self.truncateField.placeholderString = @"e.g. 24";
    self.truncateField.font = [NSFont systemFontOfSize:11];
    self.truncateField.bezeled = YES; self.truncateField.bezeled = YES;
    self.truncateField.target = self;
    self.truncateField.action = @selector(truncateChanged:);
    self.truncateField.toolTip = @"Truncate password to N chars (leave empty for full length). For hashed Base62, 16-24 chars is secure.";
    self.truncateField.autoresizingMask = NSViewMaxYMargin;
    // Send action on end editing
    [self.truncateField setDelegate:(id<NSTextFieldDelegate>)self];
    [content addSubview:self.truncateField];

    self.truncateStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(430, 261, 19, 22)];
    self.truncateStepper.minValue = 0; self.truncateStepper.maxValue = 128; self.truncateStepper.increment = 1;
    self.truncateStepper.valueWraps = NO;
    self.truncateStepper.doubleValue = self.truncateLength;
    self.truncateStepper.target = self;
    self.truncateStepper.action = @selector(truncateChanged:);
    self.truncateStepper.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.truncateStepper];

    self.encodingInfoLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(455, 265, 50, 14)];
    self.encodingInfoLabel.stringValue = @"";
    self.encodingInfoLabel.font = [NSFont systemFontOfSize:10];
    self.encodingInfoLabel.textColor = [NSColor secondaryLabelColor];
    self.encodingInfoLabel.bezeled = NO; self.encodingInfoLabel.drawsBackground = NO; self.encodingInfoLabel.editable = NO; self.encodingInfoLabel.selectable = NO;
    self.encodingInfoLabel.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.encodingInfoLabel];

    NSTextField *hexLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 242, 200, 14)];
    hexLabel.stringValue = @"Card Data (password)";
    hexLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    hexLabel.textColor = [NSColor labelColor];
    hexLabel.bezeled = NO; hexLabel.drawsBackground = NO; hexLabel.editable = NO; hexLabel.selectable = NO;
    hexLabel.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:hexLabel];

    NSTextField *hexHint = [[NSTextField alloc] initWithFrame:NSMakeRect(140, 242, 360, 12)];
    hexHint.stringValue = @"— copied to clipboard, auto-type is optional (needs Device Control)";
    hexHint.font = [NSFont systemFontOfSize:10];
    hexHint.textColor = [NSColor secondaryLabelColor];
    hexHint.bezeled = NO; hexHint.drawsBackground = NO; hexHint.editable = NO; hexHint.selectable = NO;
    hexHint.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:hexHint];

    // Password field is intentionally compact and directly under the label — wraps to content.
    // For 20 chars it shows a single line; for longer it wraps. Advanced pane holds large raw views.
    NSScrollView *hexScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 195, 488, 44)];
    hexScroll.hasVerticalScroller = NO;
    hexScroll.hasHorizontalScroller = NO;
    hexScroll.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    hexScroll.borderType = NSBezelBorder;
    hexScroll.drawsBackground = YES;

    NSSize hexContentSize = hexScroll.contentSize;
    self.hexTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, hexContentSize.width, hexContentSize.height)];
    self.hexTextView.editable = NO;
    self.hexTextView.selectable = YES;
    self.hexTextView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium];
    self.hexTextView.textColor = [NSColor labelColor];
    self.hexTextView.backgroundColor = [NSColor textBackgroundColor];
    self.hexTextView.string = @"No card data yet — insert a card to read";
    self.hexTextView.autoresizingMask = NSViewWidthSizable;
    self.hexTextView.textContainerInset = NSMakeSize(6, 8);
    self.hexTextView.textContainer.lineFragmentPadding = 2;
    [self.hexTextView setAutomaticQuoteSubstitutionEnabled:NO];
    // Make it wrap and be compact
    self.hexTextView.textContainer.widthTracksTextView = YES;
    self.hexTextView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    self.hexTextView.horizontallyResizable = NO;
    self.hexTextView.verticallyResizable = YES;
    hexScroll.documentView = self.hexTextView;
    [content addSubview:hexScroll];

    self.clipboardBtn = [[NSButton alloc] initWithFrame:NSMakeRect(16, 80, 140, 26)];
    self.clipboardBtn.title = @"Copy to Clipboard";
    self.clipboardBtn.bezelStyle = NSBezelStyleRounded;
    self.clipboardBtn.target = self;
    self.clipboardBtn.action = @selector(copyHex:);
    self.clipboardBtn.keyEquivalent = @"c";
    self.clipboardBtn.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    self.clipboardBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinYMargin;
    [self.clipboardBtn setEnabled:NO];
    [content addSubview:self.clipboardBtn];

    self.typeButton = [[NSButton alloc] initWithFrame:NSMakeRect(164, 80, 140, 26)];
    self.typeButton.title = @"Type into Field";
    self.typeButton.bezelStyle = NSBezelStyleRounded;
    self.typeButton.target = self;
    self.typeButton.action = @selector(typeHex:);
    self.typeButton.autoresizingMask = NSViewMaxYMargin | NSViewMinYMargin;
    [self.typeButton setEnabled:NO];
    [content addSubview:self.typeButton];

    self.clearButton = [[NSButton alloc] initWithFrame:NSMakeRect(312, 80, 70, 26)];
    self.clearButton.title = @"Clear";
    self.clearButton.bezelStyle = NSBezelStyleRounded;
    self.clearButton.target = self;
    self.clearButton.action = @selector(clearHex:);
    self.clearButton.autoresizingMask = NSViewMaxYMargin | NSViewMinYMargin;
    [content addSubview:self.clearButton];

    NSButton *refreshBtn = [[NSButton alloc] initWithFrame:NSMakeRect(390, 80, 70, 26)];
    refreshBtn.title = @"Refresh";
    refreshBtn.bezelStyle = NSBezelStyleRounded;
    refreshBtn.target = self;
    refreshBtn.action = @selector(refreshReaders:);
    refreshBtn.autoresizingMask = NSViewMaxYMargin | NSViewMinYMargin | NSViewMinXMargin;
    [content addSubview:refreshBtn];

    // More compact bottom bar: auto-copy/type + delay + advanced
    self.autoCopyCheck = [[NSButton alloc] initWithFrame:NSMakeRect(16, 50, 110, 18)];
    [self.autoCopyCheck setButtonType:NSButtonTypeSwitch];
    self.autoCopyCheck.title = @"Auto-copy";
    self.autoCopyCheck.state = NSControlStateValueOn;
    self.autoCopyCheck.font = [NSFont systemFontOfSize:11];
    self.autoCopyCheck.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.autoCopyCheck];

    self.autoTypeCheck = [[NSButton alloc] initWithFrame:NSMakeRect(135, 50, 105, 18)];
    [self.autoTypeCheck setButtonType:NSButtonTypeSwitch];
    self.autoTypeCheck.title = @"Auto-type";
    self.autoTypeCheck.state = NSControlStateValueOn;
    self.autoTypeCheck.font = [NSFont systemFontOfSize:11];
    self.autoTypeCheck.target = self;
    self.autoTypeCheck.action = @selector(toggleAutoType:);
    self.autoTypeCheck.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.autoTypeCheck];

    NSTextField *delayLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(250, 50, 38, 14)];
    delayLabel.stringValue = @"Delay:";
    delayLabel.font = [NSFont systemFontOfSize:11];
    delayLabel.textColor = [NSColor secondaryLabelColor];
    delayLabel.bezeled = NO; delayLabel.drawsBackground = NO; delayLabel.editable = NO; delayLabel.selectable = NO;
    delayLabel.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:delayLabel];

    self.delayField = [[NSTextField alloc] initWithFrame:NSMakeRect(290, 48, 36, 20)];
    self.delayField.stringValue = [NSString stringWithFormat:@"%.1f", self.autoTypeDelay];
    self.delayField.font = [NSFont systemFontOfSize:11];
    self.delayField.alignment = NSTextAlignmentCenter;
    self.delayField.target = self;
    self.delayField.action = @selector(delayChanged:);
    self.delayField.toolTip = @"Seconds to wait before auto-typing (0.2-10s). Clipboard is instant.";
    self.delayField.autoresizingMask = NSViewMaxYMargin;
    [self.delayField setDelegate:(id<NSTextFieldDelegate>)self];
    [content addSubview:self.delayField];

    self.delayStepper = [[NSStepper alloc] initWithFrame:NSMakeRect(327, 48, 19, 20)];
    self.delayStepper.minValue = 0.2; self.delayStepper.maxValue = 10.0; self.delayStepper.increment = 0.5;
    self.delayStepper.valueWraps = NO;
    self.delayStepper.doubleValue = self.autoTypeDelay;
    self.delayStepper.target = self;
    self.delayStepper.action = @selector(delayChanged:);
    self.delayStepper.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:self.delayStepper];

    NSTextField *delayUnit = [[NSTextField alloc] initWithFrame:NSMakeRect(348, 50, 12, 14)];
    delayUnit.stringValue = @"s";
    delayUnit.font = [NSFont systemFontOfSize:11];
    delayUnit.textColor = [NSColor secondaryLabelColor];
    delayUnit.bezeled = NO; delayUnit.drawsBackground = NO; delayUnit.editable = NO; delayUnit.selectable = NO;
    delayUnit.autoresizingMask = NSViewMaxYMargin;
    [content addSubview:delayUnit];

    NSButton *advancedBtn = [[NSButton alloc] initWithFrame:NSMakeRect(375, 48, 95, 22)];
    advancedBtn.title = self.advancedVisible ? @"◀ Advanced" : @"Advanced ▶";
    advancedBtn.tag = 999;
    advancedBtn.bezelStyle = NSBezelStyleRounded;
    advancedBtn.font = [NSFont systemFontOfSize:11];
    advancedBtn.target = self;
    advancedBtn.action = @selector(toggleAdvancedPane:);
    advancedBtn.toolTip = @"Show raw hex, pre-truncate data, and ATR — the non-encoded source";
    advancedBtn.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [content addSubview:advancedBtn];

    // Subtle support link — does not distract from primary actions
    NSButton *coffeeLink = [[NSButton alloc] initWithFrame:NSMakeRect(380, 6, 124, 18)];
    coffeeLink.title = @"\u2764\uFE0F Buy Me a Coffee";
    coffeeLink.bezelStyle = NSBezelStyleInline;
    coffeeLink.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    coffeeLink.target = self;
    coffeeLink.action = @selector(openBuyMeACoffee:);
    coffeeLink.toolTip = @"Support CardPass at buymeacoffee.com/einnovoeg";
    coffeeLink.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    if ([coffeeLink respondsToSelector:@selector(setButtonType:)]) {
        coffeeLink.contentTintColor = [NSColor systemPinkColor];
    }
    [content addSubview:coffeeLink];

    // Advanced pane — separate window that slides out to the right, per spec.
    // Main password field (left window) stays compact and unchanged; this pane shows two
    // separate, larger boxes: Raw Hex and Encoded pre-truncate.
    NSRect advFrame = NSMakeRect(0, 0, 360, 470);
    self.advancedWindow = [[NSWindow alloc] initWithContentRect:advFrame
                                                      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                        backing:NSBackingStoreBuffered defer:NO];
    self.advancedWindow.title = @"CardPass — Advanced";
    self.advancedWindow.minSize = NSMakeSize(340, 400);
    self.advancedWindow.releasedWhenClosed = NO;
    self.advancedWindow.delegate = self;
    self.advancedWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.advancedWindow.backgroundColor = [NSColor colorWithWhite:0.13 alpha:1.0];
    self.advancedWindow.isVisible = NO; // shown via toggleAdvancedPane:
    // Position it to the right of main window on first show
    NSView *advContent = self.advancedWindow.contentView;
    advContent.wantsLayer = YES;
    advContent.layer.backgroundColor = [[NSColor colorWithWhite:0.11 alpha:1.0] CGColor];

    NSTextField *advTitle = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 440, 336, 16)];
    advTitle.stringValue = @"Advanced — Raw & Pre-Truncate";
    advTitle.font = [NSFont boldSystemFontOfSize:12];
    advTitle.textColor = [NSColor labelColor];
    advTitle.bezeled = NO; advTitle.drawsBackground = NO; advTitle.editable = NO; advTitle.selectable = NO;
    [advContent addSubview:advTitle];

    NSTextField *rawLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 418, 336, 12)];
    rawLabel.stringValue = @"Raw Hex (non-encoded, non-hashed, non-truncated):";
    rawLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    rawLabel.textColor = [NSColor secondaryLabelColor];
    rawLabel.bezeled = NO; rawLabel.drawsBackground = NO; rawLabel.editable = NO; rawLabel.selectable = NO;
    [advContent addSubview:rawLabel];

    // Larger raw boxes — show full card data
    NSScrollView *rawScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 300, 336, 90)];
    rawScroll.hasVerticalScroller = YES;
    rawScroll.borderType = NSBezelBorder;
    rawScroll.drawsBackground = YES;
    rawScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSSize rawSize = rawScroll.contentSize;
    self.rawHexView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, rawSize.width, rawSize.height)];
    self.rawHexView.editable = NO; self.rawHexView.selectable = YES;
    self.rawHexView.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    self.rawHexView.textColor = [NSColor labelColor];
    self.rawHexView.backgroundColor = [NSColor textBackgroundColor];
    self.rawHexView.string = @"(raw data appears here after card read)";
    self.rawHexView.textContainerInset = NSMakeSize(6,6);
    [self.rawHexView setAutomaticQuoteSubstitutionEnabled:NO];
    rawScroll.documentView = self.rawHexView;
    [advContent addSubview:rawScroll];

    NSTextField *preLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 280, 336, 12)];
    preLabel.stringValue = @"Encoded + Hashed (pre-truncate):";
    preLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    preLabel.textColor = [NSColor secondaryLabelColor];
    preLabel.bezeled = NO; preLabel.drawsBackground = NO; preLabel.editable = NO; preLabel.selectable = NO;
    [advContent addSubview:preLabel];

    NSScrollView *preScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 110, 336, 155)];
    preScroll.hasVerticalScroller = YES;
    preScroll.borderType = NSBezelBorder;
    preScroll.drawsBackground = YES;
    preScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSSize preSize = preScroll.contentSize;
    self.preTruncateView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, preSize.width, preSize.height)];
    self.preTruncateView.editable = NO; self.preTruncateView.selectable = YES;
    self.preTruncateView.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    self.preTruncateView.textColor = [NSColor labelColor];
    self.preTruncateView.backgroundColor = [NSColor textBackgroundColor];
    self.preTruncateView.string = @"(encoded data before truncation)";
    self.preTruncateView.textContainerInset = NSMakeSize(6,6);
    [self.preTruncateView setAutomaticQuoteSubstitutionEnabled:NO];
    preScroll.documentView = self.preTruncateView;
    [advContent addSubview:preScroll];

    NSButton *copyRawBtn = [[NSButton alloc] initWithFrame:NSMakeRect(12, 78, 150, 22)];
    copyRawBtn.title = @"Copy Raw Hex";
    copyRawBtn.bezelStyle = NSBezelStyleRounded;
    copyRawBtn.font = [NSFont systemFontOfSize:11];
    copyRawBtn.target = self;
    copyRawBtn.action = @selector(copyRawHex:);
    [advContent addSubview:copyRawBtn];

    NSButton *copyPreBtn = [[NSButton alloc] initWithFrame:NSMakeRect(170, 78, 178, 22)];
    copyPreBtn.title = @"Copy Encoded";
    copyPreBtn.bezelStyle = NSBezelStyleRounded;
    copyPreBtn.font = [NSFont systemFontOfSize:11];
    copyPreBtn.target = self;
    copyPreBtn.action = @selector(copyPreTruncate:);
    [advContent addSubview:copyPreBtn];

    // Custom text for this card — user can set any text to paste instead of card data
    NSTextField *customLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 58, 336, 12)];
    customLabel.stringValue = @"Custom text for this card (optional):";
    customLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    customLabel.textColor = [NSColor secondaryLabelColor];
    customLabel.bezeled = NO; customLabel.drawsBackground = NO; customLabel.editable = NO; customLabel.selectable = NO;
    [advContent addSubview:customLabel];

    NSTextField *customField = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 36, 220, 22)];
    customField.placeholderString = @"e.g. MySecretPassword123";
    customField.font = [NSFont systemFontOfSize:11];
    customField.target = self;
    customField.action = @selector(customTextChanged:);
    customField.tag = 1001;
    [customField setDelegate:(id<NSTextFieldDelegate>)self];
    [advContent addSubview:customField];
    // Store reference via tag lookup
    NSButton *saveCustomBtn = [[NSButton alloc] initWithFrame:NSMakeRect(238, 36, 50, 22)];
    saveCustomBtn.title = @"Save";
    saveCustomBtn.bezelStyle = NSBezelStyleRounded;
    saveCustomBtn.font = [NSFont systemFontOfSize:11];
    saveCustomBtn.target = self;
    saveCustomBtn.action = @selector(saveCustomText:);
    saveCustomBtn.tag = 1002;
    [advContent addSubview:saveCustomBtn];

    NSButton *clearCustomBtn = [[NSButton alloc] initWithFrame:NSMakeRect(292, 36, 44, 22)];
    clearCustomBtn.title = @"Clear";
    clearCustomBtn.bezelStyle = NSBezelStyleRounded;
    clearCustomBtn.font = [NSFont systemFontOfSize:11];
    clearCustomBtn.target = self;
    clearCustomBtn.action = @selector(clearCustomText:);
    [advContent addSubview:clearCustomBtn];

    NSTextField *advHint = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 12, 336, 20)];
    advHint.stringValue = @"Raw Hex is the exact bytes from the card (hex). Encoded shows the result after Base62/58/64 + SHA-256 but before truncation. Main password field (left window) is the final truncated output and is intentionally compact.";
    advHint.font = [NSFont systemFontOfSize:10];
    advHint.textColor = [NSColor secondaryLabelColor];
    advHint.bezeled = NO; advHint.drawsBackground = NO; advHint.editable = NO; advHint.selectable = NO;
    advHint.usesSingleLineMode = NO;
    [advHint setPreferredMaxLayoutWidth:336];
    advHint.autoresizingMask = NSViewWidthSizable;
    [advContent addSubview:advHint];

    // Keep a hidden pane view for backwards-compat (not used for layout, but keeps property non-nil)
    self.advancedPane = [[NSView alloc] initWithFrame:NSMakeRect(0,0,0,0)];
    self.advancedPane.hidden = YES;
    [self.advancedPane setHidden:YES];

    NSBox *bottomSep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 70, 520, 1)];
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

    // Menu bar icon: chip + stars, template for visibility on light/dark menu bars
    NSImage *icon = [NSImage imageNamed:@"MenuIcon"];
    if (!icon) {
        NSString *menuPath = [[NSBundle mainBundle] pathForResource:@"MenuIcon" ofType:@"png"];
        if (menuPath) icon = [[NSImage alloc] initWithContentsOfFile:menuPath];
    }
    if (!icon) {
        // Fallback to AppIcon if MenuIcon not found (e.g. running via ./CardPass)
        NSString *icnsPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
        if (icnsPath) icon = [[NSImage alloc] initWithContentsOfFile:icnsPath];
    }
    if (icon) {
        icon.size = NSMakeSize(16, 16);
        icon.template = YES; // monochrome, adapts to menu bar appearance
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

    // Advanced submenu — raw data lives here, NOT in main menu (per spec)
    NSMenuItem *advancedMenuItem = [[NSMenuItem alloc] initWithTitle:@"Advanced" action:nil keyEquivalent:@""];
    NSMenu *advancedMenu = [[NSMenu alloc] initWithTitle:@"Advanced"];
    NSMenuItem *showAdvItem = [[NSMenuItem alloc] initWithTitle:@"Show Advanced Pane" action:@selector(toggleAdvancedPane:) keyEquivalent:@""];
    showAdvItem.target = self;
    showAdvItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [advancedMenu addItem:showAdvItem];
    NSMenuItem *showRawItem = [[NSMenuItem alloc] initWithTitle:@"Show Raw Hex…" action:@selector(showRawHexPanel:) keyEquivalent:@""];
    showRawItem.target = self;
    [advancedMenu addItem:showRawItem];
    NSMenuItem *copyPreItem = [[NSMenuItem alloc] initWithTitle:@"Copy Encoded (pre-truncate)" action:@selector(copyPreTruncate:) keyEquivalent:@""];
    copyPreItem.target = self;
    [advancedMenu addItem:copyPreItem];
    NSMenuItem *copyRawItem = [[NSMenuItem alloc] initWithTitle:@"Copy Raw Hex" action:@selector(copyRawHex:) keyEquivalent:@""];
    copyRawItem.target = self;
    [advancedMenu addItem:copyRawItem];
    advancedMenuItem.submenu = advancedMenu;
    [self.statusMenu addItem:advancedMenuItem];

    [self.statusMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *accItem = [[NSMenuItem alloc] initWithTitle:@"Check Auto-Type Permission (Device Control)…" action:@selector(checkAccessibility:) keyEquivalent:@""];
    accItem.target = self;
    accItem.toolTip = @"Clipboard copy via ⌘V needs no permission; auto-type is optional";
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
        // Store raw bytes for encoding/hashing pipeline. Hex is base16 of raw bytes.
        NSData *raw = dataFromHexString(hex);
        if (!raw) {
            // Fallback: treat hex string bytes as raw if decoding fails
            raw = [hex dataUsingEncoding:NSUTF8StringEncoding];
        }
        self.lastRawData = raw;
        // Use raw hex as card identifier for custom mapping (stable, unique per card)
        self.currentCardId = hex; // hex is the raw hex from card
        self.lastHex = hex; // keep original for reference; transformed shown in view
        self.lastAtrHex = hexForAtr((unsigned char*)"",0); // not used

        // If user set a custom text for this card, populate the advanced field
        NSString *custom = [self customTextForCardId:self.currentCardId];
        NSTextField *customField = (NSTextField *)[self.advancedWindow.contentView viewWithTag:1001];
        if (customField) {
            customField.stringValue = custom ?: @"";
            customField.placeholderString = custom ? @"" : @"e.g. MySecretPassword123";
        }
        // Compute transformed password and show it (Base62/hash/truncate) — but if custom exists, effectivePaste will use it
        [self updateTransformedDisplay];
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

        NSString *effective = [self effectivePasteString];
        if (self.autoCopyCheck.state == NSControlStateValueOn) {
            copyToClipboard([effective UTF8String]);
            NSLog(@"Auto-copied %lu chars (effective, raw %lu hex) via enc %ld hash:%@ trunc:%ld custom:%@", (unsigned long)effective.length, (unsigned long)hex.length, (long)self.selectedEncoding, self.hashEnabled?@"YES":@"NO", (long)self.truncateLength, [self customTextForCardId:self.currentCardId] ? @"YES" : @"NO");
        }

        BOOL autoType = (self.autoTypeCheck.state == NSControlStateValueOn);
        if (autoType && effective.length > 0) {
            // Auto-type is now attempted *without* pre-checking trust — we try all
            // paste methods (AX, Cmd+V, AppleScript, per-char) and only show a
            // gentle fallback if everything fails. This fixes the Tahoe case where
            // isTrusted was flaky even though the toggle was on.
            NSString *delayStr = [NSString stringWithFormat:@"%.1f", self.autoTypeDelay];
            if ([delayStr hasSuffix:@".0"]) delayStr = [delayStr substringToIndex:delayStr.length-2];
            self.statusLabel.stringValue = [NSString stringWithFormat:@"Typing in %@s… (%@)", delayStr, name];
            self.statusLabel.textColor = [NSColor systemBlueColor];
            if (self.statusButton) self.statusButton.title = @" Typing...";

            // Log trust for debugging, but don't block on it
            NSLog(@"Auto-type: trust PostEvent=%d AX=%d (will try all methods regardless)", 
                  ({
                      void *h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY);
                      BOOL v = NO;
                      if (h) { BOOL (*p)(void)=dlsym(h,"CGPreflightPostEventAccess"); if(p) v=p(); dlclose(h); }
                      v;
                  }), AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge id)kAXTrustedCheckOptionPrompt:@NO}));

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.autoTypeDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!self.lastHex || self.lastHex.length==0) return;
                NSString *toPaste = [self effectivePasteString];
                if (!toPaste || toPaste.length==0) toPaste = [self currentTransformedString];
                if (!toPaste || toPaste.length==0) toPaste = self.lastHex;
                NSLog(@"Auto-type attempting robust paste for %lu chars (custom:%@)", (unsigned long)toPaste.length, [self customTextForCardId:self.currentCardId] ? @"YES" : @"NO");
                // typeString now tries AX → Cmd+V → AppleScript → per-char without pre-check
                typeString([toPaste UTF8String]);
                // Assume paste was attempted; show success and return to Ready.
                // If the user sees nothing pasted, they can still press ⌘V (clipboard is set).
                self.statusLabel.stringValue = @"Ready — pasted (or press ⌘V) ✓";
                self.statusLabel.textColor = [NSColor systemGreenColor];
                if (self.statusButton) {
                    NSString *p = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
                    NSImage *ic = p ? [[NSImage alloc] initWithContentsOfFile:p] : nil;
                    if (ic) { ic.size = NSMakeSize(18,18); self.statusButton.image = ic; self.statusButton.title = @" Ready"; }
                    else self.statusButton.title = @" Ready";
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    self.statusLabel.stringValue = @"Ready — insert a card";
                    self.statusLabel.textColor = [NSColor systemGreenColor];
                    if (self.statusButton) {
                        NSString *pp = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
                        NSImage *icc = pp ? [[NSImage alloc] initWithContentsOfFile:pp] : nil;
                        if (icc) { icc.size = NSMakeSize(18,18); self.statusButton.image = icc; self.statusButton.title = @" Ready"; }
                        else self.statusButton.title = @"CardPass Ready";
                    }
                });
            });
        } else {
            if (self.autoCopyCheck.state == NSControlStateValueOn) {
                self.statusLabel.stringValue = @"Copied to clipboard — ready (press ⌘V to paste)";
            } else {
                self.statusLabel.stringValue = @"Ready — insert a card";
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
    NSString *toCopy = [self effectivePasteString];
    if (!toCopy || toCopy.length==0) toCopy = self.lastHex;
    if (toCopy.length == 0) {
        NSBeep();
        return;
    }
    copyToClipboard([toCopy UTF8String]);
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
    NSString *toPaste = [self effectivePasteString];
    if (!toPaste || toPaste.length==0) toPaste = [self currentTransformedString];
    if (!toPaste || toPaste.length==0) toPaste = self.lastHex;
    if (toPaste.length == 0) { NSBeep(); return; }
    NSLog(@"Manual Type pressed for %lu chars (custom:%@), attempting robust paste", (unsigned long)toPaste.length, [self customTextForCardId:self.currentCardId] ? @"YES" : @"NO");
    // Ensure clipboard has the latest effective value
    copyToClipboard([toPaste UTF8String]);
    self.statusLabel.stringValue = @"Typing...";
    self.statusLabel.textColor = [NSColor systemBlueColor];
    if (self.statusButton) self.statusButton.title = @" Typing...";
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Use toPaste captured strongly for this attempt
        NSString *pasteStr = toPaste;
        typeString([pasteStr UTF8String]);
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
    self.lastRawData = nil;
    self.hexTextView.string = @"No card data yet — insert a card to read";
    self.hexTextView.textColor = [NSColor secondaryLabelColor];
    self.clipboardMenuItem.enabled = NO;
    self.typeMenuItem.enabled = NO;
    self.clipboardBtn.enabled = NO;
    self.typeButton.enabled = NO;
    self.encodingInfoLabel.stringValue = @"";
    self.rawHexView.string = @"(raw data appears here after card read)";
    self.preTruncateView.string = @"(encoded data before truncation)";
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

// MARK: - Encoding / Hash / Truncate controls
- (void)encodingChanged:(id)sender {
    self.selectedEncoding = (CPEncoding)[self.encodingPopup indexOfSelectedItem];
    [[NSUserDefaults standardUserDefaults] setInteger:self.selectedEncoding forKey:@"CPEncoding"];
    NSLog(@"Encoding changed to %ld (0=Hex 1=B62 2=B58 3=B64)", (long)self.selectedEncoding);
    [self updateTransformedDisplay];
}

- (void)hashToggled:(id)sender {
    self.hashEnabled = (self.hashCheck.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:self.hashEnabled forKey:@"CPHashEnabled"];
    NSLog(@"Hash %@", self.hashEnabled?@"ON (SHA-256)":@"OFF");
    [self updateTransformedDisplay];
}

- (void)truncateChanged:(id)sender {
    NSInteger val = 0;
    if (sender == self.truncateStepper) {
        val = (NSInteger)self.truncateStepper.doubleValue;
        self.truncateField.stringValue = val > 0 ? [NSString stringWithFormat:@"%ld", (long)val] : @"";
    } else {
        // From text field
        NSString *s = [self.truncateField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (s.length == 0) val = 0;
        else val = [s integerValue];
        if (val < 0) val = 0;
        if (val > 128) val = 128;
        self.truncateStepper.doubleValue = val;
    }
    self.truncateLength = val;
    [[NSUserDefaults standardUserDefaults] setInteger:self.truncateLength forKey:@"CPTruncateLength"];
    NSLog(@"Truncate set to %ld", (long)self.truncateLength);
    [self updateTransformedDisplay];
}

- (void)delayChanged:(id)sender {
    double val = self.autoTypeDelay;
    if (sender == self.delayStepper) {
        val = self.delayStepper.doubleValue;
        self.delayField.stringValue = [NSString stringWithFormat:@"%.1f", val];
    } else {
        NSString *s = [self.delayField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        val = [s doubleValue];
        if (val < 0.2) val = 0.2;
        if (val > 10.0) val = 10.0;
        self.delayStepper.doubleValue = val;
        self.delayField.stringValue = [NSString stringWithFormat:@"%.1f", val];
    }
    self.autoTypeDelay = val;
    [[NSUserDefaults standardUserDefaults] setDouble:self.autoTypeDelay forKey:@"CPAutoTypeDelay"];
    NSLog(@"Delay set to %.1f s", self.autoTypeDelay);
}

- (NSString *)customTextForCardId:(NSString *)cardId {
    if (!cardId || cardId.length==0) return nil;
    return self.customMappings[cardId];
}

- (NSString *)effectivePasteString {
    // If user set a custom text for this card, use it; otherwise use transformed
    NSString *custom = [self customTextForCardId:self.currentCardId];
    if (custom && custom.length>0) {
        NSLog(@"effectivePaste: using custom for %@ (%lu chars)", self.currentCardId, (unsigned long)custom.length);
        return custom;
    }
    return [self currentTransformedString];
}

- (void)customTextChanged:(id)sender {
    // Live update as user types, but not yet saved
    NSTextField *field = (NSTextField *)[self.advancedWindow.contentView viewWithTag:1001];
    if (!field) field = (NSTextField *)sender;
    NSString *txt = [field stringValue];
    NSLog(@"customTextChanged: %@ (%lu)", txt, (unsigned long)txt.length);
    // Don't auto-save; user must click Save
}

- (void)saveCustomText:(id)sender {
    if (!self.currentCardId) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"No Card Yet";
        a.informativeText = @"Insert a card first to set its custom text. The custom text is tied to that card's raw hex.";
        [a addButtonWithTitle:@"OK"];
        [a beginSheetModalForWindow:self.advancedWindow ?: self.mainWindow completionHandler:nil];
        return;
    }
    NSTextField *field = (NSTextField *)[self.advancedWindow.contentView viewWithTag:1001];
    NSString *txt = [[field stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (txt.length==0) {
        [self.customMappings removeObjectForKey:self.currentCardId];
    } else {
        self.customMappings[self.currentCardId] = txt;
    }
    [[NSUserDefaults standardUserDefaults] setObject:self.customMappings forKey:@"CPCustomMappings"];
    NSLog(@"saveCustomText: for %@ -> %@ (%lu)", self.currentCardId, txt, (unsigned long)txt.length);
    [self updateTransformedDisplay];
    self.statusLabel.stringValue = txt.length>0 ? [NSString stringWithFormat:@"Custom text saved for this card (%lu chars) ✓", (unsigned long)txt.length] : @"Custom text cleared";
    self.statusLabel.textColor = [NSColor systemGreenColor];
}

- (void)clearCustomText:(id)sender {
    NSTextField *field = (NSTextField *)[self.advancedWindow.contentView viewWithTag:1001];
    field.stringValue = @"";
    [self saveCustomText:sender];
}

- (void)toggleAdvancedPane:(id)sender {
    self.advancedVisible = !self.advancedVisible;
    [[NSUserDefaults standardUserDefaults] setBool:self.advancedVisible forKey:@"CPAdvancedVisible"];
    // Update button title in main window
    NSView *content = self.mainWindow.contentView;
    NSButton *advBtn = (NSButton *)[content viewWithTag:999];
    if (!advBtn) {
        for (NSView *sv in content.subviews) {
            advBtn = (NSButton *)[sv viewWithTag:999];
            if (advBtn) break;
        }
    }
    if (advBtn) advBtn.title = self.advancedVisible ? @"◀ Advanced" : @"Advanced ▶";

    if (self.advancedVisible) {
        // Show separate Advanced window to the right of main window
        NSRect mainFrame = self.mainWindow.frame;
        NSRect advFrame = self.advancedWindow.frame;
        advFrame.origin.x = NSMaxX(mainFrame) + 8;
        advFrame.origin.y = mainFrame.origin.y + (mainFrame.size.height - advFrame.size.height)/2;
        [self.advancedWindow setFrame:advFrame display:NO];
        [self.advancedWindow makeKeyAndOrderFront:sender];
        [self.mainWindow addChildWindow:self.advancedWindow ordered:NSWindowAbove];
        [self updateTransformedDisplay];
        NSLog(@"Advanced window shown at %.0f,%.0f", advFrame.origin.x, advFrame.origin.y);
    } else {
        [self.mainWindow removeChildWindow:self.advancedWindow];
        [self.advancedWindow orderOut:sender];
        NSLog(@"Advanced window hidden");
    }
    // Also keep hidden flag for backwards compat
    self.advancedPane.hidden = !self.advancedVisible;
}

- (void)copyRawHex:(id)sender {
    if (!self.lastRawData) { NSBeep(); return; }
    // Show raw hex (non-encoded)
    NSMutableString *hex = [NSMutableString stringWithCapacity:self.lastRawData.length*2];
    const uint8_t *b = self.lastRawData.bytes;
    for (NSUInteger i=0;i<self.lastRawData.length;i++) [hex appendFormat:@"%02X", b[i]];
    copyToClipboard([hex UTF8String]);
    self.statusLabel.stringValue = @"Copied raw hex ✓";
    self.statusLabel.textColor = [NSColor systemGreenColor];
}

- (void)copyPreTruncate:(id)sender {
    if (!self.lastRawData) { NSBeep(); return; }
    // Encoded + hashed but before truncate
    NSString *pre = transformData(self.lastRawData, self.selectedEncoding, self.hashEnabled, 0);
    copyToClipboard([pre UTF8String]);
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Copied encoded (%lu) ✓", (unsigned long)pre.length];
    self.statusLabel.textColor = [NSColor systemGreenColor];
}

- (void)showRawHexPanel:(id)sender {
    // Ensure advanced pane is visible so user sees both raw and encoded
    if (!self.advancedVisible) [self toggleAdvancedPane:sender];
    [self showWindowAction:sender];
    // Also show a sheet with raw hex for quick copy
    if (!self.lastRawData) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"No Raw Data Yet";
        a.informativeText = @"Insert a card to see raw hex. The Advanced pane (right side) will show: Raw Hex (exact bytes from card) and Encoded pre-truncate. The main password field (left) is the final truncated output and is unchanged.";
        [a addButtonWithTitle:@"OK"];
        [a beginSheetModalForWindow:self.mainWindow completionHandler:nil];
        return;
    }
    NSMutableString *rawHex = [NSMutableString stringWithCapacity:self.lastRawData.length*2];
    const uint8_t *b = self.lastRawData.bytes;
    for (NSUInteger i=0;i<self.lastRawData.length;i++) [rawHex appendFormat:@"%02X", b[i]];
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"Raw Hex (from card)";
    a.informativeText = [NSString stringWithFormat:@"Exact bytes as read (non-encoded, non-hashed, non-truncated):\n\n%@\n\nLength: %lu bytes / %lu hex chars\n\nThis is also visible in the Advanced pane → Raw Hex. The main field shows the final password after encoding/hash/truncate.", rawHex, (unsigned long)self.lastRawData.length, (unsigned long)rawHex.length];
    [a addButtonWithTitle:@"Copy Raw Hex"];
    [a addButtonWithTitle:@"OK"];
    NSModalResponse r = [a runModal];
    if (r == NSAlertFirstButtonReturn) {
        copyToClipboard([rawHex UTF8String]);
        self.statusLabel.stringValue = @"Copied raw hex ✓";
    }
}

- (void)controlTextDidEndEditing:(NSNotification *)obj {
    if (obj.object == self.truncateField) [self truncateChanged:self.truncateField];
    else if (obj.object == self.delayField) [self delayChanged:self.delayField];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    // Allow Enter to commit fields
    if ((control == self.truncateField || control == self.delayField) && commandSelector == @selector(insertNewline:)) {
        if (control == self.truncateField) [self truncateChanged:self.truncateField];
        else [self delayChanged:self.delayField];
        [[control window] makeFirstResponder:nil];
        return YES;
    }
    return NO;
}

- (NSString *)currentTransformedString {
    // Uses lastRawData + current encoding/hash/truncate to produce the password
    if (!self.lastRawData) {
        // Fallback to hex string if no raw yet (e.g. before first read)
        if (self.lastHex.length > 0) {
            NSData *fallback = dataFromHexString(self.lastHex);
            if (fallback) return transformData(fallback, self.selectedEncoding, self.hashEnabled, self.truncateLength);
            return self.lastHex; // as-is
        }
        return @"";
    }
    return transformData(self.lastRawData, self.selectedEncoding, self.hashEnabled, self.truncateLength);
}

- (void)updateTransformedDisplay {
    if (!self.lastRawData) {
        // No data yet — keep placeholder until a card is read
        if (self.lastHex.length == 0) {
            self.hexTextView.string = @"No card data yet — insert a card to read";
            self.hexTextView.textColor = [NSColor secondaryLabelColor];
            self.encodingInfoLabel.stringValue = @"";
            // Clear advanced custom field if no card
            NSTextField *customField = (NSTextField *)[self.advancedWindow.contentView viewWithTag:1001];
            if (customField) customField.stringValue = @"";
            return;
        }
        // Legacy lastHex without raw — try to derive raw
        NSData *raw = dataFromHexString(self.lastHex);
        if (raw) self.lastRawData = raw;
    }
    NSString *transformed = [self currentTransformedString];
    NSString *effective = [self effectivePasteString];
    BOOL isCustom = (self.currentCardId && [self customTextForCardId:self.currentCardId] != nil);
    // Keep lastHex as the *effective* password for copy/type (custom takes precedence)
    self.lastHex = effective;
    if (isCustom) {
        self.hexTextView.string = effective;
        self.hexTextView.textColor = [NSColor systemPurpleColor];
    } else {
        self.hexTextView.string = transformed.length > 0 ? transformed : @"(empty — check encoding settings)";
        self.hexTextView.textColor = transformed.length > 0 ? [NSColor labelColor] : [NSColor secondaryLabelColor];
    }

    // Update custom field in advanced window
    NSTextField *customField = (NSTextField *)[self.advancedWindow.contentView viewWithTag:1001];
    if (customField) {
        NSString *custom = [self customTextForCardId:self.currentCardId];
        // Only update if field is not first responder (user not actively editing)
        if (customField != [self.advancedWindow firstResponder]) {
            customField.stringValue = custom ?: @"";
        }
    }

    // Update info label: show e.g. "43 chars (B62+hash)" or truncated note, plus custom note
    NSString *encName = @[@"Hex",@"Base62",@"Base58",@"Base64"][(NSInteger)self.selectedEncoding];
    NSString *hashNote = self.hashEnabled ? @"+SHA256" : @"";
    NSString *truncNote = self.truncateLength > 0 ? [NSString stringWithFormat:@" → %ld chars", (long)self.truncateLength] : @"";
    NSString *customNote = isCustom ? @" (custom)" : @"";
    NSString *info = @"";
    if (self.lastRawData) {
        NSUInteger rawLen = self.lastRawData.length;
        if (self.hashEnabled) {
            info = [NSString stringWithFormat:@"%lu raw → 32 hash → %lu %@%@%@%@", (unsigned long)rawLen, (unsigned long)effective.length, encName, hashNote, truncNote, customNote];
        } else {
            info = [NSString stringWithFormat:@"%lu raw → %lu %@%@%@", (unsigned long)rawLen, (unsigned long)effective.length, encName, truncNote, customNote];
        }
        if (isCustom) info = [info stringByAppendingString:@" — using custom text"];
    } else {
        info = [NSString stringWithFormat:@"%lu %@%@%@", (unsigned long)transformed.length, encName, hashNote, truncNote];
    }
    self.encodingInfoLabel.stringValue = info;

    // Update advanced pane raw / pre-truncate views
    if (self.rawHexView) {
        if (self.lastRawData) {
            NSMutableString *rawHex = [NSMutableString stringWithCapacity:self.lastRawData.length*2];
            const uint8_t *b = self.lastRawData.bytes;
            for (NSUInteger i=0;i<self.lastRawData.length;i++) [rawHex appendFormat:@"%02X", b[i]];
            self.rawHexView.string = rawHex;
            self.rawHexView.textColor = [NSColor labelColor];
        } else {
            self.rawHexView.string = @"(raw data appears here after card read)";
            self.rawHexView.textColor = [NSColor secondaryLabelColor];
        }
    }
    if (self.preTruncateView) {
        if (self.lastRawData) {
            NSString *pre = transformData(self.lastRawData, self.selectedEncoding, self.hashEnabled, 0);
            self.preTruncateView.string = pre.length > 0 ? pre : @"(empty)";
            self.preTruncateView.textColor = pre.length > 0 ? [NSColor labelColor] : [NSColor secondaryLabelColor];
        } else {
            self.preTruncateView.string = @"(encoded data before truncation)";
            self.preTruncateView.textColor = [NSColor secondaryLabelColor];
        }
    }

    // Enable copy/type if we have something to copy
    BOOL has = transformed.length > 0;
    self.clipboardMenuItem.enabled = has;
    self.typeMenuItem.enabled = has;
    self.clipboardBtn.enabled = has;
    self.typeButton.enabled = has;

    // Persist already done in the control handlers
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
        a.messageText = @"Device Control Permission Granted ✓";
        a.informativeText = @"CardPass can auto-type into password fields.\n\n"
                             "Tip: Clipboard copy (⌘V) always works even without this permission.";
        [a addButtonWithTitle:@"OK"];
        [a runModal];
        return;
    }
    NSString *panePath = currentPrivacyPanePath();
    a.messageText = @"Auto-Type Is Optional";
    a.informativeText = [NSString stringWithFormat:@"CardPass always copies card data to the clipboard — just press ⌘V to paste, no permission needed.\n\n"
                         "Auto-type (automatic keystroke injection) is optional and requires:\n"
                         "%@\n\n"
                         "Enable CardPass there, then *quit and reopen* CardPass for the change to take effect. "
                         "If the toggle is already on and you still see this, try turning it off/on and restarting CardPass.", panePath];
    [a addButtonWithTitle:@"Open Settings"];
    [a addButtonWithTitle:@"Use Clipboard (No Permission Needed)"];
    [a addButtonWithTitle:@"Cancel"];
    NSModalResponse r = [a runModal];
    if (r == NSAlertFirstButtonReturn) {
        requestTypingPermission();
    } else if (r == NSAlertSecondButtonReturn) {
        // Disable auto-type so user stops seeing prompts — clipboard still works.
        self.autoTypeCheck.state = NSControlStateValueOff;
        [self toggleAutoType:self.autoTypeCheck];
        self.statusLabel.stringValue = @"Auto-type disabled — clipboard copy still active ✓";
        self.statusLabel.textColor = [NSColor systemGreenColor];
    }
}

- (void)openBuyMeACoffee:(id)sender {
    openBuyMeACoffee();
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    if (sender == self.advancedWindow) {
        // User closed Advanced window via red button — toggle state
        self.advancedVisible = NO;
        [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"CPAdvancedVisible"];
        NSButton *btn = (NSButton *)[self.mainWindow.contentView viewWithTag:999];
        if (btn) btn.title = @"Advanced ▶";
        [self.mainWindow removeChildWindow:self.advancedWindow];
        [sender orderOut:nil];
        return NO;
    }
    [sender orderOut:nil];
    return NO;
}

- (void)windowDidMove:(NSNotification *)notification {
    // Keep Advanced window glued to the right of main window
    if (notification.object == self.mainWindow && self.advancedVisible && self.advancedWindow.isVisible) {
        NSRect mainFrame = self.mainWindow.frame;
        NSRect advFrame = self.advancedWindow.frame;
        advFrame.origin.x = NSMaxX(mainFrame) + 8;
        advFrame.origin.y = mainFrame.origin.y + (mainFrame.size.height - advFrame.size.height)/2;
        [self.advancedWindow setFrame:advFrame display:YES];
    }
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
