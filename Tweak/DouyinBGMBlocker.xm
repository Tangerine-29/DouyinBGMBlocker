#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface BDSimMediaPlayer : NSObject
@property (nonatomic, strong) id model;
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic) BOOL mute;
@end

@interface AWEPlayVideoAudioMetricsManager : NSObject
@end

@interface AWELongPressPanelViewModel : NSObject
- (BOOL)containsBizVMIdentifier:(NSString *)identifier;
@end

@interface AWELongPressPanelManager : NSObject
+ (instancetype)shareInstance;
- (void)dismissWithAnimation:(BOOL)animation completion:(id)completion;
@end

@interface AWELongPressPanelTableViewController : UITableViewController
@property (nonatomic, strong) AWELongPressPanelViewModel *longPressVM;
@end

@interface AWELongPressPanelSettingCell : UITableViewCell
@end

@interface AWEModernLongPressSettingCell : UITableViewCell
@end

@interface DUXToast : NSObject
+ (void)showText:(NSString *)text;
@end

static NSString * const kDBBLogPrefix = @"[DouyinBGMBlocker]";
static NSString * const kDBBBlockedMusicIDsKey = @"DBBBlockedMusicIDs";
static NSString * const kDBBBlockedMusicMetaKey = @"DBBBlockedMusicMeta";
static NSString * const kDBBBlockedMusicKeywordsKey = @"DBBBlockedMusicKeywords";
static NSString * const kDBBBlockMusicPanelID = @"com.shtm.douyinbgmblocker.blockMusic";
static const void *kDBBMutedByUsKey = &kDBBMutedByUsKey;
static const void *kDBBManageButtonKey = &kDBBManageButtonKey;
static const void *kDBBContentSheetKey = &kDBBContentSheetKey;
static NSString *gAFLastLoggedItemID = nil;
static NSTimeInterval gAFLastLogTime = 0;
static NSHashTable *gAFPlayers = nil;

static void DBBApplyBlockIfNeeded(BDSimMediaPlayer *player, id playModel);
static void DBBSyncAllPlayersMuteState(void);
static void DBBOpenBlockMusicManager(void);
static UIView *DBBCreateManageButtonView(void);

static NSString *DBBString(id obj) {
    if (!obj || obj == (id)kCFNull) return @"";
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    if ([obj isKindOfClass:[NSNumber class]]) return [(NSNumber *)obj stringValue];
    return [obj description];
}

static Class DBBAwemeModelClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ cls = NSClassFromString(@"AWEAwemeModel"); });
    return cls;
}

static id DBBResolveAwemeModel(id playModel) {
    if (!playModel) return nil;
    Class awemeCls = DBBAwemeModelClass();
    if (awemeCls && [playModel isKindOfClass:awemeCls]) return playModel;
    id userInfo = [playModel valueForKey:@"userInfo"];
    if (!userInfo) return nil;
    if ([userInfo isKindOfClass:[NSDictionary class]]) {
        return userInfo[@"awemeModel"] ?: userInfo[@"model"] ?: userInfo[@"aweme"];
    }
    if (awemeCls && [userInfo isKindOfClass:awemeCls]) return userInfo;
    if ([userInfo valueForKey:@"music"]) return userInfo;
    return nil;
}

static NSString *DBBItemIDFromModel(id model) {
    return DBBString([model valueForKey:@"itemID"] ?: [model valueForKey:@"itemId"]);
}

static NSString *DBBMusicIDFromAweme(id aweme) {
    return DBBString([[aweme valueForKey:@"music"] valueForKey:@"musicID"]);
}

static NSString *DBBMusicNameFromAweme(id aweme) {
    if (!aweme) return @"";
    id music = [aweme valueForKey:@"music"];
    if (!music) return @"";

    NSString *name = DBBString([music valueForKey:@"musicName"]);
    if (name.length == 0 && [music respondsToSelector:@selector(musicName)]) {
        name = DBBString([music performSelector:@selector(musicName)]);
    }
    if (name.length > 0) return name;

    NSString *author = DBBString([music valueForKey:@"authorName"] ?: [music valueForKey:@"ownerNickname"]);
    if (author.length > 0) {
        BOOL original = [[music valueForKey:@"isOriginalSound"] boolValue];
        if (original) return [NSString stringWithFormat:@"@%@创作的原声", author];
    }
    return @"";
}

static BOOL DBBIsPreloadStub(id playModel) {
    NSString *itemID = DBBItemIDFromModel(playModel);
    if (itemID.length == 0) return YES;
    return [[playModel valueForKey:@"awemeType"] longLongValue] < 0;
}

static NSArray *DBBBlockedMusicIDList(void) {
    return [NSUserDefaults.standardUserDefaults arrayForKey:kDBBBlockedMusicIDsKey] ?: @[];
}

static NSMutableDictionary *DBBBlockedMusicMeta(void) {
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:kDBBBlockedMusicMetaKey];
    return saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
}

