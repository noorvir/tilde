// Adds a second display to the Mac while it runs, as a user's external monitor: the UX specs
// use it where the VM has one display. It uses CoreGraphics' virtual displays, which have no
// public header; the interface below is theirs. It prints "ready <display id>" once the display
// is at its place, and removes it when it ends.
// usage: tilde-ux-display <width> <height> <x> <y>   points, x and y from the main display's top left
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain) dispatch_queue_t queue;
@property (retain) NSString *name;
@property unsigned int maxPixelsHigh;
@property unsigned int maxPixelsWide;
@property CGSize sizeInMillimeters;
@property unsigned int serialNum;
@property unsigned int productID;
@property unsigned int vendorID;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain) NSArray<CGVirtualDisplayMode *> *modes;
@property unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly) CGDirectDisplayID displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 5) {
            fprintf(stderr, "usage: tilde-ux-display <width> <height> <x> <y>\n");
            return 2;
        }
        unsigned int width = (unsigned int)atoi(argv[1]);
        unsigned int height = (unsigned int)atoi(argv[2]);
        int x = atoi(argv[3]);
        int y = atoi(argv[4]);

        CGVirtualDisplayDescriptor *descriptor = [[CGVirtualDisplayDescriptor alloc] init];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = @"Tilde UX Display";
        descriptor.maxPixelsWide = width;
        descriptor.maxPixelsHigh = height;
        descriptor.sizeInMillimeters = CGSizeMake(width * 0.25, height * 0.25);
        descriptor.serialNum = 1;
        descriptor.productID = 0x7444;
        descriptor.vendorID = 0x7444;
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        if (display == nil) {
            fprintf(stderr, "no virtual display\n");
            return 1;
        }
        CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
        settings.hiDPI = 0;
        settings.modes = @[[[CGVirtualDisplayMode alloc] initWithWidth:width height:height refreshRate:60]];
        if (![display applySettings:settings]) {
            fprintf(stderr, "the virtual display took no mode\n");
            return 1;
        }

        // The display comes online a moment after; then it goes to its place.
        CGDirectDisplayID identifier = display.displayID;
        for (int attempt = 0; attempt < 100; attempt++) {
            if (CGDisplayIsOnline(identifier) && CGDisplayPixelsWide(identifier) == width) {
                break;
            }
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        CGDisplayConfigRef configuration;
        CGBeginDisplayConfiguration(&configuration);
        CGConfigureDisplayOrigin(configuration, identifier, x, y);
        CGCompleteDisplayConfiguration(configuration, kCGConfigureForSession);
        for (int attempt = 0; attempt < 100; attempt++) {
            CGRect bounds = CGDisplayBounds(identifier);
            if ((int)bounds.origin.x == x && (int)bounds.origin.y == y) {
                break;
            }
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        CGRect bounds = CGDisplayBounds(identifier);
        printf("ready %u %d %d %d %d\n", identifier, (int)bounds.origin.x, (int)bounds.origin.y, (int)bounds.size.width, (int)bounds.size.height);
        fflush(stdout);
        // Until the spec ends it.
        while (true) {
            [NSRunLoop.mainRunLoop runUntilDate:[NSDate distantFuture]];
        }
    }
}
