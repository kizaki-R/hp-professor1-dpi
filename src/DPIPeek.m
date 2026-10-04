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

// MARK: - MenuBar Attached Panel

@interface MenuBarPanel : NSPanel
@end

@implementation MenuBarPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
- (void)cancelOperation:(id)sender {
    if ([self.delegate respondsToSelector:@selector(closePanelFromKey)]) {
        [self.delegate performSelector:@selector(closePanelFromKey)];
    } else {
        [self orderOut:nil];
    }
}
@end

// MARK: - App delegate

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) MenuBarPanel *window;
@property (nonatomic, strong) NSView *container;
@property (nonatomic, strong) NSVisualEffectView *effectView;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *badgeLabel;
@property (nonatomic, strong) NSButton *pinCheck;
@property (nonatomic, strong) NSButton *quitBtn;
@property (nonatomic, strong) NSBox *headerSeparator;
@property (nonatomic) BOOL pinned;
@property (nonatomic) NSTimeInterval lastCloseTime;
@property (nonatomic) NSInteger currentTheme; // 0=Auto, 1=Light, 2=Dark

@property (nonatomic, strong) NSTextView *logView;
@property (nonatomic, strong) NSScrollView *logScroll;
@property (nonatomic, strong) NSTextField *accessLabel;
@property (nonatomic, strong) NSTextField *deviceLabel;
@property (nonatomic, strong) NSButton *vendorOnlyCheck;
@property (nonatomic, strong) NSSegmentedControl *dpiSegments;
@property (nonatomic, strong) NSTextField *presetsLabel;

@property (nonatomic, strong) NSTextField *themeLabel;
@property (nonatomic, strong) NSSegmentedControl *themeSegments;
@property (nonatomic, strong) NSButton *advancedCheck;
@property (nonatomic, strong) NSButton *testHudBtn;

@property (nonatomic, strong) NSArray *permRow;
@property (nonatomic, strong) NSArray *monitorRow;
@property (nonatomic, strong) NSArray *vendorRow;
@property (nonatomic, strong) NSArray *logClearRow;
@property (nonatomic, strong) NSArray *measureRow;
@property (nonatomic, strong) NSArray *hexRow;
@property (nonatomic, strong) NSMutableArray *advancedViews;
@property (nonatomic) BOOL advancedMode;

@property (nonatomic, strong) NSTextField *measureCaption;
@property (nonatomic, strong) NSTextField *distanceField;
@property (nonatomic, strong) NSTextField *cmLabel;
@property (nonatomic, strong) NSTextField *measureLabel;
@property (nonatomic, strong) NSTextField *hexLabel;
@property (nonatomic, strong) NSTextField *hexField;

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
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self buildMenuBar];
    [self buildMainMenu];

    self.watcher = [HIDWatcher new];
    self.mapper = [DPIMapper loadFromDefaults];
    self.advancedViews = [NSMutableArray array];
    self.advancedMode = [NSUserDefaults.standardUserDefaults boolForKey:@"DPIPeek.advancedMode"];
    self.pinned = [NSUserDefaults.standardUserDefaults boolForKey:@"DPIPeek.pinned"];
    self.currentTheme = [NSUserDefaults.standardUserDefaults integerForKey:@"DPIPeek.theme"]; // 0=Auto, 1=Light, 2=Dark

    __weak AppDelegate *weakSelf = self;
    self.watcher.reportHandler = ^(HIDInterfaceInfo *iface, uint32_t reportID, NSData *payload, NSDate *when) {
        [weakSelf handleReport:iface reportID:reportID payload:payload when:when];
    };
    self.watcher.logHandler = ^(NSString *line) {
        [weakSelf appendLog:line];
    };
    self.watcher.interfaceChangedHandler = ^{
        [weakSelf refreshStatus];
    };

    self.activity = [NSProcessInfo.processInfo
                     beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                     reason:@"polling the mouse vendor channel for DPI changes"];

    [self openLogFile];
    [self buildWindow];
    [self applyTheme:self.currentTheme];
    [self refreshStatus];

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

    dispatch_async(dispatch_get_main_queue(), ^{
        [self showPanel];
    });
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

// MARK: - Menu Bar & Status Item

- (void)buildMenuBar {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"DPI";
    self.statusItem.button.toolTip = @"DPI Peek — 點擊切換面板";
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
}

