#import "MWSettingsWindow.h"
#import "MWThemeManager.h"
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define MW_SCALE_MODE_PATH @"/var/mobile/Library/Preferences/com.milkyway.reborn.scalemode.plist"
#define MW_THEME_PATH @"/var/mobile/Library/Preferences/com.milkyway.reborn.theme.plist"
#define MW_SETTINGS_LOG(fmt, ...) NSLog(@"[MilkyWayRebornSettings] " fmt, ##__VA_ARGS__)

extern void MWOpenBundleInWindow(NSString *bundleID);

static UIWindow *gMWSettingsPanelWindow = nil;
static UIView *gMWSettingsButton = nil;

@class MWSettingsButtonWindow;

@interface MWInstalledApp : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleID;
@end

@implementation MWInstalledApp
@end

static NSString *MWStringValue(id object, NSArray<NSString *> *keys) {
    for (NSString *key in keys) {
        id value = nil;
        @try {
            if ([object respondsToSelector:NSSelectorFromString(key)]) {
                value = [object valueForKey:key];
            }
        } @catch (__unused NSException *exception) {
            value = nil;
        }
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 0) return value;
    }
    return nil;
}

static NSArray<MWInstalledApp *> *MWLoadInstalledApps(void) {
    Class workspaceClass = objc_getClass("LSApplicationWorkspace");
    id workspace = nil;
    if ([workspaceClass respondsToSelector:@selector(defaultWorkspace)]) {
        workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, @selector(defaultWorkspace));
    }
    if (!workspace) return @[];

    NSArray *proxies = nil;
    for (NSString *selectorName in @[@"allInstalledApplications", @"allApplications"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![workspace respondsToSelector:selector]) continue;
        proxies = ((NSArray *(*)(id, SEL))objc_msgSend)(workspace, selector);
        if ([proxies isKindOfClass:NSArray.class]) break;
    }
    if (![proxies isKindOfClass:NSArray.class]) return @[];

    NSMutableArray<MWInstalledApp *> *apps = [NSMutableArray array];
    NSMutableSet<NSString *> *seenBundleIDs = [NSMutableSet set];
    for (id proxy in proxies) {
        NSString *bundleID = MWStringValue(proxy, @[@"bundleIdentifier", @"applicationIdentifier"]);
        if (!bundleID.length || [seenBundleIDs containsObject:bundleID]) continue;

        NSString *name = MWStringValue(proxy, @[@"localizedName", @"itemName", @"applicationIdentifier", @"bundleIdentifier"]);
        if (!name.length) name = bundleID;

        MWInstalledApp *app = [MWInstalledApp new];
        app.name = name;
        app.bundleID = bundleID;
        [apps addObject:app];
        [seenBundleIDs addObject:bundleID];
    }

    [apps sortUsingComparator:^NSComparisonResult(MWInstalledApp *left, MWInstalledApp *right) {
        NSComparisonResult result = [left.name localizedCaseInsensitiveCompare:right.name];
        return result == NSOrderedSame ? [left.bundleID compare:right.bundleID] : result;
    }];
    return apps;
}

static NSMutableDictionary *MWLoadScalePrefs(void) {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:MW_SCALE_MODE_PATH];
    return [dict isKindOfClass:[NSDictionary class]] ? [dict mutableCopy] : [NSMutableDictionary dictionary];
}

static BOOL MWWriteScalePref(NSString *bundleID, BOOL enabled) {
    if (!bundleID.length) return NO;
    NSMutableDictionary *dict = MWLoadScalePrefs();
    dict[bundleID] = @(enabled);
    BOOL ok = [dict writeToFile:MW_SCALE_MODE_PATH atomically:YES];
    notify_post("com.milkyway.reborn.preferences.changed");
    return ok;
}