static void DBBPersistBlockedMusicMeta(NSDictionary *meta) {
    [NSUserDefaults.standardUserDefaults setObject:meta forKey:kDBBBlockedMusicMetaKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

static NSArray *DBBBlockedKeywords(void) {
    return [NSUserDefaults.standardUserDefaults arrayForKey:kDBBBlockedMusicKeywordsKey] ?: @[];
}

static void DBBPersistBlockedKeywords(NSArray *keywords) {
    [NSUserDefaults.standardUserDefaults setObject:keywords forKey:kDBBBlockedMusicKeywordsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

static void DBBPersistBlockedMusicIDs(NSArray *list) {
    [NSUserDefaults.standardUserDefaults setObject:list forKey:kDBBBlockedMusicIDsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

static void DBBUpdateMusicMeta(NSString *musicID, NSString *musicName) {
    if (musicID.length == 0 || musicName.length == 0) return;
    if ([musicName isEqualToString:musicID]) return;
    NSMutableDictionary *meta = DBBBlockedMusicMeta();
    NSString *existing = meta[musicID];
    if ([existing isEqualToString:musicName]) return;
    meta[musicID] = musicName;
    DBBPersistBlockedMusicMeta(meta);
}

static NSString *DBBDisplayNameForMusicID(NSString *musicID) {
    NSString *name = DBBBlockedMusicMeta()[musicID];
    if (name.length > 0 && ![name isEqualToString:musicID]) return name;
    return @"";
}

static BOOL DBBIsMusicIDBlocked(NSString *musicID) {
    if (musicID.length == 0) return NO;
    return [DBBBlockedMusicIDList() containsObject:musicID];
}

static NSString *DBBMusicMatchTextFromAweme(id aweme) {
    id music = [aweme valueForKey:@"music"];
    if (!music) return @"";

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    void (^add)(NSString *) = ^(NSString *s) {
        s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (s.length == 0) return;
        for (NSString *existing in parts) {
            if ([existing isEqualToString:s]) return;
        }
        [parts addObject:s];
    };

    add(DBBMusicNameFromAweme(aweme));
    add(DBBString([music valueForKey:@"musicName"]));
    add(DBBString([music valueForKey:@"externalExclusiveSongSubtitle"]));
    add(DBBString([[music valueForKey:@"song"] valueForKey:@"title"]));
    return [parts componentsJoinedByString:@" | "];
}

static NSArray<NSString *> *DBBKeywordTokens(NSString *keyword) {
    if (keyword.length == 0) return @[];

    NSMutableArray<NSString *> *tokens = [NSMutableArray array];
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@",，;；/|"];
    NSArray<NSString *> *chunks = [keyword componentsSeparatedByCharactersInSet:separators];
    if (chunks.count <= 1) {
        
        NSString *trimmed = [keyword stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        return trimmed.length > 0 ? @[trimmed] : @[];
    }

    for (NSString *chunk in chunks) {
        NSString *trimmed = [chunk stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length > 0) [tokens addObject:trimmed];
    }
    return tokens;
}

static BOOL DBBTextMatchesKeyword(NSString *text, NSString *keyword) {
    if (text.length == 0 || keyword.length == 0) return NO;
    NSArray<NSString *> *tokens = DBBKeywordTokens(keyword);
    for (NSString *token in tokens) {
        if (![text localizedCaseInsensitiveContainsString:token]) return NO;
    }
    return YES;
}

static BOOL DBBMusicNameMatchesKeyword(NSString *musicName) {
    if (musicName.length == 0) return NO;
    for (NSString *keyword in DBBBlockedKeywords()) {
        if (DBBTextMatchesKeyword(musicName, keyword)) return YES;
    }
    return NO;
}

static BOOL DBBShouldBlockMusic(NSString *musicID, NSString *matchText) {
    if (DBBIsMusicIDBlocked(musicID)) return YES;
    return DBBMusicNameMatchesKeyword(matchText);
}

static void DBBBlockMusicID(NSString *musicID, NSString *musicName) {
    if (musicID.length == 0) return;
    NSMutableArray *list = [DBBBlockedMusicIDList() mutableCopy];
    if (![list containsObject:musicID]) {
        [list addObject:musicID];
        DBBPersistBlockedMusicIDs(list);
    }
    DBBUpdateMusicMeta(musicID, musicName);
}

static void DBBUnblockMusicIDs(NSArray *musicIDs) {
    if (musicIDs.count == 0) return;
    NSMutableArray *list = [DBBBlockedMusicIDList() mutableCopy];
    NSMutableDictionary *meta = DBBBlockedMusicMeta();
    for (NSString *mid in musicIDs) {
        [list removeObject:mid];
        [meta removeObjectForKey:mid];
    }
    DBBPersistBlockedMusicIDs(list);
    DBBPersistBlockedMusicMeta(meta);
    DBBSyncAllPlayersMuteState();
}

static void DBBAddKeyword(NSString *keyword) {
    NSString *trimmed = [keyword stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return;
    NSMutableArray *list = [DBBBlockedKeywords() mutableCopy];
    for (NSString *existing in list) {
        if ([existing caseInsensitiveCompare:trimmed] == NSOrderedSame) return;
    }
    [list addObject:trimmed];
    DBBPersistBlockedKeywords(list);
    DBBSyncAllPlayersMuteState();
}

static void DBBRemoveKeywords(NSArray *keywords) {
    if (keywords.count == 0) return;
    NSMutableArray *list = [DBBBlockedKeywords() mutableCopy];
    for (NSString *kw in keywords) [list removeObject:kw];
    DBBPersistBlockedKeywords(list);
    DBBSyncAllPlayersMuteState();
}

static void DBBShowToast(NSString *text) {
    Class toastCls = NSClassFromString(@"DUXToast");
    if (toastCls && [toastCls respondsToSelector:@selector(showText:)]) {
        [toastCls performSelector:@selector(showText:) withObject:text];
        return;
    }
    NSLog(@"%@ toast: %@", kDBBLogPrefix, text);
}

static void DBBRegisterPlayer(BDSimMediaPlayer *player) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ gAFPlayers = [NSHashTable weakObjectsHashTable]; });
    if (player) [gAFPlayers addObject:player];
}

static void DBBApplyBlockIfNeeded(BDSimMediaPlayer *player, id playModel) {
    if (!player || DBBIsPreloadStub(playModel)) return;
    id aweme = DBBResolveAwemeModel(playModel);
    NSString *musicID = DBBMusicIDFromAweme(aweme);
    NSString *musicName = DBBMusicNameFromAweme(aweme);
    NSString *matchText = DBBMusicMatchTextFromAweme(aweme);
    if (DBBIsMusicIDBlocked(musicID)) DBBUpdateMusicMeta(musicID, musicName);
    if (DBBShouldBlockMusic(musicID, matchText)) {
        player.mute = YES;
        objc_setAssociatedObject(player, kDBBMutedByUsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if ([objc_getAssociatedObject(player, kDBBMutedByUsKey) boolValue]) {
        player.mute = NO;
        objc_setAssociatedObject(player, kDBBMutedByUsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void DBBSyncAllPlayersMuteState(void) {
    for (BDSimMediaPlayer *player in gAFPlayers) {
        DBBApplyBlockIfNeeded(player, player.model);
    }
}

static void DBBLogAudioContext(NSString *event, BDSimMediaPlayer *player, id playModel) {
    if (DBBIsPreloadStub(playModel)) return;
    NSString *itemID = DBBItemIDFromModel(playModel);
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if ([itemID isEqualToString:gAFLastLoggedItemID] && (now - gAFLastLogTime) < 1.0) return;
    gAFLastLoggedItemID = itemID;
    gAFLastLogTime = now;
    id aweme = DBBResolveAwemeModel(playModel);
    NSString *musicID = DBBMusicIDFromAweme(aweme);
    NSString *musicName = DBBMusicNameFromAweme(aweme);
    NSString *matchText = DBBMusicMatchTextFromAweme(aweme);
    BOOL blocked = DBBShouldBlockMusic(musicID, matchText);
    NSLog(@"%@ %@%@ | itemID=%@ | musicID=%@ name=%@",
          kDBBLogPrefix, event, blocked ? @" [BLOCKED]" : @"", itemID, musicID, musicName);
}

static UIColor *DBBDUXPanelBackgroundColor(void) {
    Class cfg = NSClassFromString(@"AWEModernLongPressPanelUIConfig");
    if (cfg && [cfg respondsToSelector:@selector(panelBackgroundColor)]) {
        UIColor *c = ((id (*)(id, SEL))objc_msgSend)(cfg, @selector(panelBackgroundColor));
        if (c) return c;
    }
    if (@available(iOS 13.0, *)) return UIColor.systemBackgroundColor;
    return UIColor.whiteColor;
}

static UIColor *DBBDUXItemTitleColor(void) {
    Class cfg = NSClassFromString(@"AWEModernLongPressPanelUIConfig");
    if (cfg && [cfg respondsToSelector:@selector(itemTitleColor)]) {
        UIColor *c = ((id (*)(id, SEL))objc_msgSend)(cfg, @selector(itemTitleColor));
        if (c) return c;
    }
    if (@available(iOS 13.0, *)) return UIColor.labelColor;
    return UIColor.blackColor;
}

static UIColor *DBBDUXItemSubtitleColor(void) {
    Class cfg = NSClassFromString(@"AWEModernLongPressPanelUIConfig");
    if (cfg && [cfg respondsToSelector:@selector(itemSubTitleColor)]) {
        UIColor *c = ((id (*)(id, SEL))objc_msgSend)(cfg, @selector(itemSubTitleColor));
        if (c) return c;
    }
    if (@available(iOS 13.0, *)) return UIColor.secondaryLabelColor;
    return UIColor.darkGrayColor;
}

static UIColor *DBBDUXItemIconColor(void) {
    Class cfg = NSClassFromString(@"AWEModernLongPressPanelUIConfig");
    if (cfg && [cfg respondsToSelector:@selector(itemIconColor)]) {
        UIColor *c = ((id (*)(id, SEL))objc_msgSend)(cfg, @selector(itemIconColor));
        if (c) return c;
    }
    return [UIColor colorWithWhite:1.0 alpha:0.9];
}

static UIColor *DBBDUXSectionBackgroundColor(void) {
    Class cfg = NSClassFromString(@"AWEModernLongPressPanelUIConfig");
    if (cfg && [cfg respondsToSelector:@selector(sectionBackgroundColor)]) {
        UIColor *c = ((id (*)(id, SEL))objc_msgSend)(cfg, @selector(sectionBackgroundColor));
        if (c) return c;
    }
    if (@available(iOS 13.0, *)) return UIColor.secondarySystemGroupedBackgroundColor;
    return [UIColor colorWithWhite:0.95 alpha:1.0];
}

static UIImage *DBBInfoIconImage(void) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightMedium];
        UIImage *img = [UIImage systemImageNamed:@"exclamationmark.circle" withConfiguration:config];
        if (img) {
            return [img imageWithTintColor:DBBDUXItemSubtitleColor() renderingMode:UIImageRenderingModeAlwaysOriginal];
        }
    }
    return nil;
}

static UIImage *DBBDUXIconNamed(NSString *name, CGFloat size, id color) {
    Class imgCls = [UIImage class];
    CGSize iconSize = CGSizeMake(size, size);
    if ([imgCls respondsToSelector:@selector(iesll_dux_iconNamed:size:uiColor:)] && [color isKindOfClass:[UIColor class]]) {
        UIImage *img = ((UIImage *(*)(id, SEL, id, CGSize, UIColor *))objc_msgSend)(
            imgCls, @selector(iesll_dux_iconNamed:size:uiColor:), name, iconSize, (UIColor *)color);
        if (img) return img;
    }
    if ([imgCls respondsToSelector:@selector(dux_iconNamed:size:color:)]) {
        UIImage *img = ((UIImage *(*)(id, SEL, id, CGSize, id))objc_msgSend)(
            imgCls, @selector(dux_iconNamed:size:color:), name, iconSize, color);
        if (img) return img;
    }
    return nil;
}

static UIImage *DBBSettingsIconImage(UIColor *tint) {
    id colorArg = tint ?: DBBDUXItemIconColor();
    NSArray *names = @[@"IconSettingOutlined", @"IconSettingFill", @"IconSliderSettingsOutlined", @"IconControlOutlined"];
    for (NSString *name in names) {
        UIImage *img = DBBDUXIconNamed(name, 20, colorArg);
        if (img) return img;
        if ([colorArg isKindOfClass:[UIColor class]]) {
            img = DBBDUXIconNamed(name, 20, @"TextSecondary");
            if (img) return img;
        }
    }
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
        UIImage *img = [UIImage systemImageNamed:@"gearshape" withConfiguration:config];
        if (img && [colorArg isKindOfClass:[UIColor class]]) {
            return [img imageWithTintColor:(UIColor *)colorArg renderingMode:UIImageRenderingModeAlwaysOriginal];
        }
    }
    return nil;
}

static void DBBConfigureManageContentSheet(id sheet, UITableView *tableView) {
    if (!sheet) return;
    if ([sheet respondsToSelector:@selector(setEnableDragRightToDismiss:)]) {
        [sheet setValue:@NO forKey:@"enableDragRightToDismiss"];
    }
    if (tableView) {
        [sheet setValue:tableView forKey:@"orignScrollView"];
        if ([sheet respondsToSelector:@selector(updateSheetPresentationControllerObserveScrollView)]) {
            ((void (*)(id, SEL))objc_msgSend)(sheet, @selector(updateSheetPresentationControllerObserveScrollView));
        }
    }
}

@interface DBBBlockMusicManageViewController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIView *navBar;
@property (nonatomic, strong) UILabel *navTitleLabel;
@property (nonatomic, strong) UIButton *navLeftButton;
@property (nonatomic, strong) UIButton *navRightButton;
@property (nonatomic, strong) UIView *batchToolbar;
@property (nonatomic, strong) UIButton *batchUnblockButton;
@property (nonatomic, strong) NSLayoutConstraint *tableBottomConstraint;
@property (nonatomic, strong) NSMutableArray<NSString *> *keywords;
@property (nonatomic, strong) NSMutableArray<NSString *> *blockedIDs;
@property (nonatomic, strong) NSMutableSet<NSString *> *selectedIDs;
@property (nonatomic, assign) BOOL batchMode;
@end

@implementation DBBBlockMusicManageViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = DBBDUXPanelBackgroundColor();
    [self setupNavigationBar];
    [self setupTableView];
    [self reloadData];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    DBBConfigureManageContentSheet(objc_getAssociatedObject(self, kDBBContentSheetKey), self.tableView);
}

- (void)updateNavRightButtonTitle {
    Class navCls = NSClassFromString(@"DUXNavigationBar");
    if (navCls && [self.navBar isKindOfClass:navCls]) {
        id nav = self.navBar;
        if ([nav respondsToSelector:@selector(removeAllRightAction)]) {
            [nav performSelector:@selector(removeAllRightAction)];
        }
        __weak typeof(self) weakSelf = self;
        NSString *title = self.batchMode ? @"完成" : @"多选";
        if ([nav respondsToSelector:@selector(addRightActionWithText:onClickBlock:)]) {
            ((void (*)(id, SEL, id, id))objc_msgSend)(nav, @selector(addRightActionWithText:onClickBlock:), title, ^{
                [weakSelf toggleBatchMode];
            });
        }
        return;
    }
    [self.navRightButton setTitle:(self.batchMode ? @"完成" : @"多选") forState:UIControlStateNormal];
}

- (void)setupNavigationBar {
    Class navCls = NSClassFromString(@"DUXNavigationBar");
    if (navCls) {
        id nav = [[navCls alloc] initWithFrame:CGRectZero];
        if ([nav isKindOfClass:[UIView class]]) {
            UIView *navView = (UIView *)nav;
            navView.translatesAutoresizingMaskIntoConstraints = NO;
            navView.backgroundColor = DBBDUXPanelBackgroundColor();
            [nav setValue:@"音频屏蔽管理" forKey:@"title"];
            [self.view addSubview:navView];
            self.navBar = navView;

            __weak typeof(self) weakSelf = self;
            if ([nav respondsToSelector:@selector(addLeftActionWithText:onClickBlock:)]) {
                ((void (*)(id, SEL, id, id))objc_msgSend)(nav, @selector(addLeftActionWithText:onClickBlock:), @"关闭", ^{
                    [weakSelf closeTapped];
                });
            }
            [self updateNavRightButtonTitle];

            [NSLayoutConstraint activateConstraints:@[
                [navView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
                [navView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
                [navView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
                [navView.heightAnchor constraintEqualToConstant:52],
            ]];
            return;
        }
    }

    UIView *bar = [[UIView alloc] init];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = DBBDUXPanelBackgroundColor();
    [self.view addSubview:bar];
    self.navBar = bar;

    UIView *leftSlot = [[UIView alloc] init];
    UIView *rightSlot = [[UIView alloc] init];
    leftSlot.translatesAutoresizingMaskIntoConstraints = NO;
    rightSlot.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:leftSlot];
    [bar addSubview:rightSlot];

    UIButton *left = [UIButton buttonWithType:UIButtonTypeSystem];
    [left setTitle:@"关闭" forState:UIControlStateNormal];
    left.titleLabel.font = [UIFont systemFontOfSize:16];
    [left setTitleColor:DBBDUXItemTitleColor() forState:UIControlStateNormal];
    [left addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
    left.translatesAutoresizingMaskIntoConstraints = NO;
    [left setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [leftSlot addSubview:left];
    self.navLeftButton = left;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"音频屏蔽管理";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = DBBDUXItemTitleColor();
    title.textAlignment = NSTextAlignmentCenter;
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:title];
    self.navTitleLabel = title;

    UIButton *right = [UIButton buttonWithType:UIButtonTypeSystem];
    [right setTitle:@"多选" forState:UIControlStateNormal];
    right.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [right setTitleColor:DBBDUXItemTitleColor() forState:UIControlStateNormal];
    [right addTarget:self action:@selector(toggleBatchMode) forControlEvents:UIControlEventTouchUpInside];
    right.translatesAutoresizingMaskIntoConstraints = NO;
    [right setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [rightSlot addSubview:right];
    self.navRightButton = right;

    UIView *sep = [[UIView alloc] init];
    sep.backgroundColor = [DBBDUXItemSubtitleColor() colorWithAlphaComponent:0.25];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [bar addSubview:sep];

    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bar.heightAnchor constraintEqualToConstant:52],

        [leftSlot.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor constant:8],
        [leftSlot.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [leftSlot.widthAnchor constraintEqualToConstant:72],
        [left.leadingAnchor constraintEqualToAnchor:leftSlot.leadingAnchor],
        [left.trailingAnchor constraintLessThanOrEqualToAnchor:leftSlot.trailingAnchor],
        [left.centerYAnchor constraintEqualToAnchor:leftSlot.centerYAnchor],

        [rightSlot.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor constant:-8],
        [rightSlot.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [rightSlot.widthAnchor constraintEqualToConstant:72],
        [right.trailingAnchor constraintEqualToAnchor:rightSlot.trailingAnchor],
        [right.leadingAnchor constraintGreaterThanOrEqualToAnchor:rightSlot.leadingAnchor],
        [right.centerYAnchor constraintEqualToAnchor:rightSlot.centerYAnchor],

        [title.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:leftSlot.trailingAnchor constant:4],
        [title.trailingAnchor constraintEqualToAnchor:rightSlot.leadingAnchor constant:-4],

        [sep.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [sep.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor],
        [sep.heightAnchor constraintEqualToConstant:0.5],
    ]];
}

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.backgroundColor = DBBDUXPanelBackgroundColor();
    self.tableView.separatorColor = [DBBDUXItemSubtitleColor() colorWithAlphaComponent:0.2];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 11.0, *)) {
        self.tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [self.view addSubview:self.tableView];

    UIView *toolbar = [[UIView alloc] init];
    toolbar.translatesAutoresizingMaskIntoConstraints = NO;
    toolbar.backgroundColor = DBBDUXPanelBackgroundColor();
    toolbar.hidden = YES;
    [self.view addSubview:toolbar];
    self.batchToolbar = toolbar;

    UIView *toolbarSep = [[UIView alloc] init];
    toolbarSep.backgroundColor = [DBBDUXItemSubtitleColor() colorWithAlphaComponent:0.25];
    toolbarSep.translatesAutoresizingMaskIntoConstraints = NO;
    [toolbar addSubview:toolbarSep];

    UIButton *unblock = [UIButton buttonWithType:UIButtonTypeSystem];
    [unblock setTitle:@"取消屏蔽" forState:UIControlStateNormal];
    unblock.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    [unblock setTitleColor:DBBDUXItemTitleColor() forState:UIControlStateNormal];
    [unblock addTarget:self action:@selector(unblockSelected) forControlEvents:UIControlEventTouchUpInside];
    unblock.translatesAutoresizingMaskIntoConstraints = NO;
    [toolbar addSubview:unblock];
    self.batchUnblockButton = unblock;

    self.tableBottomConstraint = [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.navBar.bottomAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        self.tableBottomConstraint,
        [toolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [toolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [toolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [toolbar.heightAnchor constraintEqualToConstant:52],
        [toolbarSep.topAnchor constraintEqualToAnchor:toolbar.topAnchor],
        [toolbarSep.leadingAnchor constraintEqualToAnchor:toolbar.leadingAnchor],
        [toolbarSep.trailingAnchor constraintEqualToAnchor:toolbar.trailingAnchor],
        [toolbarSep.heightAnchor constraintEqualToConstant:0.5],
        [unblock.centerXAnchor constraintEqualToAnchor:toolbar.centerXAnchor],
        [unblock.centerYAnchor constraintEqualToAnchor:toolbar.centerYAnchor],
    ]];
}

- (void)reloadData {
    self.keywords = [DBBBlockedKeywords() mutableCopy];
    self.blockedIDs = [DBBBlockedMusicIDList() mutableCopy];
    if (!self.selectedIDs) self.selectedIDs = [NSMutableSet set];
    [self.selectedIDs intersectSet:[NSSet setWithArray:self.blockedIDs]];
    [self.tableView reloadData];
    [self updateToolbar];
}

- (void)closeTapped {
    id sheet = objc_getAssociatedObject(self, kDBBContentSheetKey);
    if (sheet && [sheet respondsToSelector:@selector(dismiss:withAnimated:)]) {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(sheet, @selector(dismiss:withAnimated:), nil, YES);
        return;
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)toggleBatchMode {
    self.batchMode = !self.batchMode;
    if (!self.batchMode) [self.selectedIDs removeAllObjects];
    [self updateNavRightButtonTitle];
    [self.tableView setEditing:self.batchMode animated:YES];
    [self updateToolbar];
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)updateToolbar {
    self.batchToolbar.hidden = !self.batchMode;
    self.batchUnblockButton.enabled = self.selectedIDs.count > 0;
    self.batchUnblockButton.alpha = self.selectedIDs.count > 0 ? 1.0 : 0.4;
    if (self.batchMode) {
        self.tableBottomConstraint.active = NO;
        self.tableBottomConstraint = [self.tableView.bottomAnchor constraintEqualToAnchor:self.batchToolbar.topAnchor];
        self.tableBottomConstraint.active = YES;
    } else {
        self.tableBottomConstraint.active = NO;
        self.tableBottomConstraint = [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
        self.tableBottomConstraint.active = YES;
    }
}

- (void)unblockSelected {
    if (self.selectedIDs.count == 0) return;
    DBBUnblockMusicIDs(self.selectedIDs.allObjects);
    DBBShowToast([NSString stringWithFormat:@"已取消屏蔽 %lu 首", (unsigned long)self.selectedIDs.count]);
    self.batchMode = NO;
    [self updateNavRightButtonTitle];
    [self.tableView setEditing:NO animated:YES];
    [self reloadData];
}

- (void)showInfoAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)keywordInfoTapped {
    [self showInfoAlertWithTitle:@"关键词屏蔽"
                         message:@"• 用逗号分隔多个词，歌名须同时包含全部词条才屏蔽\n• 例如 angel,中文：须同时有 angel 和 中文\n• 仅填写 angel 时，只要歌名含 angel 即屏蔽\n• 左滑可删除关键词"];
}

- (void)blockedInfoTapped {
    [self showInfoAlertWithTitle:@"已屏蔽音乐"
                         message:@"• 长按视频菜单可快速屏蔽当前 BGM\n• 左滑或右上角多选可取消屏蔽\n• 刷到对应视频后会自动补全歌名"];
}

- (UIView *)buildSectionHeaderForSection:(NSInteger)section width:(CGFloat)width {
    UIView *wrap = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 48)];
    wrap.backgroundColor = DBBDUXPanelBackgroundColor();

    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    title.textColor = DBBDUXItemTitleColor();
    title.text = section == 0 ? @"关键词屏蔽" : @"已屏蔽音乐";
    [wrap addSubview:title];

    UIButton *info = [UIButton buttonWithType:UIButtonTypeCustom];
    info.translatesAutoresizingMaskIntoConstraints = NO;
    [info setImage:DBBInfoIconImage() forState:UIControlStateNormal];
    info.accessibilityLabel = @"说明";
    if (section == 0) {
        [info addTarget:self action:@selector(keywordInfoTapped) forControlEvents:UIControlEventTouchUpInside];
    } else {
        [info addTarget:self action:@selector(blockedInfoTapped) forControlEvents:UIControlEventTouchUpInside];
    }
    [wrap addSubview:info];

    UIView *trailingView = nil;
    if (section == 0) {
        UIButton *add = [UIButton buttonWithType:UIButtonTypeSystem];
        add.translatesAutoresizingMaskIntoConstraints = NO;
        [add setTitle:@"添加" forState:UIControlStateNormal];
        add.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        [add setTitleColor:DBBDUXItemTitleColor() forState:UIControlStateNormal];
        [add addTarget:self action:@selector(addKeywordTapped) forControlEvents:UIControlEventTouchUpInside];
        [wrap addSubview:add];
        trailingView = add;
    } else {
        UILabel *count = [[UILabel alloc] init];
        count.translatesAutoresizingMaskIntoConstraints = NO;
        count.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        count.textColor = DBBDUXItemSubtitleColor();
        count.text = self.blockedIDs.count > 0
            ? [NSString stringWithFormat:@"共 %lu 首", (unsigned long)self.blockedIDs.count]
            : @"暂无";
        [wrap addSubview:count];
        trailingView = count;
    }

    UIView *sep = [[UIView alloc] init];
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    sep.backgroundColor = [DBBDUXItemSubtitleColor() colorWithAlphaComponent:0.18];
    [wrap addSubview:sep];

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:20],
        [title.centerYAnchor constraintEqualToAnchor:wrap.centerYAnchor],
        [info.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:6],
        [info.centerYAnchor constraintEqualToAnchor:wrap.centerYAnchor],
        [info.widthAnchor constraintEqualToConstant:22],
        [info.heightAnchor constraintEqualToConstant:22],
        [trailingView.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-20],
        [trailingView.centerYAnchor constraintEqualToAnchor:wrap.centerYAnchor],
        [sep.leadingAnchor constraintEqualToAnchor:wrap.leadingAnchor constant:16],
        [sep.trailingAnchor constraintEqualToAnchor:wrap.trailingAnchor constant:-16],
        [sep.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor],
        [sep.heightAnchor constraintEqualToConstant:0.5],
    ]];
    return wrap;
}

- (void)addKeywordTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加屏蔽关键词"
                                                                   message:@"用逗号分隔多个词，歌名须同时包含全部词条才屏蔽。例如 angel,中文"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"例如：angel,中文 或 魔性";
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *text = alert.textFields.firstObject.text;
        DBBAddKeyword(text);
        DBBShowToast(@"关键词已添加");
        [weakSelf reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)styleCell:(UITableViewCell *)cell {
    cell.backgroundColor = DBBDUXSectionBackgroundColor();
    cell.textLabel.textColor = DBBDUXItemTitleColor();
    cell.textLabel.font = [UIFont systemFontOfSize:16];
    cell.detailTextLabel.textColor = DBBDUXItemSubtitleColor();
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.tintColor = DBBDUXItemTitleColor();
}

- (void)styleEmptyCell:(UITableViewCell *)cell text:(NSString *)text {
    cell.backgroundColor = DBBDUXSectionBackgroundColor();
    cell.textLabel.text = text;
    cell.textLabel.textColor = DBBDUXItemSubtitleColor();
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.detailTextLabel.text = nil;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return self.keywords.count > 0 ? (NSInteger)self.keywords.count : 1;
    return self.blockedIDs.count > 0 ? (NSInteger)self.blockedIDs.count : 1;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return 48;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return section == 0 ? 10 : 0.01;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [self buildSectionHeaderForSection:section width:tableView.bounds.size.width];
}

- (void)tableView:(UITableView *)tableView willDisplayHeaderView:(UIView *)view forSection:(NSInteger)section {
    (void)tableView;
    (void)view;
    (void)section;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        static NSString * const kKW = @"DBBKeywordCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kKW];
        if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kKW];
        if (self.keywords.count == 0) {
            [self styleEmptyCell:cell text:@"暂无关键词"];
            return cell;
        }
        cell.textLabel.text = self.keywords[(NSUInteger)indexPath.row];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        [self styleCell:cell];
        return cell;
    }

    static NSString * const kID = @"DBBBlockedMusicCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kID];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kID];
    if (self.blockedIDs.count == 0) {
        [self styleEmptyCell:cell text:@"暂无已屏蔽音乐"];
        return cell;
    }
    NSString *mid = self.blockedIDs[(NSUInteger)indexPath.row];
    NSString *name = DBBDisplayNameForMusicID(mid);
    cell.textLabel.text = name.length > 0 ? name : @"未知背景音乐";
    cell.detailTextLabel.text = mid;
    if (self.batchMode) {
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.accessoryType = [self.selectedIDs containsObject:mid] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    [self styleCell:cell];
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0 && self.keywords.count == 0) return NO;
    if (indexPath.section == 1 && self.blockedIDs.count == 0) return NO;
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) return UITableViewCellEditingStyleDelete;
    return self.batchMode ? UITableViewCellEditingStyleNone : UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section == 0) {
        NSString *kw = self.keywords[(NSUInteger)indexPath.row];
        DBBRemoveKeywords(@[kw]);
        [self reloadData];
        return;
    }
    NSString *mid = self.blockedIDs[(NSUInteger)indexPath.row];
    DBBUnblockMusicIDs(@[mid]);
    [self reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 1 || !self.batchMode || self.blockedIDs.count == 0) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    NSString *mid = self.blockedIDs[(NSUInteger)indexPath.row];
    if ([self.selectedIDs containsObject:mid]) {
        [self.selectedIDs removeObject:mid];
    } else {
        [self.selectedIDs addObject:mid];
    }
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
    [self updateToolbar];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    if (indexPath.section != 1 || self.batchMode || self.blockedIDs.count == 0) return nil;
    NSString *mid = self.blockedIDs[(NSUInteger)indexPath.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                      title:@"取消屏蔽"
                                                                    handler:^(__kindof UIContextualAction *action, __kindof UIView *sourceView, void (^completionHandler)(BOOL)) {
        DBBUnblockMusicIDs(@[mid]);
        [self reloadData];
        completionHandler(YES);
    }];
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[del]];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

