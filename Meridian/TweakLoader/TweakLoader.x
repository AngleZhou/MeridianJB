#import <dlfcn.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <stdio.h>
#import <unistd.h>
#import <pthread.h>
#import <sys/stat.h>
#import <sys/types.h>

#define dylibDir @"/usr/lib/Tweaks"

NSArray *generateDylibList() {
    NSString *processName = [[NSProcessInfo processInfo] processName];
    // launchctl, amfid you are special cases
    if ([processName isEqualToString:@"launchctl"]) {
        return nil;
    }
    if ([processName isEqualToString:@"amfid"]) {
        return nil;
    }
    // Create an array containing all the filenames in dylibDir
    NSError *e = nil;
    NSArray *dylibDirContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dylibDir error:&e];
    if (e) {
        return nil;
    }
    // Read current bundle identifier
    //NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    // We're only interested in the plist files
    NSArray *plists = [dylibDirContents filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF ENDSWITH %@", @"plist"]];
    // Create an empty mutable array that will contain a list of dylib paths to be injected into the target process
    NSMutableArray *dylibsToInject = [NSMutableArray array];
    // Loop through the list of plists
    for (NSString *plist in plists) {
        // We'll want to deal with absolute paths, so append the filename to dylibDir
        NSString *plistPath = [dylibDir stringByAppendingPathComponent:plist];
        NSDictionary *filter = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        // This boolean indicates whether or not the dylib has already been injected
        BOOL isInjected = NO;
        // If supported iOS versions are specified within the plist, we check those first
        NSArray *supportedVersions = filter[@"CoreFoundationVersion"];
        if (supportedVersions) {
            if (supportedVersions.count != 1 && supportedVersions.count != 2) {
                continue; // Supported versions are in the wrong format, we should skip
            }
            if (supportedVersions.count == 1 && [supportedVersions[0] doubleValue] > kCFCoreFoundationVersionNumber) {
                continue; // Doesn't meet lower bound
            }
            if (supportedVersions.count == 2 && ([supportedVersions[0] doubleValue] > kCFCoreFoundationVersionNumber || [supportedVersions[1] doubleValue] <= kCFCoreFoundationVersionNumber)) {
                continue; // Outside bounds
            }
        }
        // Decide whether or not to load the dylib based on the Bundles values
        for (NSString *entry in filter[@"Filter"][@"Bundles"]) {
            // Check to see whether or not this bundle is actually loaded in this application or not
            if (!CFBundleGetBundleWithIdentifier((CFStringRef)entry)) {
                // If not, skip it
                continue;
            }
            [dylibsToInject addObject:[[plistPath stringByDeletingPathExtension] stringByAppendingString:@".dylib"]];
            isInjected = YES;
            break;
        }
        if (!isInjected) {
            // Decide whether or not to load the dylib based on the Executables values
            for (NSString *process in filter[@"Filter"][@"Executables"]) {
                if ([process isEqualToString:processName]) {
                    [dylibsToInject addObject:[[plistPath stringByDeletingPathExtension] stringByAppendingString:@".dylib"]];
                    isInjected = YES;
                    break;
                }
            }
        }
        if (!isInjected) {
            // Decide whether or not to load the dylib based on the Classes values
            for (NSString *clazz in filter[@"Filter"][@"Classes"]) {
                // Also check if this class is loaded in this application or not
                if (!NSClassFromString(clazz)) {
                    // This class couldn't be loaded, skip
                    continue;
                }
                // It's fine to add this dylib at this point
                [dylibsToInject addObject:[[plistPath stringByDeletingPathExtension] stringByAppendingString:@".dylib"]];
                isInjected = YES;
                break;
            }
        }
    }
    [dylibsToInject sortUsingSelector:@selector(caseInsensitiveCompare:)];
    return dylibsToInject;
}

void SpringBoardSigHandler(int signo, siginfo_t *info, void *uap){
    NSLog(@"Received signal %d", signo);

    FILE *f = fopen("/var/mobile/.safeMode", "w");
    fprintf(f, "Hello World\n");
    fclose(f);

    raise(signo);
}

int file_exist(char *filename) {
    struct stat buffer;
    int r = stat(filename, &buffer);
    return (r == 0);
}

