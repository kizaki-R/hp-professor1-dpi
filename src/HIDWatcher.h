// HIDWatcher.h — opens the mouse's HID interfaces and streams their raw reports.
#import <Foundation/Foundation.h>
#import <IOKit/hid/IOHIDLib.h>

typedef NS_ENUM(NSInteger, HIDAccessState) {
    HIDAccessGranted = 0,
    HIDAccessDenied,
    HIDAccessUnknown,
};

@interface HIDInterfaceInfo : NSObject
@property (nonatomic) NSUInteger index;
@property (nonatomic, copy) NSString *product;
@property (nonatomic, copy) NSString *transport;
@property (nonatomic) NSInteger usagePage;
@property (nonatomic) NSInteger usage;
@property (nonatomic) NSInteger maxInputReportSize;
@property (nonatomic) NSInteger maxOutputReportSize;
@property (nonatomic) BOOL vendorChannel;   // carries usage page 0xFF55 / usage 0x0202
@property (nonatomic, copy) NSString *reportDescriptorHex;
- (NSString *)summary;
@end

@interface HIDWatcher : NSObject

@property (nonatomic, copy) void (^reportHandler)(HIDInterfaceInfo *iface, uint32_t reportID, NSData *payload, NSDate *when);
@property (nonatomic, copy) void (^logHandler)(NSString *line);
@property (nonatomic, readonly) NSString *lastError;

- (HIDAccessState)accessState;
- (BOOL)requestAccess;
- (NSArray<HIDInterfaceInfo *> *)scan;
- (BOOL)startMonitoring;
- (void)stopMonitoring;
- (BOOL)isMonitoring;
- (NSArray<HIDInterfaceInfo *> *)interfaces;
- (BOOL)sendOutputReport:(NSData *)fullReport toInterface:(HIDInterfaceInfo *)iface error:(NSString **)error;

@end
