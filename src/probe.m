// probe.m — HID probe for the HP Professor 1 mouse (ROYUAN, VID 0x3151)
//
// Usage:
//   probe list                 list every HID interface of the mouse incl. report descriptor
//   probe watch [seconds]      passively dump every input report from every interface
//   probe feature              read back every feature report id and print the bytes
//
// Build: clang -fobjc-arc -o probe src/probe.m -framework Foundation -framework IOKit

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>

static const int kTargetVendorID = 0x3151;
static int gOnlyReportID = -1;   // -1 == log everything
static int gButtonsOnly = 0;     // log report 5 only when its button byte changes
static uint8_t gLastButtons = 0;

// MARK: - helpers

static NSString *hexBytes(const uint8_t *bytes, CFIndex count) {
    NSMutableArray *parts = [NSMutableArray array];
    for (CFIndex i = 0; i < count; i++) {
        [parts addObject:[NSString stringWithFormat:@"%02X", bytes[i]]];
    }
    return [parts componentsJoinedByString:@" "];
}

static id prop(IOHIDDeviceRef dev, CFStringRef key) {
    return (__bridge id)IOHIDDeviceGetProperty(dev, key);
}

static int propInt(IOHIDDeviceRef dev, CFStringRef key) {
    id v = prop(dev, key);
    return [v respondsToSelector:@selector(intValue)] ? [v intValue] : -1;
}

static NSString *describe(IOHIDDeviceRef dev) {
    NSString *product = prop(dev, CFSTR(kIOHIDProductKey)) ?: @"?";
    NSString *transport = prop(dev, CFSTR(kIOHIDTransportKey)) ?: @"?";
    return [NSString stringWithFormat:@"%@ [%@] usagePage=0x%04X usage=0x%04X in=%d out=%d feature=%d",
            product, transport,
            propInt(dev, CFSTR(kIOHIDPrimaryUsagePageKey)),
            propInt(dev, CFSTR(kIOHIDPrimaryUsageKey)),
            propInt(dev, CFSTR(kIOHIDMaxInputReportSizeKey)),
            propInt(dev, CFSTR(kIOHIDMaxOutputReportSizeKey)),
            propInt(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey))];
}

static NSArray *allDevices(IOHIDManagerRef *outManager) {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSDictionary *match = @{ (__bridge NSString *)CFSTR(kIOHIDVendorIDKey): @(kTargetVendorID) };
    IOHIDManagerSetDeviceMatching(manager, (__bridge CFDictionaryRef)match);
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        fprintf(stderr, "manager open failed: 0x%08X\n", r);
    }
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
    NSSet *set = (__bridge NSSet *)IOHIDManagerCopyDevices(manager);
    if (outManager) *outManager = manager; else CFRelease(manager);
    return set.allObjects ?: @[];
}



// ---- measurement mode: log every raw delta, tagged with the current DPI step ----

static IOHIDDeviceRef gOpenDevs[8];
static int            gOpenDevCount = 0;
static int            gQuietInput = 0;     // scanapi: log only vendor packets
static int       gMeasure = 0;
static double    gMeasureCm = 20.0;
static NSInteger gCurStep = -1;

static void measureFeed(IOHIDReportType type, uint32_t reportID, uint8_t *report, CFIndex len) {
    if (!gMeasure || len < 2) return;
    if (reportID == 6) {
        if (len >= 4 && report[1] == 0x66 && report[2] == 0x0C) {
            gCurStep = report[3];
            printf("=== step %ld (cm=%.2f) ===\n", (long)(gCurStep + 1), gMeasureCm);
            fflush(stdout);
        }
        return;
    }
    if (reportID == 5 && len >= 6 && gCurStep >= 0) {
        int16_t dx = (int16_t)(report[2] | (report[3] << 8));
        int16_t dy = (int16_t)(report[4] | (report[5] << 8));
        printf("d %ld %d %d\n", (long)(gCurStep + 1), dx, dy);
        fflush(stdout);
    }
}


// ---- vendor-API probing: send an output report, watch what comes back ----

