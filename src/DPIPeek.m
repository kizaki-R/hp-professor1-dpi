// DPIPeek.m — menu-bar utility that shows the HP Professor 1's DPI setting on screen.
//
// The mouse reports its DPI step on a vendor HID collection (usage page 0xFF55 /
// usage 0x0202, report ID 6). Captured protocol:
//
//     66 0C <step> 00 00 …     one packet per DPI-button press, <step> = 0…6 (7 steps)
//     66 0F 01|00 00 …         trailing status flag — ignored
//
// So this app overlays a HUD with the new step every time the DPI button is pressed, and
// it can measure each step's real DPI from the raw sensor counts over a measured distance.
//
// Build: ./build.sh      Run: open DPIPeek.app      Test: DPIPeek --selftest

#import <Cocoa/Cocoa.h>
#import <float.h>
#import <math.h>
#import "HIDWatcher.h"
#import "DPIMapper.h"
#import "VendorChannel.h"

// MARK: - helpers

static NSString *hexString(NSData *data) {
    const uint8_t *b = data.bytes;
    NSMutableArray *parts = [NSMutableArray arrayWithCapacity:data.length];
    for (NSUInteger i = 0; i < data.length; i++) [parts addObject:[NSString stringWithFormat:@"%02X", b[i]]];
    return [parts componentsJoinedByString:@" "];
}

static NSString *timeString(NSDate *d) {
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSDateFormatter new];
        f.dateFormat = @"HH:mm:ss.SSS";
    });
    return [f stringFromDate:d];
}

// MARK: - HUD

@interface HUDWindow : NSPanel
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *subtitleLabel;
@property (nonatomic) NSUInteger token;
+ (instancetype)sharedHUD;
- (void)showTitle:(NSString *)title subtitle:(NSString *)subtitle;
@end

@implementation HUDWindow

+ (instancetype)sharedHUD {
    static HUDWindow *hud;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hud = [[HUDWindow alloc] init]; });
    return hud;
}

- (instancetype)init {
    self = [super initWithContentRect:NSMakeRect(0, 0, 340, 122)
                            styleMask:(NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel)
                              backing:NSBackingStoreBuffered
                                defer:NO];
    if (!self) return nil;
    self.opaque = NO;
    self.backgroundColor = NSColor.clearColor;
    self.hasShadow = YES;
    self.level = NSScreenSaverWindowLevel;
    self.ignoresMouseEvents = YES;
    self.collectionBehavior = (NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorStationary |
                               NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorIgnoresCycle);

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 340, 122)];
    container.wantsLayer = YES;
    container.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.07 alpha:0.88].CGColor;
    container.layer.cornerRadius = 22.0;
    container.layer.borderWidth = 1.0;
    container.layer.borderColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.16].CGColor;
    self.contentView = container;

    _titleLabel = [NSTextField labelWithString:@"第 1 段"];
    _titleLabel.frame = NSMakeRect(8, 52, 324, 48);
    _titleLabel.alignment = NSTextAlignmentCenter;
    _titleLabel.font = [NSFont systemFontOfSize:38 weight:NSFontWeightSemibold];
    _titleLabel.textColor = NSColor.whiteColor;
    [container addSubview:_titleLabel];

    _subtitleLabel = [NSTextField labelWithString:@""];
    _subtitleLabel.frame = NSMakeRect(8, 20, 324, 22);
    _subtitleLabel.alignment = NSTextAlignmentCenter;
    _subtitleLabel.font = [NSFont systemFontOfSize:13];
    _subtitleLabel.textColor = [NSColor colorWithCalibratedWhite:1.0 alpha:0.72];
    [container addSubview:_subtitleLabel];
    return self;
}

- (void)showTitle:(NSString *)title subtitle:(NSString *)subtitle {
    self.titleLabel.stringValue = title ?: @"";
    self.subtitleLabel.stringValue = subtitle ?: @"";

    NSPoint mouse = NSEvent.mouseLocation;
    NSScreen *screen = NSScreen.mainScreen;
    for (NSScreen *s in NSScreen.screens) {
        if (NSPointInRect(mouse, s.frame)) { screen = s; break; }
    }
    NSRect sf = screen.frame;
    NSRect wf = self.frame;
    wf.origin.x = NSMidX(sf) - wf.size.width / 2.0;
    wf.origin.y = NSMaxY(sf) - wf.size.height - 150.0;
    [self setFrame:wf display:NO];

    self.alphaValue = 1.0;
    [self orderFrontRegardless];

    self.token += 1;
    NSUInteger myToken = self.token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (myToken != self.token) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.4;
            self.animator.alphaValue = 0.0;
        } completionHandler:^{
            if (myToken == self.token) [self orderOut:nil];
        }];
    });
}

