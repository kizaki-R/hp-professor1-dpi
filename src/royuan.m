// royuan.m — ROYUAN-family vendor HID protocol tool + generic auto-discovery.
//
// Transport (reverse engineered on an HP Professor 1 / ROYUAN mouse, 2026-10-04):
//   64-byte HID feature reports, report ID 0, on a vendor collection (usage page 0xFFFF, usage 2).
//   Packet: [0]=opcode, [1..6]=params, [7]=checksum (0xFF - sum of bytes 0..6), [8..63]=data.
//   GET opcodes are SET | 0x80 and echo the opcode in byte 0.
//   A 2.4 GHz receiver answers its own opcodes and relays everything else:
//     poll 0xF7 (status) -> 0xF6 <target> -> the command -> poll 0xF7 until byte0==1 -> 0xFC -> read.
//
// Device specific: opcode 0xD4 returns the DPI table:
//     [2]=active level, [3]=level count, [8..]=level count u16 LE values (+ a second copy).
//
// Usage:
//   royuan auto [--wide]        generic discovery over every HID device (start here)
//   royuan id | status | get | watchdpi [s] | probe <hex…> | raw <hex…> | scan [from] [to]
//
// Build: clang -fobjc-arc -o royuan src/royuan.m -framework Foundation -framework IOKit

#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <unistd.h>
#import <math.h>

static const int kVID = 0x3151;
static IOHIDDeviceRef gDev = NULL;
static int gRelayTarget = -1;          // -1 = talk to the device directly

// MARK: - small helpers

static int propInt(IOHIDDeviceRef d, CFStringRef k) {
    id v = (__bridge id)IOHIDDeviceGetProperty(d, k);
    return [v respondsToSelector:@selector(intValue)] ? [v intValue] : -1;
}
static NSString *propStr(IOHIDDeviceRef d, CFStringRef k) {
    return (__bridge NSString *)IOHIDDeviceGetProperty(d, k);
}
static NSString *hexBytes(const uint8_t *b, size_t n) {
    NSMutableArray *p = [NSMutableArray array];
    for (size_t i = 0; i < n; i++) [p addObject:[NSString stringWithFormat:@"%02X", b[i]]];
    return [p componentsJoinedByString:@" "];
}
static size_t parseHex(NSString *s, uint8_t *out, size_t max) {
    NSMutableString *c = [NSMutableString string];
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar ch = [s characterAtIndex:i];
        if ([hexSet characterIsMember:ch]) [c appendFormat:@"%C", ch];
    }
    size_t n = 0;
    for (NSUInteger i = 0; i + 1 < c.length && n < max; i += 2) {
        unsigned int v = 0;
        [[NSScanner scannerWithString:[c substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&v];
        out[n++] = (uint8_t)v;
    }
    return n;
}
static uint8_t checksum7(const uint8_t *b) {
    uint8_t s = 0;
    for (int i = 0; i <= 6; i++) s += b[i];
    return (uint8_t)(0xFF - s);
}

// MARK: - transport

static NSArray *candidateDevices(void) {
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatching(m, NULL);
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.5, false);
    NSSet *set = (__bridge_transfer NSSet *)IOHIDManagerCopyDevices(m);
    NSMutableArray *out = [NSMutableArray array];
    for (id d in set.allObjects) {
        IOHIDDeviceRef dev = (__bridge IOHIDDeviceRef)d;
        int feat = propInt(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey));
        BOOL vendor = NO;
        NSArray *pairs = (__bridge NSArray *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDDeviceUsagePairsKey));
        for (NSDictionary *p in pairs) {
            if ([p[(__bridge NSString *)CFSTR(kIOHIDDeviceUsagePageKey)] intValue] >= 0xFF00) vendor = YES;
        }
        if (feat >= 32 || vendor) [out addObject:(__bridge id)dev];
    }
    IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRelease(m);
    return out;
}

static BOOL openDevice(IOHIDDeviceRef dev) {
    if (gDev) { IOHIDDeviceClose(gDev, kIOHIDOptionsTypeNone); CFRelease(gDev); gDev = NULL; }
    if (IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone) != kIOReturnSuccess) return NO;
    gDev = (IOHIDDeviceRef)CFRetain(dev);
    gRelayTarget = -1;
    return YES;
}

