// Localization.m — Multi-language strings matching Windows version.
#import "Localization.h"

static NSString *const kLanguageKey = @"HPProfessor1DPI.language";

@implementation Localization

+ (instancetype)shared {
    static Localization *loc;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        loc = [Localization new];
    });
    return loc;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:kLanguageKey];
        if (saved) {
            _currentLanguage = [saved integerValue];
        } else {
            _currentLanguage = [self detectSystemLanguage];
        }
    }
    return self;
}

- (AppLanguage)detectSystemLanguage {
    NSString *lang = [NSLocale preferredLanguages].firstObject ?: @"";
    if ([lang hasPrefix:@"zh-Hans"] || [lang hasPrefix:@"zh-CN"]) {
        return AppLangZhCn;
    } else if ([lang hasPrefix:@"zh"]) {
        return AppLangZhTw;
    }
    return AppLangEn;
}

- (void)setCurrentLanguage:(AppLanguage)lang {
    _currentLanguage = lang;
    [NSUserDefaults.standardUserDefaults setInteger:lang forKey:kLanguageKey];
}

- (NSString *)title {
    return @"HP Professor 1 DPI";
}

- (NSString *)pin {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"📌 钉选";
        case AppLangEn:   return @"📌 Pin";
        default:          return @"📌 釘選";
    }
}

- (NSString *)pinTooltip {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"钉选后点击外部不会自动关闭面板";
        case AppLangEn:   return @"Keep panel open when clicking outside";
        default:          return @"釘選後點擊外部不會自動關閉面板";
    }
}

- (NSString *)quit {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"退出";
        case AppLangEn:   return @"Quit";
        default:          return @"結束";
    }
}

- (NSString *)themeTitle {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"主题：";
        case AppLangEn:   return @"Theme:";
        default:          return @"主題：";
    }
}

- (NSString *)themeAuto {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"💻 自动";
        case AppLangEn:   return @"💻 Auto";
        default:          return @"💻 自動";
    }
}

- (NSString *)themeLight {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"☀️ 浅色";
        case AppLangEn:   return @"☀️ Light";
        default:          return @"☀️ 淺色";
    }
}

- (NSString *)themeDark {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"🌙 深色";
        case AppLangEn:   return @"🌙 Dark";
        default:          return @"🌙 深色";
    }
}

- (NSString *)testHUD {
    return @"測試 HUD";
}

- (NSString *)presetsHeader24G {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"DPI 档数（2.4G 模式点击直接切换）：";
        case AppLangEn:   return @"DPI Levels (2.4G: Click below to switch):";
        default:          return @"DPI 段數（2.4G 可點擊直切）：";
    }
}

- (NSString *)presetsHeaderBLE {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"当前 DPI 档数（蓝牙模式请按鼠标实体键切换）：";
        case AppLangEn:   return @"Current DPI (Bluetooth: Use mouse button to switch):";
        default:          return @"目前 DPI 段數（藍牙模式請按滑鼠實體鍵切換）：";
    }
}

- (NSString *)presetsHeaderOffline {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"DPI 档数（未连接）：";
        case AppLangEn:   return @"DPI Levels (Offline):";
        default:          return @"DPI 段數（未連線）：";
    }
}

- (NSString *)permGranted {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"权限状态：已授予「输入监控」✔";
        case AppLangEn:   return @"Permission: Input Monitoring Granted ✔";
        default:          return @"權限狀態：已授予「輸入監控」✔";
    }
}

- (NSString *)permDenied {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"权限状态：被拒绝 ✘（请到系统设置开启）";
        case AppLangEn:   return @"Permission: Denied ✘ (Enable in System Settings)";
        default:          return @"權限狀態：被拒絕 ✘（請到系統設定開啟）";
    }
}

- (NSString *)permUnknown {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"权限状态：尚未决定（请按授权）";
        case AppLangEn:   return @"Permission: Not Granted (Click to authorize)";
        default:          return @"權限狀態：尚未決定（按要求權限）";
    }
}