static void devMatchedCB(void *context, IOReturn result, void *sender, IOHIDDeviceRef device);
static void devRemovedCB(void *context, IOReturn result, void *sender, IOHIDDeviceRef device);

static void hexToBytes(NSString *hex, uint8_t *out, size_t maxLen, size_t *outLen) {
    NSMutableString *clean = [NSMutableString string];
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for (NSUInteger i = 0; i < hex.length; i++) {
        unichar c = [hex characterAtIndex:i];
        if ([hexSet characterIsMember:c]) [clean appendFormat:@"%C", c];
    }
    size_t n = 0;
    for (NSUInteger i = 0; i + 1 < clean.length && n < maxLen; i += 2) {
        unsigned int v = 0;
        [[NSScanner scannerWithString:[clean substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&v];
        out[n++] = (uint8_t)v;
    }
    *outLen = n;
}

static IOHIDManagerRef openManager(void) {
    gOpenDevCount = 0;
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *matches = @[ @{ (__bridge NSString *)CFSTR(kIOHIDVendorIDKey): @(kTargetVendorID) },
                          @{ (__bridge NSString *)CFSTR(kIOHIDDeviceUsagePageKey): @(0xFF55),
                             (__bridge NSString *)CFSTR(kIOHIDDeviceUsageKey): @(0x0202) } ];
    IOHIDManagerSetDeviceMatchingMultiple(m, (__bridge CFArrayRef)matches);
    IOHIDManagerRegisterDeviceMatchingCallback(m, devMatchedCB, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(m, devRemovedCB, NULL);
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    printf("manager open: 0x%08X, waiting up to 90s for the mouse (move it / press DPI to wake)…\n", r);
    fflush(stdout);
    for (int i = 0; i < 90 && gOpenDevCount == 0; i++) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
    }
    if (gOpenDevCount == 0) printf("(still no device)\n");
    else { printf("device ready.\n"); fflush(stdout); }
    return m;
}

/// Send one 65 byte vendor payload as report 6 and print everything that comes back.
static void cmdSend(NSString *hexPayload, double listen) {
    @autoreleasepool {
        openManager();
        if (gOpenDevCount == 0) { printf("no device\n"); return; }
        uint8_t buf[65];
        size_t len = 0;
        hexToBytes(hexPayload, buf, sizeof buf, &len);
        if (len < 1) { printf("nothing to send\n"); return; }
        if (len < sizeof buf) memset(buf + len, 0, sizeof buf - len);
        printf(">>> SENT  %s\n", hexBytes(buf, sizeof buf).UTF8String);
        fflush(stdout);
        IOReturn r = IOHIDDeviceSetReport(gOpenDevs[0], kIOHIDReportTypeOutput, 6, buf, sizeof buf);
        printf("    SetReport -> 0x%08X%s\n", r, r == kIOReturnSuccess ? " (ok)" : " (failed)");
        fflush(stdout);
        gQuietInput = 1;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, listen, false);
        gQuietInput = 0;
        printf("--- listening done ---\n");
        fflush(stdout);
    }
}


/// Alternate two payloads so the human can feel whether the device obeys.
static void cmdPulse(NSString *hexA, NSString *hexB, double perStep, int cycles) {
    @autoreleasepool {
        openManager();
        if (gOpenDevCount == 0) { printf("no device\n"); return; }
        uint8_t a[65], b[65];
        size_t la = 0, lb = 0;
        hexToBytes(hexA, a, sizeof a, &la);
        hexToBytes(hexB, b, sizeof b, &lb);
        if (la < sizeof a) memset(a + la, 0, sizeof a - la);
        if (lb < sizeof b) memset(b + lb, 0, sizeof b - lb);
        gQuietInput = 1;
        for (int i = 0; i < cycles; i++) {
            printf("[cycle %d] >>> %s\n", i + 1, hexBytes(a, 4).UTF8String);
            fflush(stdout);
            IOHIDDeviceSetReport(gOpenDevs[0], kIOHIDReportTypeOutput, 6, a, sizeof a);
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, perStep, false);
            printf("[cycle %d] >>> %s\n", i + 1, hexBytes(b, 4).UTF8String);
            fflush(stdout);
            IOHIDDeviceSetReport(gOpenDevs[0], kIOHIDReportTypeOutput, 6, b, sizeof b);
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, perStep, false);
        }
        gQuietInput = 0;
        printf("--- pulse done ---\n");
        fflush(stdout);
    }
}

