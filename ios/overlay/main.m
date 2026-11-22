// RenPy Player - a game library front end for Ren'Py's iOS runtime (renios).
//
// Replaces the stock renios main.c. Before Ren'Py starts, it shows a native
// list of the games found in:
//
//   Documents/games/<Game>/      - copied from the repo's games/ folder by install.sh,
//                                  or added through Finder / the Files app / the + button
//   <app bundle>/games/<Game>/   - games built into the app (not used by default)
//
// When a game is picked, Ren'Py is started with that folder as its base
// directory and a per-game save directory.

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdlib.h>
#include <string.h>

int launcher_main(int argc, char **argv);
int SDL_RunApp(int argc, char **argv, int (*mainFunction)(int, char **), void *reserved);

static NSString *const RPLastPlayedKey = @"RPLastPlayed";

#pragma mark - Paths

static NSURL *RPDocumentsURL(void) {
    return [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
}

static NSURL *RPUserGamesURL(void) {
    return [RPDocumentsURL() URLByAppendingPathComponent:@"games" isDirectory:YES];
}

static NSURL *RPSavesURL(void) {
    return [RPDocumentsURL() URLByAppendingPathComponent:@"saves" isDirectory:YES];
}

static NSURL *RPBundledGamesURL(void) {
    return [NSBundle.mainBundle.resourceURL URLByAppendingPathComponent:@"games" isDirectory:YES];
}

static BOOL RPIsDirectory(NSURL *url) {
    BOOL isDir = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&isDir] && isDir;
}

static NSArray<NSURL *> *RPChildren(NSURL *url) {
    NSArray *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:url
                                                 includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                                    options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                      error:nil];
    return items ?: @[];
}

#pragma mark - Game detection

// A Ren'Py base directory either contains game/, or is itself a game
// directory holding scripts or archives.
static BOOL RPIsBaseDir(NSURL *url) {
    if (RPIsDirectory([url URLByAppendingPathComponent:@"game" isDirectory:YES])) {
        return YES;
    }

    for (NSURL *child in RPChildren(url)) {
        NSString *ext = child.pathExtension.lowercaseString;
        if ([@[@"rpy", @"rpyc", @"rpa"] containsObject:ext]) {
            return YES;
        }
    }

    return NO;
}

// Finds the base directory inside a dropped folder. Handles the folder
// itself, one level of nesting (Game/Game-1.0-pc/game), and Mac builds
// (Game.app/Contents/Resources/autorun/game).
static NSURL *RPResolveBaseDir(NSURL *root) {
    if (RPIsBaseDir(root)) {
        return root;
    }

    NSMutableArray<NSURL *> *candidates = [NSMutableArray array];

    if ([root.pathExtension.lowercaseString isEqualToString:@"app"]) {
        [candidates addObject:[root URLByAppendingPathComponent:@"Contents/Resources/autorun" isDirectory:YES]];
    }

    for (NSURL *child in RPChildren(root)) {
        if (!RPIsDirectory(child)) {
            continue;
        }

        [candidates addObject:child];

        if ([child.pathExtension.lowercaseString isEqualToString:@"app"]) {
            [candidates addObject:[child URLByAppendingPathComponent:@"Contents/Resources/autorun" isDirectory:YES]];
        }
    }

    for (NSURL *candidate in candidates) {
        if (RPIsDirectory(candidate) && RPIsBaseDir(candidate)) {
            return candidate;
        }
    }

    return nil;
}

static NSURL *RPGameDir(NSURL *base) {
    NSURL *game = [base URLByAppendingPathComponent:@"game" isDirectory:YES];
    return RPIsDirectory(game) ? game : base;
}