- (NSString *)reqPermBtn {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"要求输入监控权限";
        case AppLangEn:   return @"Request Permission";
        default:          return @"要求輸入監控權限";
    }
}

- (NSString *)openSettingsBtn {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"打开系统设置";
        case AppLangEn:   return @"Open Settings";
        default:          return @"開啟系統設定";
    }
}

- (NSString *)device24G:(NSString *)dev battery:(int)batt {
    NSString *battStr = batt > 0 ? [NSString stringWithFormat:@" ｜ %s：%d%%",
                                   (self.currentLanguage == AppLangEn ? "Battery" : (self.currentLanguage == AppLangZhCn ? "电量" : "電量")), batt] : @"";
    switch (self.currentLanguage) {
        case AppLangZhCn: return [NSString stringWithFormat:@"设备：%@ ｜ 原厂 2.4G 通道 (0xD4)%@", dev ?: @"HP Professor 1", battStr];
        case AppLangEn:   return [NSString stringWithFormat:@"Device: %@ | 2.4G Vendor Channel%@", dev ?: @"HP Professor 1", battStr];
        default:          return [NSString stringWithFormat:@"裝置：%@ ｜ 原廠 2.4G 通道 (0xD4)%@", dev ?: @"HP Professor 1", battStr];
    }
}

- (NSString *)deviceBLE:(NSUInteger)count battery:(int)batt {
    NSString *battStr = batt > 0 ? [NSString stringWithFormat:@" ｜ %s：%d%%",
                                   (self.currentLanguage == AppLangEn ? "Battery" : (self.currentLanguage == AppLangZhCn ? "电量" : "電量")), batt] : @"";
    switch (self.currentLanguage) {
        case AppLangZhCn: return [NSString stringWithFormat:@"设备：蓝牙监控中 (%lu 接口)%@", (unsigned long)count, battStr];
        case AppLangEn:   return [NSString stringWithFormat:@"Device: Bluetooth Connected (%lu interfaces)%@", (unsigned long)count, battStr];
        default:          return [NSString stringWithFormat:@"裝置：藍牙監看中 (%lu 介面)%@", (unsigned long)count, battStr];
    }
}

- (NSString *)deviceOffline {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"设备：等待鼠标连接…";
        case AppLangEn:   return @"Device: Waiting for mouse connection...";
        default:          return @"裝置：等待滑鼠連線…";
    }
}

- (NSString *)modeOffline {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"未连接";
        case AppLangEn:   return @"Offline";
        default:          return @"未連線";
    }
}

- (NSString *)modeDongle {
    return @"2.4G";
}

- (NSString *)modeBluetooth {
    switch (self.currentLanguage) {
        case AppLangZhCn: return @"蓝牙";
        case AppLangEn:   return @"Bluetooth";
        default:          return @"藍牙";
    }
}

- (NSString *)stage:(NSInteger)index total:(NSInteger)total {
    switch (self.currentLanguage) {
        case AppLangZhCn: return [NSString stringWithFormat:@"第 %ld / %ld 档", (long)index, (long)total];
        case AppLangEn:   return [NSString stringWithFormat:@"Level %ld / %ld", (long)index, (long)total];
        default:          return [NSString stringWithFormat:@"第 %ld / %ld 段", (long)index, (long)total];
    }
}

- (NSString *)hudTitleForStep:(NSInteger)step preset:(NSNumber *)preset {
    if (step < 0) return @"?";
    if (preset) return [NSString stringWithFormat:@"%@ DPI", preset];
    switch (self.currentLanguage) {
        case AppLangZhCn: return [NSString stringWithFormat:@"第 %ld 档", (long)(step + 1)];
        case AppLangEn:   return [NSString stringWithFormat:@"Level %ld", (long)(step + 1)];
        default:          return [NSString stringWithFormat:@"第 %ld 段", (long)(step + 1)];
    }
}

- (NSString *)hudSubtitleForStep:(NSInteger)step total:(NSInteger)total {
    return [self stage:(step + 1) total:total];
}

@end
