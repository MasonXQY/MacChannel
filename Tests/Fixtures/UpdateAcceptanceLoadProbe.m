#import <Foundation/Foundation.h>
#import <Sparkle/Sparkle.h>

int main(void)
{
    @autoreleasepool {
        NSString *marker = NSProcessInfo.processInfo.environment[@"MACCHANNEL_UPDATE_TEST_PROBE_MARKER"];
        NSCharacterSet *invalidCharacters = [[NSCharacterSet alphanumericCharacterSet] invertedSet];
        if (marker.length < 8 || marker.length > 64 ||
            [marker rangeOfCharacterFromSet:invalidCharacters].location != NSNotFound) {
            return 2;
        }
        if ([SPUUpdater class] == Nil) {
            return 3;
        }
        NSString *version = [[NSBundle bundleForClass:SPUUpdater.class]
            objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        if (![version isEqualToString:@"2.9.6"]) {
            return 4;
        }
        fprintf(stdout, "macchannel-update-load-probe marker=%s sparkle=%s\n",
            marker.UTF8String, version.UTF8String);
        fflush(stdout);
    }
    return 0;
}
