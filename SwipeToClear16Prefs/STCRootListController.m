#import "STCRootListController.h"
#import <UIKit/UIKit.h>
#import <spawn.h>
#import <unistd.h>

extern char **environ;

static BOOL STCSpawnTool(const char *tool, char * const argv[]) {
    if (!tool || access(tool, X_OK) != 0) return NO;
    pid_t pid = 0;
    return posix_spawn(&pid, tool, NULL, NULL, argv, environ) == 0;
}

@implementation STCRootListController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"SwipeToClear16";
}

- (void)openRepo {
    NSURL *url = [NSURL URLWithString:@"https://github.com/551UK/SwipeToClear16"];
    if (!url) return;

    UIApplication *application = UIApplication.sharedApplication;
    if ([application respondsToSelector:@selector(openURL:options:completionHandler:)]) {
        [application openURL:url options:@{} completionHandler:nil];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [application openURL:url];
#pragma clang diagnostic pop
    }
}

- (void)respring {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        const char *sbreload = "/var/jb/usr/bin/sbreload";
        if (access(sbreload, X_OK) == 0) {
            char *args[] = {(char *)sbreload, NULL};
            if (STCSpawnTool(sbreload, args)) return;
        }

        const char *rootlessKillall = "/var/jb/usr/bin/killall";
        if (access(rootlessKillall, X_OK) == 0) {
            char *args[] = {(char *)rootlessKillall, (char *)"-9", (char *)"SpringBoard", NULL};
            if (STCSpawnTool(rootlessKillall, args)) return;
        }

        const char *systemKillall = "/usr/bin/killall";
        char *args[] = {(char *)systemKillall, (char *)"-9", (char *)"SpringBoard", NULL};
        STCSpawnTool(systemKillall, args);
    });
}

@end