static UIWindowScene *MWActiveWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            if (scene.activationState == UISceneActivationStateForegroundActive ||
                scene.activationState == UISceneActivationStateForegroundInactive) {
                return (UIWindowScene *)scene;
            }
        }
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static UIWindow *MWHomescreenWindow(void) {
    static __weak UIWindow *cachedWindow = nil;
    UIWindow *cached = cachedWindow;
    if (cached.windowScene) return cached;

    Class homeWindowClass = NSClassFromString(@"SBHomeScreenWindow");
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (homeWindowClass && [window isKindOfClass:homeWindowClass]) {
                cachedWindow = window;
                return window;
            }
        }
    }

    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (homeWindowClass && [window isKindOfClass:homeWindowClass]) {
            cachedWindow = window;
            return window;
        }
    }
    return nil;
}

static UIWindow *MWNewWindow(CGRect frame, BOOL buttonWindow) {
    Class windowClass = buttonWindow ? objc_getClass("MWSettingsButtonWindow") : UIWindow.class;
    if (!windowClass) windowClass = UIWindow.class;
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = MWActiveWindowScene();
        if (scene) return [[windowClass alloc] initWithWindowScene:scene];
    }
    return [[windowClass alloc] initWithFrame:frame];
}

@interface MWSettingsButtonWindow : UIWindow
@property (nonatomic, weak) UIView *hitView;
@end

@implementation MWSettingsButtonWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!self.hitView) return nil;
    CGPoint localPoint = [self.hitView convertPoint:point fromView:self];
    if (![self.hitView pointInside:localPoint withEvent:event]) return nil;
    return [self.hitView hitTest:localPoint withEvent:event];
}
@end

@interface MWSettingsFloatButton : UIView
@end

@implementation MWSettingsFloatButton
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.layer.cornerRadius = CGRectGetWidth(frame) * 0.5;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.25;
    self.layer.shadowRadius = 14.0;
    self.layer.shadowOffset = CGSizeMake(0.0, 6.0);

    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:effect];
    blurView.frame = self.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.layer.cornerRadius = self.layer.cornerRadius;
    blurView.layer.masksToBounds = YES;
    blurView.userInteractionEnabled = NO;
    [self addSubview:blurView];

    UILabel *label = [[UILabel alloc] initWithFrame:self.bounds];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.text = @"MW";
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.labelColor;
    label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightBlack];
    label.userInteractionEnabled = NO;
    [self addSubview:label];

    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openSettings)]];
    [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)]];
    return self;
}

- (void)openSettings {
    [MWSettingsWindow presentSettings];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIView *host = self.superview;
    if (!host) return;
    CGPoint delta = [gesture translationInView:host];
    CGPoint center = self.center;
    center.x += delta.x;
    center.y += delta.y;

    CGFloat radius = CGRectGetWidth(self.bounds) * 0.5;
    CGRect bounds = host.bounds;
    center.x = MAX(radius + 8.0, MIN(center.x, CGRectGetWidth(bounds) - radius - 8.0));
    center.y = MAX(radius + 28.0, MIN(center.y, CGRectGetHeight(bounds) - radius - 28.0));
    self.center = center;
    [gesture setTranslation:CGPointZero inView:host];
}
@end

@interface MWSettingsPanelController : UIViewController <UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITextField *bundleField;
@property (nonatomic, strong) UITableView *appsTableView;
@property (nonatomic, strong) UISwitch *scaleSwitch;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, copy) NSArray<MWInstalledApp *> *allApps;
@property (nonatomic, copy) NSArray<MWInstalledApp *> *filteredApps;
@property (nonatomic, copy) NSString *selectedBundleID;
@end