@end

// MARK: - App delegate

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSTextView *logView;
@property (nonatomic, strong) NSTextField *accessLabel;
@property (nonatomic, strong) NSTextField *deviceLabel;
@property (nonatomic, strong) NSTextField *measureLabel;
@property (nonatomic, strong) NSTextField *distanceField;
@property (nonatomic, strong) NSTextField *hexField;
@property (nonatomic, strong) NSButton *vendorOnlyCheck;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *presetFields;
@property (nonatomic, strong) HIDWatcher *watcher;
@property (nonatomic, strong) VendorChannel *vendor;
@property (nonatomic, strong) DPIMapper *mapper;
@property (nonatomic, strong) NSFileHandle *logFile;
@property (nonatomic, copy) NSString *logPath;
@property (nonatomic) NSInteger burstCount;
@property (nonatomic) NSTimeInterval burstSecond;
@property (nonatomic) BOOL measuring;
@property (nonatomic) double measureCounts;
@property (nonatomic, strong) NSData *lastVendorPayload;
@property (nonatomic) NSTimeInterval lastVendorTime;
@property (nonatomic) double measuredDPI;
@property (nonatomic, strong) id<NSObject> activity;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [self buildMenuBar];
    [self buildMainMenu];

    self.watcher = [HIDWatcher new];
    self.mapper = [DPIMapper loadFromDefaults];
    self.presetFields = [NSMutableArray array];
    __weak AppDelegate *weakSelf = self;
    self.watcher.reportHandler = ^(HIDInterfaceInfo *iface, uint32_t reportID, NSData *payload, NSDate *when) {
        [weakSelf handleReport:iface reportID:reportID payload:payload when:when];
    };
    self.watcher.logHandler = ^(NSString *line) {
        [weakSelf appendLog:line];
    };

    // keep the vendor polling timer alive while the app is in the background (App Nap would throttle it)
    self.activity = [NSProcessInfo.processInfo
                     beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                     reason:@"polling the mouse vendor channel for DPI changes"];

    [self openLogFile];
    [self buildWindow];
    [self refreshStatus];
    // macOS applies a fresh Input Monitoring grant without requiring a relaunch;
    // poll so monitoring starts the moment the switch is flipped.
    [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(permissionTick:) userInfo:nil repeats:YES];

    [self appendLog:@"DPI Peek 啟動。"];
    [self appendLog:[NSString stringWithFormat:@"記錄檔：%@", self.logPath]];
    for (HIDInterfaceInfo *i in [self.watcher scan]) {
        [self appendLog:[NSString stringWithFormat:@"找到介面 #%lu %@", (unsigned long)i.index, [i summary]]];
    }

    [self connectVendorChannel];
    [NSTimer scheduledTimerWithTimeInterval:10.0 target:self selector:@selector(vendorRetryTick:) userInfo:nil repeats:YES];

    HIDAccessState st = [self.watcher accessState];
    if (st == HIDAccessGranted) {
        [self appendLog:@"已有「輸入監控」權限，開始監看。"];
        [self startMonitoring:nil];
    } else {
        [self appendLog:@"尚未取得「輸入監控」權限。"];
        if (st == HIDAccessUnknown) {
            BOOL ok = [self.watcher requestAccess];
            [self appendLog:ok ? @"權限已授予。" : @"權限未授予；請到系統設定手動勾選後重新開啟本 App。"];
            if (ok) [self startMonitoring:nil];
        }
        [self refreshStatus];
        if ([self.watcher accessState] != HIDAccessGranted) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showPermissionAlert]; });
        }
    }
}

- (void)permissionTick:(NSTimer *)timer {
    (void)timer;
    if ([self.watcher accessState] == HIDAccessGranted && ![self.watcher isMonitoring]) {
        [self appendLog:@"✔ 權限已生效，開始監看。"];
        [self startMonitoring:nil];
    } else {
        [self refreshStatus];
    }
}

