#import "MWHeaders.h"
#import "MWWindowView.h"
#import "MWPassthroughWindow.h"
#import "MWSceneHelper.h"
#import "MWBackgrounderManager.h"
#import "MWThemeManager.h"
#import "MWSettingsWindow.h"

#define SCALE_MODE_PLIST @"/var/mobile/Library/Preferences/com.milkyway.reborn.scalemode.plist"
#define MW_LOG(fmt, ...) NSLog(@"[MilkyWayReborn] " fmt, ##__VA_ARGS__)

// Static retention for RBSAssertions — prevents ARC from releasing them
static NSMutableDictionary *_activeAssertions = nil;
static dispatch_source_t _settingsSetupRetryTimer = nil;

// Helper: find appLayout by walking superview chain
static id mw_findAppLayout(UIView *view) {
    UIView *current = view;
    while (current) {
        if ([current respondsToSelector:@selector(appLayout)]) {
            id layout = [(id)current appLayout];
            if (layout) return layout;
        }
        current = current.superview;
    }
    return nil;
}

// Helper: get bundle ID from SBAppLayout
static NSString *mw_bundleIDFromLayout(id appLayout) {
    if (!appLayout) return nil;

    // Try allItems first (iOS 17+)
    if ([appLayout respondsToSelector:@selector(allItems)]) {
        NSArray *items = [appLayout allItems];
        for (id item in items) {
            if ([item respondsToSelector:@selector(bundleIdentifier)]) {
                NSString *bid = [item bundleIdentifier];
                if (bid) return bid;
            }
        }
    }

    // Try centerItem
    if ([appLayout respondsToSelector:@selector(centerItem)]) {
        id item = [appLayout centerItem];
        if ([item respondsToSelector:@selector(bundleIdentifier)])
            return [item bundleIdentifier];
    }

    // Fallback: rolesToLayoutItemsMap (iOS 13-16)
    id map = nil;
    if ([appLayout respondsToSelector:@selector(rolesToLayoutItemsMap)])
        map = [appLayout rolesToLayoutItemsMap];
    if (!map) map = MW_GetIvar(appLayout, "_rolesToLayoutItemsMap");
    if (map) {
        NSArray *values = [map allValues];
        if ([values count] > 0) {
            id item = values[0];
            if ([item respondsToSelector:@selector(bundleIdentifier)])
                return [item bundleIdentifier];
        }
    }
    return nil;
}

// Helper: get scene ID from SBAppLayout
static NSString *mw_sceneIDFromLayout(id appLayout) {
    if (!appLayout) return nil;

    if ([appLayout respondsToSelector:@selector(allItems)]) {
        NSArray *items = [appLayout allItems];
        for (id item in items) {
            if ([item respondsToSelector:@selector(uniqueIdentifier)]) {
                NSString *uid = [item uniqueIdentifier];
                if (uid) return uid;
            }
        }
    }

    if ([appLayout respondsToSelector:@selector(centerItem)]) {
        id item = [appLayout centerItem];
        if ([item respondsToSelector:@selector(uniqueIdentifier)])
            return [item uniqueIdentifier];
    }

    id map = nil;
    if ([appLayout respondsToSelector:@selector(rolesToLayoutItemsMap)])
        map = [appLayout rolesToLayoutItemsMap];
    if (!map) map = MW_GetIvar(appLayout, "_rolesToLayoutItemsMap");
    if (map) {
        NSArray *values = [map allValues];
        if ([values count] > 0) {
            id item = values[0];
            if ([item respondsToSelector:@selector(uniqueIdentifier)])
                return [item uniqueIdentifier];
        }
    }
    return nil;
}

// Helper: create _UISceneLayerHostContainerView across iOS versions
static _UISceneLayerHostContainerView *mw_createSceneContainer(FBScene *scene) {
    Class containerClass = NSClassFromString(@"_UISceneLayerHostContainerView");
    if (!containerClass) return nil;

    _UISceneLayerHostContainerView *container = nil;

    // iOS 26+: initWithScene:debugDescription:
    if ([containerClass instancesRespondToSelector:@selector(initWithScene:debugDescription:)]) {
        container = [[containerClass alloc] initWithScene:scene debugDescription:@"MilkyWayReborn"];
    }
    // iOS 15-18: initWithScene:
    else if ([containerClass instancesRespondToSelector:@selector(initWithScene:)]) {
        container = [[containerClass alloc] initWithScene:scene];
    }

    return container;
}

