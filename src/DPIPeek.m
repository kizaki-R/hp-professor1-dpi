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
#import "BLEBatteryReader.h"
#import "Localization.h"

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
@property (nonatomic, strong) NSImageView *logoView;
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *badgeLabel;
@property (nonatomic, strong) NSButton *quitBtn;
@property (nonatomic, strong) NSBox *headerSeparator;
@property (nonatomic) NSTimeInterval lastCloseTime;
@property (nonatomic) NSInteger currentTheme; // 0=Auto, 1=Light, 2=Dark

@property (nonatomic, strong) NSTextField *accessLabel;
@property (nonatomic, strong) NSTextField *deviceLabel;
@property (nonatomic, strong) NSSegmentedControl *dpiSegments;
@property (nonatomic, strong) NSTextField *presetsLabel;

@property (nonatomic, strong) NSTextField *themeLabel;
@property (nonatomic, strong) NSSegmentedControl *themeSegments;
@property (nonatomic, strong) NSSegmentedControl *langSegments;
@property (nonatomic, strong) NSButton *testHudBtn;

@property (nonatomic, strong) NSArray *permRow;

@property (nonatomic, strong) HIDWatcher *watcher;
@property (nonatomic, strong) VendorChannel *vendor;
@property (nonatomic, strong) DPIMapper *mapper;
@property (nonatomic, strong) NSFileHandle *logFile;
@property (nonatomic, copy) NSString *logPath;
@property (nonatomic, strong) NSData *lastVendorPayload;
@property (nonatomic) NSTimeInterval lastVendorTime;
@property (nonatomic, strong) id<NSObject> activity;
@property (nonatomic, strong) BLEBatteryReader *bleBattery;
@property (nonatomic) int cachedBattery;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    (void)note;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [self buildMenuBar];
    [self buildMainMenu];

    self.watcher = [HIDWatcher new];
    self.mapper = [DPIMapper loadFromDefaults];
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
    [self updateLocalizedUI];
    [self applyTheme:self.currentTheme];

    self.bleBattery = [BLEBatteryReader new];
    self.bleBattery.batteryUpdateHandler = ^(int percent) {
        [weakSelf refreshStatus];
    };
    [self.bleBattery start];

    [self refreshStatus];

    [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(permissionTick:) userInfo:nil repeats:YES];

    [self appendLog:@"HP Professor 1 DPI 啟動。"];
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
    a.messageText = @"HP Professor 1 DPI 需要「輸入監控」權限";
    a.informativeText = @"macOS 規定：任何程式要讀取滑鼠的 HID 資料，都必須由你手動授權。\n\n"
                        @"1. 按下方「開啟系統設定」\n"
                        @"2. 到「隱私權與安全性 → 輸入監控」，把 HP Professor 1 DPI 打開（沒有列出就按 + 加入本 App）\n"
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
    [self.bleBattery stop];
    if (self.activity) [NSProcessInfo.processInfo endActivity:self.activity];
    [self.mapper save];
    [self.logFile closeFile];
}

// MARK: - Menu Bar & Status Item