- (void)statusItemClicked:(id)sender {
    NSEvent *event = [NSApp currentEvent];
    if (event.type == NSEventTypeRightMouseUp) {
        [self showContextMenu];
        return;
    }
    [self togglePanel];
}

- (void)showContextMenu {
    NSMenu *menu = [NSMenu new];
    [menu addItemWithTitle:(self.window.isVisible ? @"隱藏面板" : @"顯示面板")
                    action:@selector(togglePanel) keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *themeItem = [menu addItemWithTitle:@"外觀主題" action:nil keyEquivalent:@""];
    NSMenu *themeMenu = [NSMenu new];
    NSMenuItem *autoItem = [themeMenu addItemWithTitle:@"跟隨系統 (Auto)" action:@selector(setThemeAuto:) keyEquivalent:@""];
    NSMenuItem *lightItem = [themeMenu addItemWithTitle:@"淺色模式 (Light)" action:@selector(setThemeLight:) keyEquivalent:@""];
    NSMenuItem *darkItem = [themeMenu addItemWithTitle:@"深色模式 (Dark)" action:@selector(setThemeDark:) keyEquivalent:@""];
    autoItem.target = lightItem.target = darkItem.target = self;
    autoItem.state = (self.currentTheme == 0) ? NSControlStateValueOn : NSControlStateValueOff;
    lightItem.state = (self.currentTheme == 1) ? NSControlStateValueOn : NSControlStateValueOff;
    darkItem.state = (self.currentTheme == 2) ? NSControlStateValueOn : NSControlStateValueOff;
    themeItem.submenu = themeMenu;

    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"測試 HUD" action:@selector(testHUD:) keyEquivalent:@""];
    [menu addItemWithTitle:@"輸入監控設定…" action:@selector(openPrivacySettings:) keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"結束" action:@selector(terminate:) keyEquivalent:@"q"];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [self.statusItem popUpStatusItemMenu:menu];
#pragma clang diagnostic pop
}

- (void)setThemeAuto:(id)sender { [self applyTheme:0]; }
- (void)setThemeLight:(id)sender { [self applyTheme:1]; }
- (void)setThemeDark:(id)sender { [self applyTheme:2]; }

- (void)togglePanel {
    if (self.window.isVisible) {
        [self closePanel];
    } else {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - self.lastCloseTime < 0.25) return;
        [self showPanel];
    }
}

- (void)positionPanelBelowStatusItem {
    NSStatusBarButton *btn = self.statusItem.button;
    if (!btn || !btn.window) return;
    NSRect btnRect = [btn.window convertRectToScreen:btn.frame];
    NSRect screenRect = btn.window.screen.visibleFrame;
    if (NSIsEmptyRect(screenRect)) screenRect = NSScreen.mainScreen.visibleFrame;

    CGFloat panelW = self.window.frame.size.width;
    CGFloat panelH = self.window.frame.size.height;

    CGFloat x = NSMidX(btnRect) - panelW / 2.0;
    if (x + panelW > NSMaxX(screenRect) - 10.0) {
        x = NSMaxX(screenRect) - panelW - 10.0;
    }
    if (x < NSMinX(screenRect) + 10.0) {
        x = NSMinX(screenRect) + 10.0;
    }

    CGFloat y = NSMinY(btnRect) - panelH - 4.0;
    [self.window setFrameOrigin:NSMakePoint(x, y)];
}

- (void)showPanel {
    [self positionPanelBelowStatusItem];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)closePanel {
    self.lastCloseTime = [[NSDate date] timeIntervalSince1970];
    [self.window orderOut:nil];
}

- (void)closePanelFromKey {
    if (self.pinned) return;
    [self closePanel];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    if (self.pinned || self.measuring) return;
    [self closePanel];
}

- (void)togglePin:(id)sender {
    self.pinned = (self.pinCheck.state == NSControlStateValueOn);
    [NSUserDefaults.standardUserDefaults setBool:self.pinned forKey:@"DPIPeek.pinned"];
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
    l.textColor = [NSColor labelColor];
    return l;
}