@implementation MWSettingsPanelController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.28];

    CGFloat width = MIN(CGRectGetWidth(UIScreen.mainScreen.bounds) - 32.0, 380.0);
    CGFloat height = MIN(CGRectGetHeight(UIScreen.mainScreen.bounds) - 52.0, 590.0);
    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake((CGRectGetWidth(UIScreen.mainScreen.bounds) - width) * 0.5,
                                                             (CGRectGetHeight(UIScreen.mainScreen.bounds) - height) * 0.5,
                                                             width,
                                                             height)];
    panel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                             UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    panel.layer.cornerRadius = 22.0;
    if (@available(iOS 13.0, *)) panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.clipsToBounds = YES;
    [self.view addSubview:panel];

    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    blurView.frame = panel.bounds;
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.userInteractionEnabled = NO;
    [panel addSubview:blurView];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20.0, 18.0, width - 76.0, 30.0)];
    title.text = @"MilkyWay Reborn";
    title.textColor = UIColor.labelColor;
    title.font = [UIFont systemFontOfSize:22.0 weight:UIFontWeightBold];
    [panel addSubview:title];

    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.frame = CGRectMake(width - 52.0, 14.0, 38.0, 38.0);
    [closeButton setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    closeButton.tintColor = UIColor.secondaryLabelColor;
    [closeButton addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:closeButton];

    UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(20.0, 54.0, width - 40.0, 42.0)];
    subtitle.text = @"内置设置面板，不依赖 PreferenceBundle。搜索应用并点选后即可打开小窗或切换 Scale Mode。";
    subtitle.textColor = UIColor.secondaryLabelColor;
    subtitle.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    subtitle.numberOfLines = 2;
    [panel addSubview:subtitle];

    UILabel *bundleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20.0, 106.0, width - 40.0, 18.0)];
    bundleLabel.text = @"选择应用";
    bundleLabel.textColor = UIColor.secondaryLabelColor;
    bundleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    [panel addSubview:bundleLabel];

    self.bundleField = [[UITextField alloc] initWithFrame:CGRectMake(20.0, 130.0, width - 40.0, 40.0)];
    self.bundleField.borderStyle = UITextBorderStyleRoundedRect;
    self.bundleField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.bundleField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.bundleField.clearButtonMode = UITextFieldViewModeWhileEditing;
    self.bundleField.placeholder = @"搜索应用名或 bundle id";
    self.bundleField.delegate = self;
    [self.bundleField addTarget:self action:@selector(bundleFieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [panel addSubview:self.bundleField];

    self.appsTableView = [[UITableView alloc] initWithFrame:CGRectMake(20.0, 180.0, width - 40.0, 148.0) style:UITableViewStylePlain];
    self.appsTableView.dataSource = self;
    self.appsTableView.delegate = self;
    self.appsTableView.rowHeight = 50.0;
    self.appsTableView.layer.cornerRadius = 12.0;
    self.appsTableView.clipsToBounds = YES;
    self.appsTableView.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.appsTableView.separatorInset = UIEdgeInsetsMake(0.0, 14.0, 0.0, 14.0);
    [panel addSubview:self.appsTableView];

    UIView *scaleRow = [self rowWithTitle:@"Scale Mode"
                                 subtitle:@"启用后 isMedusaCapable hook 会对该 bundle 返回对应设置值。"
                                        y:340.0
                                    width:width];
    self.scaleSwitch = [[UISwitch alloc] initWithFrame:CGRectZero];
    self.scaleSwitch.center = CGPointMake(width - 50.0, CGRectGetMidY(scaleRow.frame));
    [self.scaleSwitch addTarget:self action:@selector(scaleSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [panel addSubview:scaleRow];
    [panel addSubview:self.scaleSwitch];

    UIButton *resetThemeButton = [self actionButtonWithTitle:@"恢复内置默认主题"
                                                       frame:CGRectMake(20.0, 484.0, width - 40.0, 44.0)
                                                     primary:NO];
    [resetThemeButton addTarget:self action:@selector(resetThemeTapped) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:resetThemeButton];

    UIButton *openWindowButton = [self actionButtonWithTitle:@"Open in Window"
                                                       frame:CGRectMake(20.0, 428.0, width - 40.0, 44.0)
                                                     primary:YES];
    [openWindowButton addTarget:self action:@selector(openWindowTapped) forControlEvents:UIControlEventTouchUpInside];
    [panel addSubview:openWindowButton];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20.0, height - 54.0, width - 40.0, 36.0)];
    self.statusLabel.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium];
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.text = @"正在读取已安装应用...";
    [panel addSubview:self.statusLabel];

    [self reloadInstalledApps];
    [self refreshScaleSwitch];
}

