// HIDWatcher.m — per-device HID monitoring.
//
// Opening each IOHIDDevice individually (instead of relying only on the manager level
// callback) matters for this Bluetooth mouse: after the link sleeps and comes back the
// manager-level stream goes silent, while device match/removal callbacks re-open it.
#import "HIDWatcher.h"
#import <IOKit/hidsystem/IOHIDLib.h>

static const int kTargetVendorID = 0x3151;   // ROYUAN / HP Professor 1
static const int kVendorUsagePage = 0xFF55;  // vendor-defined pipe
static const int kVendorUsage = 0x0202;

@implementation HIDInterfaceInfo
- (NSString *)summary {
    return [NSString stringWithFormat:@"%@ [%@] page=0x%04lX usage=0x%04lX in=%ld out=%ld%@",
            self.product, self.transport, (long)self.usagePage, (long)self.usage,
            (long)self.maxInputReportSize, (long)self.maxOutputReportSize,
            self.vendorChannel ? @"  ← vendor pipe" : @""];
}
@end

@interface HIDWatcher ()
@property (nonatomic) IOHIDManagerRef manager;
@property (nonatomic, strong) NSMutableArray<HIDInterfaceInfo *> *infos;
@property (nonatomic, strong) NSMutableArray<NSValue *> *devicePtrs;
@property (nonatomic, strong) NSMutableDictionary<NSValue *, NSValue *> *buffers;  // device -> malloc'd buffer
@property (nonatomic, copy) NSString *lastError;
- (void)attachDevice:(IOHIDDeviceRef)dev;
- (void)detachDevice:(IOHIDDeviceRef)dev;
@end

static HIDInterfaceInfo *describeDevice(IOHIDDeviceRef dev, NSUInteger index) {
    HIDInterfaceInfo *info = [HIDInterfaceInfo new];
    info.index = index;
    info.product = (__bridge NSString *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductKey)) ?: @"?";
    info.transport = (__bridge NSString *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDTransportKey)) ?: @"?";
    info.vendorID = (uint32_t)[(__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDVendorIDKey)) unsignedIntValue];
    info.productID = (uint32_t)[(__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDProductIDKey)) unsignedIntValue];
    info.usagePage = [(__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDPrimaryUsagePageKey)) integerValue];
    info.usage = [(__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDPrimaryUsageKey)) integerValue];
    info.maxInputReportSize = [(__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDMaxInputReportSizeKey)) integerValue];
    info.maxOutputReportSize = [(__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDMaxOutputReportSizeKey)) integerValue];

    NSArray *pairs = (__bridge NSArray *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDDeviceUsagePairsKey));
    for (NSDictionary *p in pairs) {
        NSInteger up = [p[(__bridge NSString *)CFSTR(kIOHIDDeviceUsagePageKey)] integerValue];
        NSInteger u = [p[(__bridge NSString *)CFSTR(kIOHIDDeviceUsageKey)] integerValue];
        if (up == kVendorUsagePage && u == kVendorUsage) info.vendorChannel = YES;
    }

    NSData *rd = (__bridge NSData *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDReportDescriptorKey));
    if (rd.length) {
        NSMutableArray *parts = [NSMutableArray array];
        const uint8_t *b = rd.bytes;
        for (NSUInteger i = 0; i < rd.length; i++) [parts addObject:[NSString stringWithFormat:@"%02X", b[i]]];
        info.reportDescriptorHex = [parts componentsJoinedByString:@" "];
    }
    return info;
}

static void deviceInputCallback(void *context, IOReturn result, void *sender,
                                IOHIDReportType type, uint32_t reportID,
                                uint8_t *report, CFIndex reportLength) {
    HIDWatcher *self = (__bridge HIDWatcher *)context;
    if (!self.reportHandler || reportLength <= 0) return;
    IOHIDDeviceRef dev = (IOHIDDeviceRef)sender;
    HIDInterfaceInfo *info = nil;
    NSUInteger idx = 0;
    for (NSValue *v in self.devicePtrs) {
        if (v.pointerValue == (void *)dev) { info = idx < self.infos.count ? self.infos[idx] : nil; break; }
        idx++;
    }
    const uint8_t *bytes = report;
    CFIndex len = reportLength;
    if (reportID != 0 && len > 0 && bytes[0] == reportID) { bytes++; len--; }   // strip report id
    NSData *payload = [NSData dataWithBytes:bytes length:(NSUInteger)MAX(len, 0)];
    self.reportHandler(info, reportID, payload, [NSDate date]);
}

static void deviceMatchedCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    HIDWatcher *self = (__bridge HIDWatcher *)context;
    [self attachDevice:device];
}

static void deviceRemovedCallback(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    HIDWatcher *self = (__bridge HIDWatcher *)context;
    [self detachDevice:device];
}

@implementation HIDWatcher

- (instancetype)init {
    self = [super init];
    if (self) {
        _infos = [NSMutableArray array];
        _devicePtrs = [NSMutableArray array];
        _buffers = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc { [self stopMonitoring]; }

- (NSArray *)matchingDictionaries {
    return @[
        @{ (__bridge NSString *)CFSTR(kIOHIDVendorIDKey): @(kTargetVendorID) },
        @{ (__bridge NSString *)CFSTR(kIOHIDDeviceUsagePageKey): @(kVendorUsagePage),
           (__bridge NSString *)CFSTR(kIOHIDDeviceUsageKey): @(kVendorUsage) },
    ];
}

- (HIDAccessState)accessState {
    IOHIDAccessType t = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);
    if (t == kIOHIDAccessTypeGranted) return HIDAccessGranted;
    if (t == kIOHIDAccessTypeDenied) return HIDAccessDenied;
    return HIDAccessUnknown;
}

- (BOOL)requestAccess {
    return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) ? YES : NO;
}