// MARK: - Panel UI Construction (Width = 380px)

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 380.0, 235.0);
    self.window = [[MenuBarPanel alloc] initWithContentRect:frame
                                                  styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
    self.window.title = @"DPI Peek — HP Professor 1";
    self.window.level = NSFloatingWindowLevel;
    self.window.opaque = NO;
    self.window.backgroundColor = [NSColor clearColor];
    self.window.hasShadow = YES;
    self.window.delegate = self;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary;

    // Layer-masked container: 100% clean rounded corners with NO square border artifacts
    self.container = [[NSView alloc] initWithFrame:self.window.contentView.bounds];
    self.container.wantsLayer = YES;
    self.container.layer.cornerRadius = 14.0;
    self.container.layer.masksToBounds = YES;
    self.container.layer.borderWidth = 1.0;
    self.container.layer.borderColor = [NSColor separatorColor].CGColor;
    self.container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.window.contentView = self.container;

    // Native frosted glass background view: adapts to Light & Dark modes automatically
    self.effectView = [[NSVisualEffectView alloc] initWithFrame:self.container.bounds];
    self.effectView.material = NSVisualEffectMaterialPopover;
    self.effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.effectView.state = NSVisualEffectStateActive;
    self.effectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.container addSubview:self.effectView positioned:NSWindowBelow relativeTo:nil];

    NSView *cv = self.container;

    // Header Bar
    self.titleLabel = [self label:@"DPI Peek" x:14 w:68 y:0 size:13 bold:YES];
    [cv addSubview:self.titleLabel];

    self.badgeLabel = [self label:@"2.4G 4000 DPI" x:84 w:136 y:0 size:10 bold:NO];
    self.badgeLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:self.badgeLabel];

    self.pinCheck = [NSButton checkboxWithTitle:@"📌 釘選" target:self action:@selector(togglePin:)];
    self.pinCheck.toolTip = @"釘選後點擊外部不會自動關閉面板";
    self.pinCheck.font = [NSFont systemFontOfSize:11];
    self.pinCheck.state = self.pinned ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:self.pinCheck];

    self.quitBtn = [self button:@"結束" action:@selector(terminate:) x:0 w:52 y:0];
    self.quitBtn.font = [NSFont systemFontOfSize:11];
    [cv addSubview:self.quitBtn];

    self.headerSeparator = [[NSBox alloc] init];
    self.headerSeparator.boxType = NSBoxSeparator;
    [cv addSubview:self.headerSeparator];

    // Status Section
    self.accessLabel = [self label:@"權限狀態：檢查中…" x:14 w:352 y:0 size:11 bold:YES];
    [cv addSubview:self.accessLabel];

    self.deviceLabel = [self label:@"裝置：尚未監看" x:14 w:352 y:0 size:10 bold:NO];
    self.deviceLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:self.deviceLabel];

    NSButton *askBtn = [self button:@"要求輸入監控權限" action:@selector(requestAccess:) x:0 w:130 y:0];
    NSButton *setBtn = [self button:@"開啟系統設定" action:@selector(openPrivacySettings:) x:0 w:100 y:0];
    askBtn.font = setBtn.font = [NSFont systemFontOfSize:10];
    [cv addSubview:askBtn];
    [cv addSubview:setBtn];
    self.permRow = @[askBtn, setBtn];

    // DPI Segment Control: 7 Segments with real values
    self.presetsLabel = [self label:@"DPI 段數（2.4G 可點擊直切；藍牙為狀態顯示）：" x:14 w:352 y:0 size:10.5 bold:YES];
    [cv addSubview:self.presetsLabel];

    self.dpiSegments = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(14, 0, 352, 26)];
    self.dpiSegments.segmentCount = [self.mapper stepCount];
    self.dpiSegments.segmentStyle = NSSegmentStyleRounded;
    self.dpiSegments.trackingMode = NSSegmentSwitchTrackingSelectOne;
    self.dpiSegments.target = self;
    self.dpiSegments.action = @selector(dpiSegmentClicked:);
    self.dpiSegments.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    for (NSInteger i = 0; i < [self.mapper stepCount]; i++) {
        NSNumber *v = [self.mapper presetForStep:i];
        NSString *lbl = v ? [NSString stringWithFormat:@"%@", v] : [NSString stringWithFormat:@"P%ld", (long)(i + 1)];
        [self.dpiSegments setLabel:lbl forSegment:i];
        [self.dpiSegments setWidth:0 forSegment:i];
    }
    if (self.mapper.currentStep >= 0 && self.mapper.currentStep < self.dpiSegments.segmentCount) {
        self.dpiSegments.selectedSegment = self.mapper.currentStep;
    }
    [cv addSubview:self.dpiSegments];

    // Theme Switcher Row: Auto / Light / Dark
    self.themeLabel = [self label:@"主題：" x:14 w:40 y:0 size:11 bold:NO];
    [cv addSubview:self.themeLabel];

    self.themeSegments = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(56, 0, 195, 22)];
    self.themeSegments.segmentCount = 3;
    self.themeSegments.segmentStyle = NSSegmentStyleRounded;
    self.themeSegments.trackingMode = NSSegmentSwitchTrackingSelectOne;
    [self.themeSegments setLabel:@"💻 自動" forSegment:0];
    [self.themeSegments setLabel:@"☀️ 淺色" forSegment:1];
    [self.themeSegments setLabel:@"🌙 深色" forSegment:2];
    self.themeSegments.font = [NSFont systemFontOfSize:10.5];
    self.themeSegments.selectedSegment = self.currentTheme;
    self.themeSegments.target = self;
    self.themeSegments.action = @selector(themeSegmentClicked:);
    [cv addSubview:self.themeSegments];

    self.testHudBtn = [self button:@"測試 HUD" action:@selector(testHUD:) x:0 w:74 y:0];
    self.testHudBtn.font = [NSFont systemFontOfSize:11];
    [cv addSubview:self.testHudBtn];

    // Advanced Checkbox
    self.advancedCheck = [NSButton checkboxWithTitle:@"進階模式（除錯 · 量測）" target:self action:@selector(toggleAdvanced:)];
    self.advancedCheck.font = [NSFont systemFontOfSize:11];
    self.advancedCheck.state = self.advancedMode ? NSControlStateValueOn : NSControlStateValueOff;
    [cv addSubview:self.advancedCheck];

    // Advanced Section - Operations
    NSButton *startBtn = [self button:@"監看" action:@selector(startMonitoring:) x:0 w:52 y:0];
    NSButton *stopBtn = [self button:@"停止" action:@selector(stopMonitoring:) x:0 w:48 y:0];
    NSButton *reconnectBtn = [self button:@"重連" action:@selector(redetectPressed:) x:0 w:52 y:0];
    NSButton *readBtn = [self button:@"讀取原廠表" action:@selector(readVendorTable:) x:0 w:84 y:0];
    NSButton *rescanBtn = [self button:@"重新掃描" action:@selector(rescan:) x:0 w:70 y:0];
    startBtn.font = stopBtn.font = reconnectBtn.font = readBtn.font = rescanBtn.font = [NSFont systemFontOfSize:10];
    [cv addSubview:startBtn]; [cv addSubview:stopBtn]; [cv addSubview:reconnectBtn]; [cv addSubview:readBtn]; [cv addSubview:rescanBtn];
    self.monitorRow = @[startBtn, stopBtn, reconnectBtn, readBtn, rescanBtn];

    // Advanced Section - Log Tools
    NSButton *clearBtn = [self button:@"清除記錄" action:@selector(clearLog:) x:0 w:68 y:0];
    NSButton *folderBtn = [self button:@"開啟記錄檔" action:@selector(openLogFolder:) x:0 w:80 y:0];
    clearBtn.font = folderBtn.font = [NSFont systemFontOfSize:10];
    [cv addSubview:clearBtn]; [cv addSubview:folderBtn];
    self.logClearRow = @[clearBtn, folderBtn];

    self.vendorOnlyCheck = [NSButton checkboxWithTitle:@"只記廠商通道" target:nil action:nil];
    self.vendorOnlyCheck.toolTip = @"只記錄廠商通道 (Report ID 6)";
    self.vendorOnlyCheck.font = [NSFont systemFontOfSize:10];
    self.vendorOnlyCheck.state = NSControlStateValueOn;
    [cv addSubview:self.vendorOnlyCheck];

    // Advanced Section - Calibration
    self.measureCaption = [self label:@"實測：移動" x:0 w:62 y:0 size:10 bold:NO];
    [cv addSubview:self.measureCaption];

    self.distanceField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 32, 20)];
    self.distanceField.stringValue = @"10";
    self.distanceField.alignment = NSTextAlignmentCenter;
    self.distanceField.font = [NSFont systemFontOfSize:10];
    [cv addSubview:self.distanceField];

    self.cmLabel = [self label:@"cm" x:0 w:18 y:0 size:10 bold:NO];
    [cv addSubview:self.cmLabel];

    NSButton *measureBtn = [self button:@"開始量測" action:@selector(startMeasure:) x:0 w:66 y:0];
    NSButton *applyBtn = [self button:@"套用目前段" action:@selector(applyMeasure:) x:0 w:78 y:0];
    measureBtn.font = applyBtn.font = [NSFont systemFontOfSize:10];
    [cv addSubview:measureBtn]; [cv addSubview:applyBtn];

    self.measureLabel = [self label:@"（選段 → 沿尺水平移動）" x:0 w:130 y:0 size:9 bold:NO];
    self.measureLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:self.measureLabel];

    self.measureRow = @[self.measureCaption, self.distanceField, self.cmLabel, measureBtn, applyBtn, self.measureLabel];

    // Advanced Section - Hex Sender
    self.hexLabel = [self label:@"自訂封包：" x:0 w:62 y:0 size:10 bold:NO];
    [cv addSubview:self.hexLabel];

    self.hexField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 226, 20)];
    self.hexField.placeholderString = @"06 00 00 …";
    self.hexField.font = [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightRegular];
    [cv addSubview:self.hexField];

    NSButton *sendBtn = [self button:@"送出" action:@selector(sendHex:) x:0 w:48 y:0];
    sendBtn.font = [NSFont systemFontOfSize:10];
    [cv addSubview:sendBtn];

    self.hexRow = @[self.hexLabel, self.hexField, sendBtn];

    // Advanced Section - Live Log View
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(14, 12, 352, 220)];
    sv.hasVerticalScroller = YES;
    sv.borderType = NSBezelBorder;
    sv.autoresizingMask = NSViewNotSizable;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:sv.bounds];
    tv.editable = NO;
    tv.font = [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightRegular];
    tv.autoresizingMask = NSViewNotSizable;
    tv.verticallyResizable = YES;
    tv.horizontallyResizable = NO;
    tv.textContainer.widthTracksTextView = YES;
    tv.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    sv.documentView = tv;
    self.logView = tv;
    self.logScroll = sv;
    [cv addSubview:sv];

    [self.advancedViews addObjectsFromArray:self.monitorRow];
    [self.advancedViews addObjectsFromArray:self.logClearRow];
    [self.advancedViews addObject:self.vendorOnlyCheck];
    [self.advancedViews addObjectsFromArray:self.measureRow];
    [self.advancedViews addObjectsFromArray:self.hexRow];
    [self.advancedViews addObject:self.logScroll];

    [self applyAdvancedMode:NO];
}