- (void)buildMenuBar {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.imagePosition = NSImageLeft;
    self.statusItem.button.toolTip = @"HP Professor 1 DPI — 點擊切換面板";
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    [self.statusItem.button sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    [self updateMenuBarDisplayWithStep:self.mapper.currentStep battery:-1];
}

- (void)updateMenuBarDisplayWithStep:(NSInteger)step battery:(int)batt {
    NSStatusBarButton *btn = self.statusItem.button;
    if (!btn) return;

    // Load VELOCITY stage icon (1..7) or fallback
    int stage = (int)step + 1; // step 0..6 -> stage 1..7
    if (stage < 1 || stage > 7) stage = 1;
    NSString *iconName = [NSString stringWithFormat:@"menu_stage_%d", stage];
    NSImage *img = [NSImage imageNamed:iconName] ?: [[NSBundle mainBundle] imageForResource:iconName];
    if (img) {
        img.template = YES; // Adapts smoothly to macOS dark/light menu bar
        img.size = NSMakeSize(20, 16);
        btn.image = img;
    }

    if (batt > 0 && batt <= 100) {
        btn.title = [NSString stringWithFormat:@" %d%%", batt];
    } else {
        btn.title = @"";
    }
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
    [self closePanel];
}

- (void)windowDidResignKey:(NSNotification *)notification {
    [self closePanel];
}

- (void)buildMainMenu {
    NSMenu *menubar = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [menubar addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"關於 HP Professor 1 DPI" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:@"結束 HP Professor 1 DPI" action:@selector(terminate:) keyEquivalent:@"q"];
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
    self.window.title = @"HP Professor 1 DPI";
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

    // Native frosted glass background view: adapts to Light & Dark modes automatically with translucency
    self.effectView = [[NSVisualEffectView alloc] initWithFrame:self.container.bounds];
    self.effectView.material = NSVisualEffectMaterialUnderWindowBackground;
    self.effectView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.effectView.state = NSVisualEffectStateActive;
    self.effectView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.container addSubview:self.effectView positioned:NSWindowBelow relativeTo:nil];

    NSView *cv = self.container;

    // Header Bar: VELOCITY Logo + Title + Mode Badge + Quit
    NSImage *logo = [NSImage imageNamed:@"logo_mark"];
    if (!logo) logo = [[NSBundle mainBundle] imageForResource:@"logo_mark"];
    self.logoView = [[NSImageView alloc] initWithFrame:NSMakeRect(14, 0, 20, 20)];
    self.logoView.image = logo;
    self.logoView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [cv addSubview:self.logoView];

    self.titleLabel = [self label:@"HP Professor 1 DPI" x:38 w:136 y:0 size:12 bold:YES];
    [cv addSubview:self.titleLabel];

    self.badgeLabel = [self label:@"2.4G 4000 DPI" x:178 w:126 y:0 size:9.5 bold:NO];
    self.badgeLabel.textColor = [NSColor secondaryLabelColor];
    [cv addSubview:self.badgeLabel];

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

    self.themeSegments = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(56, 0, 142, 22)];
    self.themeSegments.segmentCount = 3;
    self.themeSegments.segmentStyle = NSSegmentStyleRounded;
    self.themeSegments.trackingMode = NSSegmentSwitchTrackingSelectOne;
    [self.themeSegments setLabel:@"自動" forSegment:0];
    [self.themeSegments setLabel:@"淺色" forSegment:1];
    [self.themeSegments setLabel:@"深色" forSegment:2];
    self.themeSegments.font = [NSFont systemFontOfSize:10.0];
    self.themeSegments.selectedSegment = self.currentTheme;
    self.themeSegments.target = self;
    self.themeSegments.action = @selector(themeSegmentClicked:);
    [cv addSubview:self.themeSegments];

    self.langSegments = [[NSSegmentedControl alloc] initWithFrame:NSMakeRect(204, 0, 94, 22)];
    self.langSegments.segmentCount = 3;
    self.langSegments.segmentStyle = NSSegmentStyleRounded;
    self.langSegments.trackingMode = NSSegmentSwitchTrackingSelectOne;
    [self.langSegments setLabel:@"繁" forSegment:0];
    [self.langSegments setLabel:@"简" forSegment:1];
    [self.langSegments setLabel:@"EN" forSegment:2];
    self.langSegments.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
    self.langSegments.selectedSegment = Localization.shared.currentLanguage;
    self.langSegments.target = self;
    self.langSegments.action = @selector(langSegmentClicked:);
    [cv addSubview:self.langSegments];

    self.testHudBtn = [self button:@"HUD" action:@selector(testHUD:) x:0 w:58 y:0];
    self.testHudBtn.font = [NSFont systemFontOfSize:10.5];
    [cv addSubview:self.testHudBtn];

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
    self.logoView.frame = NSMakeRect(14.0, y, 20.0, 20.0);
    self.titleLabel.frame = NSMakeRect(38.0, y + 2.0, 136.0, 18.0);
    self.badgeLabel.frame = NSMakeRect(178.0, y + 2.0, 136.0, 16.0);
    self.quitBtn.frame = NSMakeRect(318.0, y - 1.0, 48.0, 24.0);

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

    // Theme & Language Row
    y -= 28.0;
    self.themeLabel.frame = NSMakeRect(14.0, y + 2.0, 40.0, 18.0);
    self.themeSegments.frame = NSMakeRect(56.0, y, 142.0, 22.0);
    self.langSegments.frame = NSMakeRect(204.0, y, 94.0, 22.0);
    self.testHudBtn.frame = NSMakeRect(304.0, y, 62.0, 24.0);
}

