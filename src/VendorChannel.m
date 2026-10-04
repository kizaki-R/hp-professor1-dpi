// VendorChannel.m — HP Professor 1 / ROYUAN vendor feature channel (device specific).
#import "VendorChannel.h"
#import <IOKit/hid/IOHIDLib.h>
#import <unistd.h>

static const int kVID = 0x3151;          // ROYUAN
static const int kPIDDongle = 0x4027;    // 2.4 GHz receiver / wired
static const uint8_t kDPIOpcode = 0xD4;  // returns the DPI table
static const int kRelayMouse = 5;        // receiver relay target id for the mouse

// Closing an IOHIDManager invalidates the IOHIDDevice handles it produced (even CFRetained
// ones), so keep it open for as long as the channel lives.
static NSMutableArray *gKeptManagers = nil;

@interface VendorChannel ()
@property (nonatomic) IOHIDDeviceRef device;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) dispatch_source_t timer;
@property (nonatomic) NSInteger idleTicks;
@property (nonatomic) BOOL haveLast;
@property (nonatomic) int lastActive;
@property (nonatomic) uint8_t dpiOpcode;
@property (nonatomic) int relayTarget;
@property (nonatomic, copy) VendorDPIHandler handler;
@end

@implementation VendorChannel

- (void)dealloc { [self close]; }

- (BOOL)isReady { return self.device != NULL; }

- (NSString *)deviceName {
    if (!self.device) return @"(未連線)";
    NSString *p = (__bridge NSString *)IOHIDDeviceGetProperty(self.device, CFSTR(kIOHIDProductKey));
    NSNumber *pid = (__bridge NSNumber *)IOHIDDeviceGetProperty(self.device, CFSTR(kIOHIDProductIDKey));
    return [NSString stringWithFormat:@"%@ %04X:%04X", p ?: @"?", kVID, pid.intValue];
}

// MARK: - transport

static uint8_t checksum7(const uint8_t *b) {
    uint8_t sum = 0;
    for (int i = 0; i <= 6; i++) sum += b[i];
    return (uint8_t)(0xFF - sum);
}

- (void)writePacket:(const uint8_t *)bytes {
    uint8_t pkt[64] = {0};
    memcpy(pkt, bytes, 64);
    pkt[7] = checksum7(pkt);
    IOHIDDeviceSetReport(self.device, kIOHIDReportTypeFeature, 0, pkt, 64);
}

- (void)readPacket:(uint8_t *)out {
    CFIndex len = 64;
    memset(out, 0, 64);
    IOHIDDeviceGetReport(self.device, kIOHIDReportTypeFeature, 0, out, &len);
}

- (void)receiverStatus:(uint8_t *)out {
    uint8_t pkt[64] = {0};
    pkt[0] = 0xF7;
    [self writePacket:pkt];
    [self readPacket:out];
}

// Wait for the receiver to accept a relay, send, wait for the relayed reply, release it.
- (void)relayExchange:(int)target command:(const uint8_t *)cmd reply:(uint8_t *)reply {
    for (int attempt = 0; attempt < 2; attempt++) {
        uint8_t st[64];
        for (int i = 0; i < 12; i++) {
            [self receiverStatus:st];
            if (st[5] == 1) break;
            usleep(15 * 1000);
        }
        uint8_t sel[64] = {0};
        sel[0] = 0xF6;
        sel[1] = (uint8_t)target;
        [self writePacket:sel];
        [self writePacket:cmd];
        for (int i = 0; i < 12; i++) {
            usleep(20 * 1000);
            [self receiverStatus:st];
            if (st[0] == 1) break;
        }
        uint8_t rel[64] = {0};
        rel[0] = 0xFC;
        [self writePacket:rel];
        [self readPacket:reply];
        if (reply[0] == cmd[0]) return;
        usleep(30 * 1000);
    }
}

- (void)sendCommand:(const uint8_t *)cmd reply:(uint8_t *)reply {
    if (self.relayTarget < 0) {
        [self writePacket:cmd];
        [self readPacket:reply];
    } else {
        [self relayExchange:self.relayTarget command:cmd reply:reply];
    }
}

// MARK: - connect

/// 0xD4 decoded with the known layout: [2]=active, [3]=levels, table of u16 LE at byte 8.
- (NSArray<NSNumber *> *)decodeKnownTable:(const uint8_t *)reply count:(int *)count active:(int *)active {
    if (reply[0] != kDPIOpcode) return nil;
    int levels = reply[3];
    int act = reply[2];
    if (levels < 1 || levels > 16 || act < 0 || act >= levels) return nil;
    NSMutableArray *vals = [NSMutableArray array];
    for (int i = 0; i < levels; i++) {
        int v = reply[8 + i * 2] | (reply[9 + i * 2] << 8);
        if (v < 100 || v > 30000) return nil;
        if (vals.count && v <= [vals.lastObject intValue]) return nil;
        [vals addObject:@(v)];
    }
    if (count) *count = levels;
    if (active) *active = act;
    return vals;
}

- (void)keepManager:(IOHIDManagerRef)m {
    IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    if (!gKeptManagers) gKeptManagers = [NSMutableArray array];
    [gKeptManagers addObject:(__bridge id)m];
    CFRelease(m);
}

