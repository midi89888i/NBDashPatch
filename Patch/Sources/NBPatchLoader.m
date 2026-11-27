#import <Foundation/Foundation.h>

// +load fires as soon as the dylib is mapped — before the host app's main().
// We bounce to the Swift bootstrap on the main queue.
__attribute__((constructor))
static void NBPatchEntry(void) {
    Class cls = NSClassFromString(@"NBDashPatch.NBPatchBootstrap");
    if (cls == Nil) {
        // Swift classes may register under the module-qualified name only after
        // the runtime finishes setup; fall back to a delayed lookup.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            Class late = NSClassFromString(@"NBDashPatch.NBPatchBootstrap");
            if (late != Nil && [late respondsToSelector:@selector(start)]) {
                [late performSelector:@selector(start)];
            }
        });
        return;
    }
    if ([cls respondsToSelector:@selector(start)]) {
        [cls performSelector:@selector(start)];
    }
}
