// DPIMapper.m
#import "DPIMapper.h"

static NSString *const kPresetsKey = @"DPIPeek.presets.v2";
static const NSInteger kStepCount = 7;

@implementation DPIMapper

- (instancetype)init {
    self = [super init];
    if (self) {
        _presets = [NSMutableArray array];
        for (NSInteger i = 0; i < kStepCount; i++) [_presets addObject:NSNull.null];
        _currentStep = -1;
    }
    return self;
}

+ (instancetype)loadFromDefaults {
    DPIMapper *m = [DPIMapper new];
    NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:kPresetsKey];
    if (saved.count == 0) {
        // factory table read from the mouse itself with vendor opcode 0xD4
        NSArray *factory = @[@800, @1000, @1200, @1600, @2400, @3200, @4000];
        for (NSInteger i = 0; i < (NSInteger)factory.count && i < kStepCount; i++) m.presets[i] = factory[i];
        return m;
    }
    for (NSInteger i = 0; i < (NSInteger)saved.count && i < kStepCount; i++) {
        id v = saved[i];
        if ([v isKindOfClass:NSNumber.class]) m.presets[i] = v;
    }
    return m;
}

- (void)save {
    [NSUserDefaults.standardUserDefaults setObject:self.presets forKey:kPresetsKey];
}

+ (NSInteger)stepFromVendorPayload:(NSData *)payload {
    const uint8_t *b = payload.bytes;
    if (payload.length < 3) return -1;
    if (b[0] != 0x66) return -1;
    if (b[1] != 0x0C) return -1;         // 0x0C == "DPI step" report
    NSInteger step = b[2];
    if (step < 0 || step >= kStepCount) return -1;
    return step;
}

- (NSInteger)stepCount { return kStepCount; }

- (void)setPreset:(NSNumber *)value forStep:(NSInteger)step {
    if (step < 0 || step >= kStepCount) return;
    self.presets[step] = value ?: NSNull.null;
}

- (NSNumber *)presetForStep:(NSInteger)step {
    if (step < 0 || step >= kStepCount) return nil;
    id v = self.presets[step];
    return [v isKindOfClass:NSNumber.class] ? v : nil;
}

- (NSString *)hudTitleForStep:(NSInteger)step {
    if (step < 0) return @"?";
    NSNumber *v = [self presetForStep:step];
    return v ? [NSString stringWithFormat:@"%@ DPI", v] : [NSString stringWithFormat:@"第 %ld 段", (long)(step + 1)];
}

- (NSString *)hudSubtitleForStep:(NSInteger)step {
    if (step < 0) return @"";
    NSNumber *v = [self presetForStep:step];
    if (v) return [NSString stringWithFormat:@"第 %ld / %ld 段", (long)(step + 1), (long)kStepCount];
    return [NSString stringWithFormat:@"%ld 段中的第 %ld 段 · 可在 DPI Peek 填入數值",
            (long)kStepCount, (long)(step + 1)];
}

@end