- (BOOL)connectKnownDevice {
    [self close];

    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *matches = @[ @{ (__bridge NSString *)CFSTR(kIOHIDDeviceUsagePageKey): @(0xFFFF),
                             (__bridge NSString *)CFSTR(kIOHIDDeviceUsageKey): @(0x0002) },
                          @{ (__bridge NSString *)CFSTR(kIOHIDVendorIDKey): @(kVID) } ];
    IOHIDManagerSetDeviceMatchingMultiple(m, (__bridge CFArrayRef)matches);
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.8, false);

    IOHIDDeviceRef candidate = NULL;
    NSSet *set = (__bridge_transfer NSSet *)IOHIDManagerCopyDevices(m);
    for (id boxed in set.allObjects) {
        IOHIDDeviceRef dev = (__bridge IOHIDDeviceRef)boxed;
        NSNumber *feat = (__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDMaxFeatureReportSizeKey));
        NSNumber *vid = (__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDVendorIDKey));
        NSNumber *pid = (__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductIDKey));
        if (feat.integerValue < 32 || vid.intValue != kVID) continue;
        if (pid.intValue == kPIDDongle || candidate == NULL) candidate = dev;
    }
    if (!candidate) {
        if (self.logHandler) self.logHandler(@"找不到 HP Professor 1 的原廠介面（滑鼠要在 2.4G / 有線模式）");
        [self keepManager:m];
        return NO;
    }
    if (IOHIDDeviceOpen(candidate, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
        if (self.logHandler) self.logHandler(@"原廠介面開啟失敗");
        [self keepManager:m];
        return NO;
    }
    self.device = (IOHIDDeviceRef)CFRetain(candidate);
    [self keepManager:m];

    // the receiver relays to the mouse; wired mode answers directly
    self.dpiOpcode = kDPIOpcode;
    int targets[] = {kRelayMouse, -1};
    for (unsigned i = 0; i < sizeof(targets) / sizeof(targets[0]); i++) {
        self.relayTarget = targets[i];
        uint8_t cmd[64] = {0}, reply[64];
        cmd[0] = kDPIOpcode;
        [self sendCommand:cmd reply:reply];
        NSArray *vals = [self decodeKnownTable:reply count:NULL active:NULL];
        if (vals) {
            if (self.logHandler) {
                self.logHandler([NSString stringWithFormat:@"✔ 原廠通道已連上：%@（DPI 0x%02X，%@，%lu 段）",
                                 self.deviceName, self.dpiOpcode,
                                 self.relayTarget < 0 ? @"直接" : @"接收器中繼",
                                 (unsigned long)vals.count]);
            }
            return YES;
        }
    }
    if (self.logHandler) self.logHandler(@"原廠介面有回應，但 DPI 表讀取失敗（滑鼠可能睡著，稍後自動重試）");
    [self close];
    return NO;
}

// MARK: - DPI table

- (NSArray<NSNumber *> *)readDPITableWithCount:(int *)count active:(int *)active {
    if (!self.device) return nil;
    uint8_t cmd[64] = {0}, reply[64];
    cmd[0] = self.dpiOpcode ?: kDPIOpcode;
    [self sendCommand:cmd reply:reply];
    return [self decodeKnownTable:reply count:count active:active];
}

- (BOOL)setActiveDPIIndex:(int)index {
    if (!self.device) return NO;
    uint8_t cmd[64] = {0}, reply[64] = {0};
    cmd[0] = 0x54; // SET opcode for 0xD4 (GET = SET | 0x80)
    cmd[1] = 0x00;
    cmd[2] = (uint8_t)index;
    cmd[3] = 0x07; // 7 levels
    [self sendCommand:cmd reply:reply];
    self.lastActive = index;
    return YES;
}

// MARK: - polling

// Own serial queue (the ~150 ms exchange must not block the UI); it speeds up for a moment
// after every change so quick button presses are not missed.
- (void)beginPollingWithInterval:(NSTimeInterval)interval handler:(VendorDPIHandler)handler {
    [self stopPolling];
    self.handler = handler;
    self.haveLast = NO;
    self.idleTicks = 99;
    if (!self.queue) self.queue = dispatch_queue_create("com.kizakiworks.dpipeek.vendor", DISPATCH_QUEUE_SERIAL);

    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    uint64_t nano = (uint64_t)(interval * NSEC_PER_SEC);
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, nano), nano, 20ull * NSEC_PER_MSEC);
    __weak VendorChannel *weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{ [weakSelf pollFromQueue]; });
    dispatch_resume(self.timer);
}

- (void)stopPolling {
    if (self.timer) {
        dispatch_source_cancel(self.timer);
        self.timer = nil;
    }
    self.handler = nil;
}

- (void)pollFromQueue {
    if (!self.device || !self.handler) return;
    if (self.idleTicks >= 3) {                  // idle: only every third tick
        self.idleTicks++;
        if (self.idleTicks % 3 != 0) return;
    }
    int count = 0, active = -1;
    NSArray<NSNumber *> *values = [self readDPITableWithCount:&count active:&active];
    if (!values) return;
    BOOL changed = (!self.haveLast || active != self.lastActive);
    self.lastActive = active;
    self.haveLast = YES;
    if (changed) {
        self.idleTicks = 0;                     // burst mode for the next few ticks
        VendorDPIHandler handler = self.handler;
        dispatch_async(dispatch_get_main_queue(), ^{ handler(count, active, values); });
    } else {
        self.idleTicks++;
    }
}

- (void)close {
    [self stopPolling];
    if (self.device) {
        IOHIDDeviceClose(self.device, kIOHIDOptionsTypeNone);
        CFRelease(self.device);
        self.device = NULL;
    }
}

@end
