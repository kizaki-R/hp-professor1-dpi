// VendorChannel.h — HP Professor 1 (ROYUAN) vendor feature channel.
//
// Device specific by design: the app talks to the known mouse (VID 0x3151) that exposes a
// 64-byte vendor feature report (usage page 0xFFFF, usage 0x0002, report ID 0). The 2.4 GHz
// receiver relays to the mouse after 0xF6 <target>; wired mode answers directly.
//
//   packet: [0]=opcode [1..6]=params [7]=checksum (0xFF - sum 0..6) [8..63]=data
//   opcode 0xD4 → DPI table: [2]=active level, [3]=level count, [8..]=levels × u16 LE
//                             (then a second copy of the table)
//
// Generic discovery for other mice lives in the CLI tool `royuan auto`, not in the app.
#import <Foundation/Foundation.h>

typedef void (^VendorDPIHandler)(int levelCount, int activeIndex, NSArray<NSNumber *> *values);

@interface VendorChannel : NSObject

@property (nonatomic, copy) void (^logHandler)(NSString *line);
@property (nonatomic, copy, readonly) NSString *deviceName;
@property (nonatomic, readonly) uint8_t dpiOpcode;
@property (nonatomic, readonly) int relayTarget;      // -1 == direct (wired)

/// Find + open the mouse's vendor interface and verify it answers 0xD4.
- (BOOL)connectKnownDevice;
- (BOOL)isReady;

- (NSArray<NSNumber *> *)readDPITableWithCount:(int *)count active:(int *)active;
- (BOOL)setActiveDPIIndex:(int)index;

- (void)beginPollingWithInterval:(NSTimeInterval)interval handler:(VendorDPIHandler)handler;
- (void)stopPolling;
- (void)close;

@end
