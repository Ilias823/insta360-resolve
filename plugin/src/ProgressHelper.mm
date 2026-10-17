// TrackProgress: a small floating window that shows how far subject tracking has got.
//
// Resolve's own interface is busy while the plugin tracks, so the plugin starts this as a
// separate program inside its bundle and feeds it lines on stdin:
//   p <fraction 0..1> <text>    update the bar and the text
//   done                        close
// Pressing Cancel prints "cancel" on stdout. The window also closes if stdin closes.
#import <Cocoa/Cocoa.h>

@interface ProgressController : NSObject
@property(strong) NSTextField* label;
@property(strong) NSProgressIndicator* bar;
@property(strong) NSButton* button;
@end

@implementation ProgressController
- (void)cancel:(id)sender
{
    printf("cancel\n");
    fflush(stdout);
    self.label.stringValue = @"Stopping…";
    self.button.enabled = NO;
}
@end

int main(int argc, const char** argv)
{
    @autoreleasepool
    {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

        NSPanel* panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 400, 112)
                                                    styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskUtilityWindow
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        panel.title = argc > 1 ? @(argv[1]) : @"Insta360 Stitch";
        panel.level = NSFloatingWindowLevel;
        panel.hidesOnDeactivate = NO;
        panel.floatingPanel = YES;

        ProgressController* controller = [ProgressController new];
        controller.label = [NSTextField labelWithString:@"Starting…"];
        controller.label.frame = NSMakeRect(20, 72, 360, 20);
        controller.bar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 48, 360, 16)];
        controller.bar.indeterminate = NO;
        controller.bar.minValue = 0.0;
        controller.bar.maxValue = 1.0;
        controller.button = [NSButton buttonWithTitle:@"Cancel" target:controller action:@selector(cancel:)];
        controller.button.frame = NSMakeRect(290, 10, 90, 30);
        for (NSView* view in @[controller.label, controller.bar, controller.button])
        {
            [panel.contentView addSubview:view];
        }
        [panel center];
        [panel orderFrontRegardless];

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char line[1024];
            while (fgets(line, sizeof(line), stdin))
            {
                if (strncmp(line, "done", 4) == 0)
                {
                    break;
                }
                double fraction = 0.0;
                int used = 0;
                if (sscanf(line, "p %lf %n", &fraction, &used) >= 1)
                {
                    NSString* text = [[NSString stringWithUTF8String:line + used]
                        stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        controller.bar.doubleValue = fraction;
                        if (controller.button.enabled)
                        {
                            controller.label.stringValue = text;
                        }
                    });
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSApp terminate:nil];
            });
        });

        [app run];
    }
    return 0;
}
