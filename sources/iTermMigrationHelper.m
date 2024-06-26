//
//  iTermMigrationHelper.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 6/1/18.
//

#import "iTermMigrationHelper.h"

#import "DebugLogging.h"
#import "ITAddressBookMgr.h"
#import "iTerm2SharedARC-Swift.h"
#import "iTermDisclosableView.h"
#import "iTermPreferences.h"
#import "iTermProfilePreferences.h"
#import "iTermWarning.h"
#import "NSFileManager+iTerm.h"

@implementation iTermMigrationHelper

+ (BOOL)removeLegacyAppSupportFolderIfPossible {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *legacy = [fileManager legacyApplicationSupportDirectory];

    if (![fileManager itemIsDirectory:legacy]) {
        return NO;
    }

    BOOL foundVersionTxt = NO;
    for (NSString *file in [fileManager enumeratorAtPath:legacy]) {
        if ([file isEqualToString:@"version.txt"]) {
            foundVersionTxt = YES;
        } else {
            return NO;
        }
    }
    if (foundVersionTxt) {
        NSError *error = nil;
        [fileManager removeItemAtPath:[legacy stringByAppendingPathComponent:@"version.txt"] error:&error];
        if (error) {
            return NO;
        }
    }

    NSError *error = nil;
    [fileManager removeItemAtPath:legacy error:&error];
    return error == nil;
}

+ (void)migrateOpenAIKeyIfNeeded {
    NSString *key = [[NSUserDefaults standardUserDefaults] stringForKey:kPreferenceKeyOpenAIAPIKey];
    if (!key) {
        return;
    }
    NSString *trimmedKey = [key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trimmedKey length] == 0) {
        return;
    }
    const iTermWarningSelection selection =
    [iTermWarning showWarningWithTitle:@"Move OpenAI API key into the keychain? It is currently stored in User Defaults, which is not as secure."
                               actions:@[ @"OK", @"Erase from Settings" ]
                             accessory:nil
                            identifier:@"NoSyncMoveOpenAIAPIKeyIntoKeychain"
                           silenceable:kiTermWarningTypePersistent
                               heading:@"Move Key" 
                                window:nil];
    if (selection == kiTermWarningSelection0) {
        [self addOpenAIKeyToKeychain:key];
    }
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPreferenceKeyOpenAIAPIKey];
}

+ (void)addOpenAIKeyToKeychain:(NSString *)key {
    [AITermControllerObjC setApiKey:key];
}

+ (void)migrateApplicationSupportDirectoryIfNeeded {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *modern = [fileManager applicationSupportDirectory];
    NSString *legacy = [fileManager legacyApplicationSupportDirectory];

    if ([fileManager itemIsSymlink:legacy]) {
        // Looks migrated, or crazy and impossible to reason about.
        return;
    }

    if ([self removeLegacyAppSupportFolderIfPossible]) {
        return;
    }

    if ([fileManager itemIsDirectory:modern] && [fileManager itemIsDirectory:legacy]) {
        // This is the normal code path for migrating users.
        const BOOL legacyEmpty = [fileManager directoryEmpty:legacy];

        if (legacyEmpty) {
            [fileManager removeItemAtPath:legacy error:nil];
            [fileManager createSymbolicLinkAtPath:legacy withDestinationPath:modern error:nil];
            return;
        }

        const BOOL modernEmpty = [fileManager directoryEmpty:modern];
        if (modernEmpty) {
            [fileManager removeItemAtPath:modern error:nil];
            [fileManager moveItemAtPath:legacy toPath:modern error:nil];
            [fileManager createSymbolicLinkAtPath:legacy withDestinationPath:modern error:nil];
            return;
        }

        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Manual Update Needed";
        alert.informativeText = @"iTerm2's Application Support directory has changed.\n\n"
        @"Previously, both these directories were supported:\n~/Library/Application Support/iTerm\n~/Library/Application Support/iTerm2.\n\n"
            @"Now, only the iTerm2 version is supported. But you have files in both so please move everything from iTerm to iTerm2.";

        NSMutableArray<NSString *> *files = [NSMutableArray array];
        int over = 0;
        for (NSString *file in [fileManager enumeratorAtPath:legacy]) {
            if (files.count > 5) {
                over++;
            } else {
                [files addObject:file];
            }
        }
        [files sortUsingSelector:@selector(compare:)];
        NSString *message;
        if (over == 0) {
            message = [files componentsJoinedByString:@"\n"];
        } else {
            message = [NSString stringWithFormat:@"%@\n…and %@ more", [files componentsJoinedByString:@"\n"], @(over)];
        }

        iTermDisclosableView *accessory = [[iTermDisclosableView alloc] initWithFrame:NSZeroRect
                                                                               prompt:@"Directory Listing"
                                                                              message:message];
        iTermAccessoryViewUnfucker *unfucker = [[iTermAccessoryViewUnfucker alloc] initWithView:accessory];
        accessory.frame = NSMakeRect(0, 0, accessory.intrinsicContentSize.width, accessory.intrinsicContentSize.height);
        accessory.textView.selectable = YES;
        accessory.requestLayout = ^{
            [unfucker layout];
            [alert layout];
            [alert layout];
        };
        [unfucker layout];
        alert.accessoryView = unfucker;

        [alert addButtonWithTitle:@"Open in Finder"];
        [alert addButtonWithTitle:@"I Fixed It"];
        [alert addButtonWithTitle:@"Not Now"];
        switch ([alert runModal]) {
            case NSAlertFirstButtonReturn:
                [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:legacy],
                                                                              [NSURL fileURLWithPath:modern] ]];
                [self migrateApplicationSupportDirectoryIfNeeded];
                break;

            case NSAlertThirdButtonReturn:
                return;

            default:
                [self migrateApplicationSupportDirectoryIfNeeded];
                break;
        }
    }
}