- (void)langSegmentClicked:(NSSegmentedControl *)sender {
    Localization.shared.currentLanguage = (AppLanguage)sender.selectedSegment;
    [self updateLocalizedUI];
    [self refreshStatus];
}

- (void)updateLocalizedUI {
    Localization *loc = Localization.shared;
    self.quitBtn.title = [loc quit];
    self.themeLabel.stringValue = [loc themeTitle];
    [self.themeSegments setLabel:[loc themeAuto] forSegment:0];
    [self.themeSegments setLabel:[loc themeLight] forSegment:1];
    [self.themeSegments setLabel:[loc themeDark] forSegment:2];
    self.testHudBtn.title = [loc testHUD];
    if (self.permRow.count >= 2) {
        ((NSButton *)self.permRow[0]).title = [loc reqPermBtn];
        ((NSButton *)self.permRow[1]).title = [loc openSettingsBtn];
    }
}

- (void)applyAdvancedMode:(BOOL)animate {
    BOOL hasPermWarning = ([self.watcher accessState] != HIDAccessGranted);
    CGFloat targetH = hasPermWarning ? 220.0 : 190.0;

    NSRect curFrame = self.window.frame;
    CGFloat curTop = NSMaxY(curFrame);
    NSRect newFrame = NSMakeRect(curFrame.origin.x, curTop - targetH, 380.0, targetH);
    [self.window setFrame:newFrame display:YES animate:animate];

    [self layoutContent];
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

    BOOL isDark = [self.window.effectiveAppearance.name containsString:@"Dark"];
    NSString *logoName = isDark ? @"logo_mark" : @"logo_mark_light";
    NSImage *logo = [NSImage imageNamed:logoName] ?: [[NSBundle mainBundle] imageForResource:logoName];
    if (logo) self.logoView.image = logo;

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
        NSString *bleLimitSub = @"藍牙模式限制：請按滑鼠實體 DPI 鍵切換";
        if (Localization.shared.currentLanguage == AppLangZhCn) {
            bleLimitSub = @"蓝牙模式限制：请按鼠标实体 DPI 键切换";
        } else if (Localization.shared.currentLanguage == AppLangEn) {
            bleLimitSub = @"Bluetooth Mode: Use physical DPI button to switch";
        }
        [HUDWindow.sharedHUD showTitle:curDPI
                              subtitle:bleLimitSub];
        [self appendLog:[NSString stringWithFormat:@"%@ 提示：藍牙模式僅支援滑鼠單向通知，請改插 2.4G 接收器即可軟體直切",
                         timeString(NSDate.date)]];
    }

    [self refreshStatus];
}

