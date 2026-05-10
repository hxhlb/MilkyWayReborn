#import "MWThemeManager.h"

#define THEME_PATH @"/var/mobile/Library/Preferences/com.milkyway.reborn.theme.plist"

static UIColor *colorFromDict(NSDictionary *dict) {
    if (!dict) return [UIColor grayColor];
    return [UIColor colorWithRed:[dict[@"Red"] doubleValue]
                           green:[dict[@"Green"] doubleValue]
                            blue:[dict[@"Blue"] doubleValue]
                           alpha:[dict[@"Alpha"] doubleValue]];
}

static CGRect frameFromDict(NSDictionary *dict) {
    if (!dict) return CGRectZero;
    return CGRectMake([dict[@"X"] doubleValue],
                      [dict[@"Y"] doubleValue],
                      [dict[@"Width"] doubleValue],
                      [dict[@"Height"] doubleValue]);
}

@implementation MWThemeManager

+ (instancetype)sharedInstance {
    static MWThemeManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
        [instance reload];
    });
    return instance;
}

+ (BOOL)isDarkMode {
    if (@available(iOS 13.0, *)) {
        if (![UIApplication sharedApplication]) return NO;
        UITraitCollection *tc = [UITraitCollection currentTraitCollection];
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

- (void)reload {
    NSDictionary *theme = [NSDictionary dictionaryWithContentsOfFile:THEME_PATH];
    if (!theme) {
        [self loadDefaults];
        return;
    }

    NSDictionary *close = theme[@"CloseButton"];
    NSDictionary *min = theme[@"MinButton"];
    NSDictionary *max = theme[@"MaxButton"];
    NSDictionary *stretch = theme[@"StretchButton"];
    NSDictionary *titleBar = theme[@"TitleBar"];
    NSDictionary *titleLabel = theme[@"TitleLabel"];

    self.closeButtonColor = colorFromDict(close[@"Color"]);
    self.minButtonColor = colorFromDict(min[@"Color"]);
    self.maxButtonColor = colorFromDict(max[@"Color"]);
    self.titleBarColor = colorFromDict(titleBar[@"Color"]);
    self.titleLabelColor = colorFromDict(titleLabel[@"Color"]);
    self.stretchButtonColor = colorFromDict(stretch[@"Color"]);

    self.closeButtonFrame = frameFromDict(close[@"Frame"]);
    self.minButtonFrame = frameFromDict(min[@"Frame"]);
    self.maxButtonFrame = frameFromDict(max[@"Frame"]);
    self.stretchButtonFrame = frameFromDict(stretch[@"Frame"]);
    self.titleLabelFrame = frameFromDict(titleLabel[@"Frame"]);

    self.closeButtonCornerRadius = [close[@"CornerRadius"] doubleValue];
    self.minButtonCornerRadius = [min[@"CornerRadius"] doubleValue];
    self.maxButtonCornerRadius = [max[@"CornerRadius"] doubleValue];
    self.stretchButtonCornerRadius = [stretch[@"CornerRadius"] doubleValue];

    self.closeButtonAnchor = [close[@"RightAnchor"] boolValue] ? NSLayoutAttributeTrailing : NSLayoutAttributeLeading;
    self.minButtonAnchor = [min[@"RightAnchor"] boolValue] ? NSLayoutAttributeTrailing : NSLayoutAttributeLeading;
    self.maxButtonAnchor = [max[@"RightAnchor"] boolValue] ? NSLayoutAttributeTrailing : NSLayoutAttributeLeading;
    self.stretchButtonAnchor = [stretch[@"RightAnchor"] boolValue] ? NSLayoutAttributeTrailing : NSLayoutAttributeLeading;

    self.titleBarHeight = [titleBar[@"Frame"][@"Height"] doubleValue];
    if (self.titleBarHeight < 1) self.titleBarHeight = 24;

    self.titleLabelFontSize = [titleLabel[@"FontSize"] doubleValue];
    if (self.titleLabelFontSize < 1) self.titleLabelFontSize = 12;

    self.sizeChangerFrame = CGRectMake(100, 0, self.titleBarHeight, self.titleBarHeight);

    if ([MWThemeManager isDarkMode]) {
        UIColor *tmp = self.titleBarColor;
        self.titleBarColor = self.titleLabelColor;
        self.titleLabelColor = tmp;
    }
}

- (void)loadDefaults {
    self.closeButtonColor = [UIColor colorWithRed:1.0 green:0.38 blue:0.38 alpha:1.0];
    self.minButtonColor = [UIColor colorWithRed:1.0 green:0.91 blue:0.38 alpha:1.0];
    self.maxButtonColor = [UIColor colorWithRed:0.38 green:1.0 blue:0.38 alpha:1.0];
    self.titleBarColor = [UIColor colorWithRed:0.91 green:0.91 blue:0.91 alpha:1.0];
    self.titleLabelColor = [UIColor colorWithRed:0.33 green:0.33 blue:0.33 alpha:1.0];
    self.stretchButtonColor = [UIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:0.25];

    self.closeButtonFrame = CGRectMake(4, 4, 16, 16);
    self.minButtonFrame = CGRectMake(28, 4, 16, 16);
    self.maxButtonFrame = CGRectMake(52, 4, 16, 16);
    self.stretchButtonFrame = CGRectMake(76, 0, 24, 24);
    self.titleLabelFrame = CGRectMake(44, 0, 44, 24);

    self.closeButtonCornerRadius = 8;
    self.minButtonCornerRadius = 8;
    self.maxButtonCornerRadius = 8;
    self.stretchButtonCornerRadius = 5;

    self.closeButtonAnchor = NSLayoutAttributeLeading;
    self.minButtonAnchor = NSLayoutAttributeLeading;
    self.maxButtonAnchor = NSLayoutAttributeLeading;
    self.stretchButtonAnchor = NSLayoutAttributeTrailing;

    self.titleBarHeight = 24;
    self.titleLabelFontSize = 12;
    self.sizeChangerFrame = CGRectMake(100, 0, 24, 24);

    if ([MWThemeManager isDarkMode]) {
        UIColor *tmp = self.titleBarColor;
        self.titleBarColor = self.titleLabelColor;
        self.titleLabelColor = tmp;
    }
}

@end
