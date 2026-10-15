// Localization.h — Multi-language support matching Windows (zh-TW, zh-CN, en).
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, AppLanguage) {
    AppLangZhTw = 0,
    AppLangZhCn = 1,
    AppLangEn = 2,
};

@interface Localization : NSObject

+ (instancetype)shared;

@property (nonatomic) AppLanguage currentLanguage;

- (NSString *)title;
- (NSString *)pin;
- (NSString *)pinTooltip;
- (NSString *)quit;
- (NSString *)themeTitle;
- (NSString *)themeAuto;
- (NSString *)themeLight;
- (NSString *)themeDark;
- (NSString *)testHUD;
- (NSString *)presetsHeader24G;
- (NSString *)presetsHeaderBLE;
- (NSString *)presetsHeaderOffline;
- (NSString *)permGranted;
- (NSString *)permDenied;
- (NSString *)permUnknown;
- (NSString *)device24G:(NSString *)dev battery:(int)batt;
- (NSString *)deviceBLE:(NSUInteger)count battery:(int)batt;
- (NSString *)deviceOffline;
- (NSString *)modeOffline;
- (NSString *)modeDongle;
- (NSString *)modeBluetooth;
- (NSString *)stage:(NSInteger)index total:(NSInteger)total;
- (NSString *)hudTitleForStep:(NSInteger)step preset:(NSNumber *)preset;
- (NSString *)hudSubtitleForStep:(NSInteger)step total:(NSInteger)total;
- (NSString *)reqPermBtn;
- (NSString *)openSettingsBtn;

@end
