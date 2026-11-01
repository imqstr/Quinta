// NSURLComponents is an empty NSObject subclass in the supported Darling runtime.
// Keep component values per instance; never change NSURL itself.
@interface NSObject
+ (id)alloc; + (id)new; - (id)init; - (id)autorelease; - (void)release; - (id)copy;
@end
@interface NSString : NSObject
+ (id)stringWithUTF8String:(const char*)s;
- (id)stringByAddingPercentEncodingWithAllowedCharacters:(id)set;
- (id)stringByRemovingPercentEncoding;
- (unsigned long)length; - (const char*)UTF8String;
@end
@interface NSMutableString : NSString
+ (id)string; - (void)appendString:(id)s;
@end
@interface NSMutableDictionary : NSObject
- (id)objectForKey:(id)key; - (void)setObject:(id)value forKey:(id)key;
- (void)removeObjectForKey:(id)key;
@end
@interface NSURL : NSObject
+ (id)URLWithString:(id)s;
- (id)absoluteURL; - (id)scheme; - (id)host; - (id)port;
- (id)user; - (id)password; - (id)path; - (id)query; - (id)fragment;
- (id)absoluteString;
@end
@interface NSCharacterSet : NSObject
+ (id)characterSetWithCharactersInString:(id)s;
@end
extern void objc_setAssociatedObject(id,const void*,id,unsigned long);
extern id objc_getAssociatedObject(id,const void*);
static id studio_url_escape(id value,const char* allowed) {
    if(!value)return 0;
    const unsigned char* bytes=(const void*)[value UTF8String];
    if(!bytes)return 0;
    extern void* malloc(unsigned long);extern void free(void*);
    unsigned long length=strlen((const char*)bytes);
    char* out=malloc(length*3+1);if(!out)return 0;
    unsigned long n=0;const char* hex="0123456789ABCDEF";
    for(unsigned long i=0;i<length;i++) {
        unsigned char c=bytes[i];int keep=0;
        for(const char* a=allowed;*a;a++)if((unsigned char)*a==c) {keep=1;break;}
        if(keep)out[n++]=c;else {out[n++]='%';out[n++]=hex[c>>4];out[n++]=hex[c&15];}
    }
    out[n]=0;id result=[NSString stringWithUTF8String:out];free(out);return result;
}
static char studio_components_key;
static NSMutableDictionary* studio_components_values(id self) {
    id values=objc_getAssociatedObject(self,&studio_components_key);
    if (!values) {
        values=[NSMutableDictionary new];
        objc_setAssociatedObject(self,&studio_components_key,values,1);
        [values release];
    }
    return values;
}
static id studio_components_get(id self,SEL cmd) {
    extern const char* sel_getName(SEL);
    const char* name=sel_getName(cmd);
    NSMutableDictionary* values=studio_components_values(self);
    id value=[values objectForKey:[NSString stringWithUTF8String:name]];
    if(value) return value;
    char other[80];
    if(name[0]=='p' && name[1]=='e' && name[2]=='r') {
        unsigned i=0; for(;name[i+14];i++)other[i]=name[i+14]; other[i]=0;
        other[0]+='a'-'A';
        value=[values objectForKey:[NSString stringWithUTF8String:other]];
        return studio_url_escape(value,"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/");
    }
    const char* prefix="percentEncoded"; unsigned i=0;
    for(;prefix[i];i++)other[i]=prefix[i];
    unsigned j=0; for(;name[j];j++)other[i+j]=name[j];other[i+j]=0;other[i]-='a'-'A';
    return [[values objectForKey:[NSString stringWithUTF8String:other]] stringByRemovingPercentEncoding];
}
static void studio_components_set(id self,SEL cmd,id value) {
    extern const char* sel_getName(SEL);
    const char* setter=sel_getName(cmd); char key[64]; unsigned i=0;
    for (;setter[i+3] && setter[i+3]!=':' && i<63;i++) key[i]=setter[i+3];
    key[i]=0; if(key[0]>='A' && key[0]<='Z') key[0]+='a'-'A';
    id k=[NSString stringWithUTF8String:key];
    if(value) { id copy=[value copy];[studio_components_values(self) setObject:copy forKey:k];[copy release]; }
    else [studio_components_values(self) removeObjectForKey:k];
    // Encoded and decoded properties are two views of the same component.
    const char* plain=key;int encoded=!__builtin_strncmp(key,"percentEncoded",14);
    char counterpart[80];
    if(encoded) {
        unsigned j=0;for(;key[j+14];j++)counterpart[j]=key[j+14];counterpart[j]=0;
        counterpart[0]+='a'-'A';plain=counterpart;
    }
    if(!strcmp(plain,"path") || !strcmp(plain,"query") || !strcmp(plain,"fragment") || !strcmp(plain,"user") || !strcmp(plain,"password")) {
        if(!encoded) {
            const char* prefix="percentEncoded";unsigned j=0;
            for(;prefix[j];j++)counterpart[j]=prefix[j];
            unsigned n=0;for(;key[n];n++)counterpart[j+n]=key[n];counterpart[j+n]=0;counterpart[j]-='a'-'A';
        }
        [studio_components_values(self) removeObjectForKey:[NSString stringWithUTF8String:counterpart]];
    }

}
static id studio_components_init_url(id self,SEL cmd,NSURL* url,signed char resolve) {
    (void)cmd; if(resolve) url=[url absoluteURL];
    NSMutableDictionary* d=studio_components_values(self);
#define COMPONENT(name) if([url name]) [d setObject:[url name] forKey:@#name]
    COMPONENT(scheme); COMPONENT(host); COMPONENT(port); COMPONENT(user); COMPONENT(password); COMPONENT(path);
#undef COMPONENT
    if([url query]) [d setObject:[url query] forKey:@"percentEncodedQuery"];
    if([url fragment]) [d setObject:[url fragment] forKey:@"percentEncodedFragment"];
    return self;
}
static id studio_components_init_string(id self,SEL cmd,id string) {
    NSURL* url=[NSURL URLWithString:string];
    if(!url) { [self release]; return 0; }
    return studio_components_init_url(self,cmd,url,0);
}
static id studio_components_with_url(id cls,SEL cmd,id url,signed char resolve) {
    return [studio_components_init_url([cls alloc],cmd,url,resolve) autorelease];
}
static id studio_components_with_string(id cls,SEL cmd,id string) {
    return [studio_components_init_string([cls alloc],cmd,string) autorelease];
}
static id studio_components_encoded(NSMutableDictionary* d,id encoded,id plain,id allowed) {
    id value=[d objectForKey:encoded];
    if(value) return value;
    return studio_url_escape([d objectForKey:plain],[allowed UTF8String]);
}
static id studio_components_string(id self,SEL cmd) {
    (void)cmd; NSMutableDictionary* d=studio_components_values(self);
    NSMutableString* out=[NSMutableString string]; id v;
    if((v=[d objectForKey:@"scheme"])) { [out appendString:v]; [out appendString:@":"]; }
    if((v=[d objectForKey:@"host"])) {
        [out appendString:@"//"];
        id user=studio_components_encoded(d,@"percentEncodedUser",@"user",@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=");
        if(user) {
            [out appendString:user];
            id password=studio_components_encoded(d,@"percentEncodedPassword",@"password",@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=");
            if(password) { [out appendString:@":"]; [out appendString:password]; }
            [out appendString:@"@"];
        }
        [out appendString:v];
        if((v=[d objectForKey:@"port"])) {
            [out appendString:@":"];
            [out appendString:((id(*)(id,SEL))objc_msgSend)(v,sel_registerName("stringValue"))];
        }
    }
    v=studio_components_encoded(d,@"percentEncodedPath",@"path",@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/");
    if(v) [out appendString:v];
    v=studio_components_encoded(d,@"percentEncodedQuery",@"query",@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?");
    if(v) { [out appendString:@"?"]; [out appendString:v]; }
    v=studio_components_encoded(d,@"percentEncodedFragment",@"fragment",@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=:@/?");
    if(v) { [out appendString:@"#"]; [out appendString:v]; }
    return out;
}
static id studio_components_url(id self,SEL cmd) {
    return [NSURL URLWithString:studio_components_string(self,cmd)];
}
static void studio_components_method(Class cls,SEL selector,IMP impl,const char* types) {
    if(!class_addMethod(cls,selector,impl,types)) {
        Method method=class_getInstanceMethod(cls,selector);
        if(method)method_setImplementation(method,impl);
    }
}
static void studio_install_url_components(void) {
    Class cls=objc_getClass("NSURLComponents"); if(!cls)return;
    studio_components_method(cls,sel_registerName("initWithURL:resolvingAgainstBaseURL:"),(IMP)studio_components_init_url,"@@:@c");
    studio_components_method(object_getClass((id)cls),sel_registerName("componentsWithURL:resolvingAgainstBaseURL:"),(IMP)studio_components_with_url,"@@:@c");
    studio_components_method(cls,sel_registerName("initWithString:"),(IMP)studio_components_init_string,"@@:@");
    studio_components_method(object_getClass((id)cls),sel_registerName("componentsWithString:"),(IMP)studio_components_with_string,"@@:@");
    const char* names[]={"scheme","host","port","user","password","path","query","fragment","percentEncodedPath","percentEncodedQuery","percentEncodedFragment","percentEncodedUser","percentEncodedPassword"};
    for(unsigned n=0;n<sizeof names/sizeof names[0];n++) {
        const char* name=names[n]; char setter[80]={'s','e','t'}; unsigned i=0;
        for(;name[i];i++) setter[i+3]=name[i]; setter[i+3]=':'; setter[i+4]=0; setter[3]-=32;
        studio_components_method(cls,sel_registerName(name),(IMP)studio_components_get,"@@:");
        studio_components_method(cls,sel_registerName(setter),(IMP)studio_components_set,"v@:@");
    }
    studio_components_method(cls,sel_registerName("URL"),(IMP)studio_components_url,"@@:");
    studio_components_method(cls,sel_registerName("string"),(IMP)studio_components_string,"@@:");
}