/// Walk a range of vendor opcodes (payload 66 OP 00 …) and report which ones answer.
static void cmdScanApi(int first, int last, double perCmd) {
    @autoreleasepool {
        openManager();
        if (gOpenDevCount == 0) { printf("no device\n"); return; }
        gQuietInput = 1;
        uint8_t buf[65];
        for (int op = first; op <= last; op++) {
            memset(buf, 0, sizeof buf);
            buf[0] = 0x66;
            buf[1] = (uint8_t)op;
            printf(">>> SENT 66 %02X\n", op);
            fflush(stdout);
            IOReturn r = IOHIDDeviceSetReport(gOpenDevs[0], kIOHIDReportTypeOutput, 6, buf, sizeof buf);
            if (r != kIOReturnSuccess) printf("    SetReport -> 0x%08X\n", r);
            fflush(stdout);
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, perCmd, false);
        }
        gQuietInput = 0;
        printf("--- scan done, opcodes 0x%02X..0x%02X ---\n", first, last);
        fflush(stdout);
    }
}

// ---- per-device mode: robust against BLE sleep / reconnect ----

typedef struct {
    uint8_t *buf;
    size_t   bufLen;
    char     label[128];
} DevCtx;

static void devInputCB(void *context, IOReturn result, void *sender, IOHIDReportType type,
                       uint32_t reportID, uint8_t *report, CFIndex reportLength) {
    if (gMeasure) { measureFeed(type, reportID, report, reportLength); return; }
    if (gQuietInput) {
        if (reportID == 6) {
            printf("  <<< IN  %s\n", hexBytes(report, reportLength).UTF8String);
            fflush(stdout);
        }
        return;
    }
    if (gOnlyReportID >= 0 && (int)reportID != gOnlyReportID) return;
    if (gButtonsOnly && reportID == 5) {
        uint8_t buttons = reportLength > 1 ? report[1] : 0;
        if (buttons == gLastButtons) return;
        gLastButtons = buttons;
        printf("[%.3f] *** button byte -> 0x%02X ***\n", [NSDate date].timeIntervalSince1970, buttons);
    }
    DevCtx *ctx = (DevCtx *)context;
    printf("[%.3f] %s reportID=%u (%ldB): %s\n", [NSDate date].timeIntervalSince1970,
           ctx ? ctx->label : "?", reportID, (long)reportLength, hexBytes(report, reportLength).UTF8String);
    fflush(stdout);
}

static void devMatchedCB(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    DevCtx *ctx = calloc(1, sizeof(DevCtx));
    NSString *label = [NSString stringWithFormat:@"#%s[page=0x%04X]",
                       [prop(device, CFSTR(kIOHIDProductKey)) ?: @"?" description].UTF8String,
                       propInt(device, CFSTR(kIOHIDPrimaryUsagePageKey))];
    strlcpy(ctx->label, label.UTF8String, sizeof(ctx->label));
    int maxIn = propInt(device, CFSTR(kIOHIDMaxInputReportSizeKey));
    ctx->bufLen = (maxIn > 0 ? (size_t)maxIn : 64) + 1;
    ctx->buf = calloc(1, ctx->bufLen);
    IOHIDDeviceRegisterInputReportCallback(device, ctx->buf, (CFIndex)ctx->bufLen, devInputCB, ctx);
    IOReturn r = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
    printf("[%.3f] *** MATCHED %s -> open 0x%08X ***\n", [NSDate date].timeIntervalSince1970, ctx->label, r);
    fflush(stdout);
    if (r == kIOReturnSuccess) {
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        if (gOpenDevCount < 8) gOpenDevs[gOpenDevCount++] = device;
    }
}