@end

static UIViewController *DBBTopViewController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) { window = w; break; }
        }
    }
    UIViewController *vc = window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) {
        vc = ((UINavigationController *)vc).visibleViewController;
    }
    if ([vc isKindOfClass:[UITabBarController class]]) {
        vc = ((UITabBarController *)vc).selectedViewController;
        if ([vc isKindOfClass:[UINavigationController class]]) {
            vc = ((UINavigationController *)vc).visibleViewController;
        }
    }
    return vc;
}

static void DBBOpenBlockMusicManager(void) {
    Class mgrCls = NSClassFromString(@"AWELongPressPanelManager");
    id mgr = [mgrCls performSelector:@selector(shareInstance)];
    void (^present)(void) = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            DBBBlockMusicManageViewController *vc = [DBBBlockMusicManageViewController new];
            UIViewController *host = DBBTopViewController();
            Class sheetCls = NSClassFromString(@"DUXContentSheet");
            if (sheetCls && host) {
                CGFloat height = MIN(UIScreen.mainScreen.bounds.size.height * 0.72, 640.0);
                id sheet = ((id (*)(id, SEL, id, unsigned long long, double))objc_msgSend)(
                    [sheetCls alloc], @selector(initWithRootViewController:withTopType:withHeight:), vc, 1UL, height);
                if (sheet) {
                    [sheet setValue:@NO forKey:@"enableDragRightToDismiss"];
                    objc_setAssociatedObject(vc, kDBBContentSheetKey, sheet, OBJC_ASSOCIATION_ASSIGN);
                    if ([sheet respondsToSelector:@selector(showOnViewController:completion:)]) {
                        ((void (*)(id, SEL, id, id))objc_msgSend)(sheet, @selector(showOnViewController:completion:), host, nil);
                        return;
                    }
                }
            }
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            nav.modalPresentationStyle = UIModalPresentationPageSheet;
            [host presentViewController:nav animated:YES completion:nil];
        });
    };
    if (mgr) {
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(mgr, @selector(dismissWithAnimation:completion:), YES, present);
    } else {
        present();
    }
}