// Reads `define config.name = "..."` from the game's options.rpy, if present.
static NSString *RPReadConfigName(NSURL *gameDir) {
    NSURL *options = [gameDir URLByAppendingPathComponent:@"options.rpy"];
    NSString *text = [NSString stringWithContentsOfURL:options encoding:NSUTF8StringEncoding error:nil];
    if (!text) {
        return nil;
    }

    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"^\\s*define\\s+config\\.name\\s*=\\s*_?\\(?\\s*[\"'](.+?)[\"']"
                             options:NSRegularExpressionAnchorsMatchLines
                               error:nil];
    NSTextCheckingResult *match = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match) {
        return nil;
    }

    return [text substringWithRange:[match rangeAtIndex:1]];
}

static UIImage *RPReadIcon(NSURL *base) {
    NSURL *gameDir = RPGameDir(base);
    NSArray<NSURL *> *candidates = @[
        [gameDir URLByAppendingPathComponent:@"gui/window_icon.png"],
        [gameDir URLByAppendingPathComponent:@"icon.png"],
        [base URLByAppendingPathComponent:@"ios-icon.png"],
        [base URLByAppendingPathComponent:@"android-icon_foreground.png"],
    ];

    for (NSURL *url in candidates) {
        UIImage *image = [UIImage imageWithContentsOfFile:url.path];
        if (image) {
            return [image imageByPreparingThumbnailOfSize:CGSizeMake(96, 96)] ?: image;
        }
    }

    return nil;
}

#pragma mark - Model

@interface RPGame : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *key;      // Stable id, used for saves and last-played.
@property (nonatomic, strong) NSURL *rootURL;   // The folder that was dropped into games/.
@property (nonatomic, strong) NSURL *baseURL;   // The directory handed to Ren'Py.
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic) BOOL removable;
@end

@implementation RPGame
@end

static NSArray<RPGame *> *RPScanGames(NSURL *folder, BOOL removable) {
    NSMutableArray<RPGame *> *games = [NSMutableArray array];
    NSDictionary *lastPlayed = [NSUserDefaults.standardUserDefaults dictionaryForKey:RPLastPlayedKey];

    for (NSURL *root in RPChildren(folder)) {
        if (!RPIsDirectory(root)) {
            continue;
        }

        NSURL *base = RPResolveBaseDir(root);
        if (!base) {
            continue;
        }

        RPGame *game = [RPGame new];
        game.rootURL = root;
        game.baseURL = base;
        game.key = root.lastPathComponent;
        game.title = RPReadConfigName(RPGameDir(base)) ?: root.lastPathComponent;
        game.icon = RPReadIcon(base);
        game.removable = removable;
        [games addObject:game];
    }

    // Most recently played first, then alphabetical.
    [games sortUsingComparator:^NSComparisonResult(RPGame *a, RPGame *b) {
        NSDate *da = lastPlayed[a.key], *db = lastPlayed[b.key];
        if (da || db) {
            if (!da) return NSOrderedDescending;
            if (!db) return NSOrderedAscending;
            return [db compare:da];
        }
        return [a.title localizedCaseInsensitiveCompare:b.title];
    }];

    return games;
}

#pragma mark - Library UI

@interface RPLibraryViewController : UITableViewController <UIDocumentPickerDelegate>
@property (nonatomic, copy) void (^onSelect)(RPGame *game);
@end

@implementation RPLibraryViewController {
    NSArray<RPGame *> *_userGames;
    NSArray<RPGame *> *_bundledGames;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Ren'Py Games";
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                      target:self
                                                      action:@selector(importGame)];

    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(reload)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];

    [self reload];
}

- (void)reload {
    _userGames = RPScanGames(RPUserGamesURL(), YES);
    _bundledGames = RPScanGames(RPBundledGamesURL(), NO);
    [self.refreshControl endRefreshing];
    [self.tableView reloadData];
    [self updateEmptyState];
}

- (void)updateEmptyState {
    if (_userGames.count || _bundledGames.count) {
        self.tableView.backgroundView = nil;
        return;
    }

    UILabel *label = [UILabel new];
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.secondaryLabelColor;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.text = @"No games yet.\n\n"
                  "Copy an unzipped Ren'Py game folder into\n"
                  "Files › On My iPhone › RenPy Player › games\n"
                  "(or Finder › iPhone › Files on a Mac),\n"
                  "tap + to import a folder,\n"
                  "or put it in the project's games/ folder and run ./install.sh.";
    self.tableView.backgroundView = label;
}

