/* GLSL 1.50 compatibility; the input is an owned allocation. */
extern void *malloc(unsigned long);
extern void free(void *);

char* quinta_fix_shader_indices(char* source, unsigned long* source_length) {
    /* Generated array indices multiply by signed 1 and add signed 0.
     * GLSL 1.50 rejects this when the index is uint (NVIDIA C7011),
     * including Grass's CB3 index and material CB12 indices. Removing the
     * identity arithmetic preserves either int or uint without a cast.
     * Match the closing bracket to keep other expressions untouched. */
    static const char needle[] = " * 1 + 0]";
    static const char replacement[] = "]";
    const unsigned long needle_length = sizeof(needle) - 1;
    unsigned long matches = 0;
    for (unsigned long position = 0;
         position + needle_length <= *source_length; position++) {
        unsigned long index = 0;
        while (index < needle_length &&
               source[position + index] == needle[index])
            index++;
        if (index == needle_length) {
            matches++;
            position += needle_length - 1;
        }
    }
    if (!matches)
        return source;

    unsigned long fixed_length = *source_length - matches * (sizeof(needle) - sizeof(replacement));
    char* fixed = (char*)malloc(fixed_length + 1);
    if (!fixed)
        return source;

    unsigned long input = 0;
    unsigned long output = 0;
    while (input < *source_length) {
        unsigned long index = 0;
        while (input + index < *source_length && index < needle_length &&
               source[input + index] == needle[index])
            index++;
        if (index == needle_length) {
            for (unsigned long index = 0; index < sizeof(replacement) - 1; index++)
                fixed[output++] = replacement[index];
            input += needle_length;
        } else {
            fixed[output++] = source[input++];
        }
    }
    fixed[output] = 0;
    free(source);
    *source_length = output;
    return fixed;
}

/* UIGradient atlas row. Roblox renders its gradient cache into a framebuffer
 * whose rows come out in GL's bottom-up order, then samples them with the
 * top-down row coordinate it uses for Metal: every gradient read an empty row
 * of the cache (one flat colour, or nothing). Flip the row coordinate in the
 * gradient fragment shaders. The input is an owned allocation. */
char* quinta_fix_gradient_atlas(char* source, unsigned long* source_length) {
    static const char needle[] = ", CB2[2].x));";
    static const char replacement[] = ", 1.0 - CB2[2].x));";
    static const char marker[] = "uniform sampler2D GradientAtlasTexture;";
    const unsigned long needle_length = sizeof(needle) - 1;
    const unsigned long replacement_length = sizeof(replacement) - 1;
    const unsigned long marker_length = sizeof(marker) - 1;
    int marked = 0;
    for (unsigned long p = 0; p + marker_length <= *source_length && !marked; p++) {
        unsigned long i = 0;
        while (i < marker_length && source[p + i] == marker[i]) i++;
        marked = i == marker_length;
    }
    if (!marked)
        return source;
    unsigned long matches = 0;
    for (unsigned long p = 0; p + needle_length <= *source_length; p++) {
        unsigned long i = 0;
        while (i < needle_length && source[p + i] == needle[i]) i++;
        if (i == needle_length) { matches++; p += needle_length - 1; }
    }
    if (!matches)
        return source;
    unsigned long fixed_length = *source_length + matches * (replacement_length - needle_length);
    char* fixed = (char*)malloc(fixed_length + 1);
    if (!fixed)
        return source;
    unsigned long input = 0, output = 0;
    while (input < *source_length) {
        unsigned long i = 0;
        while (input + i < *source_length && i < needle_length && source[input + i] == needle[i]) i++;
        if (i == needle_length) {
            for (unsigned long r = 0; r < replacement_length; r++) fixed[output++] = replacement[r];
            input += needle_length;
        } else {
            fixed[output++] = source[input++];
        }
    }
    fixed[output] = 0;
    free(source);
    *source_length = output;
    return fixed;
}
