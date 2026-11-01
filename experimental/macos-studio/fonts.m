// Supply CoreText's missing descriptor and creation APIs using Darling's
// existing FreeType-backed CGFont and KTFont implementation.
extern void* CGFontCreateWithFontName(const void*);
extern void CGFontRelease(void*);
extern const void* CGFontCopyFullName(const void*);
extern const void* CFDictionaryGetValue(const void*,const void*);
extern const void* CFDictionaryCreateCopy(const void*,const void*);
extern const void* CFRetain(const void*);
extern signed char CFNumberGetValue(const void*,long,void*);
extern void* CTFontCreateWithFontDescriptor(const void*,double,const void*);
extern const void* CTFontDescriptorCopyAttribute(const void*,const void*);
static void* studio_create_font(const void* name,double size,const void* matrix) {
    (void)matrix;
    void* cg=CGFontCreateWithFontName(name ? name : (const void*)@"DejaVu Sans");
    if(!cg) cg=CGFontCreateWithFontName((const void*)@"DejaVu Sans");
    if(!cg) return 0;
    id cls=(id)objc_getClass("KTFont");
    id font=((id(*)(id,SEL,id,double))objc_msgSend)([cls alloc],sel_registerName("initWithFont:size:"),(id)cg,size>0?size:13.0);
    CGFontRelease(cg); return font;
}
static void* studio_create_descriptor(const void* attrs) {
    return attrs ? (void*)CFDictionaryCreateCopy(0,attrs) : 0;
}
static const void* studio_font_attribute_default(const void*,const void*);
static const void* studio_descriptor_attribute(const void* descriptor,const void* key) {
    const void* value=descriptor ? CFDictionaryGetValue(descriptor,key) : 0;
    return value ? CFRetain(value) : studio_font_attribute_default(descriptor,key);
}
static void* studio_create_from_descriptor(const void* descriptor,double size,const void* matrix) {
    const void* name=descriptor ? CFDictionaryGetValue(descriptor,kCTFontNameAttribute) : 0;
    if(size<=0 && descriptor) {
        const void* number=CFDictionaryGetValue(descriptor,kCTFontSizeAttribute);
        if(number) CFNumberGetValue(number,13,&size);
    }
    return studio_create_font(name,size,matrix);
}
static const void* studio_copy_font_name(const void* font) {
    return font ? ((const void*(*)(id,SEL))objc_msgSend)((id)font,sel_registerName("copyName")) : 0;
}
static void* studio_copy_descriptor(const void* font) {
    const void* name=studio_copy_font_name(font);
    if(!name) name=CFRetain((const void*)@"DejaVu Sans");
    double size=font?CTFontGetSize(font):13.0;
    const void* number=CFNumberCreate(0,13,&size);
    const void* keys[]={kCTFontNameAttribute,kCTFontSizeAttribute};
    const void* values[]={name,number};
    void* result=(void*)CFDictionaryCreate(0,keys,values,2,kCFTypeDictionaryKeyCallBacks,kCFTypeDictionaryValueCallBacks);
    CFRelease(name);CFRelease(number);return result;
}
#define STUDIO_FONT_INTERPOSE(original,replacement) \
__attribute__((used,section("__DATA,__interpose"))) static const void* interpose_##original[]={(void*)replacement,(void*)original};
STUDIO_FONT_INTERPOSE(CTFontCreateWithName,studio_create_font)
STUDIO_FONT_INTERPOSE(CTFontDescriptorCreateWithAttributes,studio_create_descriptor)
STUDIO_FONT_INTERPOSE(CTFontDescriptorCopyAttribute,studio_descriptor_attribute)
STUDIO_FONT_INTERPOSE(CTFontCreateWithFontDescriptor,studio_create_from_descriptor)
STUDIO_FONT_INTERPOSE(CTFontCopyPostScriptName,studio_copy_font_name)
extern void* CTFontCopyFontDescriptor(const void*);
STUDIO_FONT_INTERPOSE(CTFontCopyFontDescriptor,studio_copy_descriptor)
void* CTFontDescriptorCreateWithNameAndSize(const void* name,double size) {
    const void* number=CFNumberCreate(0,13,&size);
    const void* keys[]={kCTFontNameAttribute,kCTFontSizeAttribute};
    const void* values[]={name?name:(const void*)@"DejaVu Sans",number};
    void* descriptor=(void*)CFDictionaryCreate(0,keys,values,2,kCFTypeDictionaryKeyCallBacks,kCFTypeDictionaryValueCallBacks);
    CFRelease(number);return descriptor;
}
void* CTFontDescriptorCreateMatchingFontDescriptor(const void* descriptor,const void* mandatory) {
    (void)mandatory;return descriptor?(void*)CFRetain(descriptor):0;
}
extern const void* CFArrayCreate(const void*,const void**,long,const void*);
extern const char kCFTypeArrayCallBacks[];
static const void* studio_font_cascade(const void* font,const void* languages) {
    (void)font;(void)languages;
    void* descriptor=CTFontDescriptorCreateWithNameAndSize((const void*)@"DejaVu Sans",13);
    const void* value=descriptor;
    const void* result=CFArrayCreate(0,&value,1,kCFTypeArrayCallBacks);
    CFRelease(descriptor);return result;
}
static const void* studio_font_families(void) {
    const void* families[]={(const void*)@"DejaVu Sans",(const void*)@"DejaVu Sans Mono",(const void*)@"DejaVu Serif"};
    return CFArrayCreate(0,families,3,kCFTypeArrayCallBacks);
}
const void* CTFontDescriptorCreateMatchingFontDescriptors(const void* descriptor,const void* mandatory) {
    (void)mandatory;
    return CFArrayCreate(0,&descriptor,descriptor?1:0,kCFTypeArrayCallBacks);
}
extern const void* CTFontCopyDefaultCascadeListForLanguages(const void*,const void*);
extern const void* CTFontManagerCopyAvailableFontFamilyNames(void);
STUDIO_FONT_INTERPOSE(CTFontCopyDefaultCascadeListForLanguages,studio_font_cascade)
STUDIO_FONT_INTERPOSE(CTFontManagerCopyAvailableFontFamilyNames,studio_font_families)