static void DBBManageButtonTapped(id sender, SEL _cmd) {
    (void)sender;
    (void)_cmd;
    DBBOpenBlockMusicManager();
}

static UIView *DBBCreateManageButtonView(void) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, 0, 32, 32);
    btn.accessibilityLabel = @"音频屏蔽管理";
    UIImage *icon = DBBSettingsIconImage(DBBDUXItemIconColor());
    [btn setImage:icon forState:UIControlStateNormal];
    btn.imageView.contentMode = UIViewContentModeScaleAspectFit;
    if (@available(iOS 14.0, *)) {
        [btn addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            DBBOpenBlockMusicManager();
        }] forControlEvents:UIControlEventTouchUpInside];
    } else {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            class_addMethod([UIButton class], @selector(af_openBlockMusicManager), (IMP)DBBManageButtonTapped, "v@:");
        });
        [btn addTarget:btn action:@selector(af_openBlockMusicManager) forControlEvents:UIControlEventTouchUpInside];
    }
    return btn;
}

static UIImage *DBBBlockMusicIconImage(BOOL blocked) {
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium];
        NSString *name = blocked ? @"checkmark.circle.fill" : @"speaker.slash.fill";
        UIImage *image = [UIImage systemImageNamed:name withConfiguration:config];
        if (!image) image = [UIImage systemImageNamed:@"music.note" withConfiguration:config];
        if (image) return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