static MWPassthroughWindow *mw_ensurePassthroughWindow(void) {
    MWPassthroughWindow *window = [MWPassthroughWindow sharedInstance];
    if (window) return window;

    window = [[MWPassthroughWindow alloc] init];
    window.frame = [UIScreen mainScreen].bounds;
    window.backgroundColor = UIColor.clearColor;
    window.clipsToBounds = YES;
    window.windowLevel = UIWindowLevelAlert - 1;

    if (!window.rootViewController) {
        UIViewController *vc = [[UIViewController alloc] init];
        MWPassthroughView *ptView = [[MWPassthroughView alloc] initWithFrame:window.bounds];
        ptView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        ptView.backgroundColor = UIColor.clearColor;
        vc.view = ptView;
        window.rootViewController = vc;
    }

    [MWPassthroughWindow setSharedInstance:window];
    window.hidden = NO;
    MW_LOG(@"Passthrough window created lazily: %@", window);
    return window;
}

// Helper: create a windowed view from a bundle ID
static void mw_createWindowForApp(NSString *bundleID, NSString *sceneID) {
    if (!bundleID) return;
    MW_LOG(@"Creating window for %@ (scene: %@)", bundleID, sceneID);

    [[MWBackgrounderManager sharedInstance] setForegroundSceneID:(sceneID ?: bundleID) enabled:YES];
    [[MWBackgrounderManager sharedInstance] setForeground:bundleID enabled:YES];
    [MWSceneHelper wakeUpScene:bundleID];

    MWPassthroughWindow *hostWindow = mw_ensurePassthroughWindow();
    if (!hostWindow) {
        MW_LOG(@"ERROR: No host window");
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        FBScene *scene = [MWSceneHelper getFBScene:bundleID];
        MW_LOG(@"Scene lookup result: %@", scene);
        if (!scene && sceneID) {
            scene = [MWSceneHelper getFBScene:sceneID];
            MW_LOG(@"Scene retry with sceneID: %@", scene);
        }
        if (!scene) {
            MW_LOG(@"ERROR: Could not find FBScene for %@", bundleID);
            return;
        }

        // Wake up scene AGAIN right before creating container
        [MWSceneHelper setSceneForeground:scene foreground:YES];

        UIView *contentView = nil;
        _UISceneLayerHostContainerView *container = mw_createSceneContainer(scene);
        MW_LOG(@"Container created: %@", container);

        if (container) {
            // iOS 26: container auto-builds layers in init via _rebuildLayersForReason:
            // iOS 15-16: need manual layer setup
            id containerScene = [container scene];
            if (containerScene && [containerScene respondsToSelector:@selector(layerManager)]) {
                id layerManager = [containerScene layerManager];
                NSArray *layers = [layerManager layers];
                MW_LOG(@"Scene layers count: %lu", (unsigned long)[layers count]);
                if ([layers count] > 0 && [container respondsToSelector:@selector(_createHostViewForLayer:)]) {
                    for (id layer in layers) {
                        UIView *hostView = [container _createHostViewForLayer:layer];
                        if (hostView) {
                            hostView.frame = container.frame;
                            [container addSubview:hostView];
                        }
                    }
                }
            }
            contentView = container;
        }

        if (!contentView) {
            contentView = [MWSceneHelper createLayerHostView:bundleID];
        }
        if (!contentView) {
            MW_LOG(@"ERROR: Could not create content view for %@", bundleID);
            return;
        }

        contentView.frame = [UIScreen mainScreen].bounds;

        MWWindowView *windowView = [[MWWindowView alloc] initWithContentView:contentView
                                                                  identifier:bundleID
                                                                       scene:scene];

        Class sbAppCtrl = NSClassFromString(@"SBApplicationController");
        SBApplication *app = [[sbAppCtrl sharedInstance] applicationWithBundleIdentifier:bundleID];
        windowView.titleLabel.text = app.displayName ?: bundleID;

        UIView *targetView = (UIView *)hostWindow;
        if (hostWindow.rootViewController)
            targetView = hostWindow.rootViewController.view ?: (UIView *)hostWindow;
        [targetView addSubview:windowView];
        [MWPassthroughWindow addWindowedId:bundleID];

        // Start keep-alive timer (Aerial approach - proactively push foreground state)
        [MWSceneHelper startKeepAliveForBundleID:bundleID];

        MW_LOG(@"Window created successfully for %@", bundleID);

        // Acquire RBSAssertion to prevent kernel-level process suspension
        // (Bakgrunnur-style: RBSLegacyAttribute + BKSProcessAssertionPreventTaskSuspend)
        @try {
            Class sbAppCtrl2 = NSClassFromString(@"SBApplicationController");
            SBApplication *theApp = [[sbAppCtrl2 sharedInstance] applicationWithBundleIdentifier:bundleID];
            int pid = 0;
            if ([theApp respondsToSelector:@selector(pid)]) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                    [theApp methodSignatureForSelector:@selector(pid)]];
                [inv setSelector:@selector(pid)]; [inv setTarget:theApp]; [inv invoke];
                [inv getReturnValue:&pid];
            }
            if (pid <= 0 && [theApp respondsToSelector:@selector(processState)]) {
                id ps = [theApp processState];
                if (ps && [ps respondsToSelector:@selector(pid)]) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                        [ps methodSignatureForSelector:@selector(pid)]];
                    [inv setSelector:@selector(pid)]; [inv setTarget:ps]; [inv invoke];
                    [inv getReturnValue:&pid];
                }
            }
            MW_LOG(@"App %@ PID: %d", bundleID, pid);

            if (pid > 0) {
                Class rbsTargetClass = NSClassFromString(@"RBSTarget");
                Class rbsLegacyAttrClass = NSClassFromString(@"RBSLegacyAttribute");
                Class rbsAssertionClass = NSClassFromString(@"RBSAssertion");

                if (rbsTargetClass && rbsLegacyAttrClass && rbsAssertionClass) {
                    RBSTarget *target = [rbsTargetClass targetWithPid:pid];
                    NSUInteger flags = BKSProcessAssertionPreventTaskSuspend |
                                       BKSProcessAssertionPreventTaskThrottleDown |
                                       BKSProcessAssertionWantsForegroundResourcePriority |
                                       BKSProcessAssertionPreventThrottleDownUI;
                    RBSLegacyAttribute *attr = [rbsLegacyAttrClass attributeWithReason:BKSProcessAssertionReasonBackgroundUI flags:flags];
                    RBSAssertion *assertion = [[rbsAssertionClass alloc] initWithExplanation:@"MilkyWayReborn keeping app alive"
                                                                                     target:target
                                                                                 attributes:@[attr]];
                    NSError *error = nil;
                    BOOL acquired = [assertion acquireWithError:&error];
                    if (acquired) {
                        windowView.processAssertion = assertion;
                        // Also store in static dict to prevent ARC release
                        if (!_activeAssertions) _activeAssertions = [NSMutableDictionary new];
                        _activeAssertions[bundleID] = assertion;
                        MW_LOG(@"RBSAssertion acquired AND retained for PID %d: %@", pid, assertion);

                        // Resume the process using Mach task_resume
                        // The process may already be suspended at kernel level
                        mach_port_t task = MACH_PORT_NULL;
                        kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
                        if (kr == KERN_SUCCESS && task != MACH_PORT_NULL) {
                            kr = task_resume(task);
                            MW_LOG(@"task_resume(%d) = %d", pid, kr);
                            mach_port_deallocate(mach_task_self(), task);
                        } else {
                            MW_LOG(@"task_for_pid(%d) failed: %d", pid, kr);
                            // Fallback: use SIGCONT
                            kill(pid, SIGCONT);
                            MW_LOG(@"Sent SIGCONT to %d", pid);
                        }
                    } else {
                        MW_LOG(@"RBSAssertion FAILED for PID %d: %@", pid, error);
                    }
                } else {
                    MW_LOG(@"RBS classes missing: target=%d attr=%d assertion=%d",
                           rbsTargetClass != nil, rbsLegacyAttrClass != nil, rbsAssertionClass != nil);
                }
            } else {
                MW_LOG(@"Could not get PID for %@", bundleID);
            }
        } @catch (NSException *e) {
            MW_LOG(@"RBSAssertion exception: %@", e);
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            [windowView updateLayers];
            [windowView layoutSubviews];
        });
    });
}