extern const void* kCTFontTraitsAttribute;
extern const void* kCTFontFamilyNameAttribute;
extern const void* kCTFontStyleNameAttribute;
extern const void* kCTFontSymbolicTrait;
extern const void* kCTFontWeightTrait;
extern const void* kCTFontWidthTrait;
extern const void* kCTFontSlantTrait;
static const void* studio_font_traits(const void* font) {
    (void)font;double zero=0;const void* number=CFNumberCreate(0,13,&zero);
    const void* keys[]={kCTFontSymbolicTrait,kCTFontWeightTrait,kCTFontWidthTrait,kCTFontSlantTrait};
    const void* values[]={number,number,number,number};
    const void* result=CFDictionaryCreate(0,keys,values,4,kCFTypeDictionaryKeyCallBacks,kCFTypeDictionaryValueCallBacks);
    CFRelease(number);return result;
}
static const void* studio_font_attribute_default(const void* descriptor,const void* key) {
    extern signed char CFEqual(const void*,const void*);
    if(CFEqual(key,kCTFontTraitsAttribute))return studio_font_traits(0);
    if(CFEqual(key,kCTFontFamilyNameAttribute)) {
        const void* name=descriptor?CFDictionaryGetValue(descriptor,kCTFontNameAttribute):0;
        return CFRetain(name?name:(const void*)@"DejaVu Sans");
    }
    if(CFEqual(key,kCTFontStyleNameAttribute))return CFRetain((const void*)@"Regular");
    return 0;
}
static const void* studio_copy_graphics_font(const void* font,void** descriptor) {
    if(descriptor)*descriptor=studio_copy_descriptor(font);
    extern void* class_getInstanceVariable(Class,const char*);
    extern id object_getIvar(id,void*);
    void* ivar=class_getInstanceVariable(object_getClass((id)font),"_font");
    id cg=ivar?object_getIvar((id)font,ivar):0;
    return cg?CFRetain(cg):0;
}
extern const void* CGFontCopyTableForTag(const void*,unsigned);
static const void* studio_cg_font_table(const void* cg,unsigned tag) {
    void* face=cg?((void*(*)(id,SEL))objc_msgSend)((id)cg,sel_registerName("face")):0;
    static int (*load)(void*,unsigned long,long,unsigned char*,unsigned long*);
    if(!load)load=dlsym(RTLD_DEFAULT,"FT_Load_Sfnt_Table");
    if(!face || !load)return 0;
    unsigned long length=0;
    if(load(face,tag,0,0,&length) || !length || length>32*1024*1024)return 0;
    extern void* malloc(unsigned long);extern void free(void*);
    unsigned char* bytes=malloc(length);if(!bytes)return 0;
    extern const void* CFDataCreate(const void*,const unsigned char*,long);
    const void* result=0;
    if(!load(face,tag,0,bytes,&length))result=CFDataCreate(0,bytes,length);
    free(bytes);return result;
}
static const void* studio_font_table(const void* font,unsigned tag,unsigned options) {
    (void)options;const void* cg=studio_copy_graphics_font(font,0);
    const void* table=studio_cg_font_table(cg,tag);
    if(cg)CFRelease(cg);return table;
}
extern const void* CTFontCopyTraits(const void*);
extern const void* CTFontCopyGraphicsFont(const void*,void**);
extern const void* CTFontCopyTable(const void*,unsigned,unsigned);
STUDIO_FONT_INTERPOSE(CTFontCopyTraits,studio_font_traits)
STUDIO_FONT_INTERPOSE(CTFontCopyGraphicsFont,studio_copy_graphics_font)
STUDIO_FONT_INTERPOSE(CTFontCopyTable,studio_font_table)

