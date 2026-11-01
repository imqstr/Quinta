// Minimal API additions for the macOS Studio startup experiment.
// Studio-specific additions for APIs absent from the supported Darling runtime.
@class NSString;
NSString * const WKWebsiteDataTypeCookies = @"WKWebsiteDataTypeCookies";

extern int CGGetOnlineDisplayList(unsigned int, unsigned int *, unsigned int *);
unsigned int CGDisplayIsOnline(unsigned int display) {
    unsigned int displays[64], count = 0;
    if (CGGetOnlineDisplayList(64, displays, &count)) return 0;
    for (unsigned int i = 0; i < count && i < 64; ++i)
        if (displays[i] == display) return 1;
    return 0;
}

// Darling's CoreText returns NULL for several UI font types; Qt's cocoa
// platform plugin hands the result to CFRelease and Studio crashed while it
// built its theme fonts. Process-wide interposition breaks Studio's chained
// fixups under Darling, so redirect only libqcocoa's lazy pointer for
// CTFontCreateUIFontForLanguage (verified slot of this Studio build).
// The Darling sysroot ships no C headers; declare what is used.
typedef long intptr_t;
struct mach_header;
typedef struct { const char* dli_fname; void* dli_fbase; const char* dli_sname; void* dli_saddr; } Dl_info;
extern int dladdr(const void*, Dl_info*);
extern void* dlsym(void*, const char*);
#define RTLD_DEFAULT ((void*)-2)
extern unsigned long strlen(const char*);
extern int strcmp(const char*, const char*);
extern void _dyld_register_func_for_add_image(void (*)(const struct mach_header*, intptr_t));
extern void* CTFontCreateWithName(const void*, double, const void*);
extern const void* CFStringCreateWithCString(const void*, const char*, unsigned int);
extern void CFRelease(const void*);
static void* (*real_ui_font)(unsigned int, double, const void*);
static void studio_split_platform_window(void);
static void* studio_ui_font(unsigned int type, double size, const void* language) {
    studio_split_platform_window(); // Qt's classes are registered by the first theme font lookup
    void* font = real_ui_font ? real_ui_font(type, size, language) : 0;
    if (!font && real_ui_font && type != 2)
        font = real_ui_font(2 /* kCTFontUIFontSystem */, size, language);
    static const char* families[] = {"Helvetica", "LucidaGrande", "Arial", "DejaVu Sans"};
    for (unsigned i = 0; !font && i < sizeof families / sizeof families[0]; i++) {
        const void* name = CFStringCreateWithCString(0, families[i], 0x08000100U);
        if (!name) continue;
        font = CTFontCreateWithName(name, size > 0 ? size : 13.0, 0);
        CFRelease(name);
    }
    return font;
}
extern const void* CTFontCopyPostScriptName(const void*);
extern double CTFontGetSize(const void*);
extern void* CTFontDescriptorCreateWithAttributes(const void*);
extern const void* kCTFontNameAttribute;
extern const void* kCTFontSizeAttribute;
extern const void* CFNumberCreate(const void*, long, const void*);
extern const void* CFDictionaryCreate(const void*, const void**, const void**, long, const void*, const void*);
extern const char kCFTypeDictionaryKeyCallBacks[], kCFTypeDictionaryValueCallBacks[];
static void* studio_descriptor_named(const void* name, double size) {
    const void* number = CFNumberCreate(0, 13 /* kCFNumberDoubleType */, &size);
    const void* keys[] = {kCTFontNameAttribute, kCTFontSizeAttribute};
    const void* values[] = {name, number};
    const void* attributes = CFDictionaryCreate(0, keys, values, 2, kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks);
    void* descriptor = attributes ? CTFontDescriptorCreateWithAttributes(attributes) : 0;
    if (attributes) CFRelease(attributes);
    if (number) CFRelease(number);
    return descriptor;
}
static void* (*real_font_descriptor)(const void*);
static void* studio_font_descriptor(const void* font) {
    void* descriptor = real_font_descriptor && font ? real_font_descriptor(font) : 0;
    if (!descriptor) {
        const void* name = font ? CTFontCopyPostScriptName(font) : 0;
        if (!name) name = CFStringCreateWithCString(0, "Helvetica", 0x08000100U);
        descriptor = name ? studio_descriptor_named(name, font ? CTFontGetSize(font) : 13.0) : 0;
        if (name) CFRelease(name);
    }
    static int logged;
    if (logged++ < 4) {
        extern int snprintf(char*, unsigned long, const char*, ...);
        extern long write(int, const void*, unsigned long);
        char line[160];
        int n = snprintf(line, sizeof line, "[Quinta Studio] descriptor font=%p -> %p\n", font, descriptor);
        write(2, line, n > 0 ? (unsigned long)n : 0);
    }
    return descriptor;
}
static void (*real_cf_release)(const void*);
static void studio_cf_release(const void* object) {
    if (object) real_cf_release(object); // CFRelease(NULL) aborts; Qt releases failed CoreText lookups
}
static const void* (*real_cf_retain)(const void*);
static const void* studio_cf_retain(const void* object) {
    return object ? real_cf_retain(object) : 0; // same for retains of failed lookups
}
static void studio_redirect(const struct mach_header* header, unsigned long offset, void* real, void* replacement) {
    void** slot = (void**)((char*)header + offset);
    void* current = *slot;
    int lazy = (char*)current > (char*)header && (char*)current < (char*)header + 0x15EC78;
    extern int snprintf(char*, unsigned long, const char*, ...);
    extern long write(int, const void*, unsigned long);
    char line[160];
    int n = snprintf(line, sizeof line, "[Quinta Studio] slot+%#lx current=%p real=%p lazy=%d\n", offset, current, real, lazy);
    write(2, line, n > 0 ? (unsigned long)n : 0);
    if (current == real || lazy) *slot = replacement;
}
// Qt's QNSWindow/QNSPanel/QNSView define -platformWindow returning a C++
// QCocoaWindow*. Darling's AppKit (Cocotron) uses the same selector for its
// own backend window, so -[NSWindow orderWindow:relativeTo:] messaged the C++
// object and crashed when Studio showed its first window. Answer Qt's version
// only to callers inside libqcocoa and AppKit's version to everyone else.
typedef struct objc_object* id;
typedef struct objc_selector* SEL;
typedef struct objc_class* Class;
typedef struct objc_method* Method;
typedef void (*IMP)(void);
extern Class objc_getClass(const char*);
extern Class object_getClass(id);
extern Class class_getSuperclass(Class);
extern SEL sel_registerName(const char*);
extern Method class_getInstanceMethod(Class, SEL);
extern IMP method_getImplementation(Method);
extern IMP method_setImplementation(Method, IMP);
static const struct mach_header* qcocoa_header;
static struct { Class owner; id (*qt)(id, SEL); id (*appkit)(id, SEL); } platform_window_split[4];
static id studio_platform_window(id self, SEL cmd) {
    Dl_info info;
    int from_qt = dladdr(__builtin_return_address(0), &info) && info.dli_fbase == (void*)qcocoa_header;
    for (Class cls = object_getClass(self); cls; cls = class_getSuperclass(cls))
        for (unsigned i = 0; i < 4 && platform_window_split[i].owner; i++)
            if (platform_window_split[i].owner == cls)
                return (from_qt ? platform_window_split[i].qt : platform_window_split[i].appkit)(self, cmd);
    return 0;
}
// AppKit methods Studio calls that Darling lacks. Add only when missing.
extern signed char class_addMethod(Class, SEL, IMP, const char*);
static id studio_nil_for_object(id self, SEL cmd, id argument) { (void)self; (void)cmd; (void)argument; return 0; }
extern Class objc_getMetaClass(const char*);
extern id objc_msgSend(id, SEL, ...);
static id studio_url_path_allowed(id self, SEL cmd) {
    (void)cmd; // RFC 3986 pchar plus "/", as on macOS
    return ((id (*)(id, SEL, id))objc_msgSend)(self, sel_registerName("characterSetWithCharactersInString:"),
        (id)@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/");
}
#include "url_components.m"
#include "cookies.m"
#include "screens.m"
typedef struct {double x,y,width,height;} StudioImageRect;
static id studio_web_init(id self,SEL cmd,StudioImageRect frame,id configuration,signed char menu,id browser) {
    (void)cmd;(void)menu;(void)browser;
    return ((id(*)(id,SEL,StudioImageRect,id))objc_msgSend)(self,sel_registerName("initWithFrame:configuration:"),frame,configuration);
}
static void* studio_image_cgimage(id,SEL,void*,id,id);
static void studio_image_draw(id self,SEL cmd,StudioImageRect destination,StudioImageRect source,unsigned long operation,double fraction,signed char flipped,id hints) {
    (void)cmd;(void)hints;
    extern void CGContextSaveGState(void*);extern void CGContextRestoreGState(void*);
    extern void CGContextTranslateCTM(void*,double,double);extern void CGContextScaleCTM(void*,double,double);
    extern void CGContextClipToRect(void*,StudioImageRect);extern void CGContextDrawImage(void*,StudioImageRect,const void*);
    extern void CGContextSetAlpha(void*,double);
    id graphics=((id(*)(id,SEL))objc_msgSend)((id)objc_getClass("NSGraphicsContext"),sel_registerName("currentContext"));
    void* context=((void*(*)(id,SEL))objc_msgSend)(graphics,sel_registerName("graphicsPort"));
    int flip=flipped && ((signed char(*)(id,SEL))objc_msgSend)(graphics,sel_registerName("isFlipped"));
    CGContextSaveGState(context);
    if(flip){CGContextTranslateCTM(context,0,2*destination.y+destination.height);CGContextScaleCTM(context,1,-1);}
    void* image=studio_image_cgimage(self,cmd,0,graphics,0);
    if(image && destination.width>0 && destination.height>0) {
        typedef struct {double width,height;} ImageSize;
        ImageSize size=((ImageSize(*)(id,SEL))objc_msgSend)(self,sel_registerName("size"));
        if(source.width<=0 || source.height<=0)source=(StudioImageRect){0,0,size.width,size.height};
        if(source.width>0 && source.height>0) {
            ((void(*)(id,SEL,unsigned long))objc_msgSend)(graphics,sel_registerName("setCompositingOperation:"),operation);
            CGContextSetAlpha(context,fraction);CGContextClipToRect(context,destination);
            CGContextTranslateCTM(context,destination.x,destination.y);
            CGContextScaleCTM(context,destination.width/source.width,destination.height/source.height);
            CGContextDrawImage(context,(StudioImageRect){-source.x,-source.y,size.width,size.height},image);
        }
    }else ((void(*)(id,SEL,StudioImageRect,StudioImageRect,unsigned long,double))objc_msgSend)(self,sel_registerName("drawInRect:fromRect:operation:fraction:"),destination,source,operation,fraction);
    CGContextRestoreGState(context);
}
static void* studio_image_cgimage(id self,SEL cmd,void* rect,id context,id hints) {
    (void)cmd;(void)rect;(void)context;(void)hints;
    id reps=((id(*)(id,SEL))objc_msgSend)(self,sel_registerName("representations"));
    unsigned long count=((unsigned long(*)(id,SEL))objc_msgSend)(reps,sel_registerName("count"));
    for(unsigned long i=0;i<count;i++) {
        id rep=((id(*)(id,SEL,unsigned long))objc_msgSend)(reps,sel_registerName("objectAtIndex:"),i);
        SEL image=sel_registerName("CGImage");
        if(((signed char(*)(id,SEL,SEL))objc_msgSend)(rep,sel_registerName("respondsToSelector:"),image)) {
            void* cg=((void*(*)(id,SEL))objc_msgSend)(rep,image);if(cg)return cg;
        }
    }
    return 0;
}
static char studio_layer_mask_key;
static id studio_layer_mask(id self,SEL cmd) {(void)cmd;return objc_getAssociatedObject(self,&studio_layer_mask_key);}
static void studio_set_layer_mask(id self,SEL cmd,id mask) {(void)cmd;objc_setAssociatedObject(self,&studio_layer_mask_key,mask,1);}
static signed char studio_validate_menu(id self,SEL cmd,id item) {
    (void)cmd;SEL action=((SEL(*)(id,SEL))objc_msgSend)(item,sel_registerName("action"));
    return action && ((signed char(*)(id,SEL,SEL))objc_msgSend)(self,sel_registerName("respondsToSelector:"),action);
}
static double studio_backing_scale(id self,SEL cmd) {(void)self;(void)cmd;return 1.0;}
static id studio_event_copy(id self,SEL cmd,void* zone) {(void)cmd;(void)zone;return ((id(*)(id,SEL))objc_msgSend)(self,sel_registerName("retain"));}
static short studio_event_subtype(id self,SEL cmd) {(void)self;(void)cmd;return 0;}
static id studio_no_input_context(id self,SEL cmd) {(void)self;(void)cmd;return 0;}
static signed char studio_no(id self, SEL cmd) { (void)self; (void)cmd; return 0; }
static void studio_add_missing_methods(void) {
    Class input=objc_getMetaClass("NSTextInputContext");
    if(input)class_addMethod(input,sel_registerName("currentInputContext"),(IMP)studio_no_input_context,"@@:");
    Class layer = objc_getClass("CALayer");
    if(layer){class_addMethod(layer,sel_registerName("mask"),(IMP)studio_layer_mask,"@@:");class_addMethod(layer,sel_registerName("setMask:"),(IMP)studio_set_layer_mask,"v@:@");}
    Class web = objc_getClass("QuintaWebView");
    if(web)class_addMethod(web,sel_registerName("initWithFrame:configuration:enableDefaultContextMenu:browser:"),(IMP)studio_web_init,"@@:{CGRect={CGPoint=dd}{CGSize=dd}}@c@");
    Class image = objc_getClass("NSImage");
    if(image) {
        class_addMethod(image,sel_registerName("CGImageForProposedRect:context:hints:"),(IMP)studio_image_cgimage,"^v@:^v@@");
        studio_components_method(image,sel_registerName("drawInRect:fromRect:operation:fraction:respectFlipped:hints:"),(IMP)studio_image_draw,"v@:{CGRect={CGPoint=dd}{CGSize=dd}}{CGRect={CGPoint=dd}{CGSize=dd}}Qdc@");
    }
    Class window = objc_getClass("NSWindow");
    if(window)class_addMethod(window,sel_registerName("backingScaleFactor"),(IMP)studio_backing_scale,"d@:");
    const char* events[]={"NSEvent_mouse","NSEvent_key"};
    for(unsigned i=0;i<2;i++){Class event=objc_getClass(events[i]);if(event){class_addMethod(event,sel_registerName("subtype"),(IMP)studio_event_subtype,"s@:");class_addMethod(event,sel_registerName("copyWithZone:"),(IMP)studio_event_copy,"@@:^v");}}
    Class app = objc_getClass("NSApplication");
    if (app) {class_addMethod(app,sel_registerName("isFullKeyboardAccessEnabled"),(IMP)studio_no,"c@:");class_addMethod(app,sel_registerName("validateMenuItem:"),(IMP)studio_validate_menu,"c@:@");}
    studio_install_url_components();
    studio_install_cookies();
    studio_install_screens();
    Class characters = objc_getMetaClass("NSCharacterSet");
    if (characters) class_addMethod(characters, sel_registerName("URLPathAllowedCharacterSet"), (IMP)studio_url_path_allowed, "@@:");
    Class workspace = objc_getClass("NSWorkspace");
    // No registered handler: Studio falls back to its own handling.
    if (workspace) class_addMethod(workspace, sel_registerName("URLForApplicationToOpenURL:"), (IMP)studio_nil_for_object, "@@:@");
}
static void studio_split_platform_window(void) {
    static int done;
    if (done || !qcocoa_header) return;
    studio_add_missing_methods();
    static const char* names[] = {"QNSWindow", "QNSPanel", "QNSView"};
    Class view = objc_getClass("QNSView");
    if(view) {
        const char* layerMethods[]={"layerEnabledByMacOS","layerExplicitlyRequested"};
        for(unsigned i=0;i<2;i++) {
            Method method=class_getInstanceMethod(view,sel_registerName(layerMethods[i]));
            if(method)method_setImplementation(method,(IMP)studio_no);
        }
    }
    SEL selector = sel_registerName("platformWindow");
    unsigned used = 0;
    for (unsigned i = 0; i < 3; i++) {
        Class cls = objc_getClass(names[i]);
        if (!cls) return; // not registered yet; retry on the next call
        Method own = class_getInstanceMethod(cls, selector);
        Method inherited = class_getInstanceMethod(class_getSuperclass(cls), selector);
        if (!own || !inherited || own == inherited) continue;
        IMP qt = method_getImplementation(own), appkit = method_getImplementation(inherited);
        if (qt == (IMP)studio_platform_window || appkit == (IMP)studio_platform_window) continue;
        platform_window_split[used].owner = cls;
        platform_window_split[used].qt = (id (*)(id, SEL))qt;
        platform_window_split[used].appkit = (id (*)(id, SEL))appkit;
        used++;
        method_setImplementation(own, (IMP)studio_platform_window);
    }
    done = 1;
}
static void studio_bind_fonts(const struct mach_header*, intptr_t);
static void studio_image_added(const struct mach_header* header, intptr_t slide) {
    Dl_info info;
    if (!dladdr(header, &info) || !info.dli_fname) return;
    unsigned long length = strlen(info.dli_fname);
    static const char own[]="/libStudioCompat.dylib";
    if(length>=sizeof own-1 && !strcmp(info.dli_fname+length-(sizeof own-1),own))return;
    studio_bind_fonts(header,slide);
    static const char suffix[] = "/libqcocoa.dylib";
    if (length < sizeof suffix - 1 || strcmp(info.dli_fname + length - (sizeof suffix - 1), suffix)) return;
    qcocoa_header = header;
    if (!real_ui_font) real_ui_font = (void* (*)(unsigned int, double, const void*))dlsym(RTLD_DEFAULT, "CTFontCreateUIFontForLanguage");
    if (!real_font_descriptor) real_font_descriptor = (void* (*)(const void*))dlsym(RTLD_DEFAULT, "CTFontCopyFontDescriptor");
    // Lazy pointers of this Studio build's libqcocoa (llvm-objdump --lazy-bind).
    studio_redirect(header, 0x15EC78, (void*)real_ui_font, (void*)studio_ui_font);
    studio_redirect(header, 0x15EC40, (void*)real_font_descriptor, (void*)studio_font_descriptor);
    if (!real_cf_release) real_cf_release = (void (*)(const void*))dlsym(RTLD_DEFAULT, "CFRelease");
    studio_redirect(header, 0x15E7F0, (void*)real_cf_release, (void*)studio_cf_release);
    if (!real_cf_retain) real_cf_retain = (const void* (*)(const void*))dlsym(RTLD_DEFAULT, "CFRetain");
    studio_redirect(header, 0x15E7F8, (void*)real_cf_retain, (void*)studio_cf_retain);
    static const char note[] = "[Quinta Studio] UI font fallbacks installed for libqcocoa\n";
    extern long write(int, const void*, unsigned long);
    write(2, note, sizeof note - 1);
}
__attribute__((constructor)) static void studio_compat_init(void) {
    studio_add_missing_methods();
    _dyld_register_func_for_add_image(studio_image_added);
}

// Darling's KERN_PROCARGS/KERN_PROCARGS2 handler overruns its copy and
// crashed Studio while it inspected process arguments. Report the query as
// unsupported instead, which macOS also does for processes it cannot read.
extern int sysctl(int*, unsigned int, void*, unsigned long*, void*, unsigned long);
extern int* __error(void);
static int studio_sysctl(int* name, unsigned int count, void* old, unsigned long* oldlen, void* newp, unsigned long newlen) {
    if (name && count >= 2 && name[0] == 1 /* CTL_KERN */ && (name[1] == 38 || name[1] == 49)) {
        *__error() = 22; // EINVAL
        return -1;
    }
    return sysctl(name, count, old, oldlen, newp, newlen);
}
__attribute__((used, section("__DATA,__interpose"))) static const void* studio_sysctl_interpose[] = {(void*)studio_sysctl, (void*)sysctl};

// Darling's os_log crashed on the first Qt warning (Roblox routes Qt messages
// to Apple's unified log). Studio's own log files are unaffected.
extern void _os_log_impl(void*, void*, unsigned char, const char*, unsigned char*, unsigned int);
static void studio_os_log_impl(void* dso, void* log, unsigned char type, const char* format, unsigned char* buffer, unsigned int size) {
    (void)dso; (void)log; (void)type; (void)format; (void)buffer; (void)size;
}
__attribute__((used, section("__DATA,__interpose"))) static const void* studio_os_log_interpose[] = {(void*)studio_os_log_impl, (void*)_os_log_impl};

// Missing from Darling's CoreGraphics; Studio reads it to check that its user
// session is on the console. Report an active, logged-in console session.
extern const void* kCFBooleanTrue;
const void* CGSessionCopyCurrentDictionary(void) {
    const void* keys[] = {
        CFStringCreateWithCString(0, "kCGSSessionOnConsoleKey", 0x08000100U),
        CFStringCreateWithCString(0, "kCGSessionLoginDoneKey", 0x08000100U),
    };
    const void* values[] = {kCFBooleanTrue, kCFBooleanTrue};
    const void* session = CFDictionaryCreate(0, keys, values, 2, kCFTypeDictionaryKeyCallBacks, kCFTypeDictionaryValueCallBacks);
    CFRelease(keys[0]);
    CFRelease(keys[1]);
    return session;
}

// Functions this Studio build imports that Darling's CoreGraphics/CoreText do
// not export. Each answers as macOS does when the resource is unavailable
// (NULL, 0 or false), so Studio takes its failure path instead of dyld aborting.
#define STUDIO_UNAVAILABLE(name) void* name(void) { return 0; }
STUDIO_UNAVAILABLE(CGColorGetTypeID)
STUDIO_UNAVAILABLE(CGColorSpaceCopyPropertyList)
STUDIO_UNAVAILABLE(CGDisplayCreateImageForRect)

STUDIO_UNAVAILABLE(CGDisplayIsAsleep)
STUDIO_UNAVAILABLE(CGEventSetFlags)
STUDIO_UNAVAILABLE(CGEventSourceKeyState)
STUDIO_UNAVAILABLE(CGEventTapCreateForPid)
STUDIO_UNAVAILABLE(CGFontCopyPostScriptName)
STUDIO_UNAVAILABLE(CGSClearWindowTags)
STUDIO_UNAVAILABLE(CGSSetWindowTags)
STUDIO_UNAVAILABLE(CTFontDescriptorCreateCopyWithAttributes)



STUDIO_UNAVAILABLE(CTFontManagerCreateFontDescriptorFromData)
STUDIO_UNAVAILABLE(CTFontManagerCreateFontDescriptorsFromURL)
STUDIO_UNAVAILABLE(CTTypesetterCreateLine)
STUDIO_UNAVAILABLE(CTTypesetterCreateWithAttributedStringAndOptions)
unsigned int CTGetCoreTextVersion(void) { return 0x000D0000; } // kCTVersionNumber11_0
// Mounted volumes: enumerate /Volumes, where Darling mounts the host root.
extern const void* CFURLCreateWithFileSystemPath(const void*, const void*, long, signed char);
extern void* CFURLEnumeratorCreateForDirectoryURL(const void*, const void*, unsigned long, const void*);
void* CFURLEnumeratorCreateForMountedVolumes(const void* allocator, unsigned long option, const void* keys) {
    const void* path = CFStringCreateWithCString(0, "/Volumes", 0x08000100U);
    const void* url = path ? CFURLCreateWithFileSystemPath(allocator, path, 0 /* POSIX */, 1) : 0;
    void* enumerator = url ? CFURLEnumeratorCreateForDirectoryURL(allocator, url, option, keys) : 0;
    if (url) CFRelease(url);
    if (path) CFRelease(path);
    return enumerator;
}
STUDIO_UNAVAILABLE(CVPixelBufferGetDataSize)
STUDIO_UNAVAILABLE(FSEventsGetCurrentEventId)
STUDIO_UNAVAILABLE(SCNetworkReachabilitySetDispatchQueue)
STUDIO_UNAVAILABLE(TISCopyInputMethodKeyboardLayoutOverride)
STUDIO_UNAVAILABLE(NSColorSpaceFromDepth)
void* CVPixelBufferRetain(void* buffer) { extern const void* CFRetain(const void*); return buffer ? (void*)CFRetain(buffer) : 0; }
int NSBestDepth(const void* colorSpace, long bps, long bpp, signed char planar, signed char* exact) {
    (void)colorSpace; (void)bps; (void)bpp; (void)planar;
    if (exact) *exact = 1;
    return 0x208; // NSWindowDepthTwentyfourBitRGB
}
long NSBitsPerSampleFromDepth(int depth) { (void)depth; return 8; }

// Closest available shapes: Darling lacks the rounded-rect and rect-bounded
// variants, so draw square corners and an unbounded transparency layer.
typedef struct { double x, y, width, height; } StudioRect;
extern void* CGPathCreateWithRect(StudioRect, const void*);
void* CGPathCreateWithRoundedRect(StudioRect rect, double cornerWidth, double cornerHeight, const void* transform) {
    (void)cornerWidth; (void)cornerHeight;
    return CGPathCreateWithRect(rect, transform);
}
extern void CGContextBeginTransparencyLayer(void*, const void*);
void CGContextBeginTransparencyLayerWithRect(void* context, StudioRect rect, const void* auxiliaryInfo) {
    (void)rect;
    CGContextBeginTransparencyLayer(context, auxiliaryInfo);
}

#include "fonts.m"

#include "graphics.m"
#include "bindings.m"