static void devRemovedCB(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    printf("[%.3f] *** REMOVED %s ***\n", [NSDate date].timeIntervalSince1970,
           [prop(device, CFSTR(kIOHIDProductKey)) ?: @"?" description].UTF8String);
    fflush(stdout);
}

static void cmdWatchDev(double seconds) {
    IOHIDManagerRef manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *matches = @[ @{ (__bridge NSString *)CFSTR(kIOHIDVendorIDKey): @(kTargetVendorID) },
                          @{ (__bridge NSString *)CFSTR(kIOHIDDeviceUsagePageKey): @(0xFF55),
                             (__bridge NSString *)CFSTR(kIOHIDDeviceUsageKey): @(0x0202) } ];
    IOHIDManagerSetDeviceMatchingMultiple(manager, (__bridge CFArrayRef)matches);
    IOHIDManagerRegisterDeviceMatchingCallback(manager, devMatchedCB, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(manager, devRemovedCB, NULL);
    IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOReturn r = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    printf("manager open: 0x%08X\n", r);
    printf("--- press the DPI button now (%ds) ---\n", (int)seconds);
    fflush(stdout);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
    printf("done.\n");
}

// ---- end per-device mode ----


/// List every HID device on the system (to spot the dongle / wired interface).
static void cmdAll(void) {
    @autoreleasepool {
        IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
        IOHIDManagerSetDeviceMatching(m, NULL);          // everything
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.5, false);
        NSSet *set = (__bridge_transfer NSSet *)IOHIDManagerCopyDevices(m);
        printf("total HID devices: %lu\n\n", (unsigned long)set.count);
        for (id d in set.allObjects) {
            IOHIDDeviceRef dev = (__bridge IOHIDDeviceRef)d;
            int vid = propInt(dev, CFSTR(kIOHIDVendorIDKey));
            int pid = propInt(dev, CFSTR(kIOHIDProductIDKey));
            NSString *product = prop(dev, CFSTR(kIOHIDProductKey)) ?: @"?";
            NSString *transport = prop(dev, CFSTR(kIOHIDTransportKey)) ?: @"?";
            int up = propInt(dev, CFSTR(kIOHIDPrimaryUsagePageKey));
            int u  = propInt(dev, CFSTR(kIOHIDPrimaryUsageKey));
            printf("%04X:%04X  %-28s [%-22s] page=0x%04X usage=0x%04X in=%d out=%d feat=%d\n",
                   vid, pid, product.UTF8String, transport.UTF8String, up, u,
                   propInt(dev, CFSTR(kIOHIDMaxInputReportSizeKey)),
                   propInt(dev, CFSTR(kIOHIDMaxOutputReportSizeKey)),
                   propInt(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey)));
            NSArray *pairs = prop(dev, CFSTR(kIOHIDDeviceUsagePairsKey));
            for (NSDictionary *pr in pairs) {
                int pp = [pr[(__bridge NSString *)CFSTR(kIOHIDDeviceUsagePageKey)] intValue];
                int uu = [pr[(__bridge NSString *)CFSTR(kIOHIDDeviceUsageKey)] intValue];
                if (pp >= 0xFF00) printf("        vendor usage page 0x%04X usage 0x%04X\n", pp, uu);
            }
        }
        fflush(stdout);
    }
}

// MARK: - commands