static void DBBCopyPanelIconStyleFromGroup(id blockVM, id group) {
    if (!blockVM || !group) return;
    for (id item in [group valueForKey:@"groupArr"] ?: @[]) {
        if (item == blockVM) continue;
        UIColor *color = [item valueForKey:@"duxIconColor"];
        if (!color) continue;
        [blockVM setValue:color forKey:@"duxIconColor"];
        UIColor *selectedColor = [item valueForKey:@"duxIconSelectedColor"];
        if (selectedColor) [blockVM setValue:selectedColor forKey:@"duxIconSelectedColor"];
        return;
    }
}

static UIColor *DBBPanelIconTintColor(id vm, UITableViewCell *cell) {
    BOOL selected = [[vm valueForKey:@"showSelected"] boolValue];
    UIColor *color = selected ? [vm valueForKey:@"duxIconSelectedColor"] : [vm valueForKey:@"duxIconColor"];
    if (!color && selected) color = [vm valueForKey:@"duxIconColor"];
    if (color) return color;

    UILabel *title = [cell valueForKey:@"titleLable"] ?: [cell valueForKey:@"titleLabel"];
    if (title.textColor) {
        CGFloat white = 0, alpha = 0;
        if ([title.textColor getWhite:&white alpha:&alpha]) {
            if (white > 0.01 || alpha > 0.01) return title.textColor;
        } else {
            return title.textColor;
        }
    }

    
    return [UIColor colorWithWhite:1.0 alpha:0.9];
}

