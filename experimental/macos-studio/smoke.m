@interface NSObject
+ (id)new; + (id)alloc;
@end
@interface NSString:NSObject
- (const char*)UTF8String;
@end
@interface NSURL:NSObject
+ (id)URLWithString:(id)s; - (id)host; - (id)path; - (id)absoluteString;
@end
@interface NSURLComponents:NSObject
+ (id)componentsWithURL:(id)url resolvingAgainstBaseURL:(signed char)resolve;
- (void)setPath:(id)s; - (void)setPercentEncodedPath:(id)s; - (id)path; - (id)percentEncodedPath;
- (id)host; - (id)scheme; - (id)string; - (id)URL;
@end
extern id objc_getClass(const char*);
extern int strcmp(const char*,const char*);
extern int printf(const char*,...);
extern void* CTFontCreateWithName(const void*,double,const void*);
extern double CTFontGetAscent(const void*);
typedef struct {double x,y,width,height;} Rect;
typedef struct {double x,y;} Point;
extern const void* CTFontCopyTable(const void*,unsigned,unsigned);
extern long CFDataGetLength(const void*);
extern void CFRelease(const void*);
extern signed char CTFontGetGlyphsForCharacters(const void*,const unsigned short*,unsigned short*,long);
extern Rect CTFontGetBoundingRectsForGlyphs(const void*,unsigned,const unsigned short*,Rect*,long);
extern const void* CGColorSpaceCreateDeviceRGB(void);
extern void* CGBitmapContextCreate(void*,unsigned long,unsigned long,unsigned long,unsigned long,const void*,unsigned);
extern void* CGBitmapContextGetData(void*);
extern unsigned long CGBitmapContextGetBytesPerRow(void*);
extern void CGContextSetRGBFillColor(void*,double,double,double,double);
extern void CTFontDrawGlyphs(const void*,const unsigned short*,const Point*,unsigned long,void*);
extern void* CTFontCreatePathForGlyph(const void*,unsigned short,const void*);
extern signed char CGPathIsEmpty(const void*);
static int failures;
static void check(int value,const char* what) {printf("%s: %s\n",value?"PASS":"FAIL",what);if(!value)failures++;}
int main(){
 [objc_getClass("NSAutoreleasePool") new];
 id url=[NSURL URLWithString:@"https://www.roblox.com/test"];
 id c=[NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:0];
 [c setPath:@"/new path"];
 check(!strcmp([[c host] UTF8String],"www.roblox.com"),"URL preserves host");
 check(!strcmp([[c percentEncodedPath] UTF8String],"/new%20path"),"URL encodes spaces");
 check(!strcmp([[[c URL] absoluteString] UTF8String],"https://www.roblox.com/new%20path"),"URL reconstruction");
 [c setPercentEncodedPath:@"/encoded%20path"];
 check(!strcmp([[c path] UTF8String],"/encoded path"),"encoded setter replaces decoded path");
 [c setPath:@"/replacement"];
 check(!strcmp([[c percentEncodedPath] UTF8String],"/replacement"),"decoded setter replaces encoded path");
 void* f=CTFontCreateWithName((const void*)@"DejaVu Sans",18,0);
 check(f && CTFontGetAscent(f)>0,"FreeType font and ascent");
 if(!f)return 1;
 const void* table=CTFontCopyTable(f,0x68656164,0);
 check(table && CFDataGetLength(table)>=54,"TrueType head table");if(table)CFRelease(table);
 unsigned short chars[]={'H','i'},glyphs[2]={0};
 check(CTFontGetGlyphsForCharacters(f,chars,glyphs,2) && glyphs[0] && glyphs[1],"Unicode glyph mapping");
 void* path=CTFontCreatePathForGlyph(f,glyphs[0],0);
 check(path && !CGPathIsEmpty(path),"FreeType glyph outline");if(path)CFRelease(path);
 Rect bounds[2];CTFontGetBoundingRectsForGlyphs(f,0,glyphs,bounds,2);
 check(bounds[0].width>0 && bounds[0].height>0,"glyph bounding boxes");
 const void* color=CGColorSpaceCreateDeviceRGB();
 void* context=CGBitmapContextCreate(0,128,64,8,0,color,0x2006);CFRelease(color);
 check(context!=0,"bitmap context");
 if(context) {
  CGContextSetRGBFillColor(context,0,0,0,1);
  Point positions[]={{10,25},{30,25}};
  CTFontDrawGlyphs(f,glyphs,positions,2,context);
  unsigned char* bytes=CGBitmapContextGetData(context);unsigned long n=CGBitmapContextGetBytesPerRow(context)*64;
  unsigned nonzero=0;for(unsigned long i=0;i<n;i++)if(bytes[i])nonzero++;
  check(nonzero>0,"glyphs paint actual pixels");CFRelease(context);
 }
 CFRelease(f);return failures?1:0;
}