- (NSArray<RPGame *> *)gamesInSection:(NSInteger)section {
    return section == 0 ? _userGames : _bundledGames;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self gamesInSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (![self gamesInSection:section].count) {
        return nil;
    }
    return section == 0 ? @"On This Device" : @"Included With App";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0 && _userGames.count) {
        return @"Add more games through the Files app (RenPy Player › games) or the + button. Swipe left to delete.";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"game"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"game"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }

    RPGame *game = [self gamesInSection:indexPath.section][indexPath.row];
    NSDate *played = [NSUserDefaults.standardUserDefaults dictionaryForKey:RPLastPlayedKey][game.key];

    UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
    content.text = game.title;
    content.secondaryText = played
        ? [@"Last played " stringByAppendingString:[NSDateFormatter localizedStringFromDate:played
                                                                                  dateStyle:NSDateFormatterMediumStyle
                                                                                  timeStyle:NSDateFormatterShortStyle]]
        : game.rootURL.lastPathComponent;
    content.image = game.icon ?: [UIImage systemImageNamed:@"book.closed.fill"];
    content.imageProperties.maximumSize = CGSizeMake(48, 48);
    content.imageProperties.reservedLayoutSize = CGSizeMake(48, 48);
    content.imageProperties.cornerRadius = 8;
    cell.contentConfiguration = content;

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    RPGame *game = [self gamesInSection:indexPath.section][indexPath.row];

    NSMutableDictionary *lastPlayed =
        [[NSUserDefaults.standardUserDefaults dictionaryForKey:RPLastPlayedKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    lastPlayed[game.key] = [NSDate date];
    [NSUserDefaults.standardUserDefaults setObject:lastPlayed forKey:RPLastPlayedKey];

    if (self.onSelect) {
        self.onSelect(game);
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    RPGame *game = [self gamesInSection:indexPath.section][indexPath.row];
    if (!game.removable) {
        return nil;
    }

    UIContextualAction *delete = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive
                            title:@"Delete"
                          handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
                              [self confirmDelete:game completion:completion];
                          }];

    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

- (void)confirmDelete:(RPGame *)game completion:(void (^)(BOOL))completion {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Delete \"%@\"?", game.title]
                                            message:@"The game files are removed from this device. Saves are kept."
                                     preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        completion(NO);
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NSError *error = nil;
        BOOL ok = [NSFileManager.defaultManager removeItemAtURL:game.rootURL error:&error];
        completion(ok);
        if (!ok) {
            [self showError:error.localizedDescription title:@"Couldn't Delete Game"];
        }
        [self reload];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showError:(NSString *)message title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark Import

- (void)importGame {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *source = urls.firstObject;
    if (!source) {
        return;
    }

    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Importing…"
                                                                      message:source.lastPathComponent
                                                               preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:progress animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        BOOL scoped = [source startAccessingSecurityScopedResource];
        NSError *error = nil;
        BOOL ok = NO;

        if (!RPResolveBaseDir(source)) {
            error = [NSError errorWithDomain:@"RenPyPlayer" code:1 userInfo:@{
                NSLocalizedDescriptionKey: @"That folder doesn't look like a Ren'Py game. Pick the folder that contains the game/ directory (unzip it first)."
            }];
        } else {
            [fm createDirectoryAtURL:RPUserGamesURL() withIntermediateDirectories:YES attributes:nil error:nil];

            NSString *name = source.lastPathComponent;
            NSURL *dest = [RPUserGamesURL() URLByAppendingPathComponent:name isDirectory:YES];
            for (int i = 2; [fm fileExistsAtPath:dest.path]; i++) {
                dest = [RPUserGamesURL() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d", name, i]
                                                         isDirectory:YES];
            }

            ok = [fm copyItemAtURL:source toURL:dest error:&error];
        }

        if (scoped) {
            [source stopAccessingSecurityScopedResource];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [progress dismissViewControllerAnimated:YES completion:^{
                if (!ok) {
                    [self showError:error.localizedDescription title:@"Import Failed"];
                }
                [self reload];
            }];
        });
    });
}