- (void)placeRow:(NSArray *)views y:(CGFloat)y widths:(NSArray<NSNumber *> *)widths gap:(CGFloat)gap left:(CGFloat)left {
    CGFloat x = left;
    for (NSUInteger i = 0; i < [views count] && i < [widths count]; i++) {
        NSView *v = (NSView *)[views objectAtIndex:i];
        NSNumber *w = (NSNumber *)[widths objectAtIndex:i];
        NSRect f = v.frame;
        f.origin.x = x;
        f.size.width = [w doubleValue];
        if ([v isKindOfClass:[NSTextField class]] && !((NSTextField *)v).editable) {
            f.origin.y = y + 3.0;
            f.size.height = 16.0;
        } else if ([v isKindOfClass:[NSButton class]] && ((NSButton *)v).bezelStyle == NSBezelStyleRounded) {
            f.origin.y = y;
            f.size.height = 24.0;
        } else if ([v isKindOfClass:[NSTextField class]]) {
            f.origin.y = y + 1.0;
            CGFloat hh = f.size.height;
            if (hh < 20.0) hh = 20.0;
            f.size.height = hh;
        } else {
            f.origin.y = y + 2.0;
            f.size.height = 18.0;
        }
        v.frame = f;
        x += [w doubleValue] + gap;
    }
}

