#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

static char tileKey, observerKey;

static void showIcon(NSDockTile *tile, NSURL *cache, NSURL *fallback) {
    NSImage *image = [[NSImage alloc] initWithContentsOfURL:cache];
    if (!image) image = [[NSImage alloc] initWithContentsOfURL:fallback];
    if (!image) return;
    NSImageView *view = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, tile.size.width, tile.size.height)];
    view.image = image;
    view.imageScaling = NSImageScaleProportionallyUpOrDown;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    tile.contentView = view;
    [tile display];
}

// Dock may load several folder plug-ins into one host. Register a distinct
// principal class per stable instance ID, rather than sharing Bundle.main.
__attribute__((constructor)) static void registerFolderTile(void) {
    @autoreleasepool {
        Dl_info location;
        if (!dladdr((const void *)&registerFolderTile, &location)) return;
        NSURL *executable = [NSURL fileURLWithPath:@(location.dli_fname)];
        NSURL *plugin = executable.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfURL:[plugin URLByAppendingPathComponent:@"Contents/Info.plist"]];
        NSString *className = info[@"NSPrincipalClass"];
        NSString *instance = info[@"DockFolderInstanceID"];
        if (!className.length || !instance.length || NSClassFromString(className)) return;
        NSURL *support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *cache = [support URLByAppendingPathComponent:[NSString stringWithFormat:@"DockFolder/Instances/%@/FolderIcon.icns", instance]];
        NSURL *appContents = plugin.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
        NSURL *fallback = [appContents URLByAppendingPathComponent:@"Resources/AppIcon.icns"];
        Class principal = objc_allocateClassPair(NSObject.class, className.UTF8String, 0);
        if (!principal) return;
        class_addProtocol(principal, @protocol(NSDockTilePlugIn));
        IMP setter = imp_implementationWithBlock(^(id self, NSDockTile *tile) {
            NSDistributedNotificationCenter *center = NSDistributedNotificationCenter.defaultCenter;
            id oldObserver = objc_getAssociatedObject(self, &observerKey);
            if (oldObserver) [center removeObserver:oldObserver];
            objc_setAssociatedObject(self, &observerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, &tileKey, tile, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (!tile) return;
            showIcon(tile, cache, fallback);
            __weak id weakSelf = self;
            id observer = [center addObserverForName:@"com.dalong.DockFolder.iconChanged" object:instance
                queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
                    NSDockTile *current = objc_getAssociatedObject(weakSelf, &tileKey);
                    if (current) showIcon(current, cache, fallback);
                }];
            objc_setAssociatedObject(self, &observerKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        });
        class_addMethod(principal, @selector(setDockTile:), setter, "v@:@");
        objc_registerClassPair(principal);
    }
}
