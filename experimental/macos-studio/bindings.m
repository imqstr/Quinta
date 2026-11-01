// Resolve imports by symbol name rather than offsets tied to one Qt build.
// Darling does not apply __interpose consistently to chained-fixup clients.
struct StudioMachHeader { unsigned magic,cpu,subtype,type,ncmds,sizeofcmds,flags,reserved; };
struct StudioLoad { unsigned cmd,size; };
struct StudioSegment { unsigned cmd,size; char name[16]; unsigned long vmaddr,vmsize,fileoff,filesize; int maxprot,initprot; unsigned nsects,flags; };
struct StudioSection { char name[16],seg[16]; unsigned long addr,size; unsigned offset,align,reloff,nreloc,flags,reserved1,reserved2,reserved3; };
struct StudioSymtab { unsigned cmd,size,symoff,nsyms,stroff,strsize; };
struct StudioNList { unsigned strx; unsigned char type,sect; unsigned short desc; unsigned long value; };
static void* studio_font_binding(const char* name) {
#define BIND(symbol,implementation) if(!strcmp(name,"_" #symbol))return (void*)implementation
    BIND(CTFontCreateWithName,studio_create_font);
    BIND(CTFontDescriptorCreateWithAttributes,studio_create_descriptor);
    BIND(CTFontDescriptorCopyAttribute,studio_descriptor_attribute);
    BIND(CTFontCreateWithFontDescriptor,studio_create_from_descriptor);
    BIND(CTFontCopyPostScriptName,studio_copy_font_name);
    BIND(CTFontCopyFontDescriptor,studio_copy_descriptor);
    BIND(CTFontDescriptorCreateWithNameAndSize,CTFontDescriptorCreateWithNameAndSize);
    BIND(CTFontDescriptorCreateMatchingFontDescriptor,CTFontDescriptorCreateMatchingFontDescriptor);
    BIND(CTFontCopyDefaultCascadeListForLanguages,studio_font_cascade);
    BIND(CTFontManagerCopyAvailableFontFamilyNames,studio_font_families);
    BIND(CTFontDescriptorCreateMatchingFontDescriptors,CTFontDescriptorCreateMatchingFontDescriptors);
    BIND(CTFontCopyTraits,studio_font_traits);
    BIND(CTFontCopyGraphicsFont,studio_copy_graphics_font);
    BIND(CTFontCopyTable,studio_font_table);
    BIND(CGFontCopyTableForTag,studio_cg_font_table);
    BIND(CTFontGetUnderlinePosition,studio_underline_position);
    BIND(CTFontGetUnderlineThickness,studio_underline_thickness);
    BIND(CTFontGetUnitsPerEm,studio_units_per_em);
    BIND(CTFontGetBoundingBox,studio_font_bounds);
    BIND(CTFontDrawGlyphs,studio_draw_glyphs);
    BIND(CTFontGetBoundingRectsForGlyphs,studio_glyph_bounds);
    BIND(CGImageCreate,studio_image_create);
    BIND(CGColorSpaceCreateWithName,studio_color_space);
    BIND(CGImageCreateCopyWithColorSpace,studio_image_copy_color);
    BIND(CGBitmapContextCreate,studio_bitmap_create);
    BIND(CGDataProviderCreateWithData,studio_provider_create);
    BIND(CTFontCreatePathForGlyph,studio_glyph_path);
#undef BIND
    return 0;
}
static void studio_bind_fonts(const struct mach_header* image,intptr_t slide) {
    const struct StudioMachHeader* h=(const void*)image;
    if(h->magic!=0xfeedfacf)return;
    const struct StudioLoad* command=(const void*)(h+1);
    const struct StudioSymtab* sym=0;const unsigned* dysym=0;
    const struct StudioSegment* linkedit=0;
    for(unsigned i=0;i<h->ncmds;i++,command=(const void*)((const char*)command+command->size)) {
        if(command->cmd==2)sym=(const void*)command;
        if(command->cmd==11)dysym=(const void*)command;
        if(command->cmd==0x19 && !strcmp(((const struct StudioSegment*)command)->name,"__LINKEDIT"))linkedit=(const void*)command;
    }
    if(!sym || !dysym || !linkedit)return;
    const char* base=(const char*)(slide+linkedit->vmaddr-linkedit->fileoff);
    const struct StudioNList* symbols=(const void*)(base+sym->symoff);
    const char* strings=base+sym->stroff;
    const unsigned* indirect=(const void*)(base+dysym[14]);
    command=(const void*)(h+1);
    for(unsigned i=0;i<h->ncmds;i++,command=(const void*)((const char*)command+command->size)) {
        if(command->cmd!=0x19)continue;
        const struct StudioSegment* segment=(const void*)command;
        const struct StudioSection* sections=(const void*)(segment+1);
        for(unsigned j=0;j<segment->nsects;j++) {
            const struct StudioSection* section=&sections[j];
            unsigned type=section->flags&255;
            if(type!=6 && type!=7)continue;
            void** slots=(void*)(slide+section->addr);
            for(unsigned long k=0;k<section->size/sizeof(void*);k++) {
                unsigned index=section->reserved1+k;
                if(index>=dysym[15])continue;
                unsigned n=indirect[index];if(n>=sym->nsyms)continue;
                unsigned strx=symbols[n].strx;if(strx>=sym->strsize)continue;
                void* replacement=studio_font_binding(strings+strx);if(!replacement)continue;
                if(!(segment->initprot&2)) {
                    extern int mprotect(void*,unsigned long,int);
                    unsigned long page=(unsigned long)&slots[k]&~4095UL;
                    if(mprotect((void*)page,4096,segment->initprot|2))continue;
                    slots[k]=replacement;
                    mprotect((void*)page,4096,segment->initprot);
                } else slots[k]=replacement;
            }
        }
    }
}
