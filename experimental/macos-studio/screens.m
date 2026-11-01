// Qt joins CoreGraphics displays to NSScreens via NSScreenNumber. Darling's
// NSScreen.deviceDescription is empty, so Qt otherwise retains 0x0 geometry.
extern unsigned CGMainDisplayID(void);
static id studio_screen_description(id self,SEL cmd) {
    (void)cmd;
    unsigned display=0;
    SEL selector=sel_registerName("cgDirectDisplayID");
    if(((signed char(*)(id,SEL,SEL))objc_msgSend)(self,sel_registerName("respondsToSelector:"),selector))
        display=((unsigned(*)(id,SEL))objc_msgSend)(self,selector);
    if(!display)display=CGMainDisplayID();
    Class number=objc_getClass("NSNumber");
    id value=((id(*)(id,SEL,unsigned))objc_msgSend)((id)number,sel_registerName("numberWithUnsignedInt:"),display);
    id dict=[NSMutableDictionary new];[dict setObject:value forKey:@"NSScreenNumber"];
    return [dict autorelease];
}
static int studio_screen_depth(id self,SEL cmd) { (void)self;(void)cmd;return 0x208; }
static double studio_screen_scale(id self,SEL cmd) {(void)self;(void)cmd;return 1.0;}
static void studio_install_screens(void) {
    static int installed;if(installed)return;
    Class cls=objc_getClass("NSScreen");if(!cls)return;
    studio_components_method(cls,sel_registerName("deviceDescription"),(IMP)studio_screen_description,"@@:");
    studio_components_method(cls,sel_registerName("depth"),(IMP)studio_screen_depth,"i@:");
    class_addMethod(cls,sel_registerName("backingScaleFactor"),(IMP)studio_screen_scale,"d@:");
    installed=1;
}
extern const void* CFUUIDCreateWithBytes(const void*,unsigned char,unsigned char,unsigned char,unsigned char,unsigned char,unsigned char,unsigned char,unsigned char,unsigned char,unsigned char,unsigned char,unsigned char,unsigned char,unsigned char,unsigned char,unsigned char);
const void* CGDisplayCreateUUIDFromDisplayID(unsigned display) {
    return CFUUIDCreateWithBytes(0,0x51,0x75,0x69,0x6e,0x74,0x61,0,0,0,0,0,0,display>>24,display>>16,display>>8,display);
}