void MWOpenBundleInWindow(NSString *bundleID) {
    if (!bundleID.length) return;
    MW_LOG(@"Manual Open in Window requested for %@", bundleID);

    [(SpringBoard *)[UIApplication sharedApplication] launchApplicationWithIdentifier:bundleID suspended:YES];

    __block dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_walltime(NULL, 0), 300 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    __block int attempts = 0;
    dispatch_source_set_event_handler(timer, ^{
        attempts++;
        if (attempts > 25) {
            MW_LOG(@"Manual Open in Window timed out waiting for scene: %@", bundleID);
            dispatch_source_cancel(timer);
            timer = nil;
            return;
        }

        FBScene *scene = [MWSceneHelper getFBScene:bundleID];
        if (!scene) return;

        NSString *sceneID = nil;
        if ([scene respondsToSelector:@selector(identifier)])
            sceneID = [scene identifier];

        MW_LOG(@"Manual Open in Window scene found: %@ for %@", sceneID, bundleID);
        dispatch_source_cancel(timer);
        timer = nil;
        mw_createWindowForApp(bundleID, sceneID ?: bundleID);
    });
    dispatch_resume(timer);
}

static void mw_startSettingsSetupRetry(void) {
    if (_settingsSetupRetryTimer) return;
    MW_LOG(@"Starting settings setup retry timer");
    _settingsSetupRetryTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_settingsSetupRetryTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                              1 * NSEC_PER_SEC,
                              100 * NSEC_PER_MSEC);
    __block int attempts = 0;
    dispatch_source_set_event_handler(_settingsSetupRetryTimer, ^{
        attempts++;
        MW_LOG(@"Settings setup retry attempt %d", attempts);
        [MWSettingsWindow setupIfNeeded];
        if ([MWSettingsWindow isAttached] || attempts >= 30) {
            dispatch_source_cancel(_settingsSetupRetryTimer);
            _settingsSetupRetryTimer = nil;
            MW_LOG(@"Settings setup retry timer stopped, attached=%d", [MWSettingsWindow isAttached]);
        }
    });
    dispatch_resume(_settingsSetupRetryTimer);
}

