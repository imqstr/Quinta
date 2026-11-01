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
// Darling's CGDataProviderCreateWithData drops the release callback
// (O2DataProvider initWithBytes:length:), so the caller's bytes are never
// freed. Qt hands its backing store to CoreGraphics this way on every flush,
// and Studio leaked a full window bitmap per frame (~200 MB/s). Wrap the bytes
// in a CFData whose deallocator runs the caller's callback instead.
typedef void (*StudioProviderRelease)(void*,const void*,unsigned long);
struct StudioProviderBytes { StudioProviderRelease release; void* info; unsigned long size; };
typedef struct {
    long version; void* info; const void* (*retain)(const void*); void (*release)(const void*);
    const void* (*copyDescription)(const void*); void* (*allocate)(long,unsigned long,void*);
    void* (*reallocate)(void*,long,unsigned long,void*); void (*deallocate)(void*,void*);
    long (*preferredSize)(long,unsigned long,void*);
} StudioAllocatorContext;
extern const void* CFAllocatorCreate(const void*,StudioAllocatorContext*);
extern const void* CFDataCreateWithBytesNoCopy(const void*,const void*,long,const void*);
extern void* CGDataProviderCreateWithCFData(const void*);
extern void* CGDataProviderCreateWithData(void*,const void*,unsigned long,StudioProviderRelease);
extern void* malloc(unsigned long);
extern void free(void*);
static void studio_provider_bytes_done(void* bytes,void* context) {
    struct StudioProviderBytes* owner=context;
    owner->release(owner->info,bytes,owner->size);
}
static void studio_provider_context_done(const void* context) { free((void*)context); }
static void* studio_provider_create(void* info,const void* bytes,unsigned long size,StudioProviderRelease release) {
    if(!release || !bytes)return CGDataProviderCreateWithData(info,bytes,size,release);
    struct StudioProviderBytes* owner=malloc(sizeof *owner);
    if(!owner)return CGDataProviderCreateWithData(info,bytes,size,release);
    *owner=(struct StudioProviderBytes){release,info,size};
    StudioAllocatorContext context={0,owner,0,studio_provider_context_done,0,0,0,studio_provider_bytes_done,0};
    const void* allocator=CFAllocatorCreate(0,&context);
    if(!allocator){free(owner);return CGDataProviderCreateWithData(info,bytes,size,release);}
    // From here the allocator owns `owner` and frees it with the allocator.
    const void* data=CFDataCreateWithBytesNoCopy(0,bytes,(long)size,allocator);
    CFRelease(allocator);
    if(!data)return CGDataProviderCreateWithData(info,bytes,size,release);
    void* provider=CGDataProviderCreateWithCFData(data);
    CFRelease(data);
    return provider;
}
