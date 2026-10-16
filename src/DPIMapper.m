// DPIMapper.m
#import "DPIMapper.h"
#import "Localization.h"

static NSString *const kPresetsKey = @"HPProfessor1DPI.presets.v2";
static NSString *const kLegacyPresetsKey = @"DPIPeek.presets.v2";   // pre-1.1 name; read as a fallback
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
        // Settings written by a pre-1.1 build. Only the two keys are renamed, so
        // reading through to the old one is cheaper than making people re-enter
        // their measured table.
        saved = [NSUserDefaults.standardUserDefaults arrayForKey:kLegacyPresetsKey];
    }
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
    return [Localization.shared hudTitleForStep:step preset:v];
}

- (NSString *)hudSubtitleForStep:(NSInteger)step {
    if (step < 0) return @"";
    return [Localization.shared hudSubtitleForStep:step total:kStepCount];
}

@end