// ============================================================
#pragma mark - SBApplication: Force Medusa capability
// ============================================================

%hook SBApplication
- (BOOL)isMedusaCapable {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:SCALE_MODE_PLIST];
    if (prefs) {
        NSString *bid = self.bundleIdentifier;
        id val = prefs[bid];
        if (val) return [val boolValue];
    }
    return %orig;
}
%end

// ============================================================
#pragma mark - SpringBoard: Setup passthrough window on launch
// ============================================================

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    MW_LOG(@"SpringBoard launched, setting up MilkyWay Reborn");
    [MWThemeManager sharedInstance];

    mw_ensurePassthroughWindow();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [MWSettingsWindow setupIfNeeded];
    });
    MW_LOG(@"Passthrough window created");
}
%end

// iOS 16 can create the homescreen window/view after SpringBoard launch hooks run.
// Attach the settings button when the homescreen view actually lands in a window.
%hook SBHomeScreenView
- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) {
        [MWSettingsWindow attachToWindow:((UIView *)self).window];
    }
}
%end

%hook SBRootFolderView
- (void)didMoveToWindow {
    %orig;
    if (((UIView *)self).window) {
        [MWSettingsWindow attachToWindow:((UIView *)self).window];
    }
}
%end

// ============================================================
#pragma mark - SBAppLayout: Add helper accessors (legacy compat)
// ============================================================

%hook SBAppLayout
%new
- (NSString *)mw_bundleIdentifier {
    return mw_bundleIDFromLayout(self);
}

%new
- (NSString *)mw_sceneIdentifier {
    return mw_sceneIDFromLayout(self);
}

%new
- (id)rolesToLayoutItemsMap {
    return MW_GetIvar(self, "_rolesToLayoutItemsMap");
}
%end

// ============================================================
#pragma mark - App Switcher: Long press to window
// Hook SBFluidSwitcherItemContainer which HAS appLayout on iOS 26
// ============================================================

%hook SBFluidSwitcherItemContainer
- (id)initWithFrame:(CGRect)frame {
    id orig = %orig;
    if (orig) {
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:orig action:@selector(mw_longPressAction:)];
        [(UIView *)orig addGestureRecognizer:longPress];
    }
    return orig;
}

