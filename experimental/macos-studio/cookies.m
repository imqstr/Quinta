// Darling copies a missing Domain before trying OriginURL and crashes in
// CFStringCreateCopy(NULL). Normalize the documented OriginURL fallback first.
static id (*studio_cookie_with_properties)(id,SEL,id);
static id studio_cookie_create(id cls,SEL cmd,id properties) {
    id domain=((id(*)(id,SEL,id))objc_msgSend)(properties,sel_registerName("objectForKey:"),@"Domain");
    if(domain)return studio_cookie_with_properties(cls,cmd,properties);
    id origin=((id(*)(id,SEL,id))objc_msgSend)(properties,sel_registerName("objectForKey:"),@"OriginURL");
    if(!origin)return 0;
    if(!((signed char(*)(id,SEL,SEL))objc_msgSend)(origin,sel_registerName("respondsToSelector:"),sel_registerName("host")))
        origin=[NSURL URLWithString:origin];
    domain=[origin host];
    if(!domain)return 0;
    id copy=((id(*)(id,SEL))objc_msgSend)(properties,sel_registerName("mutableCopy"));
    [copy setObject:domain forKey:@"Domain"];
    id cookie=studio_cookie_with_properties(cls,cmd,copy);
    [copy release];return cookie;
}
static void studio_install_cookies(void) {
    if(studio_cookie_with_properties)return;
    Class cls=objc_getMetaClass("NSHTTPCookie");
    Method method=cls?class_getInstanceMethod(cls,sel_registerName("cookieWithProperties:")):0;
    if(method)studio_cookie_with_properties=(void*)method_setImplementation(method,(IMP)studio_cookie_create);
}