- (UIView *)rowWithTitle:(NSString *)title subtitle:(NSString *)subtitle y:(CGFloat)y width:(CGFloat)width {
    UIView *row = [[UIView alloc] initWithFrame:CGRectMake(20.0, y, width - 40.0, 64.0)];
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 6.0, width - 124.0, 22.0)];
    titleLabel.text = title;
    titleLabel.textColor = UIColor.labelColor;
    titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    [row addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 30.0, width - 124.0, 34.0)];
    subtitleLabel.text = subtitle;
    subtitleLabel.textColor = UIColor.secondaryLabelColor;
    subtitleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
    subtitleLabel.numberOfLines = 2;
    [row addSubview:subtitleLabel];
    return row;
}

- (UIButton *)actionButtonWithTitle:(NSString *)title frame:(CGRect)frame primary:(BOOL)primary {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = frame;
    button.layer.cornerRadius = 12.0;
    if (@available(iOS 13.0, *)) button.layer.cornerCurve = kCACornerCurveContinuous;
    button.backgroundColor = primary ? UIColor.systemBlueColor : UIColor.secondarySystemFillColor;
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:(primary ? UIColor.whiteColor : UIColor.labelColor) forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    return button;
}

- (void)bundleFieldChanged:(UITextField *)sender {
    (void)sender;
    self.selectedBundleID = nil;
    [self filterInstalledApps];
    [self refreshScaleSwitch];
}

- (void)reloadInstalledApps {
    self.allApps = MWLoadInstalledApps();
    [self filterInstalledApps];
    self.statusLabel.text = self.allApps.count > 0
        ? [NSString stringWithFormat:@"已读取 %lu 个应用，点选应用后直接打开小窗。", (unsigned long)self.allApps.count]
        : @"读取应用列表失败，可手动输入 bundle id 作为兜底。";
}

- (void)filterInstalledApps {
    NSString *query = self.bundleField.text.lowercaseString;
    if (!query.length) {
        self.filteredApps = self.allApps;
    } else {
        NSMutableArray<MWInstalledApp *> *matches = [NSMutableArray array];
        for (MWInstalledApp *app in self.allApps) {
            if ([app.name.lowercaseString containsString:query] ||
                [app.bundleID.lowercaseString containsString:query]) {
                [matches addObject:app];
            }
        }
        self.filteredApps = matches;
    }
    [self.appsTableView reloadData];
}