%new
- (void)mw_longPressAction:(UIGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    MW_LOG(@"Long press detected on SBFluidSwitcherItemContainer");

    id appLayout = nil;
    if ([self respondsToSelector:@selector(appLayout)])
        appLayout = [(id)self appLayout];
    if (!appLayout)
        appLayout = mw_findAppLayout((UIView *)self);

    MW_LOG(@"appLayout: %@", appLayout);
    if (!appLayout) return;

    NSString *bundleID = mw_bundleIDFromLayout(appLayout);
    NSString *sceneID = mw_sceneIDFromLayout(appLayout);
    MW_LOG(@"bundleID: %@, sceneID: %@", bundleID, sceneID);
    if (!bundleID) return;

    Class sbAppCtrl = NSClassFromString(@"SBApplicationController");
    SBApplication *app = [[sbAppCtrl sharedInstance] applicationWithBundleIdentifier:bundleID];
    id processState = [app processState];
    if (!processState || ![processState isRunning]) {
        MW_LOG(@"App not running: %@", bundleID);
        return;
    }

    mw_createWindowForApp(bundleID, sceneID);

    // Dismiss switcher
    Class mainSwitcher = NSClassFromString(@"SBMainSwitcherViewController");
    if (mainSwitcher) {
        id switcher = [mainSwitcher sharedInstance];
        Class appLayoutClass = NSClassFromString(@"SBAppLayout");
        if ([switcher respondsToSelector:@selector(_dismissSwitcherNoninteractivelyToAppLayout:dismissFloatingSwitcher:animated:)] &&
            [appLayoutClass respondsToSelector:@selector(homeScreenAppLayout)]) {
            [switcher _dismissSwitcherNoninteractivelyToAppLayout:[appLayoutClass homeScreenAppLayout]
                                          dismissFloatingSwitcher:YES animated:YES];
        }
    }
}
%end

// Also hook SBAppSwitcherPageView as fallback for older iOS
%hook SBAppSwitcherPageView
- (id)initWithFrame:(CGRect)frame {
    id orig = %orig;
    if (orig) {
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:orig action:@selector(mw_longPressAction:)];
        [(UIView *)orig addGestureRecognizer:longPress];
    }
    return orig;
}

%new
- (void)mw_longPressAction:(UIGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    MW_LOG(@"Long press detected on SBAppSwitcherPageView");

    // Walk superview chain to find container with appLayout
    id appLayout = mw_findAppLayout((UIView *)self);
    MW_LOG(@"appLayout from superview walk: %@", appLayout);
    if (!appLayout) return;

    NSString *bundleID = mw_bundleIDFromLayout(appLayout);
    NSString *sceneID = mw_sceneIDFromLayout(appLayout);
    MW_LOG(@"bundleID: %@, sceneID: %@", bundleID, sceneID);
    if (!bundleID) return;

    Class sbAppCtrl = NSClassFromString(@"SBApplicationController");
    SBApplication *app = [[sbAppCtrl sharedInstance] applicationWithBundleIdentifier:bundleID];
    id processState = [app processState];
    if (!processState || ![processState isRunning]) return;

    mw_createWindowForApp(bundleID, sceneID);

    Class mainSwitcher = NSClassFromString(@"SBMainSwitcherViewController");
    if (mainSwitcher) {
        id switcher = [mainSwitcher sharedInstance];
        Class appLayoutClass = NSClassFromString(@"SBAppLayout");
        if ([switcher respondsToSelector:@selector(_dismissSwitcherNoninteractivelyToAppLayout:dismissFloatingSwitcher:animated:)] &&
            [appLayoutClass respondsToSelector:@selector(homeScreenAppLayout)]) {
            [switcher _dismissSwitcherNoninteractivelyToAppLayout:[appLayoutClass homeScreenAppLayout]
                                          dismissFloatingSwitcher:YES animated:YES];
        }
    }
}
%end

// ============================================================
#pragma mark - FBScene: Force foreground for managed scenes
// ============================================================

