// DPIMapper.h — decodes the HP Professor 1 vendor packets and holds the DPI table.
//
// Confirmed protocol (captured from the device, 2026-10-04):
//   every DPI-button press makes the mouse send HID report ID 6 whose payload starts
//       66 0C <step> 00 00 …         <step> = 0…6, the new DPI step (7 steps, wraps)
//       66 0F 01|00 00 …             trailing status flag, ignored
#import <Foundation/Foundation.h>

@interface DPIMapper : NSObject

/// 7 slots; each entry is an NSNumber (known DPI) or NSNull (not set yet).
@property (nonatomic, strong) NSMutableArray *presets;
@property (nonatomic) NSInteger currentStep;   // -1 == unknown

+ (instancetype)loadFromDefaults;
- (void)save;

/// Returns the DPI step (0-based) carried by a vendor payload, or -1 if this packet is not a DPI report.
+ (NSInteger)stepFromVendorPayload:(NSData *)payload;

- (void)setPreset:(nullable NSNumber *)value forStep:(NSInteger)step;
- (NSNumber *)presetForStep:(NSInteger)step;      // nil when unset
- (NSInteger)stepCount;

/// "1600 DPI" when known, otherwise "第 3 段".
- (NSString *)hudTitleForStep:(NSInteger)step;
- (NSString *)hudSubtitleForStep:(NSInteger)step;

@end