- (void)showPermissionAlert {
    NSAlert *a = [NSAlert new];
    a.messageText = @"DPI Peek 需要「輸入監控」權限";
    a.informativeText = @"macOS 規定：任何程式要讀取滑鼠的 HID 資料，都必須由你手動授權。\n\n"
                        @"1. 按下方「開啟系統設定」\n"
                        @"2. 到「隱私權與安全性 → 輸入監控」，把 DPIPeek 打開（沒有列出就按 + 加入本 App）\n"
                        @"3. 回來按「重新檢查權限」（若仍失敗，請結束 App 再重新開啟）";
    [a addButtonWithTitle:@"開啟系統設定"];
    [a addButtonWithTitle:@"重新檢查權限"];
    [a addButtonWithTitle:@"稍後"];
    NSModalResponse r = [a runModal];
    if (r == NSAlertFirstButtonReturn) {
        [self openPrivacySettings:nil];
    } else if (r == NSAlertSecondButtonReturn) {
        BOOL ok = [self.watcher requestAccess];
        [self appendLog:ok ? @"權限已授予，開始監看。" : @"權限仍未授予。"];
        [self refreshStatus];
        if (ok) [self startMonitoring:nil];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return NO;
}

- (void)applicationWillTerminate:(NSNotification *)note {
    (void)note;
    [self.watcher stopMonitoring];
    [self.vendor close];
    if (self.activity) [NSProcessInfo.processInfo endActivity:self.activity];
    [self.mapper save];
    [self.logFile closeFile];
}

// MARK: UI

- (void)buildMenuBar {
    NSMenu *menu = [NSMenu new];
    NSMenuItem *it;
    it = [menu addItemWithTitle:@"顯示主視窗" action:@selector(showWindow:) keyEquivalent:@""];
    it.target = self;
    it = [menu addItemWithTitle:@"開始監看" action:@selector(startMonitoring:) keyEquivalent:@""];
    it.target = self;
    it = [menu addItemWithTitle:@"停止監看" action:@selector(stopMonitoring:) keyEquivalent:@""];
    it.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    it = [menu addItemWithTitle:@"測試 HUD" action:@selector(testHUD:) keyEquivalent:@""];
    it.target = self;
    it = [menu addItemWithTitle:@"輸入監控設定…" action:@selector(openPrivacySettings:) keyEquivalent:@""];
    it.target = self;
    [menu addItem:NSMenuItem.separatorItem];
    it = [menu addItemWithTitle:@"結束" action:@selector(terminate:) keyEquivalent:@"q"];
    it.target = NSApp;

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"DPI";
    self.statusItem.button.toolTip = @"DPI Peek — 顯示 HP Professor 1 的 DPI";
    self.statusItem.menu = menu;
}

- (void)buildMainMenu {
    NSMenu *menubar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [menubar addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"關於 DPI Peek" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:@"結束 DPI Peek" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSApp.mainMenu = menubar;
}

- (NSButton *)button:(NSString *)title action:(SEL)action x:(CGFloat)x w:(CGFloat)w y:(CGFloat)y {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
    b.bezelStyle = NSBezelStyleRounded;
    b.frame = NSMakeRect(x, y, w, 28);
    return b;
}

- (NSTextField *)label:(NSString *)text x:(CGFloat)x w:(CGFloat)w y:(CGFloat)y size:(CGFloat)size bold:(BOOL)bold {
    NSTextField *l = [NSTextField labelWithString:text];
    l.frame = NSMakeRect(x, y, w, 18);
    l.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    return l;
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 620, 780);
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                         NSWindowStyleMaskMiniaturizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"DPI Peek — HP Professor 1";
    [self.window center];
    NSView *cv = self.window.contentView;

    self.accessLabel = [self label:@"權限狀態：檢查中…" x:12 w:596 y:748 size:13 bold:YES];
    [cv addSubview:self.accessLabel];

    self.deviceLabel = [self label:@"裝置：尚未監看" x:12 w:596 y:724 size:12 bold:NO];
    self.deviceLabel.textColor = NSColor.secondaryLabelColor;
    [cv addSubview:self.deviceLabel];

    [cv addSubview:[self button:@"要求輸入監控權限" action:@selector(requestAccess:) x:12 w:150 y:686]];
    [cv addSubview:[self button:@"開啟系統設定" action:@selector(openPrivacySettings:) x:170 w:124 y:686]];
    [cv addSubview:[self button:@"開始監看" action:@selector(startMonitoring:) x:302 w:90 y:686]];
    [cv addSubview:[self button:@"停止" action:@selector(stopMonitoring:) x:400 w:60 y:686]];
    [cv addSubview:[self button:@"重新掃描" action:@selector(rescan:) x:468 w:90 y:686]];

    [cv addSubview:[self button:@"清除記錄" action:@selector(clearLog:) x:12 w:90 y:650]];
    [cv addSubview:[self button:@"開啟記錄資料夾" action:@selector(openLogFolder:) x:110 w:140 y:650]];
    [cv addSubview:[self button:@"讀取滑鼠 DPI 表" action:@selector(readVendorTable:) x:258 w:150 y:650]];
    [cv addSubview:[self button:@"重連原廠通道" action:@selector(redetectPressed:) x:416 w:120 y:650]];

    self.vendorOnlyCheck = [NSButton checkboxWithTitle:@"只記錄廠商通道 (Report ID 6)" target:nil action:nil];
    self.vendorOnlyCheck.frame = NSMakeRect(430, 654, 180, 20);
    self.vendorOnlyCheck.state = NSControlStateValueOn;
    [cv addSubview:self.vendorOnlyCheck];

    [cv addSubview:[self label:@"DPI 段數（共 7 段，留空 = 未設定）：" x:12 w:300 y:616 size:12 bold:NO]];
    for (NSInteger i = 0; i < [self.mapper stepCount]; i++) {
        NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(236 + i * 52, 612, 46, 24)];
        f.alignment = NSTextAlignmentCenter;
        f.placeholderString = [NSString stringWithFormat:@"%ld", (long)(i + 1)];
        NSNumber *v = [self.mapper presetForStep:i];
        if (v) f.stringValue = v.stringValue;
        f.tag = i;
        f.target = self;
        f.action = @selector(presetFieldChanged:);
        [cv addSubview:f];
        [self.presetFields addObject:f];
    }

    [cv addSubview:[self label:@"實測 DPI：移動" x:12 w:130 y:578 size:12 bold:NO]];
    self.distanceField = [[NSTextField alloc] initWithFrame:NSMakeRect(142, 574, 50, 24)];
    self.distanceField.stringValue = @"10";
    [cv addSubview:self.distanceField];
    [cv addSubview:[self label:@"cm" x:196 w:24 y:578 size:12 bold:NO]];
    [cv addSubview:[self button:@"開始量測" action:@selector(startMeasure:) x:226 w:90 y:572]];
    [cv addSubview:[self button:@"套用到目前段" action:@selector(applyMeasure:) x:322 w:130 y:572]];
    self.measureLabel = [self label:@"（按 DPI 鍵選段 → 沿尺水平移動）" x:462 w:150 y:578 size:11 bold:NO];
    self.measureLabel.textColor = NSColor.secondaryLabelColor;
    [cv addSubview:self.measureLabel];

    [cv addSubview:[self label:@"自訂封包 (hex)：" x:12 w:110 y:540 size:12 bold:NO]];
    self.hexField = [[NSTextField alloc] initWithFrame:NSMakeRect(126, 536, 360, 24)];
    self.hexField.placeholderString = @"06 00 00 …（第一 byte 是 Report ID）";
    [cv addSubview:self.hexField];
    [cv addSubview:[self button:@"送出" action:@selector(sendHex:) x:494 w:82 y:534]];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 12, 596, 512)];
    sv.hasVerticalScroller = YES;
    sv.borderType = NSBezelBorder;
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:sv.bounds];
    tv.editable = NO;
    tv.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    tv.autoresizingMask = NSViewWidthSizable;
    tv.verticallyResizable = YES;
    tv.horizontallyResizable = NO;
    tv.textContainer.widthTracksTextView = YES;
    tv.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    sv.documentView = tv;
    self.logView = tv;
    [cv addSubview:sv];

    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)refreshStatus {
    HIDAccessState st = self.watcher.accessState;
    NSString *text;
    NSColor *color = NSColor.labelColor;
    switch (st) {
        case HIDAccessGranted: text = @"權限狀態：已授予「輸入監控」✔"; break;
        case HIDAccessDenied:  text = @"權限狀態：被拒絕 ✘（系統設定 → 隱私權與安全性 → 輸入監控 → 勾選 DPIPeek，再重新開啟 App）";
                               color = NSColor.systemRedColor; break;
        default:               text = @"權限狀態：尚未決定（按「要求輸入監控權限」）"; break;
    }
    self.accessLabel.stringValue = text;
    self.accessLabel.textColor = color;

    if (self.watcher.isMonitoring) {
        NSArray *ifs = self.watcher.interfaces;
        NSMutableArray *names = [NSMutableArray array];
        for (HIDInterfaceInfo *i in ifs) [names addObject:[NSString stringWithFormat:@"#%lu %@", (unsigned long)i.index, i.product]];
        NSString *extra = self.vendor.isReady
            ? [NSString stringWithFormat:@"  ｜ 原廠通道：%s（DPI 0x%02X）",
               self.vendor.deviceName.UTF8String, self.vendor.dpiOpcode]
            : @"  ｜ 原廠通道：未連上";
        self.deviceLabel.stringValue = [NSString stringWithFormat:@"裝置：監看中 — %@%@",
                                        names.count ? [names componentsJoinedByString:@", "] : @"(等待滑鼠連線)", extra];
    } else {
        self.deviceLabel.stringValue = @"裝置：未監看";
    }
}

