// BLEBatteryReader.h — reads GATT Battery Service (0x180F / 0x2A19) for Professor 1 in Bluetooth mode.
#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>

@interface BLEBatteryReader : NSObject

@property (nonatomic, readonly) int batteryPercent; // -1 when unknown
@property (nonatomic, copy) void (^batteryUpdateHandler)(int percent);

- (void)start;
- (void)stop;
- (void)refresh;

@end