- (void)layoutContent {
    CGFloat y = self.window.contentView.bounds.size.height - 12.0;

    // Header bar
    y -= 22.0;
    self.titleLabel.frame = NSMakeRect(14.0, y + 2.0, 68.0, 18.0);
    self.badgeLabel.frame = NSMakeRect(84.0, y + 2.0, 140.0, 16.0);
    self.pinCheck.frame = NSMakeRect(228.0, y + 1.0, 80.0, 20.0);
    self.quitBtn.frame = NSMakeRect(314.0, y - 1.0, 52.0, 24.0);

    y -= 6.0;
    self.headerSeparator.frame = NSMakeRect(14.0, y, 352.0, 1.0);

    // Status Section
    y -= 20.0;
    self.accessLabel.frame = NSMakeRect(14.0, y, 352.0, 16.0);

    BOOL hasPermWarning = ([self.watcher accessState] != HIDAccessGranted);
    if (hasPermWarning) {
        y -= 26.0;
        for (NSView *v in self.permRow) v.hidden = NO;
        [self placeRow:self.permRow y:y widths:@[@130, @100] gap:6 left:14];
    } else {
        for (NSView *v in self.permRow) v.hidden = YES;
    }

    y -= 18.0;
    self.deviceLabel.frame = NSMakeRect(14.0, y, 352.0, 14.0);

    // DPI Segment Control Section
    y -= 20.0;
    self.presetsLabel.frame = NSMakeRect(14.0, y, 352.0, 16.0);
    y -= 28.0;
    self.dpiSegments.frame = NSMakeRect(14.0, y, 352.0, 26.0);

    // Theme Switcher Row (Auto / Light / Dark)
    y -= 26.0;
    self.themeLabel.frame = NSMakeRect(14.0, y + 2.0, 38.0, 18.0);
    self.themeSegments.frame = NSMakeRect(54.0, y, 215.0, 22.0);
    self.testHudBtn.frame = NSMakeRect(284.0, y, 82.0, 24.0);

    // Mode Toggle row
    y -= 26.0;
    self.advancedCheck.frame = NSMakeRect(14.0, y + 2.0, 240.0, 20.0);

    if (!self.advancedMode) {
        return;
    }

    // Advanced Section
    y -= 30.0;
    [self placeRow:self.monitorRow y:y widths:@[@52, @48, @52, @84, @70] gap:5 left:14];

    y -= 26.0;
    [self placeRow:self.logClearRow y:y widths:@[@68, @80] gap:6 left:14];
    self.vendorOnlyCheck.frame = NSMakeRect(174.0, y + 2.0, 140.0, 18.0);

    y -= 26.0;
    [self placeRow:self.measureRow y:y widths:@[@62, @32, @18, @66, @78, @70] gap:5 left:14];

    y -= 26.0;
    [self placeRow:self.hexRow y:y widths:@[@62, @226, @48] gap:5 left:14];

    y -= 6.0;
    CGFloat logH = MAX(140.0, y - 12.0);
    self.logScroll.frame = NSMakeRect(14.0, 12.0, 352.0, logH);
}