// MARK: logging

- (void)openLogFile {
    NSString *base = [[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent];
    NSString *dir = [base stringByAppendingPathComponent:@"logs"];
    if (![NSFileManager.defaultManager isWritableFileAtPath:base]) {
        // installed in /Applications: keep logs in ~/Library/Logs/DPIPeek instead
        dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/DPIPeek"];
    }
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    self.logPath = [dir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"dpipeek-%@.log", [f stringFromDate:NSDate.date]]];
    [NSFileManager.defaultManager createFileAtPath:self.logPath contents:nil attributes:nil];
    self.logFile = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
}

- (void)appendLog:(NSString *)line {
    void (^work)(void) = ^{
        NSAttributedString *attr = [[NSAttributedString alloc] initWithString:line attributes:@{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: NSColor.labelColor,
        }];
        NSTextStorage *storage = self.logView.textStorage;
        [storage appendAttributedString:attr];
        [storage appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
        if (storage.length > 200000) [storage deleteCharactersInRange:NSMakeRange(0, storage.length - 150000)];
        [self.logView scrollRangeToVisible:NSMakeRange(storage.length, 0)];
        NSData *lineData = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        [self.logFile writeData:lineData];
        [self.logFile synchronizeFile];
    };
    if (NSThread.isMainThread) work(); else dispatch_async(dispatch_get_main_queue(), work);
}

// MARK: vendor API

- (void)connectVendorChannel {
    __weak AppDelegate *weakSelf = self;
    if (self.vendor.isReady) {
        [self refreshStatus];
        return;
    }
    self.vendor = self.vendor ?: [VendorChannel new];
    self.vendor.logHandler = ^(NSString *line) { [weakSelf appendLog:line]; };
    if (![self.vendor connectKnownDevice]) {
        [self refreshStatus];
        return;
    }
    [self.vendor beginPollingWithInterval:0.15 handler:^(int count, int active, NSArray<NSNumber *> *values) {
        [weakSelf handleVendorDPIWithCount:count active:active values:values];
    }];
    [self refreshStatus];
}

- (void)vendorRetryTick:(NSTimer *)timer {
    (void)timer;
    if (!self.vendor.isReady) [self connectVendorChannel];
}

- (void)syncPresetFields {
    for (NSInteger i = 0; i < (NSInteger)self.presetFields.count; i++) {
        NSNumber *v = [self.mapper presetForStep:i];
        self.presetFields[i].stringValue = v ? v.stringValue : @"";
    }
}

- (void)handleVendorDPIWithCount:(int)count active:(int)active values:(NSArray<NSNumber *> *)values {
    BOOL tableChanged = NO;
    if (values.count && (NSInteger)values.count == [self.mapper stepCount]) {
        for (NSInteger i = 0; i < (NSInteger)values.count; i++) {
            NSNumber *cur = [self.mapper presetForStep:i];
            if (![cur isEqualToNumber:values[i]]) {
                [self.mapper setPreset:values[i] forStep:i];
                tableChanged = YES;
            }
        }
    }
    if (tableChanged) {
        [self.mapper save];
        [self syncPresetFields];
        NSMutableArray *parts = [NSMutableArray array];
        for (NSNumber *n in values) [parts addObject:n.stringValue];
        [self appendLog:[NSString stringWithFormat:@"從滑鼠讀到 DPI 表（%d 段）：%@", count,
                         [parts componentsJoinedByString:@" / "]]];
    }
    self.mapper.currentStep = active;
    NSString *title = [self.mapper hudTitleForStep:active];
    [HUDWindow.sharedHUD showTitle:title subtitle:[self.mapper hudSubtitleForStep:active]];
    [self appendLog:[NSString stringWithFormat:@"%@ [2.4G 原廠API] 第 %d 段 → %@",
                     timeString(NSDate.date), active + 1, title]];
}

- (void)redetectPressed:(id)sender {
    (void)sender;
    [self.vendor close];
    [self connectVendorChannel];
}

- (void)readVendorTable:(id)sender {
    (void)sender;
    if (!self.vendor.isReady) {
        [self appendLog:@"尚未連上原廠通道，嘗試連線…"];
        [self connectVendorChannel];
    }
    if (!self.vendor.isReady) {
        [self appendLog:@"✘ 找不到 HP Professor 1 的原廠通道：請切到 2.4G / 有線模式，或動一下滑鼠喚醒。"];
        return;
    }
    int count = 0, active = -1;
    NSArray<NSNumber *> *values = [self.vendor readDPITableWithCount:&count active:&active];
    if (!values) { [self appendLog:@"✘ 讀取失敗（滑鼠可能睡著了，動一下再試）。"]; return; }
    [self handleVendorDPIWithCount:count active:active values:values];
}

// MARK: HID handling

- (void)handleReport:(HIDInterfaceInfo *)iface reportID:(uint32_t)reportID payload:(NSData *)payload when:(NSDate *)when {
    NSData *copy = [payload copy];
    uint32_t rid = reportID;
    NSString *ifaceName = iface.product ?: @"?";
    NSTimeInterval ts = when.timeIntervalSince1970;

    if (rid == 5 || rid == 0) {                      // raw mouse report (BLE id 5 / dongle id 0)
        if (self.measuring && copy.length >= 5) {
            const uint8_t *b = copy.bytes;
            int16_t dx = (int16_t)(b[1] | (b[2] << 8));
            int16_t dy = (int16_t)(b[3] | (b[4] << 8));
            double step = hypot((double)dx, (double)dy);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.measureCounts += step;
                self.measureLabel.stringValue = [NSString stringWithFormat:@"量測中… 累計 %.0f counts", self.measureCounts];
            });
        }
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (rid == 6) {
            NSInteger step = [DPIMapper stepFromVendorPayload:copy];
            BOOL duplicate = (self.lastVendorPayload && [self.lastVendorPayload isEqualToData:copy] &&
                              (ts - self.lastVendorTime) < 0.15);
            self.lastVendorPayload = copy;
            self.lastVendorTime = ts;
            if (duplicate) return;                    // the mouse exposes two handles with identical reports

            if (step >= 0) {
                self.mapper.currentStep = step;
                NSString *title = [self.mapper hudTitleForStep:step];
                NSString *subtitle = [self.mapper hudSubtitleForStep:step];
                [HUDWindow.sharedHUD showTitle:title subtitle:subtitle];
                [self appendLog:[NSString stringWithFormat:@"%@ [DPI] 第 %ld 段 → %@  (%@)",
                                 timeString(when), (long)(step + 1), title, hexString(copy)]];
            } else {
                const uint8_t *b = copy.bytes;
                BOOL noise = (copy.length >= 2 && b[0] == 0x66 && b[1] == 0x0F);   // trailing status flag
                if (!noise) {
                    [self appendLog:[NSString stringWithFormat:@"%@ [vendor] %@", timeString(when), hexString(copy)]];
                }
            }
        } else if (self.vendorOnlyCheck.state == NSControlStateValueOff) {
            if (ts - self.burstSecond >= 1.0) { self.burstSecond = ts; self.burstCount = 0; }
            if (self.burstCount++ < 20) {
                [self appendLog:[NSString stringWithFormat:@"%@ [%@] ID=%u %luB  %@",
                                 timeString(when), ifaceName, rid, (unsigned long)copy.length, hexString(copy)]];
            } else if (self.burstCount == 21) {
                [self appendLog:@"…（其餘同類報告省略）"];
            }
        }
    });
}