%hook FBScene
- (void)updateSettings:(id)settings withTransitionContext:(id)ctx completion:(id)completion {
    MWBackgrounderManager *mgr = [MWBackgrounderManager sharedInstance];
    if ([mgr shouldKeepForeground:self]) {
        // ALWAYS let the update through but force foreground=YES
        // Blocking updates prevents RunningBoard from keeping the process alive
        @try {
            id mutableSettings = [settings mutableCopy];
            if (mutableSettings && [mutableSettings respondsToSelector:@selector(setForeground:)]) {
                [mutableSettings setForeground:YES];
                %orig(mutableSettings, ctx, completion);
                return;
            }
        } @catch (NSException *e) {}
    }
    %orig;
}
%end

// ============================================================
#pragma mark - UIMutableApplicationSceneSettings: Force foreground
// Original MilkyWayCore hooks updateSettings:withTransitionContext:completion:
// on BOTH FBScene AND UIMutableApplicationSceneSettings with the SAME logic:
// get _identifier, check foreground arrays, set _foreground=YES on settings.
// On iOS 26, UIMASS uses setDeactivationReasons: separately, so we hook both.
// ============================================================

%hook UIMutableApplicationSceneSettings
- (void)setDeactivationReasons:(unsigned long long)reasons {
    if (reasons != 0) {
        MWBackgrounderManager *mgr = [MWBackgrounderManager sharedInstance];

        // Try to find identifier on self
        NSString *identifier = nil;
        // Try common ivar names
        for (NSString *name in @[@"_identifier", @"_sceneIdentifier", @"_bundleIdentifier"]) {
            identifier = MW_GetIvar(self, [name UTF8String]);
            if (identifier) break;
        }
        if (!identifier && [self respondsToSelector:@selector(identifier)])
            identifier = [(id)self identifier];

        MW_LOG(@"setDeactivationReasons:%llu on %@ | identifier: %@ | managed BIDs: %@ | managed SIDs: %@",
               reasons, NSStringFromClass(object_getClass(self)),
               identifier ?: @"(nil)",
               mgr.foregroundBundleIDs, mgr.foregroundSceneIDs);

        if (identifier) {
            for (NSString *bid in mgr.foregroundBundleIDs) {
                if ([identifier containsString:bid]) {
                    MW_LOG(@"  BLOCKED deactivation (matched bundleID %@)", bid);
                    %orig(0);
                    return;
                }
            }
            for (NSString *sid in mgr.foregroundSceneIDs) {
                if ([sid isEqualToString:identifier]) {
                    MW_LOG(@"  BLOCKED deactivation (matched sceneID %@)", sid);
                    %orig(0);
                    return;
                }
            }
        } else if ([mgr.foregroundBundleIDs count] > 0) {
            MW_LOG(@"  BLOCKED deactivation (no identifier, but managed apps exist)");
            %orig(0);
            return;
        }
    }
    %orig;
}
%end

// ============================================================
#pragma mark - SBApplication: Clean up on exit (matching original)
// Original MilkyWayCore: removes bundleID from arrays, then calls original.
// Does NOT block exit - just cleans up tracked state.
// ============================================================

%hook SBApplication
- (void)_didExitWithContext:(id)ctx {
    MWBackgrounderManager *mgr = [MWBackgrounderManager sharedInstance];
    if ([self respondsToSelector:@selector(bundleIdentifier)]) {
        NSString *bid = [self bundleIdentifier];
        if (bid) {
            [mgr setForeground:bid enabled:NO];
            [MWPassthroughWindow removeWindowedId:bid];
            // Clean up RBS assertion
            id assertion = _activeAssertions[bid];
            if (assertion && [assertion respondsToSelector:@selector(invalidate)])
                [assertion invalidate];
            [_activeAssertions removeObjectForKey:bid];
        }
    }
    %orig;
}
%end

// ============================================================
#pragma mark - _UISceneHostingActivationStateHostComponent:
// This is the THIRD system that controls scene rendering on iOS 26.
// It uses _foregroundAssertionCount to decide if a scene should render.
// Even if FBScene.foreground=YES and deactivationReasons=0,
// this component can independently stop rendering if assertion count is 0.
// ============================================================