static void writePacket(const uint8_t *bytes, BOOL checksum) {
    uint8_t pkt[64] = {0};
    memcpy(pkt, bytes, 64);
    if (checksum) pkt[7] = checksum7(pkt);
    IOHIDDeviceSetReport(gDev, kIOHIDReportTypeFeature, 0, pkt, 64);
}
static void readPacket(uint8_t *out) {
    CFIndex len = 64;
    memset(out, 0, 64);
    IOHIDDeviceGetReport(gDev, kIOHIDReportTypeFeature, 0, out, &len);
}

static void receiverStatus(uint8_t *out) {
    uint8_t pkt[64] = {0};
    pkt[0] = 0xF7;
    writePacket(pkt, YES);
    readPacket(out);
}

static void relayExchange(int target, const uint8_t *cmd, uint8_t *reply) {
    for (int attempt = 0; attempt < 2; attempt++) {
        uint8_t st[64];
        for (int i = 0; i < 12; i++) {
            receiverStatus(st);
            if (st[5] == 1) break;
            usleep(15 * 1000);
        }
        uint8_t sel[64] = {0};
        sel[0] = 0xF6;
        sel[1] = (uint8_t)target;
        writePacket(sel, YES);
        writePacket(cmd, YES);
        for (int i = 0; i < 12; i++) {
            usleep(20 * 1000);
            receiverStatus(st);
            if (st[0] == 1) break;
        }
        uint8_t rel[64] = {0};
        rel[0] = 0xFC;
        writePacket(rel, YES);
        readPacket(reply);
        if (reply[0] == cmd[0]) return;
        usleep(30 * 1000);
    }
}

/// Send one command through whatever path is currently selected.
static void sendCmd(const uint8_t *cmd, uint8_t *reply) {
    if (gRelayTarget < 0) {
        writePacket(cmd, YES);
        readPacket(reply);
    } else {
        relayExchange(gRelayTarget, cmd, reply);
    }
}

static BOOL identifyEchoes(void) {
    uint8_t cmd[64] = {0}, reply[64];
    cmd[0] = 0x8F;
    sendCmd(cmd, reply);
    return reply[0] == 0x8F;
}

/// Try direct talk, then every plausible relay target. YES when the family answers.
static BOOL findWorkingPath(void) {
    gRelayTarget = -1;
    if (identifyEchoes()) return YES;
    int targets[] = {5, 10, 13, 2, 1, 0};
    for (unsigned i = 0; i < sizeof(targets) / sizeof(targets[0]); i++) {
        gRelayTarget = targets[i];
        if (identifyEchoes()) return YES;
    }
    gRelayTarget = -1;
    return NO;
}

// MARK: - DPI table heuristics

/// Look for a run of >= 4 strictly increasing u16 LE values in the plausible DPI range.
static NSArray<NSNumber *> *findDPILikeRun(const uint8_t *reply, int *offsetOut) {
    for (int start = 4; start <= 40; start += 2) {
        NSMutableArray *run = [NSMutableArray array];
        int v0 = reply[start] | (reply[start + 1] << 8);
        if (v0 < 100 || v0 > 30000) continue;
        [run addObject:@(v0)];
        for (int i = start + 2; i + 1 < 64 && run.count < 16; i += 2) {
            int v = reply[i] | (reply[i + 1] << 8);
            if (v <= [run.lastObject intValue] || v > 30000) break;
            [run addObject:@(v)];
        }
        if (run.count >= 4) {
            if (offsetOut) *offsetOut = start;
            return run;
        }
    }
    return nil;
}

/// Read 0xD4 and describe it, using both the known layout and the generic finder.
static void reportDPITable(void) {
    uint8_t cmd[64] = {0}, reply[64];
    cmd[0] = 0xD4;
    sendCmd(cmd, reply);
    if (reply[0] != 0xD4) {
        printf("    op 0xD4: 無回應（byte0=%02X）\n", reply[0]);
        return;
    }
    printf("    op 0xD4: %s\n", hexBytes(reply, 24).UTF8String);
    int levels = reply[3], active = reply[2];
    if (levels > 0 && levels <= 16) {
        printf("      → 段數 %d，目前第 %d 段，數值：", levels, active + 1);
        for (int i = 0; i < levels; i++) printf("%d ", reply[8 + i * 2] | (reply[9 + i * 2] << 8));
        printf("\n");
    }
    int off = 0;
    NSArray<NSNumber *> *run = findDPILikeRun(reply, &off);
    if (run.count >= 4) {
        printf("      → 通用啟發式在 offset %d 找到遞增序列：", off);
        for (NSNumber *n in run) printf("%d ", n.intValue);
        printf("\n");
    }
}