// MARK: actions

- (void)showWindow:(id)sender {
    (void)sender;
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)requestAccess:(id)sender {
    (void)sender;
    BOOL ok = [self.watcher requestAccess];
    [self appendLog:ok ? @"權限已授予。" : @"權限仍未授予；請到系統設定手動勾選，並重新開啟 App。"];
    [self refreshStatus];
    if (ok) [self startMonitoring:nil];
}

- (void)openPrivacySettings:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:
        [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
}

- (void)startMonitoring:(id)sender {
    (void)sender;
    if (self.watcher.isMonitoring) {          // already running (launch path + permission timer)
        [self refreshStatus];
        return;
    }
    if ([self.watcher startMonitoring]) {
        [self appendLog:@"▶︎ 開始監看。按滑鼠滾輪後方的 DPI 鍵，HUD 就會顯示目前段數。"];
    } else {
        [self appendLog:[NSString stringWithFormat:@"✘ 無法開始監看：%@", self.watcher.lastError]];
        [self appendLog:@"→ 系統設定 → 隱私權與安全性 → 輸入監控 → 勾選 DPIPeek，然後重新開啟本 App。"];
    }
    [self refreshStatus];
}

- (void)stopMonitoring:(id)sender {
    (void)sender;
    [self.watcher stopMonitoring];
    [self appendLog:@"■ 停止監看。"];
    [self refreshStatus];
}