@end

#pragma mark - Startup

static UIWindowScene *RPWindowScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) {
            return (UIWindowScene *) scene;
        }
    }
    return nil;
}

static void RPPrepareDocuments(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm createDirectoryAtURL:RPUserGamesURL() withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtURL:RPSavesURL() withIntermediateDirectories:YES attributes:nil error:nil];

    // Games can be many GB and can be copied again from the Mac, so keep them out of
    // iCloud / Finder backups. Saves are still backed up.
    [RPUserGamesURL() setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];

    NSURL *readme = [RPUserGamesURL() URLByAppendingPathComponent:@"PUT GAMES HERE.txt"];
    if (![fm fileExistsAtPath:readme.path]) {
        [@"Copy each Ren'Py game into its own folder here, for example:\n\n"
          "  games/MyGame/game/script.rpy\n\n"
          "Use the unzipped PC/Mac/Linux build of the game. Then reopen RenPy Player.\n"
            writeToURL:readme atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// Shows the library inside SDL's run loop and blocks until a game is picked.
static RPGame *RPChooseGame(void) {
    __block RPGame *chosen = nil;

    @autoreleasepool {
        UIWindowScene *scene;
        while (!(scene = RPWindowScene())) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        }

        RPLibraryViewController *library = [RPLibraryViewController new];
        library.onSelect = ^(RPGame *game) {
            chosen = game;
        };

        UIWindow *window = [[UIWindow alloc] initWithWindowScene:scene];
        window.rootViewController = [[UINavigationController alloc] initWithRootViewController:library];
        [window makeKeyAndVisible];

        while (!chosen) {
            @autoreleasepool {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
            }
        }

        window.hidden = YES;
        window.rootViewController = nil;
    }

    return chosen;
}

// For automated testing: RENPY_PLAYER_AUTOSTART=<game folder name> skips the
// library (e.g. `devicectl device process launch --environment-variables`).
static RPGame *RPAutostartGame(void) {
    const char *key = getenv("RENPY_PLAYER_AUTOSTART");
    if (!key) {
        return nil;
    }

    NSString *wanted = @(key);
    NSArray *games = [RPScanGames(RPUserGamesURL(), YES) arrayByAddingObjectsFromArray:RPScanGames(RPBundledGamesURL(), NO)];
    for (RPGame *game in games) {
        if ([game.key isEqualToString:wanted]) {
            return game;
        }
    }

    NSLog(@"RenPy Player: autostart game %@ not found", wanted);
    return nil;
}

static int RPPlayerMain(int argc, char **argv) {
    RPPrepareDocuments();

    RPGame *game = RPAutostartGame() ?: RPChooseGame();

    NSURL *saves = [RPSavesURL() URLByAppendingPathComponent:game.key isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:saves withIntermediateDirectories:YES attributes:nil error:nil];

    // Picked up by the patched path_to_logdir() in base/main.py, since bundled
    // games live in the read-only app bundle.
    setenv("RENPY_PLAYER_LOGDIR", saves.fileSystemRepresentation, 1);

    NSLog(@"RenPy Player: launching %@ (%@)", game.title, game.baseURL.path);

    // Only pass our own arguments; Xcode may add debugging flags that Ren'Py's
    // argument parser would reject.
    char *args[] = {
        argv[0],
        strdup(game.baseURL.fileSystemRepresentation),
        "--savedir",
        strdup(saves.fileSystemRepresentation),
        NULL,
    };

    return launcher_main(4, args);
}

int main(int argc, char **argv) {
    return SDL_RunApp(argc, argv, RPPlayerMain, NULL);
}