static void DBBApplyIconToCell(id vm, UITableViewCell *cell) {
    UIImage *icon = [vm valueForKey:@"iconImage"];
    UIImageView *iconView = [cell valueForKey:@"iconImageView"];
    if (!icon || !iconView) return;

    UIColor *tint = DBBPanelIconTintColor(vm, cell);
    if (@available(iOS 13.0, *)) {
        icon = [icon imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
    }
    iconView.image = icon;
    iconView.tintColor = tint;
}

static void DBBApplyManageButtonToCell(id vm, UITableViewCell *cell) {
    UIButton *btn = objc_getAssociatedObject(cell, kDBBManageButtonKey);
    if (!btn) {
        btn = (UIButton *)DBBCreateManageButtonView();
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:btn];
        [NSLayoutConstraint activateConstraints:@[
            [btn.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-32],
            [btn.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor],
            [btn.widthAnchor constraintEqualToConstant:32],
            [btn.heightAnchor constraintEqualToConstant:32],
        ]];
        objc_setAssociatedObject(cell, kDBBManageButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIImage *icon = DBBSettingsIconImage(DBBPanelIconTintColor(vm, cell));
    [btn setImage:icon forState:UIControlStateNormal];
    [vm setValue:btn forKey:@"rightSubView"];
    [vm setValue:@(36) forKey:@"rightSpace"];
}

static BOOL DBBPanelItemLooksLikeActionCell(id item) {
    if ([item valueForKey:@"shareItem"]) return NO;
    if ([[item valueForKey:@"hasShareFriend"] boolValue]) return NO;
    NSString *desc = [item valueForKey:@"describeString"];
    if (desc.length > 0) return YES;
    if ([item respondsToSelector:@selector(panelBizVMIdentifier)]) {
        NSString *biz = [item performSelector:@selector(panelBizVMIdentifier)];
        if (biz.length > 0 && ![biz.lowercaseString containsString:@"share"]) return YES;
    }
    return NO;
}

static BOOL DBBPanelGroupIsShareSection(id group) {
    for (id item in [group valueForKey:@"groupArr"] ?: @[]) {
        if ([item valueForKey:@"shareItem"]) return YES;
        if ([[item valueForKey:@"hasShareFriend"] boolValue]) return YES;
    }
    return NO;
}

static Class DBBBlockMusicVMClass(void);

static id DBBFindActionGroup(NSArray *panelDataArr) {
    id fallback = nil;
    for (id group in panelDataArr) {
        if (DBBPanelGroupIsShareSection(group)) continue;
        NSArray *groupArr = [group valueForKey:@"groupArr"];
        if (groupArr.count == 0) continue;
        for (id item in groupArr) {
            if (DBBPanelItemLooksLikeActionCell(item)) return group;
        }
        if (!fallback) fallback = group;
    }
    return fallback;
}

static NSString *DBBBlockMusicPanelBizID(id self, SEL _cmd) {
    return kDBBBlockMusicPanelID;
}

static BOOL DBBBlockMusicNeedShow(id self, SEL _cmd) {
    return DBBMusicIDFromAweme([self valueForKey:@"awemeModel"]).length > 0;
}

static void DBBBlockMusicConfigVM(id self, SEL _cmd) {
    id aweme = [self valueForKey:@"awemeModel"];
    NSString *musicID = DBBMusicIDFromAweme(aweme);
    NSString *musicName = DBBMusicNameFromAweme(aweme);
    NSString *matchText = DBBMusicMatchTextFromAweme(aweme);
    BOOL idBlocked = DBBIsMusicIDBlocked(musicID);
    BOOL keywordBlocked = !idBlocked && DBBMusicNameMatchesKeyword(matchText);
    BOOL blocked = idBlocked || keywordBlocked;

    [self setValue:(idBlocked ? @"取消屏蔽背景音乐" : @"屏蔽背景音乐") forKey:@"describeString"];
    [self setValue:[self valueForKey:@"describeString"] forKey:@"describeSelectedString"];
    if (keywordBlocked) {
        [self setValue:@"已命中关键词屏蔽" forKey:@"subtitleString"];
    } else {
        [self setValue:musicName forKey:@"subtitleString"];
    }
    [self setValue:@(blocked) forKey:@"showSelected"];
    [self setValue:@(idBlocked) forKey:@"haveSelectedState"];
    [self setValue:@(999) forKey:@"priority"];
    DBBCopyPanelIconStyleFromGroup(self, [self valueForKey:@"currentGroupModel"]);
    [self setValue:DBBCreateManageButtonView() forKey:@"rightSubView"];
    [self setValue:@(36) forKey:@"rightSpace"];

    UIImage *icon = DBBBlockMusicIconImage(blocked);
    if (icon) [self setValue:icon forKey:@"iconImage"];

    __weak id weakSelf = self;
    [self setValue:^{
        id strongSelf = weakSelf;
        if (!strongSelf) return;
        id model = [strongSelf valueForKey:@"awemeModel"];
        NSString *mid = DBBMusicIDFromAweme(model);
        NSString *name = DBBMusicNameFromAweme(model);
        if (name.length == 0) name = DBBString([strongSelf valueForKey:@"subtitleString"]);
        NSString *matchText = DBBMusicMatchTextFromAweme(model);
        if (DBBIsMusicIDBlocked(mid)) {
            DBBUnblockMusicIDs(@[mid]);
            DBBShowToast(@"已取消屏蔽该背景音乐");
        } else if (DBBMusicNameMatchesKeyword(matchText)) {
            DBBShowToast(@"该音乐已命中关键词屏蔽，请在管理中修改关键词");
        } else {
            DBBBlockMusicID(mid, name);
            DBBShowToast([NSString stringWithFormat:@"已屏蔽：%@", name]);
        }
        DBBSyncAllPlayersMuteState();
        Class mgrCls = NSClassFromString(@"AWELongPressPanelManager");
        id mgr = [mgrCls performSelector:@selector(shareInstance)];
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(mgr, @selector(dismissWithAnimation:completion:), YES, nil);
    } forKey:@"action"];
}

static void DBBBlockMusicDidUpdateCell(id self, SEL _cmd, id cell) {
    Class superCls = class_getSuperclass(object_getClass(self));
    SEL superSel = @selector(didUpdateCell:);
    if (superCls && [superCls instancesRespondToSelector:superSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, superSel, cell);
    }
    DBBApplyIconToCell(self, cell);
    if ([cell isKindOfClass:[UITableViewCell class]]) {
        DBBApplyManageButtonToCell(self, (UITableViewCell *)cell);
    }
}

static id DBBBlockMusicFactory(id self, SEL _cmd) {
    Class cls = DBBBlockMusicVMClass();
    return cls ? [[cls alloc] init] : nil;
}

static Class DBBBlockMusicVMClass(void) {
    static Class cls;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class base = NSClassFromString(@"AWELongPressPanelBaseViewModel");
        if (!base) return;
        cls = objc_allocateClassPair(base, "DBBLongPressBlockMusicViewModel", 0);
        class_addMethod(cls, @selector(panelBizVMIdentifier), (IMP)DBBBlockMusicPanelBizID, "@@:");
        class_addMethod(cls, @selector(needShow), (IMP)DBBBlockMusicNeedShow, "c@:");
        class_addMethod(cls, @selector(configVM), (IMP)DBBBlockMusicConfigVM, "v@:");
        class_addMethod(cls, @selector(didUpdateCell:), (IMP)DBBBlockMusicDidUpdateCell, "v@:@");
        class_addMethod(object_getClass(cls), @selector(longPressPanelViewModel), (IMP)DBBBlockMusicFactory, "@@:");
        objc_registerClassPair(cls);
    });
    return cls;
}