- (void)refreshStatus {
    Localization *loc = Localization.shared;
    HIDAccessState st = self.watcher.accessState;
    NSString *text;
    NSColor *color = [NSColor labelColor];
    switch (st) {
        case HIDAccessGranted:
            text = [loc permGranted];
            color = [NSColor systemGreenColor];
            break;
        case HIDAccessDenied:
            text = [loc permDenied];
            color = [NSColor systemRedColor];
            break;
        default:
            text = [loc permUnknown];
            break;
    }
    self.accessLabel.stringValue = text;
    self.accessLabel.textColor = color;

    // Update connection status and badge
    NSString *modeText = [loc modeOffline];
    NSString *dpiText = (self.mapper.currentStep >= 0) ? [self.mapper hudTitleForStep:self.mapper.currentStep] : @"";
    BOOL vendorActive = self.vendor.isReady && self.vendor.isMouseLinked;
    if (vendorActive) {
        int batt = [self.vendor readBatteryPercent];
        if (batt > 0 && batt <= 100) {
            self.cachedBattery = batt;
        } else if (self.cachedBattery > 0) {
            batt = self.cachedBattery;
        }
        NSString *battBadge = @"";
        if (batt > 0 && batt <= 100) {
            battBadge = [NSString stringWithFormat:@" · %s %d%%", (batt <= 20 ? "🪫" : "🔋"), batt];
        }
        [self updateMenuBarDisplayWithStep:self.mapper.currentStep battery:batt];
        modeText = [NSString stringWithFormat:@"%@ · %@%@", [loc modeDongle], dpiText.length ? dpiText : @"4000 DPI", battBadge];
        self.deviceLabel.stringValue = [loc device24G:self.vendor.deviceName battery:batt];
        self.presetsLabel.stringValue = [loc presetsHeader24G];
        self.statusItem.button.toolTip = [NSString stringWithFormat:@"HP Professor 1 DPI (%@ · %@%@)",
                                          [loc modeDongle],
                                          dpiText.length ? dpiText : @"4000 DPI",
                                          (batt > 0 ? [NSString stringWithFormat:@" · 電量 %d%%", batt] : @"")];
    } else {
        NSArray *ifs = self.watcher.interfaces;
        BOOL hasBLE = NO;
        for (HIDInterfaceInfo *i in ifs) {
            if (i.productID == 0x4028 || [i.product containsString:@"Professor"]) {
                hasBLE = YES; break;
            }
        }
        if (hasBLE) {
            int batt = self.bleBattery.batteryPercent;
            if (batt > 0 && batt <= 100) {
                self.cachedBattery = batt;
            } else if (self.cachedBattery > 0) {
                batt = self.cachedBattery;
            }
            NSString *battBadge = @"";
            if (batt > 0 && batt <= 100) {
                battBadge = [NSString stringWithFormat:@" · %s %d%%", (batt <= 20 ? "🪫" : "🔋"), batt];
            }
            [self updateMenuBarDisplayWithStep:self.mapper.currentStep battery:batt];
            modeText = [NSString stringWithFormat:@"%@ · %@%@", [loc modeBluetooth], dpiText.length ? dpiText : ([loc currentLanguage] == AppLangEn ? @"Connected" : @"已連線"), battBadge];
            self.deviceLabel.stringValue = [loc deviceBLE:ifs.count battery:batt];
            self.presetsLabel.stringValue = [loc presetsHeaderBLE];
            self.statusItem.button.toolTip = [NSString stringWithFormat:@"HP Professor 1 DPI (%@ · %@%@)",
                                              [loc modeBluetooth],
                                              dpiText.length ? dpiText : ([loc currentLanguage] == AppLangEn ? @"Connected" : @"已連線"),
                                              (batt > 0 ? [NSString stringWithFormat:@" · 電量 %d%%", batt] : @"")];
        } else {
            [self updateMenuBarDisplayWithStep:0 battery:-1];
            modeText = [loc modeOffline];
            self.deviceLabel.stringValue = [loc deviceOffline];
            self.presetsLabel.stringValue = [loc presetsHeaderOffline];
            self.statusItem.button.toolTip = [NSString stringWithFormat:@"HP Professor 1 DPI — %@", [loc modeOffline]];
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

// MARK: - HID handling

- (void)handleReport:(HIDInterfaceInfo *)iface reportID:(uint32_t)reportID payload:(NSData *)payload when:(NSDate *)when {
    NSData *copy = [payload copy];
    uint32_t rid = reportID;
    NSTimeInterval ts = when.timeIntervalSince1970;

    if (rid != 6) return;

    dispatch_async(dispatch_get_main_queue(), ^{
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

- (void)testHUD:(id)sender {
    (void)sender;
    NSInteger step = self.mapper.currentStep >= 0 ? self.mapper.currentStep : 2;
    [HUDWindow.sharedHUD showTitle:[self.mapper hudTitleForStep:step]
                          subtitle:[self.mapper hudSubtitleForStep:step]];
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