// MARK: - commands

static void cmdAuto(BOOL wide) {
    NSArray *cands = candidateDevices();
    printf("掃描到 %lu 個可能有原廠通道的 HID 裝置\n\n", (unsigned long)cands.count);
    for (id boxed in cands) {
        IOHIDDeviceRef dev = (__bridge IOHIDDeviceRef)boxed;
        printf("── %s  %04X:%04X  feature=%d  page=0x%04X\n",
               (propStr(dev, CFSTR(kIOHIDProductKey)) ?: @"?").UTF8String,
               propInt(dev, CFSTR(kIOHIDVendorIDKey)), propInt(dev, CFSTR(kIOHIDProductIDKey)),
               propInt(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey)),
               propInt(dev, CFSTR(kIOHIDPrimaryUsagePageKey)));
        if (!openDevice(dev)) { printf("    無法開啟\n\n"); continue; }

        if (!findWorkingPath()) {
            printf("    identify(0x8F) 無回應 → 不屬於此協定家族（或裝置睡眠中）\n\n");
            continue;
        }
        printf("    ✔ 家族確認（%s，target=%d）\n", gRelayTarget < 0 ? "直接" : "接收器中繼", gRelayTarget);

        uint8_t id[64] = {0}, idr[64];
        id[0] = 0x8F;
        sendCmd(id, idr);
        printf("    identify: %s\n", hexBytes(idr, 12).UTF8String);

        uint8_t rev[64] = {0}, revr[64];
        rev[0] = 0x80;
        sendCmd(rev, revr);
        if (revr[0] == 0x80) printf("    韌體版本: 0x%04X\n", (revr[2] << 8) | revr[1]);

        reportDPITable();

        if (wide) {
            printf("    -- 掃描 0x80..0xFF（跳過 0xAC/0xAD/0xAE）--\n");
            for (int op = 0x80; op <= 0xFF; op++) {
                if (op == 0xAC || op == 0xAD || op == 0xAE) continue;
                uint8_t c[64] = {0}, r[64];
                c[0] = (uint8_t)op;
                sendCmd(c, r);
                if (r[0] != (uint8_t)op) continue;
                int off = 0;
                NSArray<NSNumber *> *run = findDPILikeRun(r, &off);
                BOOL nonZero = NO;
                for (int i = 1; i < 32; i++) if (r[i]) nonZero = YES;
                if (run.count >= 4) {
                    printf("      DPI-like @0x%02X offset %d:", op, off);
                    for (NSNumber *n in run) printf(" %d", n.intValue);
                    printf("\n");
                } else if (nonZero) {
                    printf("      op 0x%02X 有資料: %s\n", op, hexBytes(r, 20).UTF8String);
                }
            }
        }
        printf("\n");
    }
}

static void cmdGet(void) {
    uint8_t b[64];
    readPacket(b);
    printf("feature: %s\n", hexBytes(b, 24).UTF8String);
}

static void cmdStatus(void) {
    uint8_t b[64];
    receiverStatus(b);
    printf("status: %s\n", hexBytes(b, 16).UTF8String);
    printf("  滑鼠電量 ≈ %d%%   [4]=%d(0=在線)  [5]=%d(可中繼)  [6]=%d(目標)\n",
           b[2], b[4], b[5], b[6]);
}

static void cmdWatchDPI(double seconds) {
    uint8_t cmd[64] = {0};
    cmd[0] = 0xD4;
    uint8_t reply[64];
    int lastIdx = -1, lastCount = -1;
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while ([end timeIntervalSinceNow] > 0) {
        sendCmd(cmd, reply);
        int count = reply[3], idx = reply[2];
        int cur = reply[8 + idx * 2] | (reply[9 + idx * 2] << 8);
        if (idx != lastIdx || count != lastCount) {
            printf("levels=%d  active index=%d  ->  %d DPI   (table:", count, idx, cur);
            for (int i = 0; i < count; i++) printf(" %d", reply[8 + i * 2] | (reply[9 + i * 2] << 8));
            printf(")\n");
            fflush(stdout);
            lastIdx = idx;
            lastCount = count;
        }
        usleep(300 * 1000);
    }
    printf("watchdpi done\n");
}