STUDIO_FONT_INTERPOSE(CGFontCopyTableForTag,studio_cg_font_table)
extern unsigned CGFontGetUnitsPerEm(const void*);
extern StudioRect CGFontGetFontBBox(const void*);
extern const unsigned char* CFDataGetBytePtr(const void*);
extern long CFDataGetLength(const void*);
static double studio_font_post_metric(const void* font,unsigned offset,double fallback) {
    const void* cg=studio_copy_graphics_font(font,0);
    if(!cg)return fallback;
    const void* table=studio_cg_font_table(cg,0x706f7374); // post
    unsigned units=CGFontGetUnitsPerEm(cg);double result=fallback;
    if(table && CFDataGetLength(table)>=(long)offset+2 && units) {
        const unsigned char* p=CFDataGetBytePtr(table)+offset;
        short metric=(short)(((unsigned)p[0]<<8)|p[1]);
        result=(double)metric*CTFontGetSize(font)/units;
    }
    if(table)CFRelease(table);CFRelease(cg);return result;
}
static double studio_underline_position(const void* font) {return studio_font_post_metric(font,8,-1);}
static double studio_underline_thickness(const void* font) {return studio_font_post_metric(font,10,1);}
static unsigned studio_units_per_em(const void* font) {
    const void* cg=studio_copy_graphics_font(font,0);unsigned units=cg?CGFontGetUnitsPerEm(cg):0;
    if(cg)CFRelease(cg);return units;
}
static StudioRect studio_font_bounds(const void* font) {
    const void* cg=studio_copy_graphics_font(font,0);StudioRect rect={0};
    if(cg) {rect=CGFontGetFontBBox(cg);unsigned units=CGFontGetUnitsPerEm(cg);double scale=units?CTFontGetSize(font)/units:0;
        rect.x*=scale;rect.y*=scale;rect.width*=scale;rect.height*=scale;CFRelease(cg);}
    return rect;
}
extern double CTFontGetUnderlinePosition(const void*);
extern double CTFontGetUnderlineThickness(const void*);
extern unsigned CTFontGetUnitsPerEm(const void*);
extern StudioRect CTFontGetBoundingBox(const void*);
STUDIO_FONT_INTERPOSE(CTFontGetUnderlinePosition,studio_underline_position)
STUDIO_FONT_INTERPOSE(CTFontGetUnderlineThickness,studio_underline_thickness)
STUDIO_FONT_INTERPOSE(CTFontGetUnitsPerEm,studio_units_per_em)
STUDIO_FONT_INTERPOSE(CTFontGetBoundingBox,studio_font_bounds)
typedef struct {double x,y;} StudioPoint;
extern void CGContextSaveGState(void*);
extern void CGContextRestoreGState(void*);
extern void CGContextSetFont(void*,const void*);
extern void CGContextSetFontSize(void*,double);
extern StudioPoint CGContextGetTextPosition(void*);
extern void CGContextShowGlyphsAtPoint(void*,double,double,const unsigned short*,unsigned long);
static void studio_draw_glyphs(const void* font,const unsigned short* glyphs,const StudioPoint* points,unsigned long count,void* context) {
    const void* cg=studio_copy_graphics_font(font,0);if(!cg)return;
    CGContextSaveGState(context);CGContextSetFont(context,cg);CGContextSetFontSize(context,CTFontGetSize(font));
    StudioPoint origin=CGContextGetTextPosition(context);
    for(unsigned long i=0;i<count;i++)CGContextShowGlyphsAtPoint(context,origin.x+points[i].x,origin.y+points[i].y,&glyphs[i],1);
    CGContextRestoreGState(context);CFRelease(cg);
}
extern void CTFontDrawGlyphs(const void*,const unsigned short*,const StudioPoint*,unsigned long,void*);
STUDIO_FONT_INTERPOSE(CTFontDrawGlyphs,studio_draw_glyphs)
// Public FreeType ABI prefixes, shared by the host FreeType bridge on x86_64.
struct StudioFTSlot {
    void* library;void* face;void* next;unsigned glyph_index;
    void* generic[2];
    struct {long width,height,horiBearingX,horiBearingY,horiAdvance,vertBearingX,vertBearingY,vertAdvance;} metrics;
};
struct StudioFTFace {
    long num_faces,face_index,face_flags,style_flags,num_glyphs;
    char* family_name;char* style_name;int num_fixed_sizes;void* available_sizes;
    int num_charmaps;void* charmaps;void* generic[2];long bbox[4];
    unsigned short units;short ascender,descender,height,max_width,max_height,underline_position,underline_thickness;
    struct StudioFTSlot* glyph;
};
static StudioRect studio_glyph_bounds(const void* font,unsigned orientation,const unsigned short* glyphs,StudioRect* bounds,long count) {
    (void)orientation;
    const void* cg=studio_copy_graphics_font(font,0);StudioRect total={0};
    struct StudioFTFace* face=cg?((void*(*)(id,SEL))objc_msgSend)((id)cg,sel_registerName("face")):0;
    static int (*load)(void*,unsigned,int);if(!load)load=dlsym(RTLD_DEFAULT,"FT_Load_Glyph");
    double scale=face && face->units?CTFontGetSize(font)/face->units:0;
    for(long i=0;i<count;i++) {
        StudioRect r={0};
        if(face && load && !load(face,glyphs[i],1 /* FT_LOAD_NO_SCALE */)) {
            r.x=face->glyph->metrics.horiBearingX*scale;
            r.width=face->glyph->metrics.width*scale;r.height=face->glyph->metrics.height*scale;
            r.y=face->glyph->metrics.horiBearingY*scale-r.height;
        }
        if(bounds)bounds[i]=r;
        if(!i)total=r;else {
            double right=total.x+total.width,top=total.y+total.height;
            if(r.x+r.width>right)right=r.x+r.width;if(r.y+r.height>top)top=r.y+r.height;
            if(r.x<total.x)total.x=r.x;if(r.y<total.y)total.y=r.y;
            total.width=right-total.x;total.height=top-total.y;
        }
    }
    if(cg)CFRelease(cg);return total;
}
extern StudioRect CTFontGetBoundingRectsForGlyphs(const void*,unsigned,const unsigned short*,StudioRect*,long);
STUDIO_FONT_INTERPOSE(CTFontGetBoundingRectsForGlyphs,studio_glyph_bounds)
struct StudioFTVector {long x,y;};
struct StudioFTBitmap {unsigned rows,width;int pitch;unsigned char* buffer;unsigned short num_grays;unsigned char pixel_mode,palette_mode;void* palette;};
struct StudioFTOutline {short n_contours,n_points;struct StudioFTVector* points;char* tags;short* contours;int flags;};
struct StudioFTOutlineSlot {
    struct StudioFTSlot prefix;long linearHoriAdvance,linearVertAdvance;struct StudioFTVector advance;unsigned format;
    struct StudioFTBitmap bitmap;int bitmap_left,bitmap_top;struct StudioFTOutline outline;
};
extern void* CGPathCreateMutable(void);
extern void CGPathMoveToPoint(void*,const void*,double,double);
extern void CGPathAddLineToPoint(void*,const void*,double,double);
extern void CGPathAddQuadCurveToPoint(void*,const void*,double,double,double,double);
extern void CGPathAddCurveToPoint(void*,const void*,double,double,double,double,double,double);
extern void CGPathCloseSubpath(void*);
struct StudioPathBuilder {void* path;const void* matrix;double scale;int started;};
static int studio_path_move(const struct StudioFTVector* point,void* context) {
    struct StudioPathBuilder* b=context;if(b->started)CGPathCloseSubpath(b->path);
    CGPathMoveToPoint(b->path,b->matrix,point->x*b->scale,point->y*b->scale);b->started=1;return 0;
}
static int studio_path_line(const struct StudioFTVector* point,void* context) {
    struct StudioPathBuilder* b=context;CGPathAddLineToPoint(b->path,b->matrix,point->x*b->scale,point->y*b->scale);return 0;
}
static int studio_path_conic(const struct StudioFTVector* control,const struct StudioFTVector* point,void* context) {
    struct StudioPathBuilder* b=context;CGPathAddQuadCurveToPoint(b->path,b->matrix,control->x*b->scale,control->y*b->scale,point->x*b->scale,point->y*b->scale);return 0;
}
static int studio_path_cubic(const struct StudioFTVector* c1,const struct StudioFTVector* c2,const struct StudioFTVector* point,void* context) {
    struct StudioPathBuilder* b=context;CGPathAddCurveToPoint(b->path,b->matrix,c1->x*b->scale,c1->y*b->scale,c2->x*b->scale,c2->y*b->scale,point->x*b->scale,point->y*b->scale);return 0;
}
static void* studio_glyph_path(const void* font,unsigned short glyph,const void* matrix) {
    const void* cg=studio_copy_graphics_font(font,0);
    struct StudioFTFace* face=cg?((void*(*)(id,SEL))objc_msgSend)((id)cg,sel_registerName("face")):0;
    static int (*load)(void*,unsigned,int);static int (*decompose)(const void*,const void*,void*);
    if(!load)load=dlsym(RTLD_DEFAULT,"FT_Load_Glyph");if(!decompose)decompose=dlsym(RTLD_DEFAULT,"FT_Outline_Decompose");
    void* path=0;
    if(face && face->units && load && decompose && !load(face,glyph,1|8 /* NO_SCALE | NO_BITMAP */)) {
        struct {void* move;void* line;void* conic;void* cubic;int shift;long delta;} callbacks={studio_path_move,studio_path_line,studio_path_conic,studio_path_cubic,0,0};
        struct StudioPathBuilder builder={CGPathCreateMutable(),matrix,CTFontGetSize(font)/face->units,0};
        if(builder.path) {
            if(!decompose(&((struct StudioFTOutlineSlot*)face->glyph)->outline,&callbacks,&builder)) {
                if(builder.started)CGPathCloseSubpath(builder.path);path=builder.path;
            }else CFRelease(builder.path);
        }
    }
    if(cg)CFRelease(cg);return path;
}
extern void* CTFontCreatePathForGlyph(const void*,unsigned short,const void*);
STUDIO_FONT_INTERPOSE(CTFontCreatePathForGlyph,studio_glyph_path)