static void cmdList(void) {
    IOHIDManagerRef manager = NULL;
    NSArray *devices = allDevices(&manager);
    printf("found %lu HID interface(s) for vendor 0x%04X\n", (unsigned long)devices.count, kTargetVendorID);
    for (NSUInteger i = 0; i < devices.count; i++) {
        IOHIDDeviceRef dev = (__bridge IOHIDDeviceRef)devices[i];
        printf("\n=== interface %lu: %s\n", (unsigned long)i, describe(dev).UTF8String);
        id loc = prop(dev, CFSTR(kIOHIDLocationIDKey));
        if (loc) printf("    locationID: %s\n", [[loc description] UTF8String]);
        NSData *rd = prop(dev, CFSTR(kIOHIDReportDescriptorKey));
        if (rd.length) {
            printf("    report descriptor (%lu bytes):\n", (unsigned long)rd.length);
            const uint8_t *b = rd.bytes;
            for (NSUInteger n = 0; n < rd.length; n += 16) {
                NSUInteger len = MIN((NSUInteger)16, rd.length - n);
                printf("      %s\n", hexBytes(b + n, len).UTF8String);
            }
        }
        NSArray *pairs = prop(dev, CFSTR(kIOHIDDeviceUsagePairsKey));
        for (NSDictionary *p in pairs) {
            printf("    usage pair: page=0x%04X usage=0x%04X\n",
                   [p[(__bridge NSString *)CFSTR(kIOHIDDeviceUsagePageKey)] intValue],
                   [p[(__bridge NSString *)CFSTR(kIOHIDDeviceUsageKey)] intValue]);
        }
    }
    if (manager) CFRelease(manager);
}

static void inputReportCallback(void *context, IOReturn result, void *sender,
                                IOHIDReportType type, uint32_t reportID,
                                uint8_t *report, CFIndex reportLength) {
    if (gOnlyReportID >= 0 && (int)reportID != gOnlyReportID) return;
    if (gButtonsOnly && reportID == 5) {
        uint8_t buttons = reportLength > 1 ? report[1] : 0;
        if (buttons == gLastButtons) return;
        gLastButtons = buttons;
        printf("[%.3f] *** button byte changed -> 0x%02X ***\n", [NSDate date].timeIntervalSince1970, buttons);
    }
    NSString *label = (__bridge NSString *)context;
    NSDate *now = [NSDate date];
    printf("[%.3f] %s reportID=%u (%ldB): %s\n",
           now.timeIntervalSince1970, label.UTF8String, reportID,
           (long)reportLength, hexBytes(report, reportLength).UTF8String);
    fflush(stdout);
}

static void cmdWatch(double seconds) {
    IOHIDManagerRef manager = NULL;
    NSArray *devices = allDevices(&manager);
    if (devices.count == 0) {
        printf("no device found (connected / awake?)\n");
        return;
    }
    NSMutableArray *opened = [NSMutableArray array];
    NSMutableArray *labels = [NSMutableArray array];
    for (NSUInteger i = 0; i < devices.count; i++) {
        IOHIDDeviceRef dev = (__bridge IOHIDDeviceRef)devices[i];
        NSString *label = [NSString stringWithFormat:@"if%lu[page=0x%04X usage=0x%04X]",
                           (unsigned long)i,
                           propInt(dev, CFSTR(kIOHIDPrimaryUsagePageKey)),
                           propInt(dev, CFSTR(kIOHIDPrimaryUsageKey))];
        [labels addObject:label];
        IOReturn r = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
        if (r != kIOReturnSuccess) {
            printf("could not open %s (0x%08X) — needs Input Monitoring permission\n", label.UTF8String, r);
            continue;
        }
        IOHIDDeviceRegisterInputReportCallback(dev, malloc(4096), 4096, inputReportCallback,
                                               (__bridge_retained void *)label);
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        [opened addObject:(__bridge id)dev];
        printf("listening on %s\n", label.UTF8String);
    }
    printf("--- press the DPI button now (%ds) ---\n", (int)seconds);
    fflush(stdout);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
    for (id d in opened) {
        IOHIDDeviceUnscheduleFromRunLoop((__bridge IOHIDDeviceRef)d, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        IOHIDDeviceClose((__bridge IOHIDDeviceRef)d, kIOHIDOptionsTypeNone);
    }
    printf("done.\n");
    if (manager) CFRelease(manager);
}

static void cmdFeature(void) {
    IOHIDManagerRef manager = NULL;
    NSArray *devices = allDevices(&manager);
    for (NSUInteger i = 0; i < devices.count; i++) {
        IOHIDDeviceRef dev = (__bridge IOHIDDeviceRef)devices[i];
        printf("\n=== interface %lu: %s\n", (unsigned long)i, describe(dev).UTF8String);
        IOReturn r = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
        if (r != kIOReturnSuccess) { printf("  open failed 0x%08X\n", r); continue; }
        int maxFeat = propInt(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey));
        if (maxFeat <= 0) { printf("  no feature reports\n"); IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone); continue; }
        uint8_t *buf = calloc(1, maxFeat + 1);
        for (int rid = 0; rid <= 15; rid++) {
            memset(buf, 0, maxFeat + 1);
            buf[0] = (uint8_t)rid;
            CFIndex len = maxFeat + 1;
            r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, rid, buf, &len);
            if (r == kIOReturnSuccess) {
                printf("  feature id %d (%ldB): %s\n", rid, (long)len, hexBytes(buf, len).UTF8String);
            } else {
                printf("  feature id %d -> 0x%08X\n", rid, r);
            }
        }
        free(buf);
        IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
    }
    if (manager) CFRelease(manager);
}