- (void)applyAdvancedMode:(BOOL)animate {
    [NSUserDefaults.standardUserDefaults setBool:self.advancedMode forKey:@"DPIPeek.advancedMode"];
    NSControlStateValue st = self.advancedMode ? NSControlStateValueOn : NSControlStateValueOff;
    self.advancedCheck.state = st;
    for (NSView *v in self.advancedViews) v.hidden = !self.advancedMode;

    BOOL hasPermWarning = ([self.watcher accessState] != HIDAccessGranted);
    CGFloat targetH = self.advancedMode ? 630.0 : (hasPermWarning ? 255.0 : 225.0);

    NSRect curFrame = self.window.frame;
    CGFloat curTop = NSMaxY(curFrame);
    NSRect newFrame = NSMakeRect(curFrame.origin.x, curTop - targetH, 380.0, targetH);
    [self.window setFrame:newFrame display:YES animate:animate];

    [self layoutContent];
}

- (void)toggleAdvanced:(id)sender {
    (void)sender;
    self.advancedMode = !self.advancedMode;
    [self applyAdvancedMode:YES];
}

// MARK: - Theme Switching

- (void)themeSegmentClicked:(NSSegmentedControl *)sender {
    [self applyTheme:sender.selectedSegment];
}

- (void)applyTheme:(NSInteger)themeIndex {
    self.currentTheme = themeIndex;
    [NSUserDefaults.standardUserDefaults setInteger:themeIndex forKey:@"DPIPeek.theme"];
    if (self.themeSegments.selectedSegment != themeIndex) {
        self.themeSegments.selectedSegment = themeIndex;
    }

    if (themeIndex == 1) { // Light
        self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    } else if (themeIndex == 2) { // Dark
        self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    } else { // Auto (Follow system)
        self.window.appearance = nil;
    }

    self.container.layer.borderColor = [NSColor separatorColor].CGColor;
    [self refreshStatus];
}