/*
 Thanks to @DGh0st on Discord for helping me set up this custom safe mode implementation :)
 */

@interface SBIconController : UIViewController
+ (id)sharedInstance;
@end

@interface SBApplication : NSObject
@property (nonatomic,readonly) int pid;
@end

@interface SBApplicationController : NSObject
+(id)sharedInstance;
-(id)applicationWithBundleIdentifier:(id)arg1;
@end

@interface Main : NSObject
+ (void)showRespringMessage;
@end

@implementation Main

+ (void)showRespringMessage {
    UIViewController *controller = [%c(SBIconController) sharedInstance];
    
    NSString *safeModeMessage = [NSString stringWithFormat:@"You are now in safe mode. \n"
                                 "If this is unusual, just tap 'Respring'. \n"
                                 "If this has happened multiple times in a row, uninstall any new tweaks which may be causing this issue."];
    
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Safe Mode"
                                                                   message:safeModeMessage
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction* closeAction = [UIAlertAction actionWithTitle:@"Close"
                                                          style:UIAlertActionStyleDefault
                                                        handler:nil];
    
    UIAlertAction* respringAction = [UIAlertAction actionWithTitle:@"Respring"
                                                             style:UIAlertActionStyleCancel
                                                           handler:^(UIAlertAction *action) {
                                                               [self respring];
                                                           }];
    
    [alert addAction:closeAction];
    [alert addAction:respringAction];
    
    [controller presentViewController:alert animated:YES completion:nil];
}

+ (void)respring {
    NSLog(@"Respringing to exit safe mode...");
    
    SBApplication *application = [[%c(SBApplicationController) sharedInstance] applicationWithBundleIdentifier:@"com.apple.SpringBoard"];
    int pid = [application pid];
    kill(pid, 9);
}

@end

%group SafeMode
%hook SBLockScreenViewController
- (void)finishUIUnlockFromSource:(int)source {
    %orig;
    [Main showRespringMessage];
}
%end

%hook SBDashBoardViewController
- (void)finishUIUnlockFromSource:(int)source {
    %orig;
    [Main showRespringMessage];
}
%end

%hook UIStatusBarTimeItemView
- (BOOL)updateForNewData:(id)arg1 actions:(int)arg2 {
    BOOL origValue = %orig;
    [self setValue:@"Exit Safe Mode" forKey:@"_timeString"];
    return origValue;
}
%end

%hook SpringBoard
- (void)handleStatusBarTapWithEvent:(id)arg1 {
    %orig;
    [Main showRespringMessage];
}
%end
%end

BOOL safeMode = false;

__attribute__ ((constructor))
static void ctor(void) {
    @autoreleasepool {
        safeMode = false;
        NSString *processName = [[NSProcessInfo processInfo] processName];
        if ([processName isEqualToString:@"backboardd"] || [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            struct sigaction action;
            memset(&action, 0, sizeof(action));
            action.sa_sigaction = &SpringBoardSigHandler;
            action.sa_flags = SA_SIGINFO | SA_RESETHAND;
            sigemptyset(&action.sa_mask);

            sigaction(SIGQUIT, &action, NULL);
            sigaction(SIGILL, &action, NULL);
            sigaction(SIGTRAP, &action, NULL);
            sigaction(SIGABRT, &action, NULL);
            sigaction(SIGEMT, &action, NULL);
            sigaction(SIGFPE, &action, NULL);
            sigaction(SIGBUS, &action, NULL);
            sigaction(SIGSEGV, &action, NULL);
            sigaction(SIGSYS, &action, NULL);

            if (file_exist("/var/mobile/.safeMode")) {
                safeMode = true;
                if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
                    unlink("/var/mobile/.safeMode");
                    NSLog(@"Entering Safe Mode!");
                    %init(SafeMode);
                }
            }
        }

        if (!safeMode){
            for (NSString *dylib in generateDylibList()) {
                void *dl = dlopen([dylib UTF8String], RTLD_LAZY | RTLD_GLOBAL);

                if (dl == NULL) {
                    NSLog(@"Injection failed: '%s'", dlerror());
                }
            }
        }
    }
}