+ (void)copyProfileToBookmark:(NSMutableDictionary *)dict
{
    NSString* plistFile = [[NSBundle bundleForClass:[self class]] pathForResource:@"MigrationMap"
                                                                           ofType:@"plist"];
    NSDictionary* fileDict = [NSDictionary dictionaryWithContentsOfFile: plistFile];
    NSUserDefaults* prefs = [NSUserDefaults standardUserDefaults];
    NSDictionary* keybindingProfiles = [prefs objectForKey: @"KeyBindings"];
    NSDictionary* displayProfiles =  [prefs objectForKey: @"Displays"];
    NSDictionary* terminalProfiles = [prefs objectForKey: @"Terminals"];
    NSArray* xforms = [fileDict objectForKey:@"Migration Map"];
    for (int i = 0; i < [xforms count]; ++i) {
        NSDictionary* xform = [xforms objectAtIndex:i];
        NSString* destination = [xform objectForKey:@"Destination"];
        if ([dict objectForKey:destination]) {
            continue;
        }
        NSString* prefix = [xform objectForKey:@"Prefix"];
        NSString* suffix = [xform objectForKey:@"Suffix"];
        id defaultValue = [xform objectForKey:@"Default"];

        NSDictionary* parent = nil;
        if ([prefix isEqualToString:@"Terminal"]) {
            parent = [terminalProfiles objectForKey:[dict objectForKey:KEY_TERMINAL_PROFILE]];
        } else if ([prefix isEqualToString:@"Displays"]) {
            parent = [displayProfiles objectForKey:[dict objectForKey:KEY_DISPLAY_PROFILE]];
        } else if ([prefix isEqualToString:@"KeyBindings"]) {
            parent = [keybindingProfiles objectForKey:[dict objectForKey:KEY_KEYBOARD_PROFILE]];
        } else {
            ITAssertWithMessage(0, @"Bad prefix");
        }
        id value = nil;
        if (parent) {
            value = [parent objectForKey:suffix];
        }
        if (!value) {
            value = defaultValue;
        }
        [dict setObject:value forKey:destination];
    }
}

+ (void)recursiveMigrateBookmarks:(NSDictionary*)node path:(NSArray*)path {
    NSDictionary* data = [node objectForKey:@"Data"];

    if ([data objectForKey:KEY_COMMAND_LINE]) {
        // Not just a folder if it has a command.
        NSMutableDictionary* temp = [NSMutableDictionary dictionaryWithDictionary:data];
        [self copyProfileToBookmark:temp];
        [temp setObject:[ProfileModel freshGuid] forKey:KEY_GUID];
        [temp setObject:path forKey:KEY_TAGS];
        [temp setObject:kProfilePreferenceCommandTypeCustomValue forKey:KEY_CUSTOM_COMMAND];
        NSString* dir = [data objectForKey:KEY_WORKING_DIRECTORY];
        if (dir && [dir length] > 0) {
            [temp setObject:kProfilePreferenceInitialDirectoryCustomValue
                     forKey:KEY_CUSTOM_DIRECTORY];
        } else if (dir && [dir length] == 0) {
            [temp setObject:kProfilePreferenceInitialDirectoryRecycleValue
                     forKey:KEY_CUSTOM_DIRECTORY];
        } else {
            [temp setObject:kProfilePreferenceInitialDirectoryHomeValue
                     forKey:KEY_CUSTOM_DIRECTORY];
        }
        [[ProfileModel sharedInstance] addBookmark:temp];
    }

    NSArray* entries = [node objectForKey:@"Entries"];
    for (int i = 0; i < [entries count]; ++i) {
        NSMutableArray* childPath = [NSMutableArray arrayWithArray:path];
        NSDictionary* dataDict = [node objectForKey:@"Data"];
        if (dataDict) {
            NSString* name = [dataDict objectForKey:@"Name"];
            if (name) {
                [childPath addObject:name];
            }
        }
        [self recursiveMigrateBookmarks:[entries objectAtIndex:i] path:childPath];
    }
}

@end