- (void)rescan:(id)sender {
    (void)sender;
    for (HIDInterfaceInfo *i in [self.watcher scan]) {
        [self appendLog:[NSString stringWithFormat:@"找到介面 #%lu %@", (unsigned long)i.index, [i summary]]];
    }
    [self refreshStatus];
}

- (void)clearLog:(id)sender {
    (void)sender;
    self.logView.string = @"";
}

- (void)openLogFolder:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace selectFile:self.logPath inFileViewerRootedAtPath:self.logPath.stringByDeletingLastPathComponent];
}

- (void)presetFieldChanged:(NSTextField *)sender {
    NSInteger step = sender.tag;
    NSString *t = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSNumber *value = t.length ? @(t.integerValue) : nil;
    [self.mapper setPreset:value forStep:step];
    [self.mapper save];
    [self appendLog:[NSString stringWithFormat:@"第 %ld 段設為 %@", (long)(step + 1), value ? value : @"（未設定）"]];
}

- (void)startMeasure:(id)sender {
    (void)sender;
    if (self.mapper.currentStep < 0) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"請先按一下 DPI 鍵";
        a.informativeText = @"先按滑鼠的 DPI 鍵切到想量測的那一段，再開始量測。";
        [a runModal];
        return;
    }
    self.measuring = YES;
    self.measureCounts = 0;
    self.measureLabel.stringValue = @"量測中… 累計 0 counts";
    [self appendLog:[NSString stringWithFormat:@"開始量測第 %ld 段：請沿直尺水平移動 %@ cm（慢速、直線）",
                     (long)(self.mapper.currentStep + 1), self.distanceField.stringValue]];
}