// MARK: - DPI Click Switching

- (void)dpiSegmentClicked:(NSSegmentedControl *)sender {
    NSInteger clickedIndex = sender.selectedSegment;
    [self switchToDPIIndex:clickedIndex];
}

- (void)switchToDPIIndex:(NSInteger)index {
    if (index < 0 || index >= [self.mapper stepCount]) return;

    NSString *title = [self.mapper hudTitleForStep:index];
    NSString *sub = [self.mapper hudSubtitleForStep:index];

    if (self.vendor.isReady) {
        // 2.4G Mode: Mouse hardware supports 0x54 to set the optical sensor resolution!
        BOOL ok = [self.vendor setActiveDPIIndex:(int)index];
        if (ok) {
            self.mapper.currentStep = index;
            self.dpiSegments.selectedSegment = index;
            [HUDWindow.sharedHUD showTitle:title subtitle:sub];
            [self appendLog:[NSString stringWithFormat:@"%@ [2.4G 軟體切換] 成功切換至第 %ld 段 (%@)",
                             timeString(NSDate.date), (long)(index + 1), title]];
        } else {
            [self appendLog:[NSString stringWithFormat:@"%@ [2.4G 切換失敗]", timeString(NSDate.date)]];
        }
    } else {
        // Bluetooth Mode: The hardware BLE firmware does not accept host commands
        if (self.mapper.currentStep >= 0 && self.mapper.currentStep < self.dpiSegments.segmentCount) {
            self.dpiSegments.selectedSegment = self.mapper.currentStep;
        }
        NSString *curDPI = (self.mapper.currentStep >= 0) ? [self.mapper hudTitleForStep:self.mapper.currentStep] : @"?";
        [HUDWindow.sharedHUD showTitle:curDPI
                              subtitle:@"藍牙模式限制：請按滑鼠實體 DPI 鍵切換"];
        [self appendLog:[NSString stringWithFormat:@"%@ 提示：藍牙模式僅支援滑鼠單向通知，請改插 2.4G 接收器即可軟體直切",
                         timeString(NSDate.date)]];
    }

    [self refreshStatus];
}

- (void)refreshStatus {
    HIDAccessState st = self.watcher.accessState;
    NSString *text;
    NSColor *color = [NSColor labelColor];
    switch (st) {
        case HIDAccessGranted:
            text = @"權限狀態：已授予「輸入監控」✔";
            color = [NSColor systemGreenColor];
            break;
        case HIDAccessDenied:
            text = @"權限狀態：被拒絕 ✘（請到系統設定開啟）";
            color = [NSColor systemRedColor];
            break;
        default:
            text = @"權限狀態：尚未決定（按要求權限）";
            break;
    }
    self.accessLabel.stringValue = text;
    self.accessLabel.textColor = color;

    // Update connection status and badge
    NSString *modeText = @"未連線";
    NSString *dpiText = (self.mapper.currentStep >= 0) ? [self.mapper hudTitleForStep:self.mapper.currentStep] : @"";
    BOOL vendorActive = self.vendor.isReady && self.vendor.isMouseLinked;
    if (vendorActive) {
        modeText = [NSString stringWithFormat:@"2.4G · %@", dpiText.length ? dpiText : @"4000 DPI"];
        self.deviceLabel.stringValue = [NSString stringWithFormat:@"裝置：%@ ｜ 原廠 2.4G 通道 (0xD4)", self.vendor.deviceName];
        self.presetsLabel.stringValue = @"DPI 段數（2.4G 可點擊直切）：";
    } else {
        NSArray *ifs = self.watcher.interfaces;
        BOOL hasBLE = NO;
        for (HIDInterfaceInfo *i in ifs) {
            if (i.productID == 0x4028 || [i.product containsString:@"Professor"]) {
                hasBLE = YES; break;
            }
        }
        if (hasBLE) {
            modeText = [NSString stringWithFormat:@"藍牙 · %@", dpiText.length ? dpiText : @"已連線"];
            self.deviceLabel.stringValue = [NSString stringWithFormat:@"裝置：藍牙監看中 (%lu 介面)", (unsigned long)ifs.count];
            self.presetsLabel.stringValue = @"目前 DPI 段數（藍牙模式請按滑鼠實體鍵切換）：";
        } else {
            modeText = @"未連線";
            self.deviceLabel.stringValue = @"裝置：等待滑鼠連線…";
            self.presetsLabel.stringValue = @"DPI 段數（未連線）：";
        }
    }
    self.badgeLabel.stringValue = modeText;

    // Sync labels on segments and highlight active segment
    for (NSInteger i = 0; i < [self.mapper stepCount] && i < self.dpiSegments.segmentCount; i++) {
        NSNumber *v = [self.mapper presetForStep:i];
        NSString *lbl = v ? [NSString stringWithFormat:@"%@", v] : [NSString stringWithFormat:@"P%ld", (long)(i + 1)];
        [self.dpiSegments setLabel:lbl forSegment:i];
    }
    if (self.mapper.currentStep >= 0 && self.mapper.currentStep < self.dpiSegments.segmentCount) {
        self.dpiSegments.selectedSegment = self.mapper.currentStep;
    }

    // Refresh semantic colors
    self.titleLabel.textColor = [NSColor labelColor];
    self.badgeLabel.textColor = [NSColor secondaryLabelColor];
    self.presetsLabel.textColor = [NSColor labelColor];
    self.themeLabel.textColor = [NSColor labelColor];
    self.measureCaption.textColor = [NSColor labelColor];
    self.cmLabel.textColor = [NSColor labelColor];
    self.measureLabel.textColor = [NSColor secondaryLabelColor];
    self.hexLabel.textColor = [NSColor labelColor];

    [self layoutContent];
}