// MARK: - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *cmd = argc > 1 ? @(argv[1]) : @"list";
        if ([cmd isEqualToString:@"list"]) {
            cmdList();
        } else if ([cmd isEqualToString:@"watch"]) {
            cmdWatch(argc > 2 ? atof(argv[2]) : 30.0);
        } else if ([cmd isEqualToString:@"all"]) {
            cmdAll();
        } else if ([cmd isEqualToString:@"send"]) {
            NSMutableArray *parts = [NSMutableArray array];
            for (int i = 2; i < argc; i++) [parts addObject:@(argv[i])];
            cmdSend([parts componentsJoinedByString:@" "], 4.0);
        } else if ([cmd isEqualToString:@"pulse"]) {
            NSString *a = argc > 2 ? @(argv[2]) : @"66 0C 00";
            NSString *b = argc > 3 ? @(argv[3]) : @"66 0C 06";
            cmdPulse(a, b, argc > 4 ? atof(argv[4]) : 1.5, argc > 5 ? atoi(argv[5]) : 20);
        } else if ([cmd isEqualToString:@"scanapi"]) {
            int first = argc > 2 ? (int)strtol(argv[2], NULL, 0) : 0x00;
            int last  = argc > 3 ? (int)strtol(argv[3], NULL, 0) : 0x1F;
            double per = argc > 4 ? atof(argv[4]) : 0.4;
            cmdScanApi(first, last, per);
        } else if ([cmd isEqualToString:@"measure"]) {
            gMeasure = 1;
            gMeasureCm = (argc > 3) ? atof(argv[3]) : 20.0;
            cmdWatchDev(argc > 2 ? atof(argv[2]) : 300.0);
        } else if ([cmd isEqualToString:@"watchdev"]) {
            gButtonsOnly = 0;
            cmdWatchDev(argc > 2 ? atof(argv[2]) : 60.0);
        } else if ([cmd isEqualToString:@"watchdevall"]) {
            gButtonsOnly = 1;
            cmdWatchDev(argc > 2 ? atof(argv[2]) : 60.0);
        } else if ([cmd isEqualToString:@"watchall"]) {
            gButtonsOnly = 1;
            cmdWatch(argc > 2 ? atof(argv[2]) : 60.0);
        } else if ([cmd isEqualToString:@"watch6"]) {
            gOnlyReportID = 6;
            cmdWatch(argc > 2 ? atof(argv[2]) : 60.0);
        } else if ([cmd isEqualToString:@"watch7"]) {
            gOnlyReportID = 7;
            cmdWatch(argc > 2 ? atof(argv[2]) : 60.0);
        } else if ([cmd isEqualToString:@"feature"]) {
            cmdFeature();
        } else {
            printf("usage: probe [all|list|watch [s]|watch6 [s]|watchdev [s]|measure [s] [cm]|send <hex…>|pulse <hexA> <hexB> [sec] [cycles]|scanapi [from] [to] [sec]|feature]\n");
        }
    }
    return 0;
}