static void DBBInjectBlockMusicPanelItem(id panelVM) {
    if (!panelVM) return;
    if ([panelVM respondsToSelector:@selector(containsBizVMIdentifier:)] &&
        [panelVM containsBizVMIdentifier:kDBBBlockMusicPanelID]) {
        return;
    }
    NSMutableArray *panelDataArr = [panelVM valueForKey:@"panelDataArr"];
    if (panelDataArr.count == 0) return;
    id targetGroup = DBBFindActionGroup(panelDataArr);
    if (!targetGroup) return;

    NSMutableArray *groupArr = [[targetGroup valueForKey:@"groupArr"] mutableCopy] ?: [NSMutableArray array];
    Class cls = DBBBlockMusicVMClass();
    id blockVM = cls ? [[cls alloc] init] : nil;
    if (!blockVM) return;

    [blockVM setValue:[panelVM valueForKey:@"awemeModel"] forKey:@"awemeModel"];
    [blockVM setValue:[NSClassFromString(@"AWELongPressPanelManager") performSelector:@selector(shareInstance)] forKey:@"panelManager"];
    [blockVM setValue:targetGroup forKey:@"currentGroupModel"];
    [blockVM performSelector:@selector(configVM)];

    [groupArr insertObject:blockVM atIndex:0];
    [targetGroup setValue:groupArr forKey:@"groupArr"];
    [targetGroup setValue:@((long long)groupArr.count) forKey:@"numberOfRowsInSection"];
}