- (void)applyMeasure:(id)sender {
    double cm = self.distanceField.doubleValue;
    if (cm <= 0) cm = 10.0;
    if (!self.measuring && self.measureCounts <= 0) {
        [self appendLog:@"尚未量測：請先按「開始量測」，再移動滑鼠。"];
        return;
    }
    self.measuring = NO;
    double inches = cm / 2.54;
    double dpi = self.measureCounts / inches;
    self.measuredDPI = dpi;
    NSInteger rounded = (NSInteger)(round(dpi / 25.0) * 25.0);
    NSInteger step = MAX(self.mapper.currentStep, 0);
    [self.mapper setPreset:@(rounded) forStep:step];
    [self.mapper save];
    if (step < (NSInteger)self.presetFields.count) self.presetFields[step].stringValue = @(rounded).stringValue;
    self.measureLabel.stringValue = [NSString stringWithFormat:@"≈ %ld DPI（已套用到第 %ld 段）",
                                     (long)rounded, (long)(step + 1)];
    [self appendLog:[NSString stringWithFormat:@"量測結果：%.1f counts / %.2f in = %.0f DPI → 第 %ld 段取 %ld",
                     self.measureCounts, inches, dpi, (long)(step + 1), (long)rounded]];
    self.measureCounts = 0;
}

- (void)testHUD:(id)sender {
    (void)sender;
    NSInteger step = self.mapper.currentStep >= 0 ? self.mapper.currentStep : 2;
    [HUDWindow.sharedHUD showTitle:[self.mapper hudTitleForStep:step]
                          subtitle:[self.mapper hudSubtitleForStep:step]];
}

- (void)sendHex:(id)sender {
    (void)sender;
    NSString *raw = self.hexField.stringValue;
    NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    NSMutableString *clean = [NSMutableString string];
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ([hexSet characterIsMember:c]) [clean appendFormat:@"%C", c];
    }
    if (clean.length < 2 || clean.length % 2 != 0) {
        [self appendLog:@"✘ 封包格式錯誤：請輸入偶數個 hex 字元，第一 byte 是 Report ID（例如 06 66 0C 00 …）"];
        return;
    }
    NSMutableData *data = [NSMutableData data];
    for (NSUInteger i = 0; i < clean.length; i += 2) {
        unsigned int v = 0;
        [[NSScanner scannerWithString:[clean substringWithRange:NSMakeRange(i, 2)]] scanHexInt:&v];
        uint8_t byte = (uint8_t)v;
        [data appendBytes:&byte length:1];
    }
    HIDInterfaceInfo *target = nil;
    for (HIDInterfaceInfo *i in self.watcher.interfaces) {
        if (i.maxOutputReportSize > 0) { target = i; if (i.vendorChannel) break; }
    }
    if (!target) { [self appendLog:@"✘ 沒有可寫入的介面（請先按「開始監看」）"]; return; }
    if (data.length < (NSUInteger)target.maxOutputReportSize) [data setLength:(NSUInteger)target.maxOutputReportSize];
    NSString *err = nil;
    BOOL ok = [self.watcher sendOutputReport:data toInterface:target error:&err];
    [self appendLog:[NSString stringWithFormat:@"%@ 送出封包 → %@ : %@", ok ? @"✔" : @"✘",
                     [target summary], ok ? hexString(data) : err]];
}

@end

// MARK: - selftest