- (NSString *)currentBundleID {
    if (self.selectedBundleID.length) return self.selectedBundleID;
    NSString *text = [self.bundleField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return text.length ? text : nil;
}

- (void)refreshScaleSwitch {
    NSString *bundleID = [self currentBundleID];
    NSDictionary *dict = MWLoadScalePrefs();
    id value = bundleID.length ? dict[bundleID] : nil;
    self.scaleSwitch.enabled = bundleID.length > 0;
    self.scaleSwitch.on = [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : NO;
}

- (void)scaleSwitchChanged:(UISwitch *)sender {
    NSString *bundleID = [self currentBundleID];
    BOOL ok = MWWriteScalePref(bundleID, sender.isOn);
    self.statusLabel.text = ok
        ? [NSString stringWithFormat:@"%@ Scale Mode: %@", bundleID, sender.isOn ? @"On" : @"Off"]
        : @"写入失败：请确认 bundle id 不为空，且偏好目录可写。";
}

- (void)resetThemeTapped {
    [NSFileManager.defaultManager removeItemAtPath:MW_THEME_PATH error:nil];
    [[MWThemeManager sharedInstance] reload];
    notify_post("com.milkyway.reborn.preferences.changed");
    self.statusLabel.text = @"已移除自定义主题文件，窗口样式将使用 dylib 内置默认值。";
}

- (void)openWindowTapped {
    NSString *bundleID = [self currentBundleID];
    if (!bundleID.length) {
        self.statusLabel.text = @"先搜索并点选一个应用。读取列表失败时才需要手动输入 bundle id。";
        return;
    }
    [self.view endEditing:YES];
    self.statusLabel.text = [NSString stringWithFormat:@"正在打开 %@ 的小窗...", bundleID];
    MWOpenBundleInWindow(bundleID);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.filteredApps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellID = @"MWInstalledAppCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellID];

    MWInstalledApp *app = self.filteredApps[indexPath.row];
    cell.textLabel.text = app.name;
    cell.textLabel.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    cell.detailTextLabel.text = app.bundleID;
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = [app.bundleID isEqualToString:self.selectedBundleID] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    MWInstalledApp *app = self.filteredApps[indexPath.row];
    self.selectedBundleID = app.bundleID;
    self.bundleField.text = app.name;
    [self.view endEditing:YES];
    [self filterInstalledApps];
    [self refreshScaleSwitch];
    self.statusLabel.text = [NSString stringWithFormat:@"已选择 %@（%@）。", app.name, app.bundleID];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)closePanel {
    [self.view endEditing:YES];
    [gMWSettingsPanelWindow resignKeyWindow];
    gMWSettingsPanelWindow.hidden = YES;
}
@end

@implementation MWSettingsWindow
+ (void)setupIfNeeded {
    if (gMWSettingsButton) return;
    UIWindow *hostWindow = MWHomescreenWindow();
    if (!hostWindow) {
        MW_SETTINGS_LOG(@"homescreen window unavailable, retrying");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [MWSettingsWindow setupIfNeeded];
        });
        return;
    }

    [self attachToWindow:hostWindow];
}

+ (void)attachToWindow:(UIWindow *)hostWindow {
    if (!hostWindow) return;
    if (gMWSettingsButton && gMWSettingsButton.window == hostWindow) {
        [hostWindow bringSubviewToFront:gMWSettingsButton];
        return;
    }

    CGRect bounds = hostWindow.bounds;
    if (CGRectIsEmpty(bounds)) bounds = UIScreen.mainScreen.bounds;
    MW_SETTINGS_LOG(@"setting up floating settings button on %@", hostWindow);

    CGFloat size = 50.0;
    MWSettingsFloatButton *button = [[MWSettingsFloatButton alloc] initWithFrame:CGRectMake(CGRectGetWidth(bounds) - size - 14.0,
                                                                                            CGRectGetHeight(bounds) * 0.62,
                                                                                            size,
                                                                                            size)];
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                              UIViewAutoresizingFlexibleTopMargin |
                              UIViewAutoresizingFlexibleBottomMargin;
    [hostWindow addSubview:button];
    [hostWindow bringSubviewToFront:button];
    gMWSettingsButton = button;

    if (!gMWSettingsPanelWindow) {
        gMWSettingsPanelWindow = MWNewWindow(UIScreen.mainScreen.bounds, NO);
        gMWSettingsPanelWindow.frame = UIScreen.mainScreen.bounds;
        gMWSettingsPanelWindow.windowLevel = UIWindowLevelAlert + 600.0;
        gMWSettingsPanelWindow.backgroundColor = UIColor.clearColor;
        gMWSettingsPanelWindow.rootViewController = [MWSettingsPanelController new];
        gMWSettingsPanelWindow.hidden = YES;
    }
    MW_SETTINGS_LOG(@"floating settings button ready: %@", gMWSettingsButton);
}

+ (void)presentSettings {
    if (!gMWSettingsPanelWindow) [self setupIfNeeded];
    gMWSettingsPanelWindow.hidden = NO;
    [gMWSettingsPanelWindow makeKeyAndVisible];
}

+ (BOOL)isAttached {
    return gMWSettingsButton.window != nil;
}
@end