// MARK: - logging

- (void)openLogFile {
    NSString *base = [[NSBundle mainBundle].bundlePath stringByDeletingLastPathComponent];
    NSString *dir = [base stringByAppendingPathComponent:@"logs"];
    if (![NSFileManager.defaultManager isWritableFileAtPath:base]) {
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
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: [NSColor labelColor],
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

// MARK: - vendor API

- (void)connectVendorChannel {
    __weak AppDelegate *weakSelf = self;
    if (self.vendor.isReady && self.vendor.isMouseLinked) {
        [self refreshStatus];
        return;
    }
    self.vendor = self.vendor ?: [VendorChannel new];
    self.vendor.logHandler = ^(NSString *line) { [weakSelf appendLog:line]; };
    self.vendor.onDisconnectHandler = ^{
        [weakSelf refreshStatus];
    };
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
    if (!self.vendor.isReady || !self.vendor.isMouseLinked) {
        [self connectVendorChannel];
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
    [self refreshStatus];
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

// MARK: - HID handling

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
            if (duplicate) return;

            if (step >= 0) {
                self.mapper.currentStep = step;
                NSString *title = [self.mapper hudTitleForStep:step];
                NSString *subtitle = [self.mapper hudSubtitleForStep:step];
                [HUDWindow.sharedHUD showTitle:title subtitle:subtitle];
                [self appendLog:[NSString stringWithFormat:@"%@ [DPI] 第 %ld 段 → %@  (%@)",
                                 timeString(when), (long)(step + 1), title, hexString(copy)]];
                [self refreshStatus];
            } else {
                const uint8_t *b = copy.bytes;
                BOOL noise = (copy.length >= 2 && b[0] == 0x66 && b[1] == 0x0F);
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

// MARK: - actions

- (void)showWindow:(id)sender {
    (void)sender;
    [self showPanel];
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
    if (self.watcher.isMonitoring) {
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

- (void)startMeasure:(id)sender {
    (void)sender;
    if (self.mapper.currentStep < 0) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"請先按一下 DPI 鍵";
        a.informativeText = @"先切到想量測的那一段，再開始量測。";
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
    self.measureLabel.stringValue = [NSString stringWithFormat:@"≈ %ld DPI", (long)rounded];
    [self appendLog:[NSString stringWithFormat:@"量測結果：%.1f counts / %.2f in = %.0f DPI → 第 %ld 段取 %ld",
                     self.measureCounts, inches, dpi, (long)(step + 1), (long)rounded]];
    self.measureCounts = 0;
    [self refreshStatus];
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
