extern void* CGImageCreate(unsigned long,unsigned long,unsigned long,unsigned long,unsigned long,const void*,unsigned,const void*,const double*,signed char,int);
extern void* CGColorSpaceCreateDeviceRGB(void);
extern void* CGColorSpaceCreateDeviceGray(void);
static void* studio_image_create(unsigned long width,unsigned long height,unsigned long bpc,unsigned long bpp,unsigned long row,const void* color,unsigned info,const void* provider,const double* decode,signed char interpolate,int intent) {
    void* owned=0;
    if(!color)color=owned=bpp==8?CGColorSpaceCreateDeviceGray():CGColorSpaceCreateDeviceRGB();
    // Onyx rejects 32-bit RGB with no explicit padding/alpha channel.
    if(bpc==8 && bpp==32 && !(info&31))info=(info&~31U)|6;
    void* result=CGImageCreate(width,height,bpc,bpp,row,color,info,provider,decode,interpolate,intent);
    if(owned)CFRelease(owned);return result;
}
STUDIO_FONT_INTERPOSE(CGImageCreate,studio_image_create)
extern const void* CGColorSpaceCreateWithName(const void*);
static const void* studio_color_space(const void* name) {
    const void* result=CGColorSpaceCreateWithName(name);
    return result?result:CGColorSpaceCreateDeviceRGB();
}
extern unsigned long CGImageGetWidth(const void*);
extern unsigned long CGImageGetHeight(const void*);
extern unsigned long CGImageGetBitsPerComponent(const void*);
extern unsigned long CGImageGetBitsPerPixel(const void*);
extern unsigned long CGImageGetBytesPerRow(const void*);
extern unsigned CGImageGetBitmapInfo(const void*);
extern const void* CGImageGetDataProvider(const void*);
extern const double* CGImageGetDecode(const void*);
extern signed char CGImageGetShouldInterpolate(const void*);
extern int CGImageGetRenderingIntent(const void*);
extern void* CGImageCreateCopyWithColorSpace(const void*,const void*);
extern const void* CGImageGetColorSpace(const void*);
static void* studio_image_copy_color(const void* image,const void* color) {
    if(!image)return 0;
    void* owned=0;
    if(!color)color=CGImageGetColorSpace(image);
    if(!color)color=owned=CGColorSpaceCreateDeviceRGB();
    void* result=studio_image_create(CGImageGetWidth(image),CGImageGetHeight(image),CGImageGetBitsPerComponent(image),CGImageGetBitsPerPixel(image),CGImageGetBytesPerRow(image),color,CGImageGetBitmapInfo(image),CGImageGetDataProvider(image),CGImageGetDecode(image),CGImageGetShouldInterpolate(image),CGImageGetRenderingIntent(image));
    if(owned)CFRelease(owned);return result;
}
STUDIO_FONT_INTERPOSE(CGColorSpaceCreateWithName,studio_color_space)
STUDIO_FONT_INTERPOSE(CGImageCreateCopyWithColorSpace,studio_image_copy_color)
extern void* CGBitmapContextCreate(void*,unsigned long,unsigned long,unsigned long,unsigned long,const void*,unsigned);
static void* studio_bitmap_create(void* bytes,unsigned long width,unsigned long height,unsigned long bpc,unsigned long row,const void* color,unsigned info) {
    // Onyx's skip-alpha bitmap formats lack a span reader used by FreeType.
    // Qt's RGB32 buffers carry an opaque alpha byte, so the corresponding
    // premultiplied format has the same storage and a working span reader.
    unsigned alpha=info&31;
    if(bpc==8 && (alpha==5 || alpha==6))info=(info&~31U)|(alpha==6?2:1);
    return CGBitmapContextCreate(bytes,width,height,bpc,row,color,info);
}
STUDIO_FONT_INTERPOSE(CGBitmapContextCreate,studio_bitmap_create)
