#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>
#import <AVFoundation/AVFoundation.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSError *error = nil;
        if (![bundle loadAndReturnError:&error]) { NSLog(@"FAIL: %@", error); return 1; }
        Class principal = bundle.principalClass;
        ScreenSaverView *view = [[principal alloc] initWithFrame:NSMakeRect(0, 0, 640, 360) isPreview:NO];
        if (!view) { NSLog(@"FAIL: principal class could not be instantiated"); return 2; }
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 360) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        window.contentView = view;
        [view layoutSubtreeIfNeeded];
        ScreenSaverDefaults *defaults = [ScreenSaverDefaults defaultsForModuleWithName:@"com.julianfink.MacTools.ScreenSaver"];
        NSLog(@"Configured path: %@", [defaults stringForKey:@"videoPath"]);
        [view startAnimation];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
        while ([deadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        }
        AVPlayerLayer *video = nil;
        for (CALayer *layer in view.layer.sublayers) {
            if ([layer isKindOfClass:AVPlayerLayer.class]) video = (AVPlayerLayer *)layer;
        }
        NSLog(@"Layers=%@, player=%@ status=%ld error=%@", view.layer.sublayers, video.player, (long)video.player.currentItem.status, video.player.currentItem.error);
        Float64 seconds = CMTimeGetSeconds(video.player.currentTime);
        if (!video.player || !(seconds > 0)) { NSLog(@"FAIL: selected video did not advance, time=%f", seconds); return 3; }
        [view stopAnimation];
        if (video.player != nil) { NSLog(@"FAIL: player retained after stopping"); return 4; }
        NSLog(@"PASS: saver bundle loads, selected video advances (%.2f sec), stop releases playback", seconds);
    }
    return 0;
}