- (NSArray<HIDInterfaceInfo *> *)scan {
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatchingMultiple(m, (__bridge CFArrayRef)[self matchingDictionaries]);
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    NSMutableArray *result = [NSMutableArray array];
    for (int attempt = 0; attempt < 3; attempt++) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        NSSet *set = (__bridge_transfer NSSet *)IOHIDManagerCopyDevices(m);
        [result removeAllObjects];
        NSUInteger i = 0;
        for (id d in set.allObjects) [result addObject:describeDevice((__bridge IOHIDDeviceRef)d, i++)];
        if (result.count) break;
    }
    IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFRelease(m);
    return result;
}

- (BOOL)startMonitoring {
    if (self.manager) return YES;
    IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatchingMultiple(m, (__bridge CFArrayRef)[self matchingDictionaries]);
    IOHIDManagerRegisterDeviceMatchingCallback(m, deviceMatchedCallback, (__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(m, deviceRemovedCallback, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOReturn r = IOHIDManagerOpen(m, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        self.lastError = [NSString stringWithFormat:@"IOHIDManagerOpen 失敗 (0x%08X)%@", r,
                          (r == kIOReturnNotPermitted) ? @" — 需要「輸入監控」權限" : @""];
        IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(m);
        return NO;
    }
    self.manager = m;
    // pick up devices that matched before the callbacks were registered
    NSSet *existing = (__bridge_transfer NSSet *)IOHIDManagerCopyDevices(m);
    for (id d in existing.allObjects) [self attachDevice:(__bridge IOHIDDeviceRef)d];
    return YES;
}

- (void)attachDevice:(IOHIDDeviceRef)dev {
    // the 64-byte 0xFFFF feature interface is the vendor API channel, handled by VendorChannel
    NSNumber *page = (__bridge NSNumber *)IOHIDDeviceGetProperty(dev, CFSTR(kIOHIDPrimaryUsagePageKey));
    if (page.integerValue == 0xFFFF) return;
    NSValue *key = [NSValue valueWithPointer:dev];
    for (NSValue *v in self.devicePtrs) if ([v isEqual:key]) return;   // already attached

    HIDInterfaceInfo *info = describeDevice(dev, self.infos.count);
    [self.infos addObject:info];
    [self.devicePtrs addObject:key];

    size_t len = (size_t)MAX(info.maxInputReportSize, 64) + 1;
    uint8_t *buf = calloc(1, len);
    self.buffers[key] = [NSValue valueWithPointer:buf];
    IOHIDDeviceRegisterInputReportCallback(dev, buf, (CFIndex)len, deviceInputCallback, (__bridge void *)self);

    IOReturn r = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    if (r == kIOReturnSuccess) {
        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        if (self.logHandler) self.logHandler([NSString stringWithFormat:@"已連上介面 #%lu %@", (unsigned long)info.index, [info summary]]);
    } else {
        if (self.logHandler) self.logHandler([NSString stringWithFormat:@"介面 #%lu 開啟失敗 (0x%08X)", (unsigned long)info.index, r]);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.interfaceChangedHandler) self.interfaceChangedHandler();
    });
}

- (void)detachDevice:(IOHIDDeviceRef)dev {
    NSValue *key = [NSValue valueWithPointer:dev];
    NSUInteger idx = [self.devicePtrs indexOfObject:key];
    if (idx == NSNotFound) return;
    IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
    if (self.logHandler) self.logHandler([NSString stringWithFormat:@"介面 #%lu 已斷開（滑鼠睡眠或重連）", (unsigned long)idx]);
    [self.buffers removeObjectForKey:key];
    [self.devicePtrs removeObjectAtIndex:idx];
    [self.infos removeObjectAtIndex:idx];
    for (NSUInteger i = 0; i < self.infos.count; i++) self.infos[i].index = i;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.interfaceChangedHandler) self.interfaceChangedHandler();
    });
}

- (void)stopMonitoring {
    if (!self.manager) return;
    NSSet *set = (__bridge_transfer NSSet *)IOHIDManagerCopyDevices(self.manager);
    for (id d in set.allObjects) {
        IOHIDDeviceRef dev = (__bridge IOHIDDeviceRef)d;
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
    }
    IOHIDManagerUnscheduleFromRunLoop(self.manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOHIDManagerClose(self.manager, kIOHIDOptionsTypeNone);
    CFRelease(self.manager);
    self.manager = NULL;
    [self.infos removeAllObjects];
    [self.devicePtrs removeAllObjects];
    [self.buffers removeAllObjects];
}

- (BOOL)isMonitoring { return self.manager != NULL; }
- (NSArray<HIDInterfaceInfo *> *)interfaces { return self.infos; }

- (BOOL)sendOutputReport:(NSData *)fullReport toInterface:(HIDInterfaceInfo *)iface error:(NSString **)error {
    if (!self.manager) { if (error) *error = @"尚未開始監看"; return NO; }
    if (fullReport.length < 2) { if (error) *error = @"封包太短"; return NO; }
    if (iface.index >= self.devicePtrs.count) { if (error) *error = @"介面不存在"; return NO; }
    IOHIDDeviceRef dev = (IOHIDDeviceRef)self.devicePtrs[iface.index].pointerValue;
    const uint8_t *b = fullReport.bytes;
    uint8_t reportID = b[0];
    IOReturn r = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, reportID, b + 1, (CFIndex)(fullReport.length - 1));
    if (r != kIOReturnSuccess) {
        if (error) *error = [NSString stringWithFormat:@"送出失敗 (0x%08X)", r];
        return NO;
    }
    return YES;
}

@end