%hook BDSimMediaPlayer

- (void)prepareWithPlayModel:(id)playModel {
    DBBRegisterPlayer(self);
    %orig;
    DBBLogAudioContext(@"prepareWithPlayModel", self, playModel);
    DBBApplyBlockIfNeeded(self, playModel);
}

- (void)prepareToPlay {
    %orig;
    DBBApplyBlockIfNeeded(self, self.model);
}

- (void)playOpt:(BOOL)opt {
    %orig;
    if (opt) DBBApplyBlockIfNeeded(self, self.model);
}

- (void)setMute:(BOOL)mute {
    id model = self.model;
    if (!DBBIsPreloadStub(model)) {
        id aweme = DBBResolveAwemeModel(model);
        if (DBBShouldBlockMusic(DBBMusicIDFromAweme(aweme), DBBMusicMatchTextFromAweme(aweme)) && !mute) {
            mute = YES;
        }
    }
    %orig(mute);
}

%end

%hook AWELongPressPanelSettingCell

- (void)setDefaultUI:(id)vm {
    %orig;
    if ([[vm performSelector:@selector(panelBizVMIdentifier)] isEqual:kDBBBlockMusicPanelID]) {
        DBBApplyIconToCell(vm, self);
        DBBApplyManageButtonToCell(vm, self);
    }
}

%end

%hook AWEModernLongPressSettingCell

- (void)updateUI:(id)vm {
    %orig;
    if ([[vm performSelector:@selector(panelBizVMIdentifier)] isEqual:kDBBBlockMusicPanelID]) {
        DBBApplyIconToCell(vm, self);
        DBBApplyManageButtonToCell(vm, self);
    }
}

%end

%hook AWELongPressPanelViewModel

- (void)setupPanelDataArrWithPanelConfig:(id)config friendsArr:(id)friends hasMore:(BOOL)hasMore {
    %orig;
    DBBInjectBlockMusicPanelItem(self);
}

%end

%hook AWELongPressPanelTableViewController

- (void)loadDataWithAwemeModel:(id)model {
    %orig;
    DBBInjectBlockMusicPanelItem(self.longPressVM);
}

%end

%ctor {
    NSLog(@"%@ tweak loaded | 长按菜单屏蔽 + 管理页 + 关键词", kDBBLogPrefix);
}