%hook _UISceneHostingActivationStateHostComponent
- (void)setForeground:(BOOL)fg {
    if (!fg) {
        // Check if any managed apps should stay foreground
        MWBackgrounderManager *mgr = [MWBackgrounderManager sharedInstance];
        if ([mgr.foregroundBundleIDs count] > 0 || [mgr.foregroundSceneIDs count] > 0) {
            @try {
                id hostScene = nil;
                if ([self respondsToSelector:@selector(hostScene)])
                    hostScene = [self hostScene];

                NSString *sceneId = nil;
                if (hostScene) {
                    if ([hostScene respondsToSelector:@selector(persistentIdentifier)])
                        sceneId = [hostScene performSelector:@selector(persistentIdentifier)];
                    if (!sceneId && [hostScene respondsToSelector:@selector(identityToken)]) {
                        id token = [hostScene performSelector:@selector(identityToken)];
                        if ([token respondsToSelector:@selector(identifier)])
                            sceneId = [token performSelector:@selector(identifier)];
                    }
                }

                if (sceneId) {
                    for (NSString *bid in mgr.foregroundBundleIDs) {
                        if ([sceneId containsString:bid]) {
                            %orig(YES);
                            return;
                        }
                    }
                    for (NSString *sid in mgr.foregroundSceneIDs) {
                        if ([sceneId containsString:sid]) {
                            %orig(YES);
                            return;
                        }
                    }
                }
            } @catch (NSException *e) {}
        }
    }
    %orig;
}
%end

// ============================================================
#pragma mark - FBSceneLayerManager: Notify on layer changes
// ============================================================

%hook FBSceneLayerManager
- (void)_setLayers:(id)layers {
    %orig;
    [MWPassthroughWindow notifyUpdateLayers];
}
%end

// ============================================================
#pragma mark - SBIconView: Context Menu shortcut
// ============================================================

%hook SBIconView
- (NSArray *)applicationShortcutItems {
    NSArray *orig = %orig;

    NSString *appID = nil;
    if ([self respondsToSelector:@selector(applicationBundleIdentifier)])
        appID = [self applicationBundleIdentifier];
    else if ([self respondsToSelector:@selector(applicationBundleIdentifierForShortcuts)])
        appID = [self applicationBundleIdentifierForShortcuts];

    if (!appID) return orig;

    Class shortcutClass = NSClassFromString(@"SBSApplicationShortcutItem");
    if (!shortcutClass) return orig;

    SBSApplicationShortcutItem *item = [[shortcutClass alloc] init];
    item.localizedTitle = @"Open in Window";
    item.bundleIdentifierToLaunch = appID;
    item.type = @"com.milkyway.reborn.openwindow";

    if (!orig) return @[item];
    return [orig arrayByAddingObject:item];
}

+ (void)activateShortcut:(SBSApplicationShortcutItem *)item withBundleIdentifier:(NSString *)bundleID forIconView:(id)iconView {
    if (![[item type] isEqualToString:@"com.milkyway.reborn.openwindow"]) {
        %orig;
        return;
    }

    MW_LOG(@"Open in Window shortcut for %@", bundleID);

    [(SpringBoard *)[UIApplication sharedApplication] launchApplicationWithIdentifier:bundleID suspended:YES];

    __block dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_walltime(NULL, 0), 0.3 * NSEC_PER_SEC, 0);
    __block int attempts = 0;
    dispatch_source_set_event_handler(timer, ^{
        attempts++;
        if (attempts > 20) {
            MW_LOG(@"Timed out waiting for scene for %@", bundleID);
            dispatch_source_cancel(timer);
            timer = nil;
            return;
        }

        FBScene *scene = [MWSceneHelper getFBScene:bundleID];
        if (!scene) return;

        NSString *sceneID = nil;
        if ([scene respondsToSelector:@selector(identifier)])
            sceneID = [scene identifier];
        if (!sceneID) return;

        MW_LOG(@"Scene found: %@ for %@", sceneID, bundleID);
        dispatch_source_cancel(timer);
        timer = nil;

        mw_createWindowForApp(bundleID, sceneID);
    });
    dispatch_resume(timer);
}
%end

// ============================================================
#pragma mark - Constructor
// ============================================================

%ctor {
    @autoreleasepool {
        _activeAssertions = [NSMutableDictionary new];
        [MWBackgrounderManager sharedInstance];
        MW_LOG(@"Loaded (iOS %@)", [[UIDevice currentDevice] systemVersion]);
        mw_startSettingsSetupRetry();

        %init;
    }
}