static int runSelfTest(void) {
    int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); failures++; } else { printf("ok: %s\n", msg); } } while (0)

    uint8_t dpi3[] = {0x66, 0x0C, 0x03, 0x00};
    uint8_t dpi0[] = {0x66, 0x0C, 0x00, 0x00};
    uint8_t flag1[] = {0x66, 0x0F, 0x01, 0x00};
    uint8_t flag0[] = {0x66, 0x0F, 0x00, 0x00};
    uint8_t other[] = {0x00, 0x0C, 0x03, 0x00};
    uint8_t tooLarge[] = {0x66, 0x0C, 0x09, 0x00};
    uint8_t shortPacket[] = {0x66, 0x0C};

    CHECK([DPIMapper stepFromVendorPayload:[NSData dataWithBytes:dpi3 length:4]] == 3, "decodes 66 0C 03 -> step index 3");
    CHECK([DPIMapper stepFromVendorPayload:[NSData dataWithBytes:dpi0 length:4]] == 0, "decodes 66 0C 00 -> step index 0");
    CHECK([DPIMapper stepFromVendorPayload:[NSData dataWithBytes:flag1 length:4]] == -1, "ignores 66 0F 01 flag packet");
    CHECK([DPIMapper stepFromVendorPayload:[NSData dataWithBytes:flag0 length:4]] == -1, "ignores 66 0F 00 flag packet");
    CHECK([DPIMapper stepFromVendorPayload:[NSData dataWithBytes:other length:4]] == -1, "ignores packets that do not start with 0x66");
    CHECK([DPIMapper stepFromVendorPayload:[NSData dataWithBytes:tooLarge length:4]] == -1, "rejects out-of-range step");
    CHECK([DPIMapper stepFromVendorPayload:[NSData dataWithBytes:shortPacket length:2]] == -1, "rejects short packets");

    DPIMapper *m = [DPIMapper new];
    CHECK(m.presets.count == 7, "seven DPI slots");
    CHECK([[m hudTitleForStep:2] isEqualToString:@"第 3 段"], "unknown slot shows the step number");
    [m setPreset:@1600 forStep:2];
    CHECK([[m hudTitleForStep:2] isEqualToString:@"1600 DPI"], "known slot shows the DPI value");
    CHECK([[m hudSubtitleForStep:2] isEqualToString:@"第 3 / 7 段"], "subtitle shows the position");
    [m setPreset:nil forStep:2];
    CHECK([m presetForStep:2] == nil, "clearing a slot works");

    printf(failures ? "SELFTEST FAILED (%d)\n" : "SELFTEST PASSED\n", failures);
    return failures ? 1 : 0;
}

// MARK: - main

int main(int argc, const char *argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--selftest") == 0) return runSelfTest();
        if (strcmp(argv[i], "--monitor") == 0) {
            @autoreleasepool {
                HIDWatcher *w = [HIDWatcher new];
                __block NSData *last = nil;
                __block NSTimeInterval lastTime = 0;
                w.logHandler = ^(NSString *line) { printf("%s\n", line.UTF8String); fflush(stdout); };
                w.reportHandler = ^(HIDInterfaceInfo *iface, uint32_t rid, NSData *payload, NSDate *when) {
                    if (rid != 6) return;
                    NSTimeInterval ts = when.timeIntervalSince1970;
                    if (last && [last isEqualToData:payload] && ts - lastTime < 0.15) return;
                    last = payload; lastTime = ts;
                    NSInteger step = [DPIMapper stepFromVendorPayload:payload];
                    if (step >= 0) printf("[DPI] 第 %ld 段  (%s)\n", (long)(step + 1), hexString(payload).UTF8String);
                    else printf("[vendor] %s\n", hexString(payload).UTF8String);
                    fflush(stdout);
                };
                if (![w startMonitoring]) {
                    printf("start failed: %s\n", w.lastError.UTF8String);
                    return 1;
                }
                double secs = (i + 1 < argc) ? atof(argv[i + 1]) : 60.0;
                printf("--monitor: listening %ds, press the DPI button\n", (int)secs);
                fflush(stdout);
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, secs, false);
                [w stopMonitoring];
            }
            return 0;
        }
        if (strcmp(argv[i], "--discover") == 0) {
            printf("App 是 HP Professor 1 專用，不再全域掃描。\n通用偵測請用 CLI：./royuan auto\n");
            return 0;
        }
        if (strcmp(argv[i], "--scan") == 0) {
            @autoreleasepool {
                HIDWatcher *w = [HIDWatcher new];
                printf("access state: %ld (0 = granted)\n", (long)[w accessState]);
                for (HIDInterfaceInfo *i in [w scan]) printf("#%lu %s\n", (unsigned long)i.index, [i summary].UTF8String);
            }
            return 0;
        }
    }
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