static void cmdProbe(NSString *hex) {
    uint8_t c[64] = {0}, r[64];
    parseHex(hex, c, 64);
    sendCmd(c, r);
    printf("reply: %s\n", hexBytes(r, 64).UTF8String);
}

static void cmdRaw(NSString *hex, BOOL nock) {
    uint8_t pkt[64] = {0};
    parseHex(hex, pkt, 64);
    writePacket(pkt, !nock);
    uint8_t b[64];
    readPacket(b);
    printf("reply: %s\n", hexBytes(b, 32).UTF8String);
}

static void cmdScan(int from, int to) {
    uint8_t last[64] = {0};
    for (int op = from; op <= to; op++) {
        if (op == 0xAC || op == 0xAD || op == 0xAE) continue;
        uint8_t c[64] = {0}, r[64];
        c[0] = (uint8_t)op;
        sendCmd(c, r);
        BOOL same = (memcmp(r, last, 8) == 0);
        if (!same || r[0] == (uint8_t)op) {
            printf("op %02X -> %s%s\n", op, hexBytes(r, 20).UTF8String, same ? "  (unchanged)" : "");
            fflush(stdout);
        }
        memcpy(last, r, 64);
    }
    printf("scan %02X..%02X done\n", from, to);
}

// MARK: - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *cmd = argc > 1 ? @(argv[1]) : @"auto";

        if ([cmd isEqualToString:@"auto"]) {
            BOOL wide = NO;
            for (int i = 2; i < argc; i++) if (strcmp(argv[i], "--wide") == 0) wide = YES;
            cmdAuto(wide);
            return 0;
        }

        // the remaining commands target the known mouse/receiver
        NSArray *cands = candidateDevices();
        IOHIDDeviceRef target = NULL;
        for (id boxed in cands) {
            IOHIDDeviceRef dev = (__bridge IOHIDDeviceRef)boxed;
            if (propInt(dev, CFSTR(kIOHIDVendorIDKey)) == kVID &&
                propInt(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey)) >= 32) { target = dev; break; }
        }
        if (!target) { printf("找不到 %04X 的原廠 feature 介面（滑鼠要在 2.4G/有線模式）\n", kVID); return 1; }
        if (!openDevice(target)) { printf("裝置開啟失敗\n"); return 1; }
        printf("vendor interface: %s %04X:%04X (feature %d bytes)\n",
               (propStr(target, CFSTR(kIOHIDProductKey)) ?: @"?").UTF8String,
               propInt(target, CFSTR(kIOHIDVendorIDKey)), propInt(target, CFSTR(kIOHIDProductIDKey)),
               propInt(target, CFSTR(kIOHIDMaxFeatureReportSizeKey)));

        if (!findWorkingPath()) printf("(警告：identify 無回應，仍嘗試後續命令)\n");

        if ([cmd isEqualToString:@"get"]) cmdGet();
        else if ([cmd isEqualToString:@"status"]) cmdStatus();
        else if ([cmd isEqualToString:@"id"]) {
            uint8_t c[64] = {0}, r[64];
            c[0] = 0x8F;
            sendCmd(c, r);
            printf("identify: %s\n", hexBytes(r, 16).UTF8String);
        } else if ([cmd isEqualToString:@"watchdpi"]) {
            cmdWatchDPI(argc > 2 ? atof(argv[2]) : 60.0);
        } else if ([cmd isEqualToString:@"probe"]) {
            NSMutableArray *parts = [NSMutableArray array];
            for (int i = 2; i < argc; i++) [parts addObject:@(argv[i])];
            cmdProbe([parts componentsJoinedByString:@" "]);
        } else if ([cmd isEqualToString:@"raw"]) {
            NSMutableArray *parts = [NSMutableArray array];
            BOOL nock = NO;
            for (int i = 2; i < argc; i++) {
                if (strcmp(argv[i], "--nock") == 0) nock = YES; else [parts addObject:@(argv[i])];
            }
            cmdRaw([parts componentsJoinedByString:@" "], nock);
        } else if ([cmd isEqualToString:@"scan"]) {
            cmdScan(argc > 2 ? (int)strtol(argv[2], NULL, 0) : 0x80,
                    argc > 3 ? (int)strtol(argv[3], NULL, 0) : 0x9F);
        } else {
            printf("usage: royuan [auto [--wide]|id|status|get|watchdpi [s]|probe <hex…>|raw <hex…> [--nock]|scan [from] [to]]\n");
        }
    }
    return 0;
}
