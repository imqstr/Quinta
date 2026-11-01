#include "telemetry_hosts.h"
#include "shim_lock.h"
#include "worker_wake.h"
#include "graphics_context.h"
#include "x_modifier_state.h"
#include "x_key_codes.h"
#include "dns_concurrency.h"
#include "cursor_selection.h"
#include "cursor_pixels.h"
typedef struct objc_class *Class;
typedef struct objc_object { Class isa; } *id;
typedef struct objc_selector *SEL;
typedef struct objc_method *Method;
typedef void (*IMP)(void);

extern unsigned long long mach_absolute_time(void);
extern Class objc_getClass(const char *name);
extern SEL sel_registerName(const char *str);
extern Method class_getInstanceMethod(Class cls, SEL name);
extern Method class_getClassMethod(Class cls, SEL name);
extern IMP method_getImplementation(Method m);
extern IMP method_setImplementation(Method m, IMP imp);
extern const char* method_getTypeEncoding(Method m);
extern Class object_getClass(id obj);
extern const char* object_getClassName(id obj);
extern id objc_msgSend(id self, SEL op, ...);
extern void objc_msgSend_stret(id self, SEL op, ...);

extern char *getenv(const char *);
extern int write(int fd, const void *buf, unsigned long count);
extern int backtrace(void** array, int size);
extern void backtrace_symbols_fd(void* const* array, int size, int fd);
extern void* dlsym(void* handle, const char* symbol);
extern long _dyld_get_image_vmaddr_slide(unsigned int image_index);

#define RTLD_NEXT ((void*)-1)
#define RTLD_DEFAULT ((void*)-2)

#define DYLD_INTERPOSE(_replacement,_replacee) \
   __attribute__((used)) static struct{ const void* replacement; const void* replacee; } _interpose_##_replacee \
            __attribute__ ((section ("__DATA,__interpose"))) = { (const void*)(unsigned long)&_replacement, (const void*)(unsigned long)&_replacee };

static void write_str(const char* s);
static void print_hex(unsigned long long val);
static void print_num(long long val);
extern int quinta_wayland_enabled(void);
extern int quinta_wayland_captured(void);
extern id quinta_wayland_display(void);
extern int quinta_wayland_associate(unsigned int);

// A QUINTA_* switch: on when set to anything but "" or "0".
static int quinta_env_on(const char* name) {
    const char* value = getenv(name);
    return value && value[0] && !(value[0] == '0' && !value[1]);
}

// The same, read once: `*cache` starts at -1.
static int quinta_env_cached(const char* name, volatile int* cache) {
    int value = *cache;
    if (value < 0)
        *cache = value = quinta_env_on(name);
    return value;
}

// dlsym(RTLD_NEXT, name), looked up once per call site: Darling's dlsym
// walks every loaded image, far too slow for per-frame or per-throw paths.
#define QUINTA_NEXT(type, name) ({ \
    static void* volatile quinta_next_cache; \
    void* quinta_next_symbol = quinta_next_cache; \
    if (!quinta_next_symbol) \
        quinta_next_cache = quinta_next_symbol = dlsym(RTLD_NEXT, name); \
    (type)quinta_next_symbol; })

// Darling can create an IONotificationPort but currently returns an error when
// Roblox registers HID matching notifications.  Roblox then destroys the port
// and attempts a second registration with the cleared pointer, which crashes
// inside IOKit.  Report a valid empty registration: controller hot-plugging is
// unavailable, while AppKit keyboard and mouse input remain unaffected.
typedef void (*QuintaIOServiceMatchingCallback)(void*, unsigned int);
extern int IOServiceAddMatchingNotification(
    void*, const char*, void*, QuintaIOServiceMatchingCallback, void*, unsigned int*);
static int quinta_IOServiceAddMatchingNotification(
    void* notification_port,
    const char* notification_type,
    void* matching,
    QuintaIOServiceMatchingCallback callback,
    void* context,
    unsigned int* iterator) {
    (void)notification_port;
    (void)notification_type;
    (void)callback;
    (void)context;
    // Like the real function, consume the caller's reference to `matching`.
    extern void CFRelease(const void*);
    if (matching)
        CFRelease(matching);
    if (iterator)
        *iterator = 0;
    write_str("[Quinta] IOKit HID notification registered with empty iterator\n");
    return 0;
}
DYLD_INTERPOSE(quinta_IOServiceAddMatchingNotification,
               IOServiceAddMatchingNotification);

// Rewrite invalid GLSL 1.50 array-index arithmetic and capture the first
// source the driver rejects: Roblox's normal log contains the
// compiler message and line number, but not the GLSL text that caused it.
// The fix applies to every shader. Diagnostic dumps query the current GL
// context's driver-owned source instead of retaining a global name cache.
extern void glShaderSource(unsigned int, int, const char* const*, const int*);
extern void glCompileShader(unsigned int);
extern void* malloc(unsigned long);
extern void free(void*);
typedef struct QuintaFILE QuintaFILE;
extern QuintaFILE* fopen(const char*, const char*);
extern unsigned long fwrite(const void*, unsigned long, unsigned long, QuintaFILE*);
extern int fclose(QuintaFILE*);

static volatile int quinta_dumped_failed_shader;
static volatile int quinta_dumped_final_program;

static int quinta_gl_trace_enabled(void);
static int quinta_gl_test_ui_color(void) {
    static volatile int enabled = -1;
    return quinta_env_cached("QUINTA_GL_TEST_UI_COLOR", &enabled);
}

static int quinta_shader_is_vertex(unsigned int shader) {
    // Only the optional UI-color experiment needs a type query. GL names
    // belong to a context/share group, so a process-global GLuint table is
    // neither a safe lifetime model nor reliable type evidence.
    void (*query)(unsigned int, unsigned int, int*) =
        QUINTA_NEXT(void (*)(unsigned int, unsigned int, int*), "glGetShaderiv");
    int type = 0;
    if (query) query(shader, 0x8B4FU /* GL_SHADER_TYPE */, &type);
    return type == 0x8B31U;
}

static unsigned long quinta_cstr_length(const char* text) {
    unsigned long length = 0;
    if (text)
        while (text[length]) length++;
    return length;
}

extern char* quinta_fix_shader_indices(char*, unsigned long*);
extern char* quinta_fix_gradient_atlas(char*, unsigned long*);

static void quinta_apply_ui_color_test(char* source,
                                         unsigned long source_length) {
    if (!quinta_gl_test_ui_color())
        return;
    static const char needle[] =
        "_entryPointOutput = VARYING1 * _676;";
    static const char replacement[] =
        "_entryPointOutput = vec4(1,0,1,1)  ;";
    const unsigned long length = sizeof(needle) - 1;
    for (unsigned long position = 0;
         position + length <= source_length; position++) {
        unsigned long index = 0;
        while (index < length && source[position + index] == needle[index])
            index++;
        if (index == length) {
            for (index = 0; index < length; index++)
                source[position + index] = replacement[index];
            write_str("[Quinta GL] Forced UI fragment shader color\n");
            return;
        }
    }
}

static int quinta_source_contains(const char* source,
                                    unsigned long source_length,
                                    const char* needle) {
    unsigned long needle_length = quinta_cstr_length(needle);
    for (unsigned long position = 0;
         position + needle_length <= source_length; position++) {
        unsigned long index = 0;
        while (index < needle_length &&
               source[position + index] == needle[index])
            index++;
        if (index == needle_length)
            return 1;
    }
    return 0;
}

static void quinta_glShaderSource(unsigned int shader, int count,
                                    const char* const* strings,
                                    const int* lengths) {
    void (*real_function)(unsigned int, int, const char* const*, const int*) =
        QUINTA_NEXT(void (*)(unsigned int, int, const char* const*, const int*), "glShaderSource");

    const char* fixed_string = 0;
    int fixed_length = 0;
    char* owned = 0;
    if (count > 0 && strings) {
        unsigned long total = 0;
        for (int index = 0; index < count; index++) {
            unsigned long part = (lengths && lengths[index] >= 0)
                ? (unsigned long)lengths[index]
                : quinta_cstr_length(strings[index]);
            if (part > 1024UL * 1024UL - total) {
                total = 0;
                break;
            }
            total += part;
        }
        if (total) {
            char* copy = (char*)malloc(total + 1);
            if (copy) {
                unsigned long position = 0;
                for (int index = 0; index < count; index++) {
                    unsigned long part = (lengths && lengths[index] >= 0)
                        ? (unsigned long)lengths[index]
                        : quinta_cstr_length(strings[index]);
                    for (unsigned long offset = 0; offset < part; offset++)
                        copy[position++] = strings[index][offset];
                }
                copy[position] = 0;
                copy = quinta_fix_shader_indices(copy, &total);
                copy = quinta_fix_gradient_atlas(copy, &total);
                quinta_apply_ui_color_test(copy, total);
                if (quinta_gl_test_ui_color() && quinta_shader_is_vertex(shader) &&
                    quinta_source_contains(copy, total,
                                             "out vec2 VARYING2;")) {
                    static const char forced_vertex[] =
                        "#version 150\n"
                        "in vec4 POSITION; in vec2 TEXCOORD0; in vec4 COLOR0;\n"
                        "out vec2 VARYING0; out vec4 VARYING1; out vec2 VARYING2;\n"
                        "void main(){ int v=gl_VertexID%3; vec2 p=(v==0)?vec2(-1,-1):(v==1)?vec2(3,-1):vec2(-1,3); gl_Position=vec4(p,0,1); VARYING0=vec2(0); VARYING1=vec4(1); VARYING2=vec2(0); }\n";
                    unsigned long forced_length = sizeof(forced_vertex) - 1;
                    char* forced = (char*)malloc(forced_length + 1);
                    if (forced) {
                        for (unsigned long index = 0; index <= forced_length;
                             index++)
                            forced[index] = forced_vertex[index];
                        free(copy);
                        copy = forced;
                        total = forced_length;
                        write_str("[Quinta GL] Forced UI vertex coverage\n");
                    }
                }
                fixed_string = copy;
                fixed_length = (int)total;
                owned = copy; // GL keeps its own copy of the source
            }
        }
    }
    if (real_function) {
        if (fixed_string)
            real_function(shader, 1, &fixed_string, &fixed_length);
        else
            real_function(shader, count, strings, lengths);
    }
    free(owned);
}
DYLD_INTERPOSE(quinta_glShaderSource, glShaderSource);

static void quinta_glCompileShader(unsigned int shader) {
    void (*real_compile)(unsigned int) =
        QUINTA_NEXT(void (*)(unsigned int), "glCompileShader");
    void (*real_get_shader_iv)(unsigned int, unsigned int, int*) =
        QUINTA_NEXT(void (*)(unsigned int, unsigned int, int*), "glGetShaderiv");
    if (real_compile)
        real_compile(shader);

    // A status query can wait for asynchronous driver compilation. Roblox
    // checks its own shaders; the extra query is only for source diagnostics.
    if (!quinta_gl_trace_enabled())
        return;
    int succeeded = 1;
    if (real_get_shader_iv)
        real_get_shader_iv(shader, 0x8B81U, &succeeded); // GL_COMPILE_STATUS
    if (succeeded || quinta_dumped_failed_shader)
        return;
    // The source as GL has it (after the fixes above).
    void (*real_get_source)(unsigned int, int, int*, char*) =
        QUINTA_NEXT(void (*)(unsigned int, int, int*, char*), "glGetShaderSource");
    int size = 0;
    if (real_get_shader_iv)
        real_get_shader_iv(shader, 0x8B88U, &size); // GL_SHADER_SOURCE_LENGTH
    char* source = size > 0 && size <= 1024 * 1024 && real_get_source
        ? (char*)malloc((unsigned long)size) : 0;
    int length = 0;
    if (source)
        real_get_source(shader, size, &length, source);
    if (source && length > 0 && length < size &&
        __sync_bool_compare_and_swap(&quinta_dumped_failed_shader, 0, 1)) {
        QuintaFILE* output = fopen(
            "/private/tmp/quinta-first-failed-shader.glsl", "w");
        if (output) {
            fwrite(source, 1, (unsigned long)length, output);
            fclose(output);
            write_str("[Quinta GL] Captured first failed shader source\n");
        }
    }
    free(source);
}
DYLD_INTERPOSE(quinta_glCompileShader, glCompileShader);

// Trace every CGL/EGL binding change with its thread. Roblox renders on a
// worker thread; EGL allows a surface to be current in only one thread, so a
// failed eglMakeCurrent there leaves the renderer without a window surface.
// Enabled with QUINTA_TRACE_CGL=1; the output is bounded per function.
extern void* pthread_self(void);
extern unsigned int pthread_mach_thread_np(void*);
extern int CGLCreateContext(void*, void*, void**);
extern int CGLChoosePixelFormat(const int*, void**, int*);
extern int CGLSetCurrentContext(void*);
extern int CGLContextMakeCurrentAndAttachToWindow(void*, void*);
extern int CGLFlushDrawable(void*);
extern unsigned int eglMakeCurrent(void*, void*, void*, void*);

static int quinta_trace_cgl_enabled(void) {
    static volatile int enabled = -1;
    return quinta_env_cached("QUINTA_TRACE_CGL", &enabled);
}

static int quinta_trace_cgl_should_log(volatile long* counter) {
    long count = __sync_add_and_fetch(counter, 1);
    return count <= 40 || count % 1000 == 0;
}

static void quinta_trace_cgl_prefix(const char* name, volatile long* counter) {
    write_str("[Quinta CGL] ");
    write_str(name);
    write_str(" #");
    print_num(*counter);
    write_str(" thread=");
    print_num(pthread_mach_thread_np(pthread_self()));
}

static void* quinta_cgl_egl_context(void* cgl) {
    // struct _CGLContextObj: retain_count, pthread_mutex_t (64 bytes on
    // Darwin x86_64), egl_context, egl_surface.
    return cgl ? ((void**)cgl)[9] : 0;
}

static void* quinta_cgl_egl_surface(void* cgl) {
    return cgl ? ((void**)cgl)[10] : 0;
}

static volatile long quinta_cgl_create_count;
static int quinta_CGLChoosePixelFormat(const int* attributes, void** result, int* count) {
    int* terminated = quinta_copy_pixel_attributes(attributes);
    if (!terminated) {
        if (result) *result = 0;
        if (count) *count = 0;
        return attributes ? 10016 /* kCGLBadAlloc */ : 10000 /* kCGLBadAttribute */;
    }
    int error = CGLChoosePixelFormat(attributes, result, count);
    if (!error && result && *result && terminated) {
        // Darling's CGL copy omits the final zero, but its descriptor scans
        // until zero. Replace that owned allocation with the complete list.
        void** format = (void**)*result;
        free(format[1]);
        format[1] = terminated;
    } else {
        free(terminated);
    }
    return error;
}
DYLD_INTERPOSE(quinta_CGLChoosePixelFormat, CGLChoosePixelFormat);

static int quinta_CGLCreateContext(void* format, void* share, void** result) {
    // Darling initializes its EGL display inside this call. The EGL context
    // wrapper binds desktop GL after that initialization, on this thread.
    if (quinta_trace_cgl_enabled() && format) {
        // struct _CGLPixelFormatObj { GLuint retain_count; CGLPixelFormatAttribute* attributes; }
        int* attributes = ((int**)format)[1];
        write_str("[Quinta CGL] pixel format:");
        for (int index = 0; attributes && index < 64 && attributes[index]; index++) {
            write_str(" ");
            print_num(attributes[index]);
        }
        write_str("\n");
    }
    int error = CGLCreateContext(format, share, result);
    if (quinta_trace_cgl_enabled() &&
        quinta_trace_cgl_should_log(&quinta_cgl_create_count)) {
        quinta_trace_cgl_prefix("CGLCreateContext", &quinta_cgl_create_count);
        write_str(" share=");
        print_hex((unsigned long long)share);
        write_str(" share-egl=");
        print_hex((unsigned long long)quinta_cgl_egl_context(share));
        write_str(" result=");
        print_hex((unsigned long long)(result ? *result : 0));
        write_str(" egl=");
        print_hex((unsigned long long)quinta_cgl_egl_context(result ? *result : 0));
        write_str(" error=");
        print_num(error);
        write_str("\n");
    }
    return error;
}
DYLD_INTERPOSE(quinta_CGLCreateContext, CGLCreateContext);

static volatile long quinta_cgl_set_current_count;
static int quinta_CGLSetCurrentContext(void* context) {
    quinta_context_change change;
    if (!quinta_begin_context_change(&change))
        return 10004;
    int error = CGLSetCurrentContext(context);
    error = quinta_finish_context_change(&change, error);
    if (quinta_trace_cgl_enabled() &&
        quinta_trace_cgl_should_log(&quinta_cgl_set_current_count)) {
        quinta_trace_cgl_prefix("CGLSetCurrentContext",
                                  &quinta_cgl_set_current_count);
        write_str(" cgl=");
        print_hex((unsigned long long)context);
        write_str(" egl=");
        print_hex((unsigned long long)quinta_cgl_egl_context(context));
        write_str(" surface=");
        print_hex((unsigned long long)quinta_cgl_egl_surface(context));
        write_str("\n");
    }
    return error;
}
DYLD_INTERPOSE(quinta_CGLSetCurrentContext, CGLSetCurrentContext);

static volatile long quinta_cgl_attach_count;
static int quinta_CGLContextMakeCurrentAndAttachToWindow(void* context,
                                                          void* window) {
    if (!context)
        return 10004;
    quinta_context_change change;
    if (!quinta_begin_context_change(&change))
        return 10004;
    change.surface_slot = &((void**)context)[10];
    change.previous_surface = *change.surface_slot;
    int error = CGLContextMakeCurrentAndAttachToWindow(context, window);
    error = quinta_finish_context_change(&change, error);
    if (quinta_trace_cgl_enabled() &&
        quinta_trace_cgl_should_log(&quinta_cgl_attach_count)) {
        quinta_trace_cgl_prefix("CGLContextMakeCurrentAndAttachToWindow",
                                  &quinta_cgl_attach_count);
        write_str(" cgl=");
        print_hex((unsigned long long)context);
        write_str(" egl=");
        print_hex((unsigned long long)quinta_cgl_egl_context(context));
        write_str(" window=");
        print_hex((unsigned long long)window);
        write_str("\n");
    }
    return error;
}
DYLD_INTERPOSE(quinta_CGLContextMakeCurrentAndAttachToWindow,
               CGLContextMakeCurrentAndAttachToWindow);

// Frame presentation (gl_profile.c): vsync off unless QUINTA_VSYNC=1,
// and an FPS line every 5 s with QUINTA_FPS_LOG=1.
extern void quinta_frame_presenting(void* cgl_context);
static volatile long quinta_cgl_flush_drawable_count;
static void quinta_attach_recovered_gl_drawable(void* context);
static int quinta_CGLFlushDrawable(void* context) {
    if (!context)
        return 10004;
    quinta_attach_recovered_gl_drawable(context);
    if (quinta_trace_cgl_enabled() &&
        quinta_trace_cgl_should_log(&quinta_cgl_flush_drawable_count)) {
        quinta_trace_cgl_prefix("CGLFlushDrawable",
                                  &quinta_cgl_flush_drawable_count);
        write_str(" cgl=");
        print_hex((unsigned long long)context);
        write_str(" egl=");
        print_hex((unsigned long long)quinta_cgl_egl_context(context));
        write_str(" surface=");
        print_hex((unsigned long long)quinta_cgl_egl_surface(context));
        write_str("\n");
    }
    quinta_frame_presenting(context);
    unsigned long serial = quinta_egl_swap_serial();
    return quinta_finish_cgl_swap(serial, CGLFlushDrawable(context));
}
DYLD_INTERPOSE(quinta_CGLFlushDrawable, CGLFlushDrawable);

static volatile long quinta_egl_make_current_count;
static unsigned int quinta_eglMakeCurrent(void* display, void* draw,
                                            void* read, void* context) {
    unsigned int result = eglMakeCurrent(display, draw, read, context);
    quinta_record_egl_binding(result, context);
    if (quinta_trace_cgl_enabled() &&
        quinta_trace_cgl_should_log(&quinta_egl_make_current_count)) {
        quinta_trace_cgl_prefix("eglMakeCurrent",
                                  &quinta_egl_make_current_count);
        write_str(" display=");
        print_hex((unsigned long long)display);
        write_str(" draw=");
        print_hex((unsigned long long)draw);
        write_str(" context=");
        print_hex((unsigned long long)context);
        write_str(" result=");
        print_num(result);
        write_str(" error=");
        print_hex((unsigned int)quinta_egl_binding_error());
        write_str("\n");
    }
    return result;
}
DYLD_INTERPOSE(quinta_eglMakeCurrent, eglMakeCurrent);

// Count the commands that can actually produce or resolve pixels. A steady
// stream of NSOpenGLContext flushes only proves that Darling swaps the X11
// surface; it does not prove that Roblox submitted a frame to that surface.
// Keep these wrappers passive so the diagnostic cannot change GL state.
extern void glDrawArrays(unsigned int, int, int);
extern void glDrawElements(unsigned int, int, unsigned int, const void*);
extern void glDrawRangeElements(unsigned int, unsigned int, unsigned int, int,
                                unsigned int, const void*);
extern void glDrawElementsBaseVertex(unsigned int, int, unsigned int,
                                     const void*, int);
extern void glDrawArraysInstanced(unsigned int, int, int, int);
extern void glDrawElementsInstanced(unsigned int, int, unsigned int,
                                    const void*, int);
extern void glDrawElementsInstancedBaseVertex(unsigned int, int, unsigned int,
                                              const void*, int, int);
extern void glBlitFramebuffer(int, int, int, int, int, int, int, int,
                              unsigned int, unsigned int);
extern void glBindFramebuffer(unsigned int, unsigned int);
extern void glClear(unsigned int);

static volatile long quinta_gl_draw_count;
static volatile long quinta_gl_blit_count;
static volatile long quinta_gl_clear_count;
static volatile long quinta_gl_default_framebuffer_bind_count;
static void* quinta_gl_window_surface;
static void* quinta_gl_window_egl_context;
static void* quinta_gl_render_egl_context;
static volatile long quinta_gl_surface_repair_attempts;
static volatile long quinta_gl_traced_window_draws;
static volatile long quinta_gl_skipped_foreign_draws;
static volatile int quinta_dumped_uniform_blocks;
static volatile int quinta_dumped_actual_program;

static void quinta_dump_program_sources(unsigned int program, volatile int* once, int actual) {
    if (!program)
        return;
    void (*attached_shaders)(unsigned int, int, int*, unsigned int*) =
        QUINTA_NEXT(void (*)(unsigned int, int, int*, unsigned int*), "glGetAttachedShaders");
    void (*shader_iv)(unsigned int, unsigned int, int*) =
        QUINTA_NEXT(void (*)(unsigned int, unsigned int, int*), "glGetShaderiv");
    void (*shader_source)(unsigned int, int, int*, char*) =
        QUINTA_NEXT(void (*)(unsigned int, int, int*, char*), "glGetShaderSource");
    if (!attached_shaders || !shader_iv || !shader_source ||
        !__sync_bool_compare_and_swap(once, 0, 1))
        return;
    unsigned int shaders[4] = {0, 0, 0, 0};
    int shader_count = 0;
    attached_shaders(program, 4, &shader_count, shaders);
    write_str(actual ? "[Quinta GL] actual program=" : "[Quinta GL] final program=");
    print_num(program);
    write_str(" attached="); print_num(shader_count); write_str(" shaders=");
    for (int index = 0; index < shader_count && index < 4; index++) {
        if (index) write_str(",");
        print_num(shaders[index]);
        int type = 0, source_length = 0;
        shader_iv(shaders[index], 0x8B4FU /* GL_SHADER_TYPE */, &type);
        write_str(":"); print_hex((unsigned int)type);
        shader_iv(shaders[index], 0x8B88U /* GL_SHADER_SOURCE_LENGTH */, &source_length);
        if (source_length <= 1 || source_length > 1024 * 1024)
            continue;
        char* source = (char*)malloc((unsigned long)source_length);
        if (!source) continue;
        int written = 0;
        shader_source(shaders[index], source_length, &written, source);
        char actual_path[] = "/Volumes/SystemRoot/tmp/quinta-actual-program-shader-0.glsl";
        char final_path[] = "/Volumes/SystemRoot/tmp/quinta-final-shader-0.glsl";
        actual_path[sizeof(actual_path) - sizeof("0.glsl")] = (char)('0' + index);
        final_path[sizeof(final_path) - sizeof("0.glsl")] = (char)('0' + index);
        if (written > 0 && written <= source_length) {
            QuintaFILE* output = fopen(actual ? actual_path : final_path, "w");
            if (output) {
                fwrite(source, 1, (unsigned long)written, output);
                fclose(output);
            }
        }
        free(source);
    }
    write_str("\n");
}

static void quinta_dump_actual_program_sources(unsigned int program) {
    if (program >= 700)
        quinta_dump_program_sources(program, &quinta_dumped_actual_program, 1);
}

// The EGL surface repair and foreign-draw filtering below were workarounds
// for Roblox drawing into the wrong context, which restoring the context
// after CALayerContext renders fixed properly. They stay available for
// debugging with QUINTA_GL_HACKS=1.
static int quinta_gl_hacks_disabled(void) {
    static volatile int enabled = -1;
    return !quinta_env_cached("QUINTA_GL_HACKS", &enabled);
}

static void quinta_ensure_gl_window_surface(void) {
    if (quinta_gl_hacks_disabled())
        return;
    void* surface = quinta_gl_window_surface;
    void* (*current_surface)(int) =
        (void* (*)(int))dlsym(RTLD_NEXT, "eglGetCurrentSurface");
    if (!surface || !current_surface || current_surface(0x3059)) // EGL_DRAW
        return;

    void* (*current_display)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentDisplay");
    void* (*current_context)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentContext");
    int (*make_current)(void*, void*, void*, void*) =
        (int (*)(void*, void*, void*, void*))
            dlsym(RTLD_NEXT, "eglMakeCurrent");
    unsigned int (*egl_error)(void) =
        (unsigned int (*)(void))dlsym(RTLD_NEXT, "eglGetError");
    if (!current_display || !current_context || !make_current)
        return;

    // Roblox switches from AppKit's initial CGL context to its own shared
    // render context. The latter owns the draws but Darling leaves it
    // surfaceless, so attach whichever live context is selecting framebuffer
    // zero rather than limiting this repair to AppKit's original context.
    void* context = current_context();
    if (!context)
        return;

    int attached = make_current(current_display(), surface, surface,
                                context);
    long attempt = __sync_add_and_fetch(&quinta_gl_surface_repair_attempts, 1);
    if (attempt <= 5) {
        write_str("[Quinta GL] draw-time EGL surface repair #");
        print_num(attempt);
        write_str(" result=");
        print_num(attached);
        write_str(" error=");
        print_hex(egl_error ? egl_error() : 0);
        write_str(" surface-now=");
        print_hex((unsigned long long)current_surface(0x3059));
        write_str("\n");
    }
}

static int quinta_should_skip_foreign_window_command(int learn_renderer) {
    if (quinta_gl_hacks_disabled())
        return 0;
    void* (*current_surface)(int) =
        (void* (*)(int))dlsym(RTLD_NEXT, "eglGetCurrentSurface");
    void* (*current_context)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentContext");
    if (!current_surface || !current_context ||
        current_surface(0x3059) != quinta_gl_window_surface)
        return 0;

    void* context = current_context();
    if (learn_renderer) {
        void (*get_integer)(unsigned int, int*) =
            (void (*)(unsigned int, int*))dlsym(RTLD_NEXT, "glGetIntegerv");
        int program = 0;
        if (get_integer)
            get_integer(0x8B8DU, &program); // GL_CURRENT_PROGRAM
        if (program > 0) {
            quinta_gl_render_egl_context = context;
            if (quinta_gl_test_ui_color() && program >= 700) {
                void (*disable)(unsigned int) =
                    (void (*)(unsigned int))dlsym(RTLD_NEXT, "glDisable");
                void (*color_mask)(unsigned char, unsigned char,
                                   unsigned char, unsigned char) =
                    (void (*)(unsigned char, unsigned char, unsigned char,
                              unsigned char))dlsym(RTLD_NEXT, "glColorMask");
                if (disable) {
                    disable(0x0BE2U); // GL_BLEND
                    disable(0x0B71U); // GL_DEPTH_TEST
                    disable(0x0B44U); // GL_CULL_FACE
                    disable(0x0C11U); // GL_SCISSOR_TEST
                    disable(0x0B90U); // GL_STENCIL_TEST
                    disable(0x8C89U); // GL_RASTERIZER_DISCARD
                    for (unsigned int clip = 0; clip < 8; clip++)
                        disable(0x3000U + clip); // GL_CLIP_DISTANCE0..
                }
                if (color_mask)
                    color_mask(1, 1, 1, 1);
            }
        }
    }
    return quinta_gl_render_egl_context &&
           context != quinta_gl_render_egl_context;
}

static void quinta_trace_window_draw(unsigned int mode, int count) {
    // Once the bounded capture is complete, avoid driver queries on every
    // later draw. Diagnostic logging must not keep synchronizing gameplay.
    if (__atomic_load_n(&quinta_gl_traced_window_draws, __ATOMIC_RELAXED) >= 16)
        return;
    unsigned int (*get_error)(void) =
        (unsigned int (*)(void))dlsym(RTLD_NEXT, "glGetError");
    unsigned int draw_error = get_error ? get_error() : 0;
    void* (*current_surface)(int) =
        (void* (*)(int))dlsym(RTLD_NEXT, "eglGetCurrentSurface");
    if (!current_surface || !current_surface(0x3059))
        return;

    void (*get_integer)(unsigned int, int*) =
        (void (*)(unsigned int, int*))dlsym(RTLD_NEXT, "glGetIntegerv");
    if (!get_integer)
        return;
    int framebuffer = -1;
    get_integer(0x8CA6U, &framebuffer); // GL_DRAW_FRAMEBUFFER_BINDING
    if (framebuffer)
        return;

    long sequence = __sync_add_and_fetch(&quinta_gl_traced_window_draws, 1);
    if (sequence > 16)
        return;

    int program = 0;
    int vertex_array = 0;
    int active_texture = 0;
    int texture = 0;
    int viewport[4] = {0, 0, 0, 0};
    int scissor[4] = {0, 0, 0, 0};
    get_integer(0x8B8DU, &program);       // GL_CURRENT_PROGRAM
    get_integer(0x85B5U, &vertex_array);  // GL_VERTEX_ARRAY_BINDING
    get_integer(0x84E0U, &active_texture);// GL_ACTIVE_TEXTURE
    get_integer(0x0BA2U, viewport);       // GL_VIEWPORT
    get_integer(0x0C10U, scissor);        // GL_SCISSOR_BOX

    int (*uniform_location)(unsigned int, const char*) =
        (int (*)(unsigned int, const char*))
            dlsym(RTLD_NEXT, "glGetUniformLocation");
    void (*get_uniform)(unsigned int, int, int*) =
        (void (*)(unsigned int, int, int*))
            dlsym(RTLD_NEXT, "glGetUniformiv");
    void (*active_texture_fn)(unsigned int) =
        (void (*)(unsigned int))dlsym(RTLD_NEXT, "glActiveTexture");
    int sampler = 0;
    if (uniform_location && get_uniform && program > 0) {
        int location = uniform_location((unsigned int)program,
                                        "DiffuseMapTexture");
        if (location >= 0)
            get_uniform((unsigned int)program, location, &sampler);
    }
    if (active_texture_fn) {
        active_texture_fn(0x84C0U + (unsigned int)sampler); // GL_TEXTURE0
        get_integer(0x8069U, &texture); // GL_TEXTURE_BINDING_2D
        active_texture_fn((unsigned int)active_texture);
    }

    unsigned int (*uniform_block_index)(unsigned int, const char*) =
        (unsigned int (*)(unsigned int, const char*))
            dlsym(RTLD_NEXT, "glGetUniformBlockIndex");
    void (*uniform_block_iv)(unsigned int, unsigned int, unsigned int, int*) =
        (void (*)(unsigned int, unsigned int, unsigned int, int*))
            dlsym(RTLD_NEXT, "glGetActiveUniformBlockiv");
    void (*get_integer_indexed)(unsigned int, unsigned int, int*) =
        (void (*)(unsigned int, unsigned int, int*))
            dlsym(RTLD_NEXT, "glGetIntegeri_v");
    int cb0_buffer = -1;
    int cb1_buffer = -1;
    quinta_dump_actual_program_sources((unsigned int)program);
    if (uniform_block_index && uniform_block_iv && get_integer_indexed &&
        program > 0) {
        const char* names[2] = {"block_CB0", "block_CB1"};
        int* buffers[2] = {&cb0_buffer, &cb1_buffer};
        for (int index = 0; index < 2; index++) {
            unsigned int block = uniform_block_index((unsigned int)program,
                                                      names[index]);
            if (block != 0xFFFFFFFFU) {
                int binding = 0;
                uniform_block_iv((unsigned int)program, block, 0x8A3FU,
                                 &binding); // GL_UNIFORM_BLOCK_BINDING
                get_integer_indexed(0x8A28U, (unsigned int)binding,
                                    buffers[index]);
            }
        }
    }

    if (program >= 700 && uniform_block_iv && get_integer_indexed &&
        __sync_bool_compare_and_swap(&quinta_dumped_uniform_blocks, 0, 1)) {
        void (*get_program)(unsigned int, unsigned int, int*) =
            (void (*)(unsigned int, unsigned int, int*))
                dlsym(RTLD_NEXT, "glGetProgramiv");
        void (*block_name)(unsigned int, unsigned int, int, int*, char*) =
            (void (*)(unsigned int, unsigned int, int, int*, char*))
                dlsym(RTLD_NEXT, "glGetActiveUniformBlockName");
        int blocks = 0;
        if (get_program)
            get_program((unsigned int)program, 0x8A36U, &blocks);
        write_str("[Quinta GL] uniform-blocks program=");
        print_num(program);
        write_str(" count=");
        print_num(blocks);
        write_str("\n");
        for (int block = 0; block < blocks && block < 8; block++) {
            int binding = -1;
            int size = -1;
            int buffer = -1;
            int written = 0;
            char name[128];
            name[0] = 0;
            uniform_block_iv((unsigned int)program, (unsigned int)block,
                             0x8A3FU, &binding);
            uniform_block_iv((unsigned int)program, (unsigned int)block,
                             0x8A40U, &size); // GL_UNIFORM_BLOCK_DATA_SIZE
            if (block_name)
                block_name((unsigned int)program, (unsigned int)block,
                           127, &written, name);
            name[127] = 0;
            if (binding >= 0)
                get_integer_indexed(0x8A28U, (unsigned int)binding, &buffer);
            write_str("[Quinta GL] uniform-block #");
            print_num(block);
            write_str(" name=");
            write_str(name);
            write_str(" binding=");
            print_num(binding);
            write_str(" buffer=");
            print_num(buffer);
            write_str(" size=");
            print_num(size);
            write_str("\n");
        }
    }

    unsigned char (*is_enabled)(unsigned int) =
        (unsigned char (*)(unsigned int))dlsym(RTLD_NEXT, "glIsEnabled");
    void* (*current_context)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentContext");
    write_str("[Quinta GL] window-draw #");
    print_num(sequence);
    write_str(" mode=");
    print_hex(mode);
    write_str(" count=");
    print_num(count);
    write_str(" program=");
    print_num(program);
    write_str(" error=");
    print_hex(draw_error);
    write_str(" egl-context=");
    print_hex((unsigned long long)(current_context ? current_context() : 0));
    write_str(" vao=");
    print_num(vertex_array);
    write_str(" sampler=");
    print_num(sampler);
    write_str(" texture=");
    print_num(texture);
    write_str(" cb0=");
    print_num(cb0_buffer);
    write_str(" cb1=");
    print_num(cb1_buffer);
    write_str(" blend=");
    print_num(is_enabled ? is_enabled(0x0BE2U) : -1);
    write_str(" scissor-enabled=");
    print_num(is_enabled ? is_enabled(0x0C11U) : -1);
    write_str(" viewport=");
    print_num(viewport[0]); write_str(","); print_num(viewport[1]);
    write_str(","); print_num(viewport[2]); write_str(",");
    print_num(viewport[3]);
    write_str(" scissor=");
    print_num(scissor[0]); write_str(","); print_num(scissor[1]);
    write_str(","); print_num(scissor[2]); write_str(",");
    print_num(scissor[3]);
    write_str("\n");
}

// GL call tracing is opt-in (QUINTA_TRACE_GL=1). Without it the wrappers
// below only forward: tracing costs dlsym, glGetError and several
// glGetIntegerv per draw, which in game (thousands of draws per frame) was a
// large part of the frame time.
static int quinta_gl_trace_enabled(void) {
    static volatile int enabled = -1;
    return quinta_env_cached("QUINTA_TRACE_GL", &enabled);
}

static void quinta_glBindFramebuffer(unsigned int target,
                                       unsigned int framebuffer) {
    static void (*real_function)(unsigned int, unsigned int);
    if (!real_function)
        real_function = (void (*)(unsigned int, unsigned int))
            dlsym(RTLD_NEXT, "glBindFramebuffer");
    if (!quinta_gl_trace_enabled() && quinta_gl_hacks_disabled()) {
        if (real_function)
            real_function(target, framebuffer);
        return;
    }
    // Binding framebuffer 0 selects the window drawable. Restore its EGL
    // surface before GL validates the following clear and draw commands.
    if (!framebuffer) {
        quinta_ensure_gl_window_surface();
        __sync_add_and_fetch(&quinta_gl_default_framebuffer_bind_count, 1);
    }
    if (real_function)
        real_function(target, framebuffer);
}
DYLD_INTERPOSE(quinta_glBindFramebuffer, glBindFramebuffer);

static void quinta_glClear(unsigned int mask) {
    static void (*real_function)(unsigned int);
    if (!real_function)
        real_function = (void (*)(unsigned int))dlsym(RTLD_NEXT, "glClear");
    if (!quinta_gl_trace_enabled() && quinta_gl_hacks_disabled()) {
        if (real_function)
            real_function(mask);
        return;
    }
    quinta_ensure_gl_window_surface();
    __sync_add_and_fetch(&quinta_gl_clear_count, 1);
    if (real_function &&
        !quinta_should_skip_foreign_window_command(0))
        real_function(mask);
}
DYLD_INTERPOSE(quinta_glClear, glClear);

static void quinta_glDrawArrays(unsigned int mode, int first, int count) {
    static void (*real_function)(unsigned int, int, int);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, int))
            dlsym(RTLD_NEXT, "glDrawArrays");
    if (!quinta_gl_trace_enabled() && quinta_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, first, count);
        // Keep the initial AppKit draw's error check without enabling tracing
        // on every draw. Removing this single query reproduces an early
        // NVIDIA worker abort under Darling, with both -O0 and -O2 builds.
        if (quinta_graphics_first_draw()) {
            unsigned int (*error)(void) = QUINTA_NEXT(unsigned int (*)(void), "glGetError");
            if (error) error();
        }
        return;
    }
    quinta_ensure_gl_window_surface();
    __sync_add_and_fetch(&quinta_gl_draw_count, 1);
    if (real_function &&
        !quinta_should_skip_foreign_window_command(1))
        real_function(mode, first, count);
    else
        __sync_add_and_fetch(&quinta_gl_skipped_foreign_draws, 1);
    quinta_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(quinta_glDrawArrays, glDrawArrays);

static void quinta_glDrawElements(unsigned int mode, int count,
                                    unsigned int type, const void* indices) {
    static void (*real_function)(unsigned int, int, unsigned int, const void*);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, unsigned int, const void*))
            dlsym(RTLD_NEXT, "glDrawElements");
    if (!quinta_gl_trace_enabled() && quinta_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, count, type, indices);
        return;
    }
    quinta_ensure_gl_window_surface();
    __sync_add_and_fetch(&quinta_gl_draw_count, 1);
    if (real_function &&
        !quinta_should_skip_foreign_window_command(1))
        real_function(mode, count, type, indices);
    else
        __sync_add_and_fetch(&quinta_gl_skipped_foreign_draws, 1);
    quinta_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(quinta_glDrawElements, glDrawElements);

static void quinta_glDrawRangeElements(unsigned int mode, unsigned int start,
                                         unsigned int end, int count,
                                         unsigned int type,
                                         const void* indices) {
    static void (*real_function)(unsigned int, unsigned int, unsigned int, int,
                                 unsigned int, const void*);
    if (!real_function)
        real_function = (void (*)(unsigned int, unsigned int, unsigned int, int,
                                  unsigned int, const void*))
            dlsym(RTLD_NEXT, "glDrawRangeElements");
    if (!quinta_gl_trace_enabled() && quinta_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, start, end, count, type, indices);
        return;
    }
    quinta_ensure_gl_window_surface();
    __sync_add_and_fetch(&quinta_gl_draw_count, 1);
    if (real_function &&
        !quinta_should_skip_foreign_window_command(1))
        real_function(mode, start, end, count, type, indices);
    else
        __sync_add_and_fetch(&quinta_gl_skipped_foreign_draws, 1);
    quinta_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(quinta_glDrawRangeElements, glDrawRangeElements);

static void quinta_glDrawElementsBaseVertex(unsigned int mode, int count,
                                              unsigned int type,
                                              const void* indices,
                                              int base_vertex) {
    static void (*real_function)(unsigned int, int, unsigned int, const void*,
                                 int);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, unsigned int, const void*,
                                  int))dlsym(RTLD_NEXT,
                                             "glDrawElementsBaseVertex");
    if (!quinta_gl_trace_enabled() && quinta_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, count, type, indices, base_vertex);
        return;
    }
    quinta_ensure_gl_window_surface();
    __sync_add_and_fetch(&quinta_gl_draw_count, 1);
    if (real_function &&
        !quinta_should_skip_foreign_window_command(1))
        real_function(mode, count, type, indices, base_vertex);
    else
        __sync_add_and_fetch(&quinta_gl_skipped_foreign_draws, 1);
    quinta_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(quinta_glDrawElementsBaseVertex, glDrawElementsBaseVertex);

static void quinta_glDrawArraysInstanced(unsigned int mode, int first,
                                           int count, int instances) {
    static void (*real_function)(unsigned int, int, int, int);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, int, int))
            dlsym(RTLD_NEXT, "glDrawArraysInstanced");
    if (!quinta_gl_trace_enabled() && quinta_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, first, count, instances);
        return;
    }
    quinta_ensure_gl_window_surface();
    __sync_add_and_fetch(&quinta_gl_draw_count, 1);
    if (real_function &&
        !quinta_should_skip_foreign_window_command(1))
        real_function(mode, first, count, instances);
    else
        __sync_add_and_fetch(&quinta_gl_skipped_foreign_draws, 1);
    quinta_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(quinta_glDrawArraysInstanced, glDrawArraysInstanced);

static void quinta_glDrawElementsInstanced(unsigned int mode, int count,
                                             unsigned int type,
                                             const void* indices,
                                             int instances) {
    static void (*real_function)(unsigned int, int, unsigned int, const void*,
                                 int);
    if (!real_function)
        real_function = (void (*)(unsigned int, int, unsigned int, const void*,
                                  int))dlsym(RTLD_NEXT,
                                             "glDrawElementsInstanced");
    if (!quinta_gl_trace_enabled() && quinta_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, count, type, indices, instances);
        return;
    }
    quinta_ensure_gl_window_surface();
    __sync_add_and_fetch(&quinta_gl_draw_count, 1);
    if (real_function &&
        !quinta_should_skip_foreign_window_command(1))
        real_function(mode, count, type, indices, instances);
    else
        __sync_add_and_fetch(&quinta_gl_skipped_foreign_draws, 1);
    quinta_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(quinta_glDrawElementsInstanced, glDrawElementsInstanced);

static void quinta_glDrawElementsInstancedBaseVertex(
    unsigned int mode, int count, unsigned int type, const void* indices,
    int instances, int base_vertex) {
    static void (*real_function)(unsigned int, int, unsigned int, const void*,
                                 int, int);
    if (!real_function)
        real_function =
            (void (*)(unsigned int, int, unsigned int, const void*, int, int))
                dlsym(RTLD_NEXT, "glDrawElementsInstancedBaseVertex");
    if (!quinta_gl_trace_enabled() && quinta_gl_hacks_disabled()) {
        if (real_function)
            real_function(mode, count, type, indices, instances, base_vertex);
        return;
    }
    quinta_ensure_gl_window_surface();
    __sync_add_and_fetch(&quinta_gl_draw_count, 1);
    if (real_function &&
        !quinta_should_skip_foreign_window_command(1))
        real_function(mode, count, type, indices, instances, base_vertex);
    else
        __sync_add_and_fetch(&quinta_gl_skipped_foreign_draws, 1);
    quinta_trace_window_draw(mode, count);
}
DYLD_INTERPOSE(quinta_glDrawElementsInstancedBaseVertex,
               glDrawElementsInstancedBaseVertex);

static void quinta_glBlitFramebuffer(int sx0, int sy0, int sx1, int sy1,
                                       int dx0, int dy0, int dx1, int dy1,
                                       unsigned int mask,
                                       unsigned int filter) {
    static void (*real_function)(int, int, int, int, int, int, int, int,
                                 unsigned int, unsigned int);
    if (!real_function)
        real_function =
            (void (*)(int, int, int, int, int, int, int, int, unsigned int,
                      unsigned int))dlsym(RTLD_NEXT, "glBlitFramebuffer");
    __sync_add_and_fetch(&quinta_gl_blit_count, 1);
    if (real_function)
        real_function(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter);
}
DYLD_INTERPOSE(quinta_glBlitFramebuffer, glBlitFramebuffer);

static void write_str(const char* s) {
    if (!s) return;
    int len = 0;
    while (s[len]) len++;
    write(2, s, len);
}

static void print_hex(unsigned long long val) {
    char buf[20];
    buf[0] = '0';
    buf[1] = 'x';
    for (int i = 15; i >= 0; i--) {
        int nibble = (val >> (i * 4)) & 0xF;
        buf[2 + (15 - i)] = (nibble < 10) ? ('0' + nibble) : ('a' + nibble - 10);
    }
    buf[18] = '\0';
    write(2, buf, 18);
}

static void print_num(long long val) {
    char buf[32];
    int pos = 30;
    buf[31] = '\0';
    int neg = 0;
    if (val < 0) { neg = 1; val = -val; }
    if (val == 0) {
        buf[pos--] = '0';
    } else {
        while (val > 0) {
            buf[pos--] = '0' + (val % 10);
            val /= 10;
        }
    }
    if (neg) buf[pos--] = '-';
    write(2, &buf[pos + 1], 30 - pos);
}

static void print_backtrace(void) {
    void* frames[64];
    int n = backtrace(frames, 64);
    for (int i = 0; i < n; i++) {
        write_str("  [frame ");
        print_num(i);
        write_str("]: ");
        print_hex((unsigned long long)frames[i]);
        write_str("\n");
    }
    backtrace_symbols_fd(frames, n, 2);
}

// Trace the exact resolver requests made by Roblox. A plain getaddrinfo probe
// succeeds in Darling while Roblox reports DnsResolve, so the hints passed by
// its networking layer are relevant to the failure.
struct quinta_addrinfo_head {
    int ai_flags;
    int ai_family;
    int ai_socktype;
    int ai_protocol;
};
//
// Preserve Darling's getaddrinfo validation and addrinfo allocation, but use
// a caller-owned BIND state for its imported res_9_query transport. The legacy
// query uses global _res storage; merely removing the old lookup lock races
// query IDs, sockets and buffers. Reentrant APIs let independent lookups run
// concurrently. A custom runtime without them keeps the protected fallback.
// Temporary EAI_AGAIN/EAI_FAIL/EAI_SYSTEM errors still get four attempts with
// direct Linux sleeps 50 ms apart; permanent errors are never retried.
extern int getaddrinfo(const char*, const char*, const void*, void**);
extern int res_9_query(const char*, int, int, unsigned char*, int);
extern int *__error(void);
extern void quinta_sleep_us(unsigned int);
extern int quinta_dns_resolve(const char* node, const char* service,
                                const void* hints, void** result);
static const struct quinta_resolver_api *quinta_resolver_functions(void) {
    static struct quinta_resolver_api api;
    static volatile unsigned int ready, initialization_lock;
    if (!__atomic_load_n(&ready, __ATOMIC_ACQUIRE)) {
        quinta_lock(&initialization_lock);
        if (!ready) {
            api.initialize = (int (*)(void*))dlsym(RTLD_NEXT, "res_9_ninit");
            api.query = (int (*)(void*, const char*, int, int, unsigned char*, int))
                dlsym(RTLD_NEXT, "res_9_nquery");
            api.destroy = (void (*)(void*))dlsym(RTLD_NEXT, "res_9_ndestroy");
            __atomic_store_n(&ready, 1, __ATOMIC_RELEASE);
        }
        quinta_unlock(&initialization_lock);
    }
    return &api;
}
static int quinta_res_9_query(const char *name, int dns_class, int type,
                               unsigned char *answer, int capacity) {
    quinta_query_function original = QUINTA_NEXT(quinta_query_function, "res_9_query");
    return quinta_query_in_scope(original, name, dns_class, type, answer, capacity);
}
DYLD_INTERPOSE(quinta_res_9_query, res_9_query)
// Milliseconds on the Linux CLOCK_MONOTONIC, like quinta_sleep_us: the
// resolver work and its lock waits are what a startup stall is made of.
struct quinta_timespec { long sec; long nsec; };
static long quinta_millis(void) {
    struct quinta_timespec now = {0, 0};
    long result;
    __asm__ volatile("syscall"
                     : "=a"(result)
                     : "a"(228L /* Linux clock_gettime */), "D"(1L /* MONOTONIC */), "S"(&now)
                     : "rcx", "r11", "memory");
    (void)result;
    return now.sec * 1000 + now.nsec / 1000000;
}
// One line per lookup. Emitted for every failed lookup and for any lookup
// slower than 200 ms. waited_ms is zero on the concurrent private-state path;
// it remains useful when an older runtime needs the serialized fallback.
static void quinta_dns_trace(const char* node, const char* service,
                               const void* hints, int attempts, int status,
                               long waited_ms, long took_ms) {
    write_str("[Quinta DNS] node=");
    write_str(node ? node : "(null)");
    write_str(" service=");
    write_str(service ? service : "(null)");
    if (hints) {
        const struct quinta_addrinfo_head* head =
            (const struct quinta_addrinfo_head*)hints;
        write_str(" flags="); print_num(head->ai_flags);
        write_str(" family="); print_num(head->ai_family);
        write_str(" socktype="); print_num(head->ai_socktype);
        write_str(" protocol="); print_num(head->ai_protocol);
    } else {
        write_str(" hints=(null)");
    }
    write_str(" attempts="); print_num(attempts);
    write_str(" result="); print_num(status);
    write_str(" waited_ms="); print_num(waited_ms);
    write_str(" took_ms="); print_num(took_ms);
    write_str("\n");
}
static int ascii_strings_equal(const char* left, const char* right);
static int quinta_getaddrinfo(const char* node, const char* service,
                                const void* hints, void** result) {
    // Preserve the existing optional-telemetry hostname policy. Regional
    // beacon timeouts were observed, but an isolated redirect comparison
    // did not eliminate the remaining leave-game rendering pause.
    if (quinta_is_blocked_telemetry(node)) {
        if (result)
            *result = 0;
        return 8; /* EAI_NONAME */
    }
    long started = quinta_millis();
    // DNS chosen in the launcher, for Roblox only (dns_override.c).
    int own = quinta_dns_resolve(node, service, hints, result);
    if (own >= 0) {
        long took = quinta_millis() - started;
        if (took > 200)
            quinta_dns_trace(node, service, hints, 0, own, 0, took);
        return own;
    }
    int (*real_getaddrinfo)(const char*, const char*, const void*, void**) =
        QUINTA_NEXT(int (*)(const char*, const char*, const void*, void**), "getaddrinfo");

    int attempts = 0;
    long waited_ms = 0;
    int status = quinta_retry_addrinfo(real_getaddrinfo, quinta_resolver_functions(),
        node, service, hints, result, __error(), quinta_millis, quinta_sleep_us,
        &attempts, &waited_ms);

    long took = quinta_millis() - started;
    static volatile int trace = -1;
    if (status != 0 || waited_ms > 200 || took > 200 ||
        quinta_env_cached("QUINTA_TRACE_DNS", &trace)) {
        quinta_dns_trace(node, service, hints, attempts, status, waited_ms, took);
    }
    return status;
}
DYLD_INTERPOSE(quinta_getaddrinfo, getaddrinfo)

// Interposed functions
extern void exit(int);
extern void _exit(int);
extern void _Exit(int);
extern void abort(void);
extern void __cxa_throw(void*, void*, void(*)(void*));
extern void _ZSt9terminatev(void);
extern void objc_exception_throw(id);
extern int NSApplicationMain(int argc, const char *argv[]);

// The exception hooks run for every throw and every unwinding step (Lua
// errors in game scripts are C++ exceptions), so the switch and the real
// functions are looked up once, not with getenv and dlsym every time.
static int trace_exceptions_enabled(void) {
    static volatile int enabled = -1;
    return quinta_env_cached("QUINTA_TRACE_EXCEPTIONS", &enabled);
}

void my_cxa_throw(void* thrown_exception, void* tinfo, void (*dest)(void*)) {
    void (*real_throw)(void*, void*, void(*)(void*)) =
        QUINTA_NEXT(void (*)(void*, void*, void(*)(void*)), "__cxa_throw");
    if (!trace_exceptions_enabled()) {
        if (real_throw) real_throw(thrown_exception, tinfo, dest);
        while (1);
    }
    write_str("\n[Quinta Hook] ========================================\n");
    write_str("[Quinta Hook] __cxa_throw called!\n");
    if (tinfo) {
        const char* mangled = ((const char**)tinfo)[1];
        if (mangled) {
            write_str("[Quinta Hook] Mangled type: ");
            write_str(mangled);
            write_str("\n");
            typedef char* (*demangle_fn)(const char*, char*, unsigned long*, int*);
            demangle_fn demangle = (demangle_fn)dlsym(RTLD_DEFAULT, "__cxa_demangle");
            if (demangle) {
                int status = 0;
                char* demangled = demangle(mangled, 0, 0, &status);
                if (demangled) {
                    write_str("[Quinta Hook] Demangled type: ");
                    write_str(demangled);
                    write_str("\n");
                }
            }
        }
    }
    // C++ can throw scalars and arbitrary classes, not just std::exception.
    // Never interpret an unknown exception object as a vtable or call through it.
    write_str("[Quinta Hook] Backtrace:\n");
    print_backtrace();
    write_str("[Quinta Hook] ========================================\n\n");
    if (real_throw)
        real_throw(thrown_exception, tinfo, dest);
    while (1);
}
DYLD_INTERPOSE(my_cxa_throw, __cxa_throw);

void my_objc_exception_throw(id exception) {
    void (*real_throw)(id) = QUINTA_NEXT(void (*)(id), "objc_exception_throw");
    if (!trace_exceptions_enabled()) {
        if (real_throw) real_throw(exception);
        while (1);
    }
    write_str("\n[Quinta Hook] ========================================\n");
    write_str("[Quinta Hook] objc_exception_throw called!\n");
    if (exception) {
        write_str("[Quinta Hook] Exception class: ");
        write_str(object_getClassName(exception));
        write_str("\n");
        id reason = ((id (*)(id, SEL))objc_msgSend)(exception, sel_registerName("reason"));
        if (reason) {
            write_str("[Quinta Hook] Exception reason: ");
            write_str(((const char* (*)(id, SEL))objc_msgSend)(reason, sel_registerName("UTF8String")));
            write_str("\n");
        }
    }
    write_str("[Quinta Hook] Backtrace:\n");
    print_backtrace();
    write_str("[Quinta Hook] ========================================\n\n");
    if (real_throw)
        real_throw(exception);
    while (1);
}
DYLD_INTERPOSE(my_objc_exception_throw, objc_exception_throw);

// Interpose _Unwind_Resume, __throw_system_error, __cxa_rethrow
extern void _Unwind_Resume(void*);
void my_Unwind_Resume(void* exc) {
    void (*real_fn)(void*) = QUINTA_NEXT(void (*)(void*), "_Unwind_Resume");
    if (!trace_exceptions_enabled()) {
        if (real_fn) real_fn(exc);
        while (1);
    }
    write_str("\n[Quinta Hook] ========================================\n");
    write_str("[Quinta Hook] _Unwind_Resume called! exc: ");
    print_hex((unsigned long long)exc);
    write_str("\nBacktrace:\n");
    print_backtrace();
    write_str("[Quinta Hook] ========================================\n\n");
    if (real_fn) real_fn(exc);
    while (1);
}
DYLD_INTERPOSE(my_Unwind_Resume, _Unwind_Resume);

extern void _ZNSt3__120__throw_system_errorEiPKc(int, const char*);
void my_throw_system_error(int err, const char* msg) {
    void (*real_fn)(int, const char*) =
        QUINTA_NEXT(void (*)(int, const char*), "_ZNSt3__120__throw_system_errorEiPKc");
    if (!trace_exceptions_enabled()) {
        if (real_fn) real_fn(err, msg);
        while (1);
    }
    write_str("\n[Quinta Hook] ========================================\n");
    write_str("[Quinta Hook] std::__throw_system_error called! err: ");
    print_num(err);
    write_str(", msg: ");
    write_str(msg ? msg : "(null)");
    write_str("\nBacktrace:\n");
    print_backtrace();
    write_str("[Quinta Hook] ========================================\n\n");
    if (real_fn) real_fn(err, msg);
    while (1);
}
DYLD_INTERPOSE(my_throw_system_error, _ZNSt3__120__throw_system_errorEiPKc);

extern void __cxa_rethrow(void);
void my_cxa_rethrow(void) {
    void (*real_fn)(void) = QUINTA_NEXT(void (*)(void), "__cxa_rethrow");
    if (!trace_exceptions_enabled()) {
        if (real_fn) real_fn();
        while (1);
    }
    write_str("\n[Quinta Hook] ========================================\n");
    write_str("[Quinta Hook] __cxa_rethrow called!\nBacktrace:\n");
    print_backtrace();
    write_str("[Quinta Hook] ========================================\n\n");
    if (real_fn) real_fn();
    while (1);
}
DYLD_INTERPOSE(my_cxa_rethrow, __cxa_rethrow);

static id quinta_pending_uri(void);
static int ascii_strings_equal(const char* left, const char* right);
static volatile int quinta_protocol_string_present;
static volatile int quinta_pending_uri_injection_logged;

static int quinta_has_protocol_string(int argc, const char *argv[]) {
    if (!argv)
        return 0;
    for (int index = 0; index < argc; index++) {
        if (argv[index] && ascii_strings_equal(argv[index], "-protocolString"))
            return 1;
    }
    return 0;
}

static void quinta_log_startup_argv(int argc, const char *argv[]) {
    write_str("[Quinta Argv] argc=");
    print_num(argc);
    write_str("\n");
    for (int index = 0; index < argc; index++) {
        write_str("[Quinta Argv] argv[");
        print_num(index);
        write_str("]=");
        write_str(argv && argv[index] ? argv[index] : "(null)");
        write_str("\n");
    }
    quinta_protocol_string_present = quinta_has_protocol_string(argc, argv);
    const char* pending = getenv("QUINTA_PENDING_URI");
    write_str("[Quinta URL] Startup sources: -protocolString=");
    print_num(quinta_protocol_string_present != 0);
    write_str(" QUINTA_PENDING_URI=");
    print_num(pending && pending[0] ? 1 : 0);
    write_str("\n");
    if (quinta_protocol_string_present && pending && pending[0])
        write_str("[Quinta URL] Both protocolString and pending URI are present; protocolString wins\n");
}

int my_NSApplicationMain(int argc, const char *argv[]) {
    write_str("\n[Quinta Hook] NSApplicationMain entered!\n");
    quinta_log_startup_argv(argc, argv);
    if (quinta_protocol_string_present) {
        write_str("[Quinta URL] Pending URI injection: disabled (native -protocolString present)\n");
    } else {
        write_str("[Quinta URL] Pending URI injection: enabled (no -protocolString)\n");
        // Capture the process-bound copy before the launcher can clear its
        // host-side pending file. The value remains opaque until it is turned
        // into the Cocoa URL object at delivery time.
        (void)quinta_pending_uri();
    }

    void* (*open_display)(const char*) = (void* (*)(const char*))dlsym(RTLD_DEFAULT, "XOpenDisplay");
    int (*close_display)(void*) = (int (*)(void*))dlsym(RTLD_DEFAULT, "XCloseDisplay");
    if (open_display && !quinta_wayland_enabled()) {
        void* test_dpy = open_display(0);
        if (!test_dpy) {
            write_str("[Quinta] FATAL: Cannot connect to X11 display! XOpenDisplay returned NULL.\n");
            write_str("[Quinta] Make sure an X server or Xwayland is running.\n");
            extern void quinta_immediate_exit(int);
            quinta_immediate_exit(1);
        } else if (close_display) {
            close_display(test_dpy);
        }
    }
    int (*real_main)(int, const char*[]) = (int (*)(int, const char*[]))dlsym(RTLD_NEXT, "NSApplicationMain");
    int res = real_main ? real_main(argc, argv) : 0;
    write_str("\n[Quinta Hook] NSApplicationMain returned: ");
    print_num(res);
    write_str("\n[Quinta Hook] Backtrace:\n");
    print_backtrace();
    return res;
}
DYLD_INTERPOSE(my_NSApplicationMain, NSApplicationMain);

// Signal crash handler
struct darwin_sigaction {
    void (*sa_sigaction)(int, void*, void*);
    unsigned int sa_mask;
    int sa_flags;
};
extern int sigaction(int, const struct darwin_sigaction*, struct darwin_sigaction*);

static int quinta_crash_diagnostics_enabled(void) {
    static volatile int enabled = -1;
    int value = __atomic_load_n(&enabled, __ATOMIC_RELAXED);
    if (value < 0) {
        const char* setting = getenv("QUINTA_DIAGNOSTIC_SIGNALS");
        value = setting && setting[0] == '1' && !setting[1];
        __atomic_store_n(&enabled, value, __ATOMIC_RELAXED);
    }
    return value;
}

static int quinta_diagnostic_fatal_signal(int sig) {
    // Darwin signal numbers, not the Linux host's numbering.
    return sig == 4 || sig == 5 || sig == 6 || sig == 10 || sig == 11;
}

static void crash_handler(int sig, void* info, void* uap) {
    static volatile int reporting;
    // A second fault must not recurse through the diagnostic writer.
    if (__atomic_exchange_n(&reporting, 1, __ATOMIC_RELAXED))
        _exit(128 + sig);
    write_str("\n\n[Quinta FATAL CRASH] ****************************************\n");
    write_str("[Quinta FATAL CRASH] Signal received: ");
    print_num(sig);
    write_str("\n");
    if (info) {
        write_str("[Quinta FATAL CRASH] siginfo: ");
        print_hex((unsigned long long)info);
        // Darwin siginfo_t: si_code at byte 8, si_pid at 12, si_addr at 24.
        const unsigned char* si = (const unsigned char*)info;
        write_str("\n  si_code: ");
        print_num(*(const int*)(si + 8));
        write_str("\n  si_pid: ");
        print_num(*(const int*)(si + 12));
        write_str("\n  si_addr: ");
        print_hex(*(const unsigned long long*)(si + 24));
        write_str("\n");
    }
    if (uap) {
        write_str("[Quinta FATAL CRASH] ucontext: ");
        print_hex((unsigned long long)uap);
        write_str("\n");
        unsigned long long* p = (unsigned long long*)uap;
        write_str("  uc_mcontext ptr: ");
        print_hex(p[6]);
        write_str("\n");
        const unsigned long long* mc = (const unsigned long long*)p[6];
        // Darwin x86_64 exception state plus registers through RFLAGS.
        // Do not read a missing or shorter architecture context.
        if (mc && p[5] >= 20 * sizeof(*mc)) {
            write_str("  RAX: "); print_hex(mc[2]); write_str("\n");
            write_str("  RBX: "); print_hex(mc[3]); write_str("\n");
            write_str("  RCX: "); print_hex(mc[4]); write_str("\n");
            write_str("  RDX: "); print_hex(mc[5]); write_str("\n");
            write_str("  RDI: "); print_hex(mc[6]); write_str("\n");
            write_str("  RSI: "); print_hex(mc[7]); write_str("\n");
            write_str("  RBP: "); print_hex(mc[8]); write_str("\n");
            write_str("  RSP: "); print_hex(mc[9]); write_str("\n");
            write_str("  RIP: "); print_hex(mc[18]); write_str("\n");
            write_str("  RFLAGS: "); print_hex(mc[19]); write_str("\n");
            // Exception state before the registers: trap number, error code
            // and the faulting address.
            write_str("  trap: "); print_num(mc[0] & 0xffff);
            write_str(" err: "); print_hex(mc[0] >> 32);
            write_str(" exception address: "); print_hex(mc[1]); write_str("\n");

            // Keep signal-time diagnosis to kernel-provided registers. Walking
            // arbitrary stack memory can fault again; dladdr and pthread APIs
            // can deadlock on locks held by the interrupted thread. Opt-in
            // (QUINTA_TRACE_CRASH_SYMBOLS=1) for porting work, where a missing
            // symbol name costs more than a rare hang of an already dead process.
            static volatile int symbols = -1;
            if (quinta_env_cached("QUINTA_TRACE_CRASH_SYMBOLS", &symbols)) {
                struct { const char* fname; void* fbase; const char* sname; void* saddr; } info;
                extern int dladdr(const void*, void*);
                unsigned long long frames[12]; int count = 0;
                frames[count++] = mc[18];
                // A leaf such as objc_msgSend has no frame; its caller's return
                // address is on top of the stack.
                if (mc[9] > 0x10000 && (mc[9] & 7) == 0) frames[count++] = *(unsigned long long*)mc[9];
                unsigned long long* frame = (unsigned long long*)mc[8];
                while (count < 12 && frame && ((unsigned long long)frame & 7) == 0 &&
                       (unsigned long long)frame > 0x10000 && frame[1] > 0x1000) {
                    frames[count++] = frame[1];
                    unsigned long long* next = (unsigned long long*)frame[0];
                    if (next <= frame) break;
                    frame = next;
                }
                for (int i = 0; i < count; i++) {
                    write_str("  #"); print_num(i); write_str(" "); print_hex(frames[i]);
                    if (dladdr((void*)frames[i], &info)) {
                        write_str(" "); write_str(info.fname ? info.fname : "?");
                        write_str(" "); write_str(info.sname ? info.sname : "?");
                        write_str("+"); print_hex(frames[i] - (unsigned long long)info.saddr);
                    }
                    write_str("\n");
                }
            }
        } else {
            write_str("  register context unavailable or too short\n");
        }
    }
    write_str("[Quinta FATAL CRASH] ****************************************\n\n");
    _exit(128 + sig);
}

int my_sigaction(int sig, const struct darwin_sigaction *act, struct darwin_sigaction *oact) {
    write_str("[Quinta Hook] sigaction called for sig: ");
    print_num(sig);
    write_str(", new handler: ");
    print_hex(act ? (unsigned long long)act->sa_sigaction : 0);
    write_str("\n");
    int (*real_sigaction)(int, const void*, void*) =
        QUINTA_NEXT(int (*)(int, const void*, void*), "sigaction");
    // Opt-in crash diagnosis only: preserve the application's handlers normally.
    if (quinta_crash_diagnostics_enabled() && quinta_diagnostic_fatal_signal(sig) && act && real_sigaction) {
        struct darwin_sigaction debug_action = {crash_handler, 0, 0x0040};
        return real_sigaction(sig, &debug_action, oact);
    }
    return real_sigaction ? real_sigaction(sig, act, oact) : 0;
}
DYLD_INTERPOSE(my_sigaction, sigaction);

// Swizzle NSConcreteScanner
static id (*orig_concrete_initWithString)(id self, SEL _cmd, id str) = 0;
static id hooked_concrete_initWithString(id self, SEL _cmd, id str) {
    if (!str) {
        write_str("\n[Quinta Hook] -[NSConcreteScanner initWithString:nil] called!\n");
    }
    return orig_concrete_initWithString(self, _cmd, str);
}

// Swizzle NSApplication run
static void (*orig_app_run)(id self, SEL _cmd) = 0;
static void quinta_queue_pending_uri(id app);
static void hooked_app_run(id self, SEL _cmd) {
    write_str("\n[Quinta Hook] -[NSApplication run] entered!\n");
    // If Darling does not call finishLaunching through the swizzled entry
    // point, the main-queue turn below still runs after AppKit has started its
    // event loop and the delegate has been installed.
    quinta_queue_pending_uri(self);
    orig_app_run(self, _cmd);
    write_str("\n[Quinta Hook] -[NSApplication run] returned!\n");
}

static int ascii_strings_equal(const char* left, const char* right) {
    if (!left || !right)
        return 0;
    while (*left && *right && *left == *right) {
        left++;
        right++;
    }
    return *left == 0 && *right == 0;
}

static void (*orig_app_finish_launching)(id self, SEL cmd) = 0;

// Browser protocol handoff -------------------------------------------------
//
// A direct executable launch has no LaunchServices/Apple Event envelope.  The
// launcher therefore passes the original opaque browser value in
// QUINTA_PENDING_URI and leaves the pending-uri file path available as a
// fallback.  Once AppKit has finished launching, deliver it through the
// delegate's normal Cocoa URL entry point.  No URI fields are inspected or
// rebuilt here.
extern QuintaFILE* fopen(const char*, const char*);
extern unsigned long fread(void*, unsigned long, unsigned long, QuintaFILE*);
extern int fclose(QuintaFILE*);
extern void dispatch_async(void*, void (^)(void));
extern unsigned long long dispatch_time(unsigned long long, long long);
extern void dispatch_after(unsigned long long, void*, void (^)(void));
extern struct dispatch_queue_s _dispatch_main_q;

static id quinta_captured_delegate;
static volatile int quinta_pending_uri_checked;
static volatile int quinta_pending_uri_delivered;
static id quinta_pending_uri_string;

static unsigned long quinta_fourcc(char a, char b, char c, char d) {
    return ((unsigned long)(unsigned char)a << 24) |
           ((unsigned long)(unsigned char)b << 16) |
           ((unsigned long)(unsigned char)c << 8) |
           (unsigned long)(unsigned char)d;
}

static id quinta_ns_string_from_bytes(const char* bytes, unsigned long length) {
    if (!bytes || !length)
        return 0;
    char* copy = (char*)malloc(length + 1);
    if (!copy)
        return 0;
    for (unsigned long index = 0; index < length; index++)
        copy[index] = bytes[index];
    copy[length] = 0;
    id string_class = (id)objc_getClass("NSString");
    id value = string_class
        ? ((id (*)(id, SEL, const char*))objc_msgSend)(
              string_class, sel_registerName("stringWithUTF8String:"), copy)
        : 0;
    free(copy);
    if (value)
        value = ((id (*)(id, SEL))objc_msgSend)(value, sel_registerName("retain"));
    return value;
}

static id quinta_pending_uri(void) {
    if (quinta_pending_uri_checked)
        return quinta_pending_uri_string;
    quinta_pending_uri_checked = 1;

    const char* value = getenv("QUINTA_PENDING_URI");
    unsigned long length = value ? quinta_cstr_length(value) : 0;
    if (value && length)
        quinta_pending_uri_string = quinta_ns_string_from_bytes(value, length);

    // A launch without the command-line copy can still consume the pending
    // file.  It is read through SystemRoot because Darling's /tmp and home are
    // private while the launcher cache is on the host filesystem.
    if (!quinta_pending_uri_string) {
        const char* path = getenv("QUINTA_PENDING_URI_FILE");
        QuintaFILE* file = path && path[0] ? fopen(path, "rb") : 0;
        if (file) {
            unsigned long capacity = 64 * 1024;
            char* bytes = (char*)malloc(capacity);
            unsigned long count = bytes ? fread(bytes, 1, capacity, file) : 0;
            fclose(file);
            if (count)
                quinta_pending_uri_string = quinta_ns_string_from_bytes(bytes, count);
            free(bytes);
        }
    }

    if (quinta_pending_uri_string) {
        write_str("[Quinta URL] Pending URI detected\n");
    }
    return quinta_pending_uri_string;
}

static signed char quinta_log_uri_selector(id delegate, const char* name) {
    SEL selector = sel_registerName(name);
    Class delegate_class = object_getClass(delegate);
    Method method = delegate_class ? class_getInstanceMethod(delegate_class, selector) : 0;
    signed char responds = ((signed char (*)(id, SEL, SEL))objc_msgSend)(
        delegate, sel_registerName("respondsToSelector:"), selector);
    write_str("[Quinta URL] Selector ");
    write_str(name);
    write_str(" responds=");
    print_num(responds != 0);
    write_str(" encoding=");
    const char* encoding = method ? method_getTypeEncoding(method) : 0;
    write_str(encoding ? encoding : "(unavailable)");
    if (ascii_strings_equal(name, "application:openURLs:")) {
        write_str(" expected=v32@0:8@16@24 matches=");
        print_num(ascii_strings_equal(encoding, "v32@0:8@16@24"));
    }
    write_str("\n");
    return responds;
}

static unsigned long quinta_uri_delay_ms(void) {
    const char* value = getenv("QUINTA_URI_DELAY_MS");
    if (!value || !value[0])
        return 0;
    unsigned long delay = 0;
    for (const char* digit = value; *digit; digit++) {
        if (*digit < '0' || *digit > '9' || delay > 1000) {
            write_str("[Quinta URL] Invalid delay; using 0 ms\n");
            return 0;
        }
        delay = delay * 10 + (unsigned long)(*digit - '0');
    }
    if (delay > 10000) {
        write_str("[Quinta URL] Delay exceeds 10000 ms; using 0 ms\n");
        return 0;
    }
    return delay;
}

static id quinta_make_url_event(id url_string) {
    Class descriptor_class = objc_getClass("NSAppleEventDescriptor");
    if (!descriptor_class)
        return 0;
    SEL descriptor_with_string = sel_registerName("descriptorWithString:");
    SEL apple_event = sel_registerName(
        "appleEventWithEventClass:eventID:targetDescriptor:returnID:transactionID:");
    if (!class_getClassMethod(descriptor_class, descriptor_with_string) ||
        !class_getClassMethod(descriptor_class, apple_event))
        return 0;
    id url_descriptor = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)descriptor_class, descriptor_with_string, url_string);
    id event = ((id (*)(id, SEL, unsigned long, unsigned long, id, short, long))objc_msgSend)(
        (id)descriptor_class, apple_event,
        quinta_fourcc('G', 'U', 'R', 'L'), // kInternetEventClass
        quinta_fourcc('G', 'U', 'R', 'L'), // kAEGetURL
        0, -1, 0);                            // auto return ID, any transaction
    SEL set_parameter = sel_registerName("setParamDescriptor:forKeyword:");
    if (!event || !url_descriptor || !class_getInstanceMethod(descriptor_class, set_parameter))
        return 0;
    ((void (*)(id, SEL, id, unsigned long))objc_msgSend)(
        event, set_parameter, url_descriptor, quinta_fourcc('-', '-', '-', '-'));
    return event;
}

static void quinta_deliver_pending_uri(id app) {
    if (quinta_protocol_string_present) {
        if (!quinta_pending_uri_injection_logged) {
            quinta_pending_uri_injection_logged = 1;
            write_str("[Quinta URL] Pending URI injection skipped; -protocolString already supplied the URI\n");
        }
        return;
    }
    if (quinta_pending_uri_delivered)
        return;
    id value = quinta_pending_uri();
    if (!value)
        return;
    id delegate = quinta_captured_delegate;
    if (!delegate && app)
        delegate = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("delegate"));
    if (!delegate) {
        write_str("[Quinta URL] Delegate not available yet\n");
        return;
    }
    quinta_captured_delegate = delegate;
    write_str("[Quinta URL] Delegate: ");
    write_str(object_getClassName(delegate));
    write_str("\n");

    const char* open_urls_name = "application:openURLs:";
    const char* open_file_name = "application:openFile:";
    const char* handle_get_url_name = "application:handleGetURLEvent:withReplyEvent:";
    signed char has_open_urls = quinta_log_uri_selector(delegate, open_urls_name);
    signed char has_open_file = quinta_log_uri_selector(delegate, open_file_name);
    signed char has_get_url = quinta_log_uri_selector(delegate, handle_get_url_name);
    id url = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)objc_getClass("NSURL"), sel_registerName("URLWithString:"), value);
    if (!url) {
        write_str("[Quinta URL] NSURL rejected the pending URI; trying legacy handlers\n");
    } else {
        id absolute = ((id (*)(id, SEL))objc_msgSend)(url, sel_registerName("absoluteString"));
        signed char unchanged = absolute && ((signed char (*)(id, SEL, id))objc_msgSend)(
            absolute, sel_registerName("isEqualToString:"), value);
        write_str("[Quinta URL] NSURL absoluteString matches pending=");
        print_num(unchanged != 0);
        write_str("\n");
    }

    const char* order = getenv("QUINTA_URI_SELECTOR_ORDER");
    int apple_first = ascii_strings_equal(order, "B");
    write_str(apple_first ? "[Quinta URL] Selector order=B\n" :
                            "[Quinta URL] Selector order=A\n");
    for (int choice = 0; choice < 3; choice++) {
        int kind = apple_first ? (choice == 0 ? 2 : choice == 1 ? 0 : 1) : choice;
        if (kind == 0 && url && has_open_urls) {
        SEL open_urls = sel_registerName(open_urls_name);
        id urls = ((id (*)(id, SEL, const id*, unsigned long))objc_msgSend)(
            (id)objc_getClass("NSArray"), sel_registerName("arrayWithObjects:count:"), &url, 1);
        if (!urls) {
            write_str("[Quinta URL] Delivered failed\n");
            return;
        }
        write_str("[Quinta URL] Using: application:openURLs:\n");
        write_str("[Quinta URL] Before application:openURLs:\n");
        @try {
            // -[RobloxPlayerAppDelegate application:openURLs:] is void with
            // NSApplication* and NSArray<NSURL*>* object arguments.
            ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, open_urls, app, urls);
            write_str("[Quinta URL] After application:openURLs:\n");
            quinta_pending_uri_delivered = 1;
            write_str("[Quinta URL] Delivered successfully\n");
        } @catch (id exception) {
            (void)exception;
            write_str("[Quinta URL] Delivered failed\n");
        }
        return;
        }

        if (kind == 1 && has_open_file) {
        SEL open_file = sel_registerName(open_file_name);
        write_str("[Quinta URL] Using: application:openFile:\n");
        signed char accepted = 0;
        write_str("[Quinta URL] Before application:openFile:\n");
        @try {
            accepted = ((signed char (*)(id, SEL, id, id))objc_msgSend)(delegate, open_file, app, value);
            write_str("[Quinta URL] After application:openFile: accepted=");
            print_num(accepted != 0);
            write_str("\n");
        } @catch (id exception) {
            (void)exception;
            write_str("[Quinta URL] Delivered failed\n");
            return;
        }
        if (accepted) {
            quinta_pending_uri_delivered = 1;
            write_str("[Quinta URL] Delivered successfully\n");
        } else {
            write_str("[Quinta URL] Delivered failed\n");
        }
        return;
        }

        if (kind == 2 && has_get_url) {
        SEL handle_get_url = sel_registerName(handle_get_url_name);
        write_str("[Quinta URL] Using: application:handleGetURLEvent:withReplyEvent:\n");
        id event = quinta_make_url_event(value);
        if (!event) {
            write_str("[Quinta URL] Delivered failed\n");
            return;
        }
        write_str("[Quinta URL] Before application:handleGetURLEvent:withReplyEvent:\n");
        @try {
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(delegate, handle_get_url, app, event, 0);
            write_str("[Quinta URL] After application:handleGetURLEvent:withReplyEvent:\n");
            quinta_pending_uri_delivered = 1;
            write_str("[Quinta URL] Delivered successfully\n");
        } @catch (id exception) {
            (void)exception;
            write_str("[Quinta URL] Delivered failed\n");
        }
        return;
        }
    }

    write_str("[Quinta URL] Delivered failed\n");
}

static void quinta_queue_pending_uri(id app) {
    if (quinta_protocol_string_present) {
        if (!quinta_pending_uri_injection_logged) {
            quinta_pending_uri_injection_logged = 1;
            write_str("[Quinta URL] Pending URI injection skipped; -protocolString already supplied the URI\n");
        }
        return;
    }
    if (!quinta_pending_uri())
        return;
    write_str("[Quinta URL] Pending URI injection running\n");
    unsigned long delay_ms = quinta_uri_delay_ms();
    write_str("[Quinta URL] Queued delivery after ");
    print_num(delay_ms);
    write_str(" ms\n");
    if (delay_ms) {
        dispatch_after(dispatch_time(0, (long long)delay_ms * 1000000LL),
                       &_dispatch_main_q, ^{ quinta_deliver_pending_uri(app); });
    } else {
        dispatch_async(&_dispatch_main_q, ^{ quinta_deliver_pending_uri(app); });
    }
}

// Window icon: QUINTA_ICON_ARGB names a file of 32-bit little-endian words
// in _NET_WM_ICON layout (width, height, ARGB pixels, repeated per size),
// written by the launcher. It is set on the Roblox X window from a separate
// X connection, so docks and window switchers show the Mac O Blox logo.
extern void* malloc(unsigned long);
extern void free(void*);
static unsigned long quinta_icon_window;
static void* quinta_set_window_icon_thread(void* unused) {
    (void)unused;
    const char* path = getenv("QUINTA_ICON_ARGB");
    QuintaFILE* file = path ? fopen(path, "rb") : 0;
    if (!file)
        return 0;
    extern unsigned long fread(void*, unsigned long, unsigned long, QuintaFILE*);
    unsigned int* words = (unsigned int*)malloc(1 << 22);
    unsigned long count = words ? fread(words, 4, (1 << 22) / 4, file) : 0;
    fclose(file);
    if (!count) {
        free(words);
        return 0;
    }
    // Xlib passes format-32 property data as C longs.
    unsigned long* longs = (unsigned long*)malloc(count * sizeof(unsigned long));
    for (unsigned long index = 0; index < count && longs; index++)
        longs[index] = words[index];
    free(words);
    void* (*open_display)(const char*) = (void* (*)(const char*))dlsym(RTLD_DEFAULT, "XOpenDisplay");
    unsigned long (*intern)(void*, const char*, int) =
        (unsigned long (*)(void*, const char*, int))dlsym(RTLD_DEFAULT, "XInternAtom");
    int (*change)(void*, unsigned long, unsigned long, unsigned long, int, int, const void*, int) =
        (int (*)(void*, unsigned long, unsigned long, unsigned long, int, int, const void*, int))
            dlsym(RTLD_DEFAULT, "XChangeProperty");
    int (*close_display)(void*) = (int (*)(void*))dlsym(RTLD_DEFAULT, "XCloseDisplay");
    int (*sync)(void*, int) = (int (*)(void*, int))dlsym(RTLD_DEFAULT, "XSync");
    void* display = open_display && longs ? open_display(0) : 0;
    if (display && intern && change) {
        unsigned long atom = intern(display, "_NET_WM_ICON", 0);
        change(display, quinta_icon_window, atom, 6 /* XA_CARDINAL */, 32,
               0 /* PropModeReplace */, longs, (int)count);
        if (sync)
            sync(display, 0);
        write_str("[Quinta] Window icon set\n");
    }
    if (display && close_display)
        close_display(display);
    free(longs);
    return 0;
}

static unsigned long quinta_native_window_handle(id window) {
    /* NSWindow/RBXWindow is the Cocoa object. Only its platformWindow has
     * Darling's X11 windowHandle; sending it to RBXWindow raises an exception
     * on every attempted camera lock, before the lock can become active. */
    SEL responds = sel_registerName("respondsToSelector:");
    SEL native = sel_registerName("platformWindow");
    if (!window || !((signed char (*)(id, SEL, SEL))objc_msgSend)(window, responds, native))
        return 0;
    id platform = ((id (*)(id, SEL))objc_msgSend)(window, native);
    if (!platform || !((signed char (*)(id, SEL, SEL))objc_msgSend)(
                         platform, responds,
                         sel_registerName("windowHandle")))
        return 0;
    return ((unsigned long (*)(id, SEL))objc_msgSend)(
        platform, sel_registerName("windowHandle"));
}

static void quinta_set_window_icon(id window) {
    if (quinta_wayland_enabled())
        return;
    if (!getenv("QUINTA_ICON_ARGB") || quinta_icon_window)
        return;
    quinta_icon_window = quinta_native_window_handle(window);
    if (!quinta_icon_window)
        return;
    extern int pthread_create(void**, const void*, void* (*)(void*), void*);
    extern int pthread_detach(void*);
    void* thread;
    if (pthread_create(&thread, 0, quinta_set_window_icon_thread, 0) == 0)
        pthread_detach(thread);
}

// Darling draws the macOS menu bar (Roblox, Edit, Window...) inside each
// window. With QUINTA_HIDE_MENU_BAR=1 its height is 0: cocotron uses
// +[NSMainMenuView menuHeight] for the bar itself and for converting between
// window frame and content rect, so the game fills the whole window, also
// after Roblox rebuilds its menu (which re-showed a strip after sign-in).
static double quinta_zero_menu_height(id cls, SEL cmd) {
    (void)cls; (void)cmd;
    return 0.0;
}

// Secure-coding convenience methods (macOS 10.13) missing in Darling.
// Roblox archives some state with them after sign-in and unarchives it at
// the next start, which crashed. Map them to the older keyed archiver API;
// unreadable data or an object of the wrong class gives nil, not a crash.
static id keyed_archiver_archived_data(id cls, SEL cmd, id root, signed char secure, id* error) {
    (void)cls; (void)cmd; (void)secure;
    if (error)
        *error = 0;
    return ((id (*)(id, SEL, id))objc_msgSend)(
        (id)objc_getClass("NSKeyedArchiver"), sel_registerName("archivedDataWithRootObject:"), root);
}
static id keyed_unarchiver_unarchived_object(id cls, SEL cmd, Class expected, id data, id* error) {
    (void)cls; (void)cmd;
    if (error)
        *error = 0;
    if (!data)
        return 0;
    id object = 0;
    @try {
        object = ((id (*)(id, SEL, id))objc_msgSend)(
            (id)objc_getClass("NSKeyedUnarchiver"), sel_registerName("unarchiveObjectWithData:"), data);
    } @catch (id exception) {
        (void)exception;
        object = 0;
    }
    if (object && expected &&
        !((signed char (*)(id, SEL, Class))objc_msgSend)(object, sel_registerName("isKindOfClass:"), expected))
        object = 0;
    return object;
}

static void quinta_install_late_hooks(void);
static void quinta_start_xfixes_worker(void);
static void hooked_app_finish_launching(id self, SEL cmd) {
    quinta_install_late_hooks();
    quinta_start_xfixes_worker(); // ready before the first mouse lock
    orig_app_finish_launching(self, cmd);
    write_str("[Quinta Hook] -[NSApplication finishLaunching] returned\n");
    quinta_queue_pending_uri(self);

    id windows = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("windows"));
    unsigned long count = windows
        ? ((unsigned long (*)(id, SEL))objc_msgSend)(windows, sel_registerName("count")) : 0;
    for (unsigned long index = 0; index < count; index++) {
        id window = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
            windows, sel_registerName("objectAtIndex:"), index);
        const char* class_name = window ? object_getClassName(window) : 0;
        if (!ascii_strings_equal(class_name, "RBXWindow"))
            continue;
        quinta_set_window_icon(window);
        signed char visible = ((signed char (*)(id, SEL))objc_msgSend)(
            window, sel_registerName("isVisible"));
        if (!visible) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                window, sel_registerName("makeKeyAndOrderFront:"), 0);
            write_str("[Quinta] Ordered RBXWindow to the front after launch\n");
        }
    }
}

// Swizzle NSApplication terminate:
// The launcher watches QUINTA_QUIT_SENTINEL: the file's existence means the
// user asked to quit, so the session can end without waiting for Roblox's
// whole teardown (network closes, telemetry) to finish.
static void quinta_write_quit_sentinel(void) {
    const char* path = getenv("QUINTA_QUIT_SENTINEL");
    if (!path || !path[0])
        return;
    QuintaFILE* file = fopen(path, "w");
    if (!file)
        return;
    fclose(file);
    write_str("[Quinta] Quit sentinel written\n");
}
static void hooked_app_check_for_terminate(id self, SEL _cmd) {
    // No-op: Cocotron's _checkForTerminate calls [self terminate: self] whenever
    // windows are temporarily hidden (place load, return to menu).
}
static void (*orig_app_terminate)(id self, SEL _cmd, id sender) = 0;
static void hooked_app_terminate(id self, SEL _cmd, id sender) {
    write_str("\n[Quinta Hook] -[NSApplication terminate:] called!\nBacktrace:\n");
    print_backtrace();
    if (sender != self)
        quinta_write_quit_sentinel();
    orig_app_terminate(self, _cmd, sender);
}

// Swizzle NSApplication setDelegate:
static void (*orig_app_setDelegate)(id self, SEL _cmd, id del) = 0;
static void hooked_app_setDelegate(id self, SEL _cmd, id del) {
    write_str("\n[Quinta Hook] -[NSApplication setDelegate:] called with: ");
    write_str(del ? object_getClassName(del) : "(nil)");
    write_str("\n");
    orig_app_setDelegate(self, _cmd, del);
    quinta_captured_delegate = del;
}

// Swizzle NSBundle loadNibNamed:owner:
static signed char (*orig_loadNibNamed)(id self, SEL _cmd, id name, id owner) = 0; // BOOL
static signed char hooked_loadNibNamed(id self, SEL _cmd, id name, id owner) {
    write_str("\n[Quinta Hook] +[NSBundle loadNibNamed:owner:] entered\n");
    signed char res = orig_loadNibNamed(self, _cmd, name, owner);
    write_str("[Quinta Hook] +[NSBundle loadNibNamed:owner:] returned: ");
    print_num(res);
    write_str("\n");
    return res;
}

// Swizzle NSNib instantiateNibWithExternalNameTable:
static signed char (*orig_instantiateNib)(id self, SEL _cmd, id table) = 0; // BOOL
static signed char hooked_instantiateNib(id self, SEL _cmd, id table) {
    write_str("\n[Quinta Hook] -[NSNib instantiateNibWithExternalNameTable:] entered\n");
    signed char res = orig_instantiateNib(self, _cmd, table);
    write_str("[Quinta Hook] -[NSNib instantiateNibWithExternalNameTable:] returned: ");
    print_num(res);
    write_str("\n");
    return res;
}

// Swizzle NSWindowTemplate initWithCoder:
static __thread unsigned int in_wt_init;
static id (*orig_wt_initWithCoder)(id self, SEL _cmd, id coder) = 0;
static id hooked_wt_initWithCoder(id self, SEL _cmd, id coder) {
    write_str("[Quinta Hook] -[NSWindowTemplate initWithCoder:] START\n");
    in_wt_init++;
    id res = 0;
    @try {
        res = orig_wt_initWithCoder(self, _cmd, coder);
    } @catch (id exception) {
        if (quinta_crash_diagnostics_enabled()) {
            write_str("[Quinta Startup] Window template exception class: ");
            write_str(object_getClassName(exception));
            write_str("\n");
        }
        @throw;
    } @finally {
        in_wt_init--;
    }
    write_str("[Quinta Hook] -[NSWindowTemplate initWithCoder:] END -> ");
    print_hex((unsigned long long)res);
    write_str("\n");
    return res;
}

// Swizzle NSKeyedUnarchiver decodeObjectForKey:
static id (*orig_decodeObjectForKey)(id self, SEL _cmd, id key) = 0;
static id hooked_decodeObjectForKey(id self, SEL _cmd, id key) {
    const char* kstr = in_wt_init && key
        ? ((const char* (*)(id, SEL))objc_msgSend)(key, sel_registerName("UTF8String")) : 0;
    if (in_wt_init) {
        write_str("  [WT decodeObjectForKey]: ");
        write_str(kstr ? kstr : "(null)");
        write_str("\n");
    }
    id res = orig_decodeObjectForKey(self, _cmd, key);
    if (in_wt_init) {
        write_str("    -> returned: ");
        write_str(res ? object_getClassName(res) : "(nil)");
        write_str("\n");
    }
    return res;
}

#include "startup_diagnostics.h"

// Swizzle NSIBObjectData initWithCoder:
static id (*orig_od_initWithCoder)(id self, SEL _cmd, id coder) = 0;
static id hooked_od_initWithCoder(id self, SEL _cmd, id coder) {
    write_str("[Quinta Hook] -[NSIBObjectData initWithCoder:] START\n");
    id res = orig_od_initWithCoder(self, _cmd, coder);
    write_str("[Quinta Hook] -[NSIBObjectData initWithCoder:] END -> ");
    print_hex((unsigned long long)res);
    write_str("\n");
    return res;
}

// Swizzle NSIBObjectData establishConnections
static void (*orig_od_establish)(id self, SEL _cmd) = 0;
static void hooked_od_establish(id self, SEL _cmd) {
    write_str("[Quinta Hook] -[NSIBObjectData establishConnections] START\n");
    orig_od_establish(self, _cmd);
    write_str("[Quinta Hook] -[NSIBObjectData establishConnections] END\n");
}

// Swizzle NSNibConnector establishConnection
static void (*orig_conn_establish)(id self, SEL _cmd) = 0;
static void hooked_conn_establish(id self, SEL _cmd) {
    write_str("[Quinta Hook] -[NSNibConnector establishConnection] called on: ");
    write_str(object_getClassName(self));
    write_str("\n");
    orig_conn_establish(self, _cmd);
    write_str("[Quinta Hook] -[NSNibConnector establishConnection] finished\n");
}

// Cocoa x86_64 ABI: NSRect is four doubles passed by value; BOOL is signed char.
typedef struct { double x, y; } QuintaPoint;
typedef struct { double width, height; } QuintaSize;
typedef struct { QuintaPoint origin; QuintaSize size; } QuintaRect;
typedef signed char QuintaBool;

// Swizzle NSWindow initWithContentRect:styleMask:backing:defer:
static id (*orig_win_init)(id self, SEL _cmd, QuintaRect r, unsigned long sm, unsigned long bs, QuintaBool def) = 0;
static id hooked_win_init(id self, SEL _cmd, QuintaRect r, unsigned long sm, unsigned long bs, QuintaBool def) {
    write_str("\n[Quinta Hook] -[NSWindow initWithContentRect:...] START, class: ");
    write_str(object_getClassName(self));
    write_str("\n");
    id res = orig_win_init(self, _cmd, r, sm, bs, def);
    write_str("[Quinta Hook] -[NSWindow initWithContentRect:...] END -> ");
    print_hex((unsigned long long)res);
    write_str("\n");
    return res;
}

// Experimental 1x backing-size fallback for Darling's non-Retina NSView.
// Only add it when AppKit does not implement the method.
extern signed char class_addMethod(Class, SEL, IMP, const char*);
static QuintaSize backing_size_1x(id self, SEL cmd, QuintaSize size) {
    (void)self; (void)cmd;
    return size;
}

// Pair the client's UI contract with engine-only mouse coordinates.
#include "input_scale_hook.h"
#include "ui_scale_hook.h"

// Title bar options of macOS 10.10 that Roblox sets on its window
// (setTitlebarAppearsTransparent:, setTitleVisibility:). The Darling release
// this is tested with has them; an older or differently built Darling does
// not, and the game died at start with "unrecognized selector". Darling draws
// no such title bar anyway, so where they are missing they only remember the
// value. Per window state is not needed: Roblox has one window.
static signed char quinta_titlebar_transparent;
static long quinta_title_visibility;
static void window_set_titlebar_appears_transparent(id self, SEL cmd, signed char flag) {
    (void)self; (void)cmd;
    quinta_titlebar_transparent = flag;
}
static void window_ignore_flag(id self, SEL cmd, signed char flag) { (void)self; (void)cmd; (void)flag; }
static signed char window_flag_no(id self, SEL cmd) { (void)self; (void)cmd; return 0; }
static void window_ignore_object(id self, SEL cmd, id value) { (void)self; (void)cmd; (void)value; }
static id window_object_nil(id self, SEL cmd) { (void)self; (void)cmd; return 0; }
static void window_ignore_none(id self, SEL cmd) { (void)self; (void)cmd; }
static void window_ignore_integer(id self, SEL cmd, long value) { (void)self; (void)cmd; (void)value; }
static signed char window_titlebar_appears_transparent(id self, SEL cmd) {
    (void)self; (void)cmd;
    return quinta_titlebar_transparent;
}
static void window_set_title_visibility(id self, SEL cmd, long visibility) {
    (void)self; (void)cmd;
    quinta_title_visibility = visibility;
}
static long window_title_visibility(id self, SEL cmd) {
    (void)self; (void)cmd;
    return quinta_title_visibility;
}

// NSWindow gained rectangle variants of its screen conversion API after the
// AppKit snapshot used by Darling.  Roblox uses convertRectFromScreen: while
// handling mouse movement.  Falling through Objective-C forwarding is unsafe
// for a CGRect return on x86_64, so implement the methods in terms of the older
// point conversion calls which Darling does provide.
static QuintaRect window_convert_rect_from_screen(id self, SEL cmd, QuintaRect rect) {
    (void)cmd;
    rect.origin = ((QuintaPoint (*)(id, SEL, QuintaPoint))objc_msgSend)(
        self, sel_registerName("convertScreenToBase:"), rect.origin);
    return rect;
}

static QuintaRect window_convert_rect_to_screen(id self, SEL cmd, QuintaRect rect) {
    (void)cmd;
    rect.origin = ((QuintaPoint (*)(id, SEL, QuintaPoint))objc_msgSend)(
        self, sel_registerName("convertBaseToScreen:"), rect.origin);
    return rect;
}

static long window_number_at_point(id cls, SEL cmd, QuintaPoint point, long belowWindowNumber) {
    (void)cls; (void)cmd; (void)point; (void)belowWindowNumber;
    id app = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
    id win = app ? ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("keyWindow")) : 0;
    if (!win && app)
        win = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("mainWindow"));
    if (!win && app) {
        id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
        if (windows && ((unsigned long (*)(id, SEL))objc_msgSend)(windows, sel_registerName("count")) > 0)
            win = ((id (*)(id, SEL, unsigned long))objc_msgSend)(windows, sel_registerName("objectAtIndex:"), 0);
    }
    if (win) {
        if (!((QuintaBool (*)(id, SEL))objc_msgSend)(win, sel_registerName("isKeyWindow"))) {
            ((void (*)(id, SEL, id))objc_msgSend)(win, sel_registerName("makeKeyAndOrderFront:"), (id)0);
        }
        return ((long (*)(id, SEL))objc_msgSend)(win, sel_registerName("windowNumber"));
    }
    return 0;
}

// Darling exposes a deliberately small WebPreferences forwarding stub, but
// omits this legacy singleton constructor.  Roblox asks for the singleton while
// creating its experience coordinator, before any preference setters are sent.
static id quinta_standard_web_preferences;
static volatile int quinta_web_preferences_lock;
static id web_preferences_standard_preferences(id cls, SEL cmd) {
    (void)cmd;
    if (quinta_standard_web_preferences)
        return quinta_standard_web_preferences;
    while (__sync_lock_test_and_set(&quinta_web_preferences_lock, 1))
        quinta_sleep_us(1000);
    if (!quinta_standard_web_preferences) {
        id preferences = ((id (*)(id, SEL))objc_msgSend)(
            cls, sel_registerName("alloc"));
        preferences = preferences
            ? ((id (*)(id, SEL))objc_msgSend)(preferences, sel_registerName("init"))
            : 0;
        quinta_standard_web_preferences = preferences;
    }
    __sync_lock_release(&quinta_web_preferences_lock);
    return quinta_standard_web_preferences;
}

/* The generic WebKit forwarding stub advertises a zero-argument signature
 * for this BOOL setter, which raises NSForwardSignatureError in Roblox. */
static char web_plugins_enabled_key;
static void web_preferences_set_plugins_enabled(id self, SEL cmd, QuintaBool enabled) {
    (void)cmd;
    extern void objc_setAssociatedObject(id, const void*, id, unsigned long);
    id value = ((id (*)(id, SEL, QuintaBool))objc_msgSend)(
        (id)objc_getClass("NSNumber"), sel_registerName("numberWithBool:"), enabled);
    objc_setAssociatedObject(self, &web_plugins_enabled_key, value, 1);
}
static QuintaBool web_preferences_plugins_enabled(id self, SEL cmd) {
    (void)cmd;
    extern id objc_getAssociatedObject(id, const void*);
    id value = objc_getAssociatedObject(self, &web_plugins_enabled_key);
    return value ? ((QuintaBool (*)(id, SEL))objc_msgSend)(value, sel_registerName("boolValue")) : 0;
}

// Darling's AVFoundation class shell does not implement device discovery.
// Roblox/WebRTC probes cameras during Universal App startup even when voice or
// video capture is not in use.  An empty inventory is the correct headless
// result and lets the rest of the client continue initializing.
static id empty_capture_devices(id cls, SEL cmd) {
    (void)cls; (void)cmd;
    return ((id (*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSArray"), sel_registerName("array"));
}

// +[AVCaptureDevice authorizationStatusForMediaType:] and
// requestAccessForMediaType:completionHandler: (voice chat asks for the
// microphone): granted; the host's own permissions still apply.
static long capture_authorization_status(id cls, SEL cmd, id media_type) {
    (void)cls; (void)cmd; (void)media_type;
    return 3; // AVAuthorizationStatusAuthorized
}
struct QuintaBoolBlock { void* isa; int flags; int reserved; void (*invoke)(void*, signed char); };
static void capture_request_access(id cls, SEL cmd, id media_type, struct QuintaBoolBlock* handler) {
    (void)cls; (void)cmd; (void)media_type;
    if (handler && handler->invoke)
        handler->invoke(handler, 1);
}
static id empty_capture_devices_for_media_type(id cls, SEL cmd, id media_type) {
    (void)media_type;
    return empty_capture_devices(cls, cmd);
}

static id no_default_capture_device(id cls, SEL cmd, id media_type) {
    (void)cls; (void)cmd; (void)media_type;
    return 0;
}

// Keep the missing CALayer property as associated state. Darling's renderer
// still only supports the existing 1x path; this does not add Retina rendering.
extern void objc_setAssociatedObject(id, const void*, id, unsigned long);
extern id objc_getAssociatedObject(id, const void*);
static char contents_scale_key;
static void layer_set_contents_scale(id self, SEL cmd, double scale) {
    (void)cmd;
    id number = ((id (*)(id, SEL, double))objc_msgSend)(
        (id)objc_getClass("NSNumber"), sel_registerName("numberWithDouble:"), scale);
    objc_setAssociatedObject(self, &contents_scale_key, number, 1);
    if (scale != 1.0)
        write_str("[Quinta] Warning: CALayer backing rendering above/below 1x is unimplemented\n");
}
static double layer_contents_scale(id self, SEL cmd) {
    (void)cmd;
    id number = objc_getAssociatedObject(self, &contents_scale_key);
    return number ? ((double (*)(id, SEL))objc_msgSend)(number, sel_registerName("doubleValue")) : 1.0;
}

// Preserve requested touch filtering; this does not synthesize touch events.
static char allowed_touch_types_key;
static void view_set_allowed_touch_types(id self, SEL cmd, unsigned long types) {
    (void)cmd;
    id number = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
        (id)objc_getClass("NSNumber"), sel_registerName("numberWithUnsignedLong:"), types);
    objc_setAssociatedObject(self, &allowed_touch_types_key, number, 1);
}
static unsigned long view_allowed_touch_types(id self, SEL cmd) {
    (void)cmd;
    id number = objc_getAssociatedObject(self, &allowed_touch_types_key);
    return number ? ((unsigned long (*)(id, SEL))objc_msgSend)(number, sel_registerName("unsignedLongValue")) : 0;
}

// Newer AppKit exposes inertial-scroll phases on NSEvent. Darling does not
// synthesize those events, so the only correct value for its existing mouse
// events is NSEventPhaseNone (zero). This also keeps Roblox's input path out of
// Objective-C forwarding while the pointer is over the render view.
static unsigned long event_phase_none(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}

// Darling predates NSProcessInfo's thermal and low-power APIs. Linux exposes
// neither state through this compatibility layer, so report the documented
// neutral values used by macOS when no throttling is active.
static long process_info_thermal_state_nominal(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}

static QuintaBool process_info_low_power_mode_disabled(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}

// Darling's NSColor_catalog (system/catalog colours) releases ivars in dealloc
// that its initializers never retained. Qt's macOS platform plugin asks for
// such colours while Roblox Studio starts, and the first autorelease-pool
// drain crashed on the over-released object. Clear the object ivars first so
// the original dealloc releases nothing it does not own (a small leak).
typedef struct objc_ivar* QuintaIvar;
extern QuintaIvar* class_copyIvarList(Class, unsigned int*);
extern const char* ivar_getTypeEncoding(QuintaIvar);
extern void object_setIvar(id, QuintaIvar, id);
static void (*orig_catalog_color_dealloc)(id, SEL);
static void catalog_color_dealloc(id self, SEL cmd) {
    unsigned int count = 0;
    QuintaIvar* ivars = class_copyIvarList(objc_getClass("NSColor_catalog"), &count);
    for (unsigned int i = 0; ivars && i < count; i++) {
        const char* type = ivar_getTypeEncoding(ivars[i]);
        if (type && type[0] == '@')
            object_setIvar(self, ivars[i], 0);
    }
    free(ivars);
    orig_catalog_color_dealloc(self, cmd);
}

// Darling's NSColor_CGColor lacks colour-space conversion; Qt converts every
// palette colour with it and Studio died on NSInvalidArgumentException.
// Rebuild an RGB colour from the CGColor's components.
extern unsigned long CGColorGetNumberOfComponents(void*);
extern const double* CGColorGetComponents(void*);
static id cgcolor_using_color_space(id self, SEL cmd, id space) {
    // A CGColor is never a pattern: Qt asks for NSPatternColorSpace to detect
    // pattern colours and must get nil back.
    if (space && cmd == sel_registerName("colorUsingColorSpaceName:")) {
        const char* name = ((const char* (*)(id, SEL))objc_msgSend)(space, sel_registerName("UTF8String"));
        if (name && ascii_strings_equal(name, "NSPatternColorSpace"))
            return 0;
    }
    void* color = ((void* (*)(id, SEL))objc_msgSend)(self, sel_registerName("CGColor"));
    double r = 0, g = 0, b = 0, a = 1;
    unsigned long n = color ? CGColorGetNumberOfComponents(color) : 0;
    const double* c = color ? CGColorGetComponents(color) : 0;
    if (c && n >= 4) { r = c[0]; g = c[1]; b = c[2]; a = c[3]; }
    else if (c && n == 2) { r = g = b = c[0]; a = c[1]; }
    else if (c && n == 1) { r = g = b = c[0]; }
    return ((id (*)(id, SEL, double, double, double, double))objc_msgSend)(
        (id)objc_getClass("NSColor"), sel_registerName("colorWithCalibratedRed:green:blue:alpha:"), r, g, b, a);
}

// NSScreen's refresh-rate API (macOS 12) is missing in Darling. Roblox reads
// maximumFramesPerSecond to decide which frame-rate caps are valid and reset
// a saved "240 FPS" back to default on every start. Report the host monitor's
// refresh rate, detected by the launcher (QUINTA_DISPLAY_HZ).
static long quinta_display_hz(void) {
    static volatile long cached = -1;
    long value = __atomic_load_n(&cached, __ATOMIC_RELAXED);
    if (value >= 0)
        return value;
    const char* text = getenv("QUINTA_DISPLAY_HZ");
    value = 0;
    for (int i = 0; text && text[i] >= '0' && text[i] <= '9' && i < 4; i++)
        value = value * 10 + (text[i] - '0');
    if (value < 30 || value > 1000)
        value = 60;
    __atomic_store_n(&cached, value, __ATOMIC_RELAXED);
    return value;
}
static long screen_maximum_frames_per_second(id self, SEL cmd) {
    (void)self; (void)cmd;
    return quinta_display_hz();
}
static double screen_refresh_interval(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 1.0 / (double)quinta_display_hz();
}

// Trace the handoff between Roblox's OpenGL renderer and Darling's X11
// drawable. Keep this bounded because makeCurrentContext/flushBuffer normally
// run once per frame.
static id (*orig_gl_context_init)(id, SEL, id, id) = 0;
static void (*orig_gl_context_set_view)(id, SEL, id) = 0;
static void (*orig_gl_context_make_current)(id, SEL) = 0;
static void (*orig_gl_context_flush)(id, SEL) = 0;
static volatile long quinta_gl_make_current_count;
static volatile long quinta_gl_flush_count;

static void trace_gl_context(const char* action, id self, long count) {
    void** slots = (void**)self;
    write_str("[Quinta GL] ");
    write_str(action);
    if (count >= 0) {
        write_str(" #");
        print_num(count);
    }
    write_str(" self=");
    print_hex((unsigned long long)self);
    if (self) {
        write_str(" class=");
        write_str(object_getClassName(self));
        write_str(" view=");
        print_hex((unsigned long long)slots[2]);
        write_str(" cgl-context=");
        print_hex((unsigned long long)slots[3]);
        write_str(" subwindow=");
        print_hex((unsigned long long)slots[4]);
        write_str(" egl-surface=");
        print_hex((unsigned long long)slots[5]);
    }
    write_str("\n");
}

extern void quinta_prepare_context(void* format);
extern void quinta_finish_context(void);
extern void quinta_note_pixel_format(void* format, const unsigned int* attributes);
static id hooked_gl_context_init(id self, SEL cmd, id format, id shared) {
    quinta_prepare_context(format); // Core Profile if Roblox asked for it (gl_profile.c)
    id result = orig_gl_context_init(self, cmd, format, shared);
    quinta_finish_context();
    trace_gl_context("init", result, -1);
    return result;
}

static void hooked_gl_context_set_view(id self, SEL cmd, id view) {
    orig_gl_context_set_view(self, cmd, view);
    trace_gl_context("setView", self, -1);
}

static void hooked_gl_context_make_current(id self, SEL cmd) {
    orig_gl_context_make_current(self, cmd);
    long count = __sync_add_and_fetch(&quinta_gl_make_current_count, 1);
    void** slots = (void**)self;
    if (self && slots[3] && slots[5]) {
        void** cgl_slots = (void**)slots[3];
        quinta_gl_window_surface = slots[5];
        quinta_gl_window_egl_context = cgl_slots[9];
    }
    if (count <= 5 || count == 60 || count == 600)
        trace_gl_context("makeCurrentContext", self, count);
    if (quinta_gl_hacks_disabled()) // runs every frame: no lookups
        return;
    void* (*current_display)(void) = QUINTA_NEXT(void* (*)(void), "eglGetCurrentDisplay");
    void* (*current_context)(void) = QUINTA_NEXT(void* (*)(void), "eglGetCurrentContext");
    void* (*current_surface)(int) = QUINTA_NEXT(void* (*)(int), "eglGetCurrentSurface");
    int (*make_current)(void*, void*, void*, void*) =
        QUINTA_NEXT(int (*)(void*, void*, void*, void*), "eglMakeCurrent");
    unsigned int (*egl_error)(void) = QUINTA_NEXT(unsigned int (*)(void), "eglGetError");
    if (self && slots[5] && current_display && current_context &&
        current_surface && make_current && !current_surface(0x3059)) {
        void* display = current_display();
        void* context = current_context();
        int attached = make_current(display, slots[5], slots[5], context);
        write_str("[Quinta GL] repaired missing EGL window surface result=");
        print_num(attached);
        write_str(" error=");
        print_hex(egl_error ? egl_error() : 0);
        write_str(" surface-now=");
        print_hex((unsigned long long)current_surface(0x3059));
        write_str("\n");
    }
}

static void dump_final_program_shaders(int program) {
    if (program > 0)
        quinta_dump_program_sources((unsigned int)program, &quinta_dumped_final_program, 0);
}

static void trace_gl_frame_state(long count) {
    void (*get_integer)(unsigned int, int*) =
        (void (*)(unsigned int, int*))dlsym(RTLD_NEXT, "glGetIntegerv");
    void (*read_pixels)(int, int, int, int, unsigned int, unsigned int, void*) =
        (void (*)(int, int, int, int, unsigned int, unsigned int, void*))
            dlsym(RTLD_NEXT, "glReadPixels");
    void (*set_read_buffer)(unsigned int) =
        (void (*)(unsigned int))dlsym(RTLD_NEXT, "glReadBuffer");
    if (!get_integer)
        return;

    int draw_framebuffer = -1;
    int read_framebuffer = -1;
    int program = -1;
    int draw_buffer = -1;
    int read_buffer = -1;
    int viewport[4] = {-1, -1, -1, -1};
    get_integer(0x8CA6U, &draw_framebuffer); // GL_DRAW_FRAMEBUFFER_BINDING
    get_integer(0x8CAAU, &read_framebuffer); // GL_READ_FRAMEBUFFER_BINDING
    get_integer(0x8B8DU, &program);          // GL_CURRENT_PROGRAM
    get_integer(0x0C01U, &draw_buffer);      // GL_DRAW_BUFFER
    get_integer(0x0C02U, &read_buffer);      // GL_READ_BUFFER
    get_integer(0x0BA2U, viewport);          // GL_VIEWPORT
    dump_final_program_shaders(program);

    void* (*egl_current_context)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentContext");
    void* (*egl_current_surface)(int) =
        (void* (*)(int))dlsym(RTLD_NEXT, "eglGetCurrentSurface");
    void* (*egl_current_display)(void) =
        (void* (*)(void))dlsym(RTLD_NEXT, "eglGetCurrentDisplay");

    write_str("[Quinta GL] frame-state #");
    print_num(count);
    write_str(" draws=");
    print_num(quinta_gl_draw_count);
    write_str(" blits=");
    print_num(quinta_gl_blit_count);
    write_str(" clears=");
    print_num(quinta_gl_clear_count);
    write_str(" default-binds=");
    print_num(quinta_gl_default_framebuffer_bind_count);
    write_str(" draw-fbo=");
    print_num(draw_framebuffer);
    write_str(" read-fbo=");
    print_num(read_framebuffer);
    write_str(" program=");
    print_num(program);
    write_str(" draw-buffer=");
    print_hex((unsigned long long)(unsigned int)draw_buffer);
    write_str(" read-buffer=");
    print_hex((unsigned long long)(unsigned int)read_buffer);
    write_str(" egl-context=");
    print_hex((unsigned long long)(egl_current_context
                                      ? egl_current_context()
                                      : 0));
    write_str(" egl-display=");
    print_hex((unsigned long long)(egl_current_display
                                      ? egl_current_display()
                                      : 0));
    write_str(" egl-draw-surface=");
    print_hex((unsigned long long)(egl_current_surface
                                      ? egl_current_surface(0x3059)
                                      : 0)); // EGL_DRAW
    write_str(" viewport=");
    print_num(viewport[0]);
    write_str(",");
    print_num(viewport[1]);
    write_str(",");
    print_num(viewport[2]);
    write_str(",");
    print_num(viewport[3]);
    if (read_pixels && set_read_buffer && viewport[2] > 0 && viewport[3] > 0) {
        static const int fractions[3] = {1, 2, 3};
        // Roblox leaves the default read buffer disabled. Select the same back
        // buffer it draws into only while sampling, then restore its state.
        set_read_buffer(0x0402U); // GL_BACK_LEFT
        write_str(" samples=");
        for (int row = 0; row < 3; row++) {
            for (int column = 0; column < 3; column++) {
                unsigned char pixel[4] = {0, 0, 0, 0};
                int x = viewport[0] + viewport[2] * fractions[column] / 4;
                int y = viewport[1] + viewport[3] * fractions[row] / 4;
                read_pixels(x, y, 1, 1, 0x1908U, 0x1401U, pixel);
                if (row || column)
                    write_str(";");
                print_num(pixel[0]);
                write_str(",");
                print_num(pixel[1]);
                write_str(",");
                print_num(pixel[2]);
                write_str(",");
                print_num(pixel[3]);
            }
        }
        set_read_buffer((unsigned int)read_buffer);
    }
    write_str("\n");
}

static void hooked_gl_context_flush(id self, SEL cmd) {
    long count = __sync_add_and_fetch(&quinta_gl_flush_count, 1);
    static volatile int test_clear = -1;
    if (quinta_env_cached("QUINTA_GL_TEST_CLEAR", &test_clear)) {
        void (*disable)(unsigned int) =
            (void (*)(unsigned int))dlsym(RTLD_NEXT, "glDisable");
        void (*color_mask)(unsigned char, unsigned char, unsigned char,
                           unsigned char) =
            (void (*)(unsigned char, unsigned char, unsigned char,
                      unsigned char))dlsym(RTLD_NEXT, "glColorMask");
        void (*clear_color)(float, float, float, float) =
            (void (*)(float, float, float, float))
                dlsym(RTLD_NEXT, "glClearColor");
        void (*clear)(unsigned int) =
            (void (*)(unsigned int))dlsym(RTLD_NEXT, "glClear");
        unsigned int (*get_error)(void) =
            (unsigned int (*)(void))dlsym(RTLD_NEXT, "glGetError");
        unsigned int (*check_framebuffer)(unsigned int) =
            (unsigned int (*)(unsigned int))
                dlsym(RTLD_NEXT, "glCheckFramebufferStatus");
        void (*finish)(void) = (void (*)(void))dlsym(RTLD_NEXT, "glFinish");
        if (disable && color_mask && clear_color && clear) {
            unsigned int before_error = get_error ? get_error() : 0;
            disable(0x0C11U); // GL_SCISSOR_TEST
            color_mask(1, 1, 1, 1);
            clear_color(1.0f, 0.0f, 1.0f, 1.0f);
            clear(0x00004000U); // GL_COLOR_BUFFER_BIT
            if (finish)
                finish();
            if (count <= 5) {
                write_str("[Quinta GL] test-clear before-error=");
                print_hex(before_error);
                write_str(" after-error=");
                print_hex(get_error ? get_error() : 0);
                write_str(" framebuffer-status=");
                print_hex(check_framebuffer
                              ? check_framebuffer(0x8CA9U) // GL_DRAW_FRAMEBUFFER
                              : 0);
                write_str("\n");
            }
        }
    }
    if (quinta_gl_trace_enabled() && (count <= 5 || count == 60 || count == 600)) {
        trace_gl_frame_state(count);
        trace_gl_context("flushBuffer", self, count);
    }
    orig_gl_context_flush(self, cmd);
}

// Darling's CALayerContext renders layers on the main thread and leaves its
// own CGL context current. On macOS the render server does this in another
// process, so Roblox makes its NSOpenGLContext current once and expects it to
// stay current. Without restoring it, every later Roblox GL call goes to the
// surfaceless layer context, where Roblox's shaders and buffers do not exist.
extern void* CGLGetCurrentContext(void);
static void (*orig_layer_context_render_layer)(id, SEL, id) = 0;
static volatile long quinta_layer_context_restores;
static void hooked_layer_context_render_layer(id self, SEL cmd, id layer) {
    void* previous = CGLGetCurrentContext();
    orig_layer_context_render_layer(self, cmd, layer);
    if (CGLGetCurrentContext() != previous) {
        int error = quinta_CGLSetCurrentContext(previous);
        if (!error && __sync_add_and_fetch(&quinta_layer_context_restores, 1) == 1)
            write_str("[Quinta GL] Restored app GL context after CALayerContext render\n");
    }
}

/* CARenderer calls its image uploader directly, so dyld interposition cannot
 * replace that call. Populate a new texture before entering its recursive
 * renderer; the original then preserves its animation and child transforms. */
extern void quinta_CATexImage2DCGImage(void*);
extern void glGenTextures(int, unsigned int*);
extern unsigned char glIsTexture(unsigned int);
extern void glBindTexture(unsigned int, unsigned int);
extern void glTexParameteri(unsigned int, unsigned int, int);
static void (*orig_ca_renderer_render_layer)(id, SEL, id, double, double);
static void hooked_ca_renderer_render_layer(id self, SEL cmd, id layer,
                                           double z, double current_time) {
    // Metal drawables are presented by their native Vulkan subsurface. The
    // Darling GL compositor only understands bitmap layers and attempts to
    // upload even nil contents, dereferencing a NULL CGDataProvider.
    Class metal_layer = (Class)objc_getClass("QMMetalLayer");
    if (metal_layer && ((unsigned char (*)(id, SEL, Class))objc_msgSend)(
            layer, sel_registerName("isKindOfClass:"), metal_layer))
        return;
    id number = ((id (*)(id, SEL))objc_msgSend)(layer, sel_registerName("_textureId"));
    unsigned int texture = number ? ((unsigned int (*)(id, SEL))objc_msgSend)(
        number, sel_registerName("unsignedIntValue")) : 0;
    if (!texture || !glIsTexture(texture)) {
        if (!texture) {
            glGenTextures(1, &texture);
            if (!texture)
                return;
            id value = ((id (*)(id, SEL, unsigned int))objc_msgSend)(
                (id)objc_getClass("NSNumber"), sel_registerName("numberWithUnsignedInt:"), texture);
            ((void (*)(id, SEL, id))objc_msgSend)(layer, sel_registerName("_setTextureId:"), value);
        }
        glBindTexture(0x0DE1 /* GL_TEXTURE_2D */, texture);
        id contents = ((id (*)(id, SEL))objc_msgSend)(layer, sel_registerName("contents"));
        quinta_CATexImage2DCGImage(contents);
        const char* filter_names[] = {"minificationFilter", "magnificationFilter"};
        const unsigned int parameters[] = {0x2801, 0x2800};
        for (int i = 0; i < 2; ++i) {
            id filter = ((id (*)(id, SEL))objc_msgSend)(layer, sel_registerName(filter_names[i]));
            unsigned char nearest = ((unsigned char (*)(id, SEL, id))objc_msgSend)(
                filter, sel_registerName("isEqualToString:"), @"nearest");
            glTexParameteri(0x0DE1, parameters[i], nearest ? 0x2600 : 0x2601);
        }
        glTexParameteri(0x0DE1, 0x2802 /* GL_TEXTURE_WRAP_S */, 0x2901 /* GL_REPEAT */);
        glTexParameteri(0x0DE1, 0x2803 /* GL_TEXTURE_WRAP_T */, 0x2901);
    }
    orig_ca_renderer_render_layer(self, cmd, layer, z, current_time);
}

// Mouse lock (in-game camera). On macOS CGAssociateMouseAndMouseCursorPosition
// (false) freezes the cursor and mouse events carry raw deltas. Darling's
// version cannot be used for that:
//  - it passes "connected" to -[NSDisplay grabMouse:] unchanged (inverted);
//  - Roblox repeats the call every frame and each grab recenters the pointer;
//  - in grab mode deltas are measured from the pin point, and events queued
//    before the asynchronous warp-back report growing offsets (5, 10, 15
//    instead of 5, 5, 5), so the camera spun far too fast;
//  - Roblox's per-frame CGWarpMouseCursorPosition fought the pin point.
// Capture the pointer on the game's existing X11 connection, confine it to
// that native window, and leave Darling's _cursorGrabbed false. XI2 raw
// motion supplies camera deltas; ordinary pointer deltas remain a fallback.
// Recenter and restore with absolute native window coordinates, so queued
// events cannot overshoot by applying a stale relative correction. Roblox's
// per-frame warp requests during capture are ignored.
extern int CGAssociateMouseAndMouseCursorPosition(unsigned int connected);
extern int CGWarpMouseCursorPosition(QuintaPoint position);
#define QUINTA_LOCK_RADIUS 100.0
#include "pointer_motion.h"
#include "mouse_motion.h"
#include "drag_cursor.h"
static QuintaPointerMotion quinta_pointer_motion;
static volatile int quinta_native_motion_active;
static volatile int quinta_pointer_grabbed;
static volatile int quinta_mouse_lock_requested;
static volatile int quinta_drop_next_motion; // first motion after re-entering mid-lock
static volatile int quinta_drop_warp_motion;
static int quinta_warp_wait_events; // motion events seen since the warp
static QuintaPoint quinta_expected_warp_delta;
static volatile long quinta_associate_mouse_count;
static QuintaPoint quinta_lock_anchor;
static volatile int quinta_lock_anchor_pending;
static void* quinta_capture_display;
static unsigned long quinta_capture_window;
static int quinta_capture_attempted, quinta_capture_error;
static int quinta_capture_start_x, quinta_capture_start_y;
static int quinta_capture_anchor_x, quinta_capture_anchor_y;
static volatile int quinta_cursor_hidden_applied;
static volatile unsigned long quinta_cursor_hidden_generation;
static unsigned long quinta_capture_generation;
// Only request publication and small numeric snapshots use this lock. Native
// Xlib operations and AppKit callbacks run on the event owner's main thread.
static volatile unsigned int quinta_capture_request_lock;
static unsigned long quinta_capture_request_generation, quinta_capture_processed_generation;
static int quinta_capture_request_ready = 1, quinta_capture_request_has_snapshot;
static unsigned int quinta_capture_request_root;
static int quinta_capture_request_x, quinta_capture_request_y;
static int quinta_capture_request_no_restore, quinta_recenter_requested;
static QuintaPoint quinta_locked_cursor_position;
static int quinta_locked_cursor_position_valid, quinta_locked_cursor_position_pending;
static unsigned long quinta_capture_root;
static unsigned int quinta_capture_root_height;
static double quinta_capture_quartz_y_offset;
extern int pthread_main_np(void);
extern int quinta_raw_x_pointer_snapshot(unsigned int*, int*, int*);
static void quinta_wake_event_queue(void);
static void quinta_process_mouse_capture_requests(void);

typedef struct objc_ivar* Ivar;
extern Ivar class_getInstanceVariable(Class, const char*);
extern long ivar_getOffset(Ivar);

// The platform window's connection owns its event selections. A display
// opened by a worker or by NSDisplay currentDisplay on another thread cannot
// own this grab: owner_events=False would route motion to the wrong queue.
static void* quinta_native_window_display(id window) {
    if (!window) return 0;
    id platform = ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("platformWindow"));
    Ivar ivar = platform ? class_getInstanceVariable(object_getClass(platform), "_display") : 0;
    return ivar ? *(void**)((char*)platform + ivar_getOffset(ivar)) : 0;
}

static int quinta_query_native_pointer(void* display, unsigned long window,
                                         int* x, int* y) {
    static int (*query)(void*, unsigned long, unsigned long*, unsigned long*,
                        int*, int*, int*, int*, unsigned int*);
    if (!query)
        query = (int (*)(void*, unsigned long, unsigned long*, unsigned long*,
                         int*, int*, int*, int*, unsigned int*))
            dlsym(RTLD_DEFAULT, "XQueryPointer");
    unsigned long root, child;
    int root_x, root_y;
    unsigned int state;
    return query && display && window &&
        query(display, window, &root, &child, &root_x, &root_y, x, y, &state);
}

static int quinta_warp_native_pointer(void* display, unsigned long window, int x, int y) {
    static int (*warp)(void*, unsigned long, unsigned long, int, int,
                       unsigned int, unsigned int, int, int);
    static int (*flush)(void*);
    if (!warp) {
        warp = (int (*)(void*, unsigned long, unsigned long, int, int,
                        unsigned int, unsigned int, int, int))
            dlsym(RTLD_DEFAULT, "XWarpPointer");
        flush = (int (*)(void*))dlsym(RTLD_DEFAULT, "XFlush");
    }
    if (!warp || !display || !window) return 0;
    warp(display, 0, window, 0, 0, 0, 0, x, y);
    if (flush) flush(display);
    return 1;
}

static unsigned long (*quinta_x_next_request)(void*);
static void (*quinta_x_lock_display)(void*);
static void (*quinta_x_unlock_display)(void*);

static int quinta_native_motion_supported(void) {
    static int resolved;
    if (!resolved) {
        quinta_x_next_request = (unsigned long (*)(void*))dlsym(RTLD_DEFAULT, "XNextRequest");
        quinta_x_lock_display = (void (*)(void*))dlsym(RTLD_DEFAULT, "XLockDisplay");
        quinta_x_unlock_display = (void (*)(void*))dlsym(RTLD_DEFAULT, "XUnlockDisplay");
        resolved = 1;
    }
    return quinta_x_next_request && quinta_x_lock_display && quinta_x_unlock_display;
}

static int quinta_warp_capture_pointer(int x, int y) {
    if (!quinta_native_motion_supported() || quinta_pointer_motion.warp_pending) return 0;
    /* Cursor setters can share this connection. Keep the request sequence
     * query and the warp together so an unrelated request cannot take its
     * serial. Xlib permits public calls while XLockDisplay is held. */
    quinta_x_lock_display(quinta_capture_display);
    unsigned long serial = quinta_x_next_request(quinta_capture_display);
    int warped = quinta_warp_native_pointer(quinta_capture_display, quinta_capture_window, x, y);
    quinta_x_unlock_display(quinta_capture_display);
    if (!warped) return 0;
    quinta_pointer_motion_warp(&quinta_pointer_motion, serial, x, y);
    return 1;
}

// The fallback's Cocoa motion filter requests a recenter. Query the actual
// native position for the warp delta; its queued event location can be stale.
static int quinta_recenter_pointer_on_owner(void) {
    int x, y;
    if (!__atomic_load_n(&quinta_cursor_hidden_applied, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&quinta_cursor_hidden_generation, __ATOMIC_ACQUIRE) != quinta_capture_generation ||
        !quinta_query_native_pointer(quinta_capture_display, quinta_capture_window, &x, &y))
        return 0;
    if (x == quinta_capture_anchor_x && y == quinta_capture_anchor_y) return 1;
    if (!quinta_warp_native_pointer(quinta_capture_display, quinta_capture_window,
                                     quinta_capture_anchor_x, quinta_capture_anchor_y))
        return 0;
    quinta_lock(&quinta_capture_request_lock);
    quinta_expected_warp_delta.x = quinta_capture_anchor_x - x;
    quinta_expected_warp_delta.y = y - quinta_capture_anchor_y;
    quinta_warp_wait_events = 0;
    quinta_drop_warp_motion = 1;
    quinta_unlock(&quinta_capture_request_lock);
    return 1;
}

static id quinta_lock_window(void) {
    id app = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"),
                                             sel_registerName("sharedApplication"));
    id window = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("keyWindow"));
    if (!window)
        window = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("mainWindow"));
    return window;
}

// While locked, a macOS cursor does not move: event locations, the window's
// mouse location and +[NSEvent mouseLocation] all stay where the lock began,
// and only the deltas change. Here the real pointer wanders around the window
// center, so report the frozen positions to Roblox as macOS would.
static QuintaPoint quinta_frozen_window_location;
static QuintaPoint quinta_frozen_screen_location;
static QuintaPoint (*orig_event_location_in_window)(id, SEL) = 0;
static QuintaPoint (*orig_window_mouse_location)(id, SEL) = 0;
static QuintaPoint (*orig_event_mouse_location)(id, SEL) = 0;
static QuintaPoint hooked_event_location_in_window(id self, SEL cmd) {
    if (__atomic_load_n(&quinta_pointer_grabbed, __ATOMIC_ACQUIRE)) {
        unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
            self, sel_registerName("type"));
        if ((type >= 1 && type <= 7) || type == 25 || type == 26 || type == 27) {
            quinta_lock(&quinta_capture_request_lock);
            QuintaPoint point = quinta_frozen_window_location;
            quinta_unlock(&quinta_capture_request_lock);
            return point;
        }
    }
    return orig_event_location_in_window(self, cmd);
}
static QuintaPoint hooked_window_mouse_location(id self, SEL cmd) {
    if (__atomic_load_n(&quinta_pointer_grabbed, __ATOMIC_ACQUIRE)) {
        quinta_lock(&quinta_capture_request_lock);
        QuintaPoint point = quinta_frozen_window_location;
        quinta_unlock(&quinta_capture_request_lock);
        return point;
    }
    return orig_window_mouse_location(self, cmd);
}
static QuintaPoint hooked_event_mouse_location(id cls, SEL cmd) {
    if (__atomic_load_n(&quinta_pointer_grabbed, __ATOMIC_ACQUIRE)) {
        quinta_lock(&quinta_capture_request_lock);
        QuintaPoint point = quinta_frozen_screen_location;
        quinta_unlock(&quinta_capture_request_lock);
        return point;
    }
    return orig_event_mouse_location(cls, cmd);
}
static QuintaPoint quinta_real_event_location(id event) {
    SEL selector = sel_registerName("locationInWindow");
    return orig_event_location_in_window ? orig_event_location_in_window(event, selector)
        : ((QuintaPoint (*)(id, SEL))objc_msgSend)(event, selector);
}

// Under Xwayland, XWarpPointer only moves the X server's idea of the pointer;
// the next Wayland motion reports the real position again, so recentering
// bounced the pointer back and forth. Xwayland emulates warps properly while
// the X cursor is hidden with XFixes. The requests go over a private X11
// socket (xfixes_raw.c), and on a worker thread, so the game thread never
// waits on X.
//
// The worker sleeps in a read of a pipe and wakes when the wanted state
// changes. It used to poll every 5 ms with Darling's usleep, two
// darlingserver requests each (400 a second for the whole session), and a
// hide could lag 5 ms behind the lock. It starts, and opens its connection,
// when the app finishes launching, not at the first lock.
extern int quinta_raw_xfixes_open(void);
extern int quinta_raw_xfixes_set_hidden(int hidden);
extern int quinta_wayland_enabled(void);
extern int pthread_create(void**, const void*, void* (*)(void*), void*);
extern int pthread_detach(void*);
extern int pipe(int[2]);
extern long read(int, void*, unsigned long);
extern int quinta_cursor_overlay_update_at(int, unsigned long, int, int, int, unsigned long);
extern int quinta_cursor_overlay_update_selected(int, unsigned long, int, int, int, unsigned long, unsigned long);
extern int quinta_cursor_overlay_update_drag(int,unsigned long,int,int,int,unsigned long,unsigned long,int);
extern void quinta_cursor_overlay_select_image(unsigned long, const unsigned int*, unsigned int, unsigned int,
                                                unsigned int, unsigned int);
static volatile int quinta_cursor_wanted_hidden;
static volatile unsigned long quinta_cursor_lock_window;
static int quinta_cursor_lock_x, quinta_cursor_lock_y;
static unsigned long quinta_cursor_lock_generation;
static volatile int quinta_cursor_hide_depth;
static volatile int quinta_cursor_worker_ready;
static volatile int quinta_cursor_worker_started;
static volatile unsigned long long quinta_cursor_retry_after;
static volatile int quinta_input_focused = 1;
static int quinta_cursor_wake[2] = {-1, -1};
static QuintaCursorSelection quinta_window_cursor_selection;
static volatile unsigned int quinta_window_cursor_lock;
static QuintaDragCursor quinta_drag_cursor;
static unsigned long long quinta_input_now_ns(void) {
    struct { long seconds, nanoseconds; } now = {0, 0};
    long result;
    __asm__ volatile("syscall" : "=a"(result)
        : "a"(228L /* Linux clock_gettime */), "D"(1L /* CLOCK_MONOTONIC */), "S"(&now)
        : "rcx", "r11", "memory");
    return result == 0 ? (unsigned long long)now.seconds * 1000000000ULL + now.nanoseconds : 0;
}
static void* quinta_xfixes_worker(void* unused) {
    (void)unused;
    if (!quinta_raw_xfixes_open()) {
        write_str("[Quinta] XFixes unavailable, mouse lock may bounce\n");
        __atomic_store_n(&quinta_cursor_retry_after, quinta_input_now_ns() + 1000000000ULL, __ATOMIC_RELEASE);
        __atomic_store_n(&quinta_cursor_worker_ready, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&quinta_cursor_worker_started, 0, __ATOMIC_RELEASE);
        return 0;
    }
    write_str("[Quinta] XFixes ready for cursor hiding\n");
    void* (*open_display)(const char*) =
        (void* (*)(const char*))dlsym(RTLD_DEFAULT, "XOpenDisplay");
    int (*close_display)(void*) = (int (*)(void*))dlsym(RTLD_DEFAULT, "XCloseDisplay");
    int (*undefine_cursor)(void*, unsigned long) =
        (int (*)(void*, unsigned long))dlsym(RTLD_DEFAULT, "XUndefineCursor");
    int (*query_tree)(void*, unsigned long, unsigned long*, unsigned long*,
                      unsigned long**, unsigned int*) =
        (int (*)(void*, unsigned long, unsigned long*, unsigned long*,
                 unsigned long**, unsigned int*))dlsym(RTLD_DEFAULT, "XQueryTree");
    int (*free_data)(void*) = (int (*)(void*))dlsym(RTLD_DEFAULT, "XFree");
    int (*sync_display)(void*, int) = (int (*)(void*, int))dlsym(RTLD_DEFAULT, "XSync");
    void* xlib_display = open_display ? open_display(0) : 0;
    QuintaCursorApplyAPI cursor_api = {undefine_cursor, query_tree, free_data, sync_display};
    if (xlib_display && undefine_cursor && query_tree && free_data && sync_display)
        write_str("[Quinta] Window cursor worker ready\n");
    __atomic_store_n(&quinta_cursor_worker_ready, 1, __ATOMIC_RELEASE);
    int applied = 0;
    for (;;) {
        QuintaCursorSelection selected = {0};
        quinta_lock(&quinta_window_cursor_lock);
        int wanted = __atomic_load_n(&quinta_cursor_wanted_hidden, __ATOMIC_ACQUIRE);
        unsigned long lock_window = __atomic_load_n(&quinta_cursor_lock_window, __ATOMIC_ACQUIRE);
        int lock_x = quinta_cursor_lock_x, lock_y = quinta_cursor_lock_y;
        unsigned long lock_generation = quinta_cursor_lock_generation;
        unsigned long cursor_id = quinta_window_cursor_selection.window == lock_window
            ? quinta_window_cursor_selection.cursor : 0;
        int right_drag=quinta_drag_cursor_visible(&quinta_drag_cursor);
        int changed = quinta_cursor_selection_take(&quinta_window_cursor_selection, &selected);
        quinta_unlock(&quinta_window_cursor_lock);
        if (changed) {
            if (quinta_cursor_selection_apply(&cursor_api, xlib_display, selected.window)) {
                static volatile long defined;
                if (__sync_add_and_fetch(&defined, 1) <= 3) {
                    write_str("[Quinta Cursor] Applied selected cursor; rendering children inherit it\n");
                }
            }
        }
        if (!quinta_cursor_overlay_update_drag(wanted, lock_window,
                __atomic_load_n(&quinta_cursor_hide_depth, __ATOMIC_ACQUIRE) == 0,
                lock_x, lock_y, lock_generation, cursor_id,right_drag)) {
            static int reported;
            if (!reported) {
                reported = 1;
                write_str("[Quinta Cursor] Visible locked-cursor overlay unavailable\n");
            }
        }
        if (wanted != applied) {
            if (quinta_raw_xfixes_set_hidden(wanted)) {
                applied = wanted;
            } else {
                __atomic_store_n(&quinta_cursor_hidden_generation, 0, __ATOMIC_RELEASE);
                __atomic_store_n(&quinta_cursor_hidden_applied, 0, __ATOMIC_RELEASE);
                __atomic_store_n(&quinta_cursor_worker_ready, 0, __ATOMIC_RELEASE);
                quinta_cursor_overlay_update_at(0, 0, 0, 0, 0, 0);
                if (xlib_display && close_display) close_display(xlib_display);
                __atomic_store_n(&quinta_cursor_retry_after, quinta_input_now_ns() + 1000000000ULL, __ATOMIC_RELEASE);
                __atomic_store_n(&quinta_cursor_worker_started, 0, __ATOMIC_RELEASE);
                write_str("[Quinta Cursor] XFixes transition failed; cursor worker will retry\n");
                quinta_wake_event_queue();
                return 0;
            }
        }
        if (wanted == applied) {
            // A rapid relock may reuse an already hidden cursor. Acknowledge
            // the new epoch without sending another nested HideCursor.
            __atomic_store_n(&quinta_cursor_hidden_generation, wanted ? lock_generation : 0, __ATOMIC_RELEASE);
            __atomic_store_n(&quinta_cursor_hidden_applied, wanted, __ATOMIC_RELEASE);
            quinta_wake_event_queue();
        }
        char bytes[64];
        if (read(quinta_cursor_wake[0], bytes, sizeof bytes) <= 0)
            quinta_sleep_us(5000); // no pipe: poll, but without darlingserver
    }
    return 0;
}

static void quinta_start_xfixes_worker(void) {
    if (quinta_wayland_enabled())
        return;
    if (quinta_input_now_ns() < __atomic_load_n(&quinta_cursor_retry_after, __ATOMIC_ACQUIRE) ||
        !__sync_bool_compare_and_swap(&quinta_cursor_worker_started, 0, 1))
        return;
    if (quinta_cursor_wake[0] < 0)
        quinta_wake_pipe(quinta_cursor_wake);
    void* thread;
    if (pthread_create(&thread, 0, quinta_xfixes_worker, 0) == 0) {
        pthread_detach(thread);
        quinta_wake_worker(quinta_cursor_wake[1]);
    } else {
        __atomic_store_n(&quinta_cursor_retry_after, quinta_input_now_ns() + 1000000000ULL, __ATOMIC_RELEASE);
        __atomic_store_n(&quinta_cursor_worker_started, 0, __ATOMIC_RELEASE);
    }
}

static void quinta_set_x_cursor_hidden(int hidden) {
    quinta_lock(&quinta_window_cursor_lock);
    __atomic_store_n(&quinta_cursor_wanted_hidden, hidden, __ATOMIC_RELEASE);
    quinta_unlock(&quinta_window_cursor_lock);
    quinta_start_xfixes_worker();
    if (__atomic_load_n(&quinta_cursor_worker_ready, __ATOMIC_ACQUIRE))
        quinta_wake_worker(quinta_cursor_wake[1]);
}


static void quinta_cursor_changed(void) {
    if (__atomic_load_n(&quinta_cursor_worker_ready, __ATOMIC_ACQUIRE))
        quinta_wake_worker(quinta_cursor_wake[1]);
}
static void quinta_drag_cursor_update_buttons(unsigned buttons) {
    quinta_lock(&quinta_window_cursor_lock);
    int before=quinta_drag_cursor_visible(&quinta_drag_cursor);
    quinta_drag_cursor_buttons(&quinta_drag_cursor,buttons);
    int changed=before!=quinta_drag_cursor_visible(&quinta_drag_cursor);
    quinta_unlock(&quinta_window_cursor_lock);
    if(changed)quinta_cursor_changed();
}
static void (*orig_cursor_hide)(id, SEL);
static void hooked_cursor_hide(id self, SEL cmd) {
    __atomic_add_fetch(&quinta_cursor_hide_depth, 1, __ATOMIC_RELEASE);
    orig_cursor_hide(self, cmd);
    quinta_cursor_changed();
}
static void (*orig_cursor_unhide)(id, SEL);
static void hooked_cursor_unhide(id self, SEL cmd) {
    orig_cursor_unhide(self, cmd);
    int depth = __atomic_load_n(&quinta_cursor_hide_depth, __ATOMIC_ACQUIRE);
    while (depth > 0 && !__atomic_compare_exchange_n(&quinta_cursor_hide_depth,
            &depth, depth - 1, 0, __ATOMIC_RELEASE, __ATOMIC_RELAXED)) {}
    quinta_cursor_changed();
}

// Raw motion for the lock (raw_mouse.c). With XInput 2 the camera deltas
// come from the mouse itself: no pointer acceleration, no merged motion, and
// the warps that keep the hidden pointer inside the window need no
// recognising, since warps produce no raw events. While it is active the
// game gets no pointer motion at all during the lock: raw deltas are summed
// within each bounded X event batch, then posted as one mouse event. Button,
// keyboard and focus transitions flush the sum to preserve their ordering.
// and the real MotionNotify events only serve to keep the pointer near its
// anchor. The selection changes on the event loop's own thread and X
// connection (the game thread only asks). QUINTA_RAW_MOUSE=0 keeps the
// pointer-delta lock.
typedef struct objc_ivar* Ivar; // also declared with the cursor code below
extern Ivar class_getInstanceVariable(Class, const char*);
extern long ivar_getOffset(Ivar);
extern int quinta_raw_mouse_select(void* display, int enabled);
extern int quinta_raw_mouse_event(void* display, void* event, double* dx, double* dy);
extern unsigned long quinta_raw_mouse_event_timestamp(void);
static id quinta_event_queue(id display);
static void quinta_lock_event_queue(void);
static void quinta_unlock_event_queue(void);
static unsigned long quinta_event_type(id event);
static double (*orig_mouse_event_delta_x)(id, SEL);
static double (*orig_mouse_event_delta_y)(id, SEL);
static volatile int quinta_raw_mouse_wanted;   // the lock state, set by the game thread
static int quinta_raw_mouse_selected;          // what the event loop applied last
static volatile int quinta_raw_mouse_active;   // raw events selected: deltas come from them
static unsigned int quinta_raw_buttons;        // X buttons held, bit 1..3
static int quinta_raw_have_anchor;
static int quinta_raw_anchor_x, quinta_raw_anchor_y; // X window coordinates, y down
static long quinta_raw_events, quinta_raw_posted;
static unsigned long long quinta_raw_last_motion_ns;
static int quinta_raw_core_motion_seen;
static unsigned int quinta_raw_last_server_time;
static int quinta_raw_have_server_time;
static unsigned long quinta_raw_selection_serial;
static unsigned long quinta_x_modifier_flags;
static unsigned char quinta_x_modifier_masks[256], quinta_x_modifier_keys_down[256];
static void* quinta_x_modifier_display;
static volatile unsigned int quinta_x_event_draining;
static id quinta_raw_pending_window;
static double quinta_raw_pending_dx, quinta_raw_pending_dy;
static unsigned long quinta_raw_pending_type, quinta_raw_pending_flags;
static unsigned int quinta_raw_pending_button;
static QuintaPoint quinta_raw_pending_location;
/* Darling classifies Button2 (middle) as right-drag. Correct the generated
 * event at postEvent:, on the same thread, without changing its X state. */
static __thread unsigned long quinta_core_motion_type;
static __thread unsigned int quinta_core_motion_button;
/* Likewise for a key Darling gave no key code (x_key_codes.h): the code to put
 * on the key event that postXEvent: is about to queue, or -1. */
static __thread int quinta_x_key_override = -1;
static __thread int quinta_x_batch_last;

static int quinta_raw_mouse_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        const char* value = getenv("QUINTA_RAW_MOUSE");
        enabled = !(value && value[0] == '0');
    }
    return enabled;
}

static void* quinta_x11_display_connection(id display) {
    static long offset = -2;
    if (offset == -2) {
        Ivar ivar = class_getInstanceVariable(object_getClass(display), "_display");
        offset = ivar ? (long)ivar_getOffset(ivar) : -1;
    }
    return offset >= 0 ? *(void**)((char*)display + offset) : (void*)0;
}

// One mouse event with the raw deltas, on the lock window. Darling's deltaY
// is computed upward and hooked_mouse_event_delta_y flips it for the game,
// so the raw y (downward, as macOS reports it) is stored flipped.
static unsigned long quinta_motion_type(unsigned int buttons, unsigned int* button) {
    return quinta_mouse_motion_event(buttons,
        __atomic_load_n(&quinta_pointer_grabbed,__ATOMIC_ACQUIRE),button);
}

static void quinta_flush_raw_motion(id display) {
    id window = quinta_raw_pending_window;
    if (!window) return;
    double dx = quinta_raw_pending_dx, dy = quinta_raw_pending_dy;
    quinta_raw_pending_window = 0;
    quinta_raw_pending_dx = quinta_raw_pending_dy = 0;
    if (!quinta_pointer_grabbed || (!dx && !dy)) {
        ((void (*)(id, SEL))objc_msgSend)(window, sel_registerName("release"));
        return;
    }
    id event_class = (id)objc_getClass("NSEvent");
    id event = ((id (*)(id, SEL, unsigned long, QuintaPoint, unsigned long, id, long, double, double))objc_msgSend)(
        event_class, sel_registerName("mouseEventWithType:location:modifierFlags:window:clickCount:deltaX:deltaY:"),
        quinta_raw_pending_type, quinta_raw_pending_location, quinta_raw_pending_flags,
        window, 1, dx, -dy);
    if (event) {
        ((void (*)(id, SEL, long))objc_msgSend)(event, sel_registerName("_setButtonNumber:"),
                                               (long)quinta_raw_pending_button);
        ((void (*)(id, SEL, id, signed char))objc_msgSend)(display, sel_registerName("postEvent:atStart:"), event, 0);
        quinta_raw_posted++;
    }
    ((void (*)(id, SEL))objc_msgSend)(window, sel_registerName("release"));
}

static void quinta_accumulate_raw_motion(id display, double dx, double dy) {
    id window = quinta_lock_window();
    if (!window) return;
    unsigned int button;
    unsigned long type = quinta_motion_type(quinta_raw_buttons, &button);
    if (quinta_raw_pending_window &&
        (quinta_raw_pending_window != window || quinta_raw_pending_type != type ||
         quinta_raw_pending_flags != quinta_x_modifier_flags || quinta_raw_pending_button != button))
        quinta_flush_raw_motion(display);
    if (!quinta_raw_pending_window) {
        quinta_raw_pending_window = ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("retain"));
        quinta_raw_pending_type = type;
        quinta_raw_pending_button = button;
        quinta_raw_pending_flags = quinta_x_modifier_flags;
        quinta_raw_pending_location = quinta_frozen_window_location;
    }
    quinta_raw_pending_dx += dx;
    quinta_raw_pending_dy += dy;
    /* Direct postXEvent: callers also get their event without needing a drain. */
    if (!__atomic_load_n(&quinta_x_event_draining, __ATOMIC_ACQUIRE))
        quinta_flush_raw_motion(display);
}

static unsigned long quinta_modifiers_for_x_state(unsigned int state) {
    unsigned long flags = 0;
    if (state & 1u) flags |= 1UL << 17;       // Shift
    if (state & 2u) flags |= 1UL << 16;       // Caps Lock
    if (state & 4u) flags |= 1UL << 18;       // Control
    if (state & 8u) flags |= 1UL << 19;       // Alt
    if (state & 64u) flags |= 1UL << 20;      // Super/Command
    if (state & 128u) flags |= 1UL << 23;     // AltGr/Function
    return flags;
}

static unsigned int quinta_buttons_for_x_state(unsigned int state) {
    return ((state & (1u << 8)) ? 1u << 1 : 0) |
           ((state & (1u << 9)) ? 1u << 2 : 0) |
           ((state & (1u << 10)) ? 1u << 3 : 0);
}

static void quinta_refresh_x_modifier_mapping(id self, int seed_keys) {
    struct modifier_map { int keys_per_modifier; unsigned char* keycodes; };
    static struct modifier_map* (*get_mapping)(void*);
    static int (*free_mapping)(struct modifier_map*);
    static int (*query_keys)(void*, char*);
    if (!get_mapping) {
        get_mapping = (struct modifier_map* (*)(void*))dlsym(RTLD_DEFAULT, "XGetModifierMapping");
        free_mapping = (int (*)(struct modifier_map*))dlsym(RTLD_DEFAULT, "XFreeModifiermap");
        query_keys = (int (*)(void*, char*))dlsym(RTLD_DEFAULT, "XQueryKeymap");
    }
    void* display = quinta_x11_display_connection(self);
    if (!display || !get_mapping || !free_mapping) return;
    struct modifier_map* map = get_mapping(display);
    if (map && map->keycodes && map->keys_per_modifier >= 0 && map->keys_per_modifier <= 256) {
        for (int key = 0; key < 256; key++) quinta_x_modifier_masks[key] = 0;
        for (int modifier = 0; modifier < 8; modifier++)
            for (int index = 0; index < map->keys_per_modifier; index++) {
                unsigned int key = map->keycodes[modifier * map->keys_per_modifier + index];
                if (key) quinta_x_modifier_masks[key] |= 1u << modifier;
            }
        quinta_x_modifier_display = display;
    }
    if (map) free_mapping(map);
    if (seed_keys && query_keys) {
        char down[32] = {0};
        if (query_keys(display, down))
            for (int key = 0; key < 256; key++)
                quinta_x_modifier_keys_down[key] = ((unsigned char)down[key / 8] >> (key % 8)) & 1;
    }
}

static void quinta_update_x_input_state(id display, void* event) {
    int type = *(int*)event;
    if (type < 2 || type > 6) return;
    unsigned int state = *(unsigned int*)((char*)event + 80);
    if (type == 2 || type == 3) {
        if (quinta_x_modifier_display != quinta_x11_display_connection(display))
            quinta_refresh_x_modifier_mapping(display, 1);
        state = quinta_x_modifier_transition(state,
            *(unsigned int*)((char*)event + 84), type == 2,
            quinta_x_modifier_masks, quinta_x_modifier_keys_down);
    }
    unsigned long flags = quinta_modifiers_for_x_state(state);
    unsigned int buttons = quinta_buttons_for_x_state(state);
    if (type == 4 || type == 5) {
        unsigned int button = *(unsigned int*)((char*)event + 84);
        if (button >= 1 && button <= 3) {
            if (type == 4) buttons |= 1u << button;
            else buttons &= ~(1u << button);
        }
    }
    int buttons_changed = buttons != quinta_raw_buttons;
    if (flags != quinta_x_modifier_flags || buttons_changed)
        quinta_flush_raw_motion(display);
    quinta_x_modifier_flags = flags;
    quinta_raw_buttons = buttons;
    if (buttons_changed) quinta_drag_cursor_update_buttons(buttons);
}

static void quinta_update_pointer_baseline(id display, void* event) {
    id platform = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
        display, sel_registerName("windowForID:"), *(unsigned long*)((char*)event + 32));
    if (platform) {
        QuintaPoint point = {*(int*)((char*)event + 64), *(int*)((char*)event + 68)};
        point = ((QuintaPoint (*)(id, SEL, QuintaPoint))objc_msgSend)(
            platform, sel_registerName("transformPoint:"), point);
        ((void (*)(id, SEL, QuintaPoint))objc_msgSend)(
            platform, sel_registerName("setLastKnownCursorPosition:"), point);
    }
}

// X events of the event loop, before Darling sees them. Returns 1 when the
// event is consumed here.
static int quinta_raw_mouse_x_event(id self, void* event) {
    void* display = quinta_x11_display_connection(self);
    if (!display)
        return 0;
    if (quinta_pointer_grabbed && display != quinta_capture_display)
        return 0;
    int wanted = quinta_raw_mouse_enabled() && quinta_raw_mouse_wanted && quinta_native_motion_active;
    static volatile int trace_events = -1;
    if (quinta_pointer_grabbed && quinta_env_cached("QUINTA_TRACE_LOCK", &trace_events)) {
        static long traced;
        if (traced++ < 40) {
            write_str("[Quinta Lock] X event type=");
            print_num(*(int*)event);
            write_str(wanted ? " wanted=1" : " wanted=0");
            write_str(quinta_raw_mouse_active ? " active=1\n" : " active=0\n");
        }
    }
    if (wanted != quinta_raw_mouse_selected) {
        int selected = 0;
        if (wanted || quinta_raw_mouse_selected == 1) {
            quinta_x_lock_display(display);
            selected = quinta_raw_mouse_select(display, wanted);
            if (wanted && selected)
                quinta_raw_selection_serial = quinta_x_next_request(display) - 1;
            quinta_x_unlock_display(display);
        }
        quinta_raw_mouse_selected = wanted;
        __atomic_store_n(&quinta_raw_mouse_active, wanted && selected, __ATOMIC_RELEASE);
        if (quinta_raw_mouse_active)
            quinta_drop_next_motion = 0;
        quinta_raw_events = quinta_raw_posted = 0;
        quinta_raw_last_motion_ns = quinta_input_now_ns();
        quinta_raw_core_motion_seen = 0;
        quinta_raw_have_server_time = 0;
        static int reported;
        if (wanted && !reported) {
            reported = 1;
            write_str(selected ? "[Quinta Input] mouse lock uses raw motion (XInput 2)\n"
                               : "[Quinta Input] no raw motion, mouse lock uses pointer deltas\n");
        }
    }
    int type = *(int*)event;
    double dx, dy;
    if (quinta_raw_mouse_event(display, event, &dx, &dy)) {
        if (quinta_raw_mouse_active && quinta_pointer_grabbed && (dx != 0 || dy != 0)) {
            quinta_raw_events++;
            quinta_raw_last_motion_ns = quinta_input_now_ns();
            quinta_raw_core_motion_seen = 0;
            quinta_raw_last_server_time = (unsigned int)quinta_raw_mouse_event_timestamp();
            quinta_raw_have_server_time = 1;
            quinta_accumulate_raw_motion(self, dx, dy);
            static volatile int trace = -1;
            if (quinta_env_cached("QUINTA_TRACE_LOCK", &trace) && quinta_raw_events <= 200) {
                write_str("[Quinta Lock] raw dx=");
                print_num((long long)dx);
                write_str(" dy=");
                print_num((long long)dy);
                write_str("\n");
            }
        }
        return 1;
    }
    if (type == 6 && quinta_native_motion_active && quinta_pointer_grabbed &&
        *(unsigned long*)((char*)event + 32) == quinta_capture_window) {
        /* XMotionEvent: x/y at 64/68. The pointer stays near its anchor;
         * the game gets no pointer motion during the lock. */
        int x = *(int*)((char*)event + 64), y = *(int*)((char*)event + 68);
        unsigned long serial = *(unsigned long*)((char*)event + 8);
        quinta_pointer_motion_delta(&quinta_pointer_motion,
            serial, x, y, &dx, &dy);
        /* Synthetic warp notifications do not prove the device is moving.
         * Check elapsed time only when real pointer displacement is present;
         * polling rate and the number of recenter events must not decide it. */
        unsigned long long now = quinta_input_now_ns();
        unsigned int server_time = (unsigned int)*(unsigned long*)((char*)event + 56);
        /* Ignore companions of received raw reports, including reports
         * queued before XISelectEvents took effect. An idle mouse must not
         * disable a working stream after its final core companion. */
        int unmatched = serial >= quinta_raw_selection_serial &&
            (!quinta_raw_have_server_time ||
             (int)(server_time - quinta_raw_last_server_time) > 0);
        if (quinta_raw_mouse_active && unmatched && (dx || dy)) quinta_raw_core_motion_seen = 1;
        if (quinta_raw_mouse_active && unmatched && (dx || dy) && now &&
            now >= quinta_raw_last_motion_ns &&
            now - quinta_raw_last_motion_ns >= 100000000ULL) {
            quinta_flush_raw_motion(self);
            __atomic_store_n(&quinta_raw_mouse_active, 0, __ATOMIC_RELEASE);
            quinta_raw_mouse_select(display, 0);
            write_str("[Quinta Input] no raw motion arrived, mouse lock uses pointer deltas\n");
        }
        if (!quinta_raw_mouse_active && (dx || dy))
            quinta_accumulate_raw_motion(self, dx, dy);
        int ox = x - quinta_raw_anchor_x, oy = y - quinta_raw_anchor_y;
        if (quinta_raw_have_anchor && display == quinta_capture_display &&
            __atomic_load_n(&quinta_cursor_hidden_applied, __ATOMIC_ACQUIRE) &&
            __atomic_load_n(&quinta_cursor_hidden_generation, __ATOMIC_ACQUIRE) == quinta_capture_generation &&
            *(unsigned long*)((char*)event + 32) == quinta_capture_window &&
            (ox > QUINTA_LOCK_RADIUS || ox < -QUINTA_LOCK_RADIUS ||
            oy > QUINTA_LOCK_RADIUS || oy < -QUINTA_LOCK_RADIUS ||
            quinta_lock_anchor_pending)) {
            quinta_lock(&quinta_capture_request_lock);
            quinta_lock_anchor_pending = 0;
            quinta_unlock(&quinta_capture_request_lock);
            quinta_warp_capture_pointer(quinta_raw_anchor_x, quinta_raw_anchor_y);
        }
        /* Keep Darling's previous position current even when its NSEvent is
         * suppressed, so releasing lock or falling back cannot jump. */
        quinta_update_pointer_baseline(self, event);
        return 1;
    }
    return 0;
}

static void quinta_release_mouse_capture_inner(int restore) {
    static int (*ungrab)(void*, unsigned long);
    static int (*sync)(void*, int);
    if (!ungrab) {
        ungrab = (int (*)(void*, unsigned long))dlsym(RTLD_DEFAULT, "XUngrabPointer");
        sync = (int (*)(void*, int))dlsym(RTLD_DEFAULT, "XSync");
    }
    if (quinta_pointer_grabbed && quinta_capture_display) {
        // A normal unlock restores the exact saved local pixel position.
        // Focus loss and window teardown release without stealing the pointer
        // back from another window or warping into a disappearing drawable.
        if (ungrab) ungrab(quinta_capture_display, 0 /* CurrentTime */);
        // An activation can start with the pointer outside the game. Remove
        // confinement before restoration so that saved coordinate is reachable.
        if (restore)
            quinta_warp_native_pointer(quinta_capture_display, quinta_capture_window,
                                         quinta_capture_start_x, quinta_capture_start_y);
        // Process restore/ungrab before the private worker shows the cursor.
        if (sync) sync(quinta_capture_display, 0);
        if (__sync_add_and_fetch(&quinta_associate_mouse_count, 1) <= 20)
            write_str("[Quinta Input] mouse lock off\n");
    }
    /* End the selection on its event owner, even when no further X event
     * arrives before a rapid unlock/relock. The next lock negotiates afresh. */
    if (quinta_raw_mouse_selected == 1 && quinta_capture_display)
        quinta_raw_mouse_select(quinta_capture_display, 0);
    quinta_raw_mouse_selected = 0;
    quinta_lock(&quinta_capture_request_lock);
    __atomic_store_n(&quinta_pointer_grabbed, 0, __ATOMIC_RELEASE);
    quinta_raw_mouse_wanted = 0;
    __atomic_store_n(&quinta_raw_mouse_active, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&quinta_native_motion_active, 0, __ATOMIC_RELEASE);
    quinta_pointer_motion = (QuintaPointerMotion){0};
    quinta_drop_warp_motion = quinta_drop_next_motion = 0;
    quinta_recenter_requested = 0;
    quinta_locked_cursor_position_valid = quinta_locked_cursor_position_pending = 0;
    quinta_capture_root = quinta_capture_root_height = 0;
    quinta_unlock(&quinta_capture_request_lock);
    quinta_raw_mouse_selected = -1; // a rapid relock must reapply XI2 selection
    quinta_raw_have_anchor = 0;
    quinta_capture_display = 0;
    quinta_capture_window = 0;
    quinta_capture_generation = 0;
    quinta_capture_attempted = quinta_capture_error = 0;
    quinta_lock(&quinta_window_cursor_lock);
    quinta_drag_cursor_capture(&quinta_drag_cursor,0);
    __atomic_store_n(&quinta_cursor_lock_window, 0, __ATOMIC_RELEASE);
    quinta_unlock(&quinta_window_cursor_lock);
    quinta_set_x_cursor_hidden(0);
}

static void quinta_release_mouse_capture(int restore) {
    if (pthread_main_np()) {
        quinta_release_mouse_capture_inner(restore);
        return;
    }
    quinta_lock(&quinta_capture_request_lock);
    quinta_capture_request_generation++;
    quinta_capture_request_ready = 1;
    quinta_capture_request_has_snapshot = 0;
    quinta_capture_request_no_restore = !restore;
    quinta_unlock(&quinta_capture_request_lock);
    quinta_wake_event_queue();
}

static int quinta_apply_mouse_capture_inner(int grab, int has_snapshot,
                                             unsigned int snapshot_root, int snapshot_x, int snapshot_y) {
    if (!grab) {
        if (quinta_pointer_grabbed || quinta_capture_attempted)
            quinta_release_mouse_capture_inner(1);
        return 0;
    }
    if (quinta_pointer_grabbed) {
        if (!__atomic_load_n(&quinta_cursor_worker_ready, __ATOMIC_ACQUIRE))
            quinta_start_xfixes_worker();
        return 0;
    }
    // Roblox repeats association every frame. A failed grab is retried on
    // the next lock or activation transition, without per-frame round trips.
    if (quinta_capture_attempted) return quinta_capture_error;
    quinta_capture_attempted = 1;
    quinta_capture_error = 1001; // kCGErrorFailure
    static int (*grab_pointer)(void*, unsigned long, int, unsigned int, int, int,
                               unsigned long, unsigned long, unsigned long);
    static int (*get_geometry)(void*, unsigned long, unsigned long*, int*, int*,
                               unsigned int*, unsigned int*, unsigned int*, unsigned int*);
    if (!grab_pointer) {
        grab_pointer = (int (*)(void*, unsigned long, int, unsigned int, int, int,
                                unsigned long, unsigned long, unsigned long))
            dlsym(RTLD_DEFAULT, "XGrabPointer");
        get_geometry = (int (*)(void*, unsigned long, unsigned long*, int*, int*,
                                unsigned int*, unsigned int*, unsigned int*, unsigned int*))
            dlsym(RTLD_DEFAULT, "XGetGeometry");
    }
    id window = quinta_lock_window();
    unsigned long handle = quinta_native_window_handle(window);
    void* display = handle ? quinta_native_window_display(window) : 0;
    int x, y, geometry_x, geometry_y;
    unsigned long root;
    unsigned int width, height, border, depth;
    static int (*translate)(void*, unsigned long, unsigned long, int, int, int*, int*, unsigned long*);
    if (!translate)
        translate = (int (*)(void*, unsigned long, unsigned long, int, int, int*, int*, unsigned long*))
            dlsym(RTLD_DEFAULT, "XTranslateCoordinates");
    unsigned long child;
    int positioned = has_snapshot && translate && display && handle &&
        translate(display, snapshot_root, handle, snapshot_x, snapshot_y, &x, &y, &child);
    int used_snapshot = positioned;
    if (!positioned) positioned = quinta_query_native_pointer(display, handle, &x, &y);
    if (!grab_pointer || !get_geometry || !display || !handle || !positioned ||
        !get_geometry(display, handle, &root, &geometry_x, &geometry_y, &width, &height, &border, &depth) ||
        !width || !height) {
        write_str("[Quinta Input] mouse lock unavailable: native pointer/window query failed\n");
        return quinta_capture_error;
    }
    // Button events include wheel buttons. Focus remains with the ordinary
    // keyboard owner; XGrabPointer accepts only pointer event masks here.
    unsigned int mask = (1u << 2) | (1u << 3) | (1u << 4) | (1u << 5) | (1u << 6);
    int result = grab_pointer(display, handle, 0 /* owner_events=False */, mask,
                               1 /* GrabModeAsync */, 1 /* GrabModeAsync */,
                               handle /* confine_to */, 0, 0 /* CurrentTime */);
    if (result != 0 /* GrabSuccess */) {
        write_str("[Quinta Input] XGrabPointer failed: ");
        print_num(result);
        write_str("\n");
        return quinta_capture_error;
    }
    quinta_capture_display = display;
    quinta_capture_window = handle;
    quinta_capture_start_x = x;
    quinta_capture_start_y = y;
    quinta_pointer_motion = (QuintaPointerMotion){.x = x, .y = y};
    __atomic_store_n(&quinta_native_motion_active,
        quinta_native_motion_supported(), __ATOMIC_RELEASE);
    int margin = (int)QUINTA_LOCK_RADIUS + 20;
    quinta_capture_anchor_x = width > (unsigned int)(margin * 2)
        ? (x < margin ? margin : (x > (int)width - margin ? (int)width - margin : x)) : (int)width / 2;
    quinta_capture_anchor_y = height > (unsigned int)(margin * 2)
        ? (y < margin ? margin : (y > (int)height - margin ? (int)height - margin : y)) : (int)height / 2;
    quinta_raw_anchor_x = quinta_capture_anchor_x;
    quinta_raw_anchor_y = quinta_capture_anchor_y;
    quinta_raw_have_anchor = 1;
    id platform = ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("platformWindow"));
    QuintaPoint native_start = {x, y};
    QuintaPoint frozen_window = ((QuintaPoint (*)(id, SEL, QuintaPoint))objc_msgSend)(
        platform, sel_registerName("transformPoint:"), native_start);
    QuintaPoint native_anchor = {quinta_capture_anchor_x, quinta_capture_anchor_y};
    QuintaPoint lock_anchor = ((QuintaPoint (*)(id, SEL, QuintaPoint))objc_msgSend)(
        platform, sel_registerName("transformPoint:"), native_anchor);
    SEL screen_selector = sel_registerName("mouseLocation");
    id event_class = (id)objc_getClass("NSEvent");
    QuintaPoint frozen_screen = orig_event_mouse_location
        ? orig_event_mouse_location(event_class, screen_selector)
        : ((QuintaPoint (*)(id, SEL))objc_msgSend)(event_class, screen_selector);
    int root_x = snapshot_x, root_y = snapshot_y;
    int root_positioned = used_snapshot || (translate &&
        translate(display, handle, root, x, y, &root_x, &root_y, &child));
    unsigned long root_parent;
    int root_geometry_x, root_geometry_y;
    unsigned int root_width, root_height, root_border, root_depth;
    int screen_positioned = root_positioned && get_geometry(display, root, &root_parent,
        &root_geometry_x, &root_geometry_y, &root_width, &root_height, &root_border, &root_depth);
    if (screen_positioned) {
        frozen_screen.x = root_x;
        frozen_screen.y = (double)root_height - root_y;
    }
    /* Match Roblox's getGlobalPointFromPointInView:point: exactly: it
     * subtracts screen Y from the first NSScreen frame's height. */
    id screens = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSScreen"),
                                                sel_registerName("screens"));
    double primary_height = screen_positioned ? (double)root_height : 0;
    if (screen_positioned && screens && ((unsigned long (*)(id, SEL))objc_msgSend)(
            screens, sel_registerName("count"))) {
        id first = ((id (*)(id, SEL, unsigned long))objc_msgSend)(screens,
            sel_registerName("objectAtIndex:"), 0);
        QuintaRect frame;
        /* NSRect is 32 bytes: x86_64 objc_msgSend_stret receives an explicit
         * return buffer. The ordinary dispatcher expects self in that slot. */
        ((void (*)(QuintaRect*, id, SEL))objc_msgSend_stret)(
            &frame, first, sel_registerName("frame"));
        if (__builtin_isfinite(frame.size.height) && frame.size.height >= 0 && frame.size.height <= root_height)
            primary_height = frame.size.height;
    }
    quinta_lock(&quinta_capture_request_lock);
    quinta_frozen_window_location = frozen_window;
    quinta_frozen_screen_location = frozen_screen;
    quinta_capture_root = screen_positioned ? root : 0;
    quinta_capture_root_height = screen_positioned ? root_height : 0;
    /* Roblox converts AppKit's global bottom-left coordinate using the
     * first display's frame height. Darling's AppKit instead uses the
     * entire X root height for window frames and NSEvent.mouseLocation.
     * With vertically offset outputs those heights differ. Undo that
     * difference before interpreting a Quartz warp as an X root point. */
    quinta_capture_quartz_y_offset = screen_positioned ? (double)root_height - primary_height : 0;
    quinta_lock_anchor = lock_anchor;
    quinta_lock_anchor_pending = x != quinta_capture_anchor_x || y != quinta_capture_anchor_y;
    quinta_drop_warp_motion = quinta_drop_next_motion = 0;
    quinta_raw_mouse_wanted = 1;
    __atomic_store_n(&quinta_pointer_grabbed, 1, __ATOMIC_RELEASE);
    quinta_unlock(&quinta_capture_request_lock);
    quinta_lock(&quinta_window_cursor_lock);
    quinta_cursor_lock_x = x;
    quinta_cursor_lock_y = y;
    quinta_drag_cursor_buttons(&quinta_drag_cursor,quinta_raw_buttons);
    quinta_drag_cursor_capture(&quinta_drag_cursor,1);
    quinta_capture_generation = ++quinta_cursor_lock_generation;
    __atomic_store_n(&quinta_cursor_lock_window, handle, __ATOMIC_RELEASE);
    quinta_unlock(&quinta_window_cursor_lock);
    quinta_capture_error = 0;
    quinta_set_x_cursor_hidden(1);
    if (__sync_add_and_fetch(&quinta_associate_mouse_count, 1) <= 20)
        write_str("[Quinta Input] mouse lock on (native window confined)\n");
    return 0;
}
static int quinta_apply_mouse_capture(int grab) {
    return quinta_apply_mouse_capture_inner(grab, 0, 0, 0, 0);
}

static void quinta_apply_locked_cursor_position(void) {
    quinta_lock(&quinta_capture_request_lock);
    int pending = quinta_locked_cursor_position_pending;
    QuintaPoint position = quinta_locked_cursor_position;
    unsigned long root = quinta_capture_root;
    unsigned int root_height = quinta_capture_root_height;
    double quartz_y_offset = quinta_capture_quartz_y_offset;
    if (quinta_pointer_grabbed) quinta_locked_cursor_position_pending = 0;
    quinta_unlock(&quinta_capture_request_lock);
    if (!pending || !root || !quinta_pointer_grabbed) return;
    static int (*translate)(void*, unsigned long, unsigned long, int, int, int*, int*, unsigned long*);
    if (!translate)
        translate = (int (*)(void*, unsigned long, unsigned long, int, int, int*, int*, unsigned long*))
            dlsym(RTLD_DEFAULT, "XTranslateCoordinates");
    int x, y;
    unsigned long child;
    double root_y = position.y + quartz_y_offset;
    if (!__builtin_isfinite(root_y) || root_y <= -2147483000.0 || root_y >= 2147483000.0) return;
    if (!translate || !translate(quinta_capture_display, root, quinta_capture_window,
                                 (int)position.x, (int)root_y, &x, &y, &child)) return;
    static int (*geometry)(void*, unsigned long, unsigned long*, int*, int*,
                            unsigned int*, unsigned int*, unsigned int*, unsigned int*);
    if (!geometry) geometry = (int (*)(void*, unsigned long, unsigned long*, int*, int*,
                                       unsigned int*, unsigned int*, unsigned int*, unsigned int*))
        dlsym(RTLD_DEFAULT, "XGetGeometry");
    unsigned long parent;
    int gx, gy;
    unsigned int width, height, border, depth;
    if (!geometry || !geometry(quinta_capture_display, quinta_capture_window,
                              &parent, &gx, &gy, &width, &height, &border, &depth)) return;
    /* A stale or malformed engine request must never replace the valid
     * position frozen at capture, nor put the visible overlay off-window. */
    if (x < 0 || y < 0 || x >= (int)width || y >= (int)height) {
        static unsigned int rejected;
        if (rejected++ < 8) {
            write_str("[Quinta Input] rejected mouse-lock target outside native window: x=");
            print_num(x); write_str(" y="); print_num(y); write_str("\n");
        }
        return;
    }
    id window = quinta_lock_window();
    if (quinta_native_window_handle(window) != quinta_capture_window) return;
    id platform = ((id (*)(id, SEL))objc_msgSend)(window, sel_registerName("platformWindow"));
    QuintaPoint native = {x, y};
    QuintaPoint local = ((QuintaPoint (*)(id, SEL, QuintaPoint))objc_msgSend)(
        platform, sel_registerName("transformPoint:"), native);
    quinta_lock(&quinta_capture_request_lock);
    quinta_frozen_window_location = local;
    quinta_frozen_screen_location = (QuintaPoint){position.x, (double)root_height - root_y};
    quinta_unlock(&quinta_capture_request_lock);
    quinta_lock(&quinta_window_cursor_lock);
    quinta_cursor_lock_x = x;
    quinta_cursor_lock_y = y;
    quinta_unlock(&quinta_window_cursor_lock);
    quinta_cursor_changed();
}

static void quinta_process_mouse_capture_requests(void) {
    if (!pthread_main_np()) return;
    if (quinta_pointer_grabbed && !__atomic_load_n(&quinta_cursor_worker_ready, __ATOMIC_ACQUIRE))
        quinta_start_xfixes_worker();
    quinta_lock(&quinta_capture_request_lock);
    int pending = quinta_capture_request_ready &&
        quinta_capture_request_generation != quinta_capture_processed_generation;
    int wanted = __atomic_load_n(&quinta_mouse_lock_requested, __ATOMIC_ACQUIRE) &&
        __atomic_load_n(&quinta_input_focused, __ATOMIC_ACQUIRE);
    int has_snapshot = quinta_capture_request_has_snapshot;
    unsigned int root = quinta_capture_request_root;
    int x = quinta_capture_request_x, y = quinta_capture_request_y;
    int no_restore = quinta_capture_request_no_restore;
    if (pending) quinta_capture_processed_generation = quinta_capture_request_generation;
    int recenter = quinta_recenter_requested;
    quinta_unlock(&quinta_capture_request_lock);
    if (pending) {
        if (!wanted && no_restore) quinta_release_mouse_capture_inner(0);
        else quinta_apply_mouse_capture_inner(wanted, has_snapshot, root, x, y);
    }
    quinta_apply_locked_cursor_position();
    /* At a confined edge the server can stop emitting core motion. A
     * watchdog on the event owner can still switch modes and recenter after
     * earlier physical motion proved that the raw stream was missing. */
    unsigned long long now = quinta_input_now_ns();
    if (quinta_pointer_grabbed && quinta_raw_mouse_active && quinta_raw_core_motion_seen &&
        now && now >= quinta_raw_last_motion_ns &&
        now - quinta_raw_last_motion_ns >= 100000000ULL) {
        __atomic_store_n(&quinta_raw_mouse_active, 0, __ATOMIC_RELEASE);
        quinta_raw_mouse_select(quinta_capture_display, 0);
        write_str("[Quinta Input] no raw motion arrived, mouse lock uses pointer deltas\n");
        quinta_lock_anchor_pending = 1;
    }
    if (quinta_pointer_grabbed && quinta_native_motion_active &&
        !quinta_pointer_motion.warp_pending &&
        __atomic_load_n(&quinta_cursor_hidden_applied, __ATOMIC_ACQUIRE) &&
        __atomic_load_n(&quinta_cursor_hidden_generation, __ATOMIC_ACQUIRE) == quinta_capture_generation &&
        (quinta_lock_anchor_pending ||
         quinta_pointer_motion.x - quinta_capture_anchor_x > QUINTA_LOCK_RADIUS ||
         quinta_pointer_motion.x - quinta_capture_anchor_x < -QUINTA_LOCK_RADIUS ||
         quinta_pointer_motion.y - quinta_capture_anchor_y > QUINTA_LOCK_RADIUS ||
         quinta_pointer_motion.y - quinta_capture_anchor_y < -QUINTA_LOCK_RADIUS)) {
        if (quinta_warp_capture_pointer(quinta_capture_anchor_x, quinta_capture_anchor_y))
            quinta_lock_anchor_pending = 0;
    }
    if (recenter && quinta_pointer_grabbed && !quinta_raw_mouse_active &&
        quinta_recenter_pointer_on_owner()) {
        quinta_lock(&quinta_capture_request_lock);
        quinta_recenter_requested = 0;
        quinta_lock_anchor_pending = 0;
        quinta_unlock(&quinta_capture_request_lock);
    }
}
static int quinta_CGAssociateMouseAndMouseCursorPosition(unsigned int connected) {
    if (quinta_wayland_enabled())
        return quinta_wayland_associate(connected);
    /* Persistent capture intent survives focus loss; camera drags end on
     * blur. Unlocks while suspended still cancel persistent intent. */
    int wanted = !connected;
    if (wanted && !__atomic_load_n(&quinta_input_focused, __ATOMIC_ACQUIRE))
        return 0;
    quinta_lock(&quinta_capture_request_lock);
    if (wanted && !__atomic_load_n(&quinta_input_focused, __ATOMIC_ACQUIRE)) {
        quinta_unlock(&quinta_capture_request_lock);
        return 0;
    }
    if (wanted == __atomic_load_n(&quinta_mouse_lock_requested, __ATOMIC_ACQUIRE)) {
        quinta_unlock(&quinta_capture_request_lock);
        return 0;
    }
    __atomic_store_n(&quinta_mouse_lock_requested, wanted, __ATOMIC_RELEASE);
    quinta_locked_cursor_position_valid = quinta_locked_cursor_position_pending = 0;
    unsigned long generation = ++quinta_capture_request_generation;
    quinta_capture_request_ready = !wanted;
    quinta_capture_request_has_snapshot = 0;
    quinta_capture_request_no_restore = 0;
    quinta_unlock(&quinta_capture_request_lock);
    unsigned int root = 0;
    int x = 0, y = 0;
    int sampled = wanted && __atomic_load_n(&quinta_input_focused, __ATOMIC_ACQUIRE) &&
        quinta_raw_x_pointer_snapshot(&root, &x, &y);
    if (wanted) {
        quinta_lock(&quinta_capture_request_lock);
        // An unlock or newer lock published during this snapshot wins.
        if (generation == quinta_capture_request_generation) {
            quinta_capture_request_has_snapshot = sampled;
            quinta_capture_request_root = root;
            quinta_capture_request_x = x;
            quinta_capture_request_y = y;
            quinta_capture_request_ready = 1;
        }
        quinta_unlock(&quinta_capture_request_lock);
    }
    quinta_wake_event_queue();
    return 0;
}
DYLD_INTERPOSE(quinta_CGAssociateMouseAndMouseCursorPosition,
               CGAssociateMouseAndMouseCursorPosition);

static int quinta_CGWarpMouseCursorPosition(QuintaPoint position) {
    extern int quinta_wayland_warp(QuintaPoint);
    if (quinta_wayland_enabled())
        return quinta_wayland_warp(position);
    if (__atomic_load_n(&quinta_pointer_grabbed, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&quinta_mouse_lock_requested, __ATOMIC_ACQUIRE)) {
        /* Shift lock intentionally moves its visible cursor to the center.
         * Move the logical cursor/overlay on the event owner without moving
         * the confined native pointer or replacing its unlock restoration.
         * Identical per-frame requests do not cause X queries or worker wakes.
         * Background requests must not warp the desktop after focus loss. */
        if (__atomic_load_n(&quinta_input_focused, __ATOMIC_ACQUIRE) &&
            __builtin_isfinite(position.x) && __builtin_isfinite(position.y) &&
            position.x > -2147483000.0 && position.x < 2147483000.0 &&
            position.y > -2147483000.0 && position.y < 2147483000.0) {
            quinta_lock(&quinta_capture_request_lock);
            int changed = !quinta_locked_cursor_position_valid ||
                position.x != quinta_locked_cursor_position.x || position.y != quinta_locked_cursor_position.y;
            if (changed) {
                quinta_locked_cursor_position = position;
                quinta_locked_cursor_position_valid = quinta_locked_cursor_position_pending = 1;
            }
            quinta_unlock(&quinta_capture_request_lock);
            if (changed) quinta_wake_event_queue();
        }
        return 0;
    }
    return CGWarpMouseCursorPosition(position);
}
DYLD_INTERPOSE(quinta_CGWarpMouseCursorPosition, CGWarpMouseCursorPosition);

// Returns 1 if the motion event must be dropped (it only reflects our warp).
static int quinta_filter_locked_motion_inner(QuintaPoint location, double dx, double dy);
static double (*orig_mouse_event_delta_x)(id, SEL);
static double (*orig_mouse_event_delta_y)(id, SEL);
// QUINTA_TRACE_LOCK=1: log every motion event seen during mouse lock.
static void quinta_trace_lock_motion(id event, double dx, double dy, const char* action) {
    static volatile int enabled = -1;
    if (!quinta_env_cached("QUINTA_TRACE_LOCK", &enabled))
        return;
    QuintaPoint location = quinta_real_event_location(event);
    unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("type"));
    write_str("[Quinta Lock] type=");
    print_num((long long)type);
    write_str(" dx=");
    print_num((long long)dx);
    write_str(" dy=");
    print_num((long long)dy);
    write_str(" at=");
    print_num((long long)location.x);
    write_str(",");
    print_num((long long)location.y);
    write_str(" ");
    write_str(action);
    write_str("\n");
}

static int quinta_filter_locked_motion(id event) {
    if (!__atomic_load_n(&quinta_pointer_grabbed, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&quinta_native_motion_active, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&quinta_raw_mouse_active, __ATOMIC_ACQUIRE))
        return 0;
    // Raw Darling deltas (Cocoa axes), without sign flip or sensitivity.
    SEL delta_x = sel_registerName("deltaX"), delta_y = sel_registerName("deltaY");
    double dx = orig_mouse_event_delta_x ? orig_mouse_event_delta_x(event, delta_x)
        : ((double (*)(id, SEL))objc_msgSend)(event, delta_x);
    double dy = orig_mouse_event_delta_y ? orig_mouse_event_delta_y(event, delta_y)
        : ((double (*)(id, SEL))objc_msgSend)(event, delta_y);
    QuintaPoint location = quinta_real_event_location(event);
    quinta_lock(&quinta_capture_request_lock);
    int dropping = quinta_drop_warp_motion;
    int dropped = quinta_filter_locked_motion_inner(location, dx, dy);
    int now_dropping = quinta_drop_warp_motion;
    int recenter = quinta_recenter_requested;
    quinta_unlock(&quinta_capture_request_lock);
    if (recenter) quinta_wake_event_queue();
    quinta_trace_lock_motion(event, dx, dy,
                               dropped ? "DROPPED" : (dropping && !now_dropping ? "" :
                               (now_dropping && !dropping ? "RECENTER" : "")));
    return dropped;
}

static int quinta_filter_locked_motion_inner(QuintaPoint location, double dx, double dy) {
    if (!__atomic_load_n(&quinta_pointer_grabbed, __ATOMIC_ACQUIRE) ||
        __atomic_load_n(&quinta_raw_mouse_active, __ATOMIC_ACQUIRE)) return 0;
    if (quinta_drop_warp_motion) {
        double ex = quinta_expected_warp_delta.x, ey = quinta_expected_warp_delta.y;
        double diff_sq = (dx - ex) * (dx - ex) + (dy - ey) * (dy - ey);
        double ex_sq = ex * ex + ey * ey;
        // The warp was a recentering jump of ~100px. If this motion carries the warp's jump
        // (within generous tolerance, or in the warp direction with >20% magnitude), drop it
        // so it never leaks to the camera.
        int is_warp = (diff_sq < (0.64 * ex_sq + 16.0)) ||
                      (ex != 0 && (dx * ex > 0) && (dx * dx >= 0.04 * ex * ex)) ||
                      (ey != 0 && (dy * ey > 0) && (dy * dy >= 0.04 * ey * ey));
        if (is_warp) {
            quinta_drop_warp_motion = 0;
            return 1;
        }
        // After 2 events, the warp has surely arrived or passed. Never wait 8 events,
        // which stalled recentering and let the pointer reach the screen edge.
        if (++quinta_warp_wait_events > 2)
            quinta_drop_warp_motion = 0;
    }
    if (!quinta_drop_warp_motion) {
        double ox = location.x - quinta_lock_anchor.x, oy = location.y - quinta_lock_anchor.y;
        if (quinta_lock_anchor_pending ||
            ox > QUINTA_LOCK_RADIUS || ox < -QUINTA_LOCK_RADIUS ||
                   oy > QUINTA_LOCK_RADIUS || oy < -QUINTA_LOCK_RADIUS) {
            quinta_recenter_requested = 1;
        }
    }
    return 0;
}

// macOS reports mouse motion deltaY positive downward; Darling computes it in
// Cocoa window coordinates (positive upward). Scroll events keep their sign.
// QUINTA_MOUSE_SENSITIVITY scales camera motion during mouse lock.
static double quinta_mouse_sensitivity(void) {
    static double value = -1;
    if (value < 0) {
        const char* text = getenv("QUINTA_MOUSE_SENSITIVITY");
        double parsed = 0;
        if (text && text[0]) {
            double scale = 1;
            int fraction = 0;
            for (const char* c = text; *c; c++) {
                if (*c >= '0' && *c <= '9') {
                    if (fraction) { scale /= 10; parsed += (*c - '0') * scale; }
                    else parsed = parsed * 10 + (*c - '0');
                } else if (*c == '.' || *c == ',') {
                    fraction = 1;
                }
            }
        }
        value = parsed > 0.05 && parsed < 20 ? parsed : 1.0;
    }
    return value;
}
// QUINTA_SCROLL_SENSITIVITY scales wheel delta for UI menus and scrolling.
static double quinta_scroll_sensitivity(void) {
    static double value = -1;
    if (value < 0) {
        const char* text = getenv("QUINTA_SCROLL_SENSITIVITY");
        double parsed = 0;
        if (text && text[0]) {
            double scale = 1;
            int fraction = 0;
            for (const char* c = text; *c; c++) {
                if (*c >= '0' && *c <= '9') {
                    if (fraction) { scale /= 10; parsed += (*c - '0') * scale; }
                    else parsed = parsed * 10 + (*c - '0');
                } else if (*c == '.' || *c == ',') {
                    fraction = 1;
                }
            }
        }
        value = parsed > 0.1 && parsed < 30 ? parsed : 1.5;
    }
    return value;
}
static int quinta_is_motion_type(id event) {
    unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("type"));
    return type == 5 || type == 6 || type == 7 || type == 27;
}
static int quinta_is_scroll_type(id event) {
    unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("type"));
    return type == 22; // NSScrollWheel
}
static double (*orig_mouse_event_delta_x)(id, SEL) = 0;
static double hooked_mouse_event_delta_x(id self, SEL cmd) {
    double delta = orig_mouse_event_delta_x(self, cmd);
    if ((quinta_pointer_grabbed || quinta_wayland_captured()) && quinta_is_motion_type(self))
        return delta * quinta_mouse_sensitivity();
    if (quinta_is_scroll_type(self))
        return delta * quinta_scroll_sensitivity();
    return delta;
}
static double (*orig_mouse_event_delta_y)(id, SEL) = 0;
static double hooked_mouse_event_delta_y(id self, SEL cmd) {
    double delta = orig_mouse_event_delta_y(self, cmd);
    if (quinta_is_scroll_type(self))
        return delta * quinta_scroll_sensitivity();
    if (!quinta_is_motion_type(self))
        return delta;
    delta = -delta;
    return (quinta_pointer_grabbed || quinta_wayland_captured()) ? delta * quinta_mouse_sensitivity() : delta;
}

// Scroll wheel APIs missing from Darling's NSEvent. X11 wheels report coarse
// line deltas; macOS reports pixels for the same events (about 10 px per
// line). Roblox's Universal App menu scrolls on the pixel deltas only, so
// with line-scale values the wheel appeared dead there.
#define QUINTA_SCROLL_LINE_PIXELS 25.0
static QuintaBool event_has_precise_scrolling_deltas(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 1;
}
static QuintaBool event_is_direction_inverted(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}
static double event_scrolling_delta_x(id self, SEL cmd) {
    (void)cmd;
    double d = ((double (*)(id, SEL))objc_msgSend)(self, sel_registerName("deltaX"));
    return d * QUINTA_SCROLL_LINE_PIXELS;
}
static double event_scrolling_delta_y(id self, SEL cmd) {
    (void)cmd;
    double d = ((double (*)(id, SEL))objc_msgSend)(self, sel_registerName("deltaY"));
    return d * QUINTA_SCROLL_LINE_PIXELS;
}

// Darling's -[X11Cursor initWithImage:hotPoint:] copies each pixel row with a
// wrong source offset, so custom cursors show shifted rows and bytes read past
// the bitmap (the bright pink/blue fringe). Rebuild the Xcursor image here.
typedef struct {
    unsigned int version, size, width, height, xhot, yhot, delay;
    unsigned int* pixels;
} QuintaXcursorImage;
typedef struct objc_ivar* Ivar;
extern Ivar class_getInstanceVariable(Class, const char*);
extern long ivar_getOffset(Ivar);

/* Darling caches a failed CGLGetWindow result while keeping its CGSubWindow.
 * The next update only resizes that subwindow, leaving a blank window forever.
 * Retry a mapped native Wayland drawable on the AppKit owner, with a finite
 * budget and backoff. Valid surfaces never enter the repair path. */
extern void* CGLGetWindow(void*);
extern int quinta_wayland_enabled(void);
static void (*orig_gl_update_view_parameters)(id, SEL);
static long quinta_gl_subwindow_offset, quinta_gl_window_offset;
static unsigned long long quinta_input_now_ns(void);
static void quinta_recover_gl_drawable(id self, int scheduled) {
    if (!quinta_wayland_enabled() || !pthread_main_np()) return;
    void** surface = (void**)((char*)self + quinta_gl_window_offset);
    id child = *(id*)((char*)self + quinta_gl_subwindow_offset);
    if (*surface || !child) return;
    void* native = ((void* (*)(id, SEL))objc_msgSend)(child, sel_registerName("nativeWindow"));
    if (!native) return;
    static struct { id owner; void* native; unsigned attempts; unsigned long long next; } retries[64];
    static unsigned replace;
    int slot = -1;
    for (int i = 0; i < 64; i++)
        if (retries[i].owner == self) { slot = i; break; }
    if (slot < 0) slot = (int)(replace++ % 64);
    if (retries[slot].owner != self || retries[slot].native != native) {
        retries[slot].owner = self;
        retries[slot].native = native;
        retries[slot].attempts = 0;
        retries[slot].next = 0;
    }
    unsigned long long now = quinta_input_now_ns();
    if (retries[slot].attempts >= 12 || (!scheduled && now < retries[slot].next)) return;
    retries[slot].attempts++;
    retries[slot].next = now + 100000000ULL;
    void* recovered = CGLGetWindow(native);
    __atomic_store_n(surface, recovered, __ATOMIC_RELEASE);
    SEL retry = sel_registerName("_ciderRetryWaylandDrawable:");
    ((void (*)(id, SEL, id, SEL, id))objc_msgSend)((id)objc_getClass("NSObject"),
        sel_registerName("cancelPreviousPerformRequestsWithTarget:selector:object:"), self, retry, (id)0);
    if (recovered) write_str("[Quinta Wayland] Recovered an initially unavailable EGL drawable\n");
    else if (retries[slot].attempts == 12)
        write_str("[Quinta Wayland] EGL drawable remains unavailable after retries; use X11 / Xwayland and send the complete launch log\n");
    else ((void (*)(id, SEL, SEL, id, double))objc_msgSend)(self,
        sel_registerName("performSelector:withObject:afterDelay:"), retry, (id)0, 0.1);
}
static void quinta_retry_gl_drawable(id self, SEL cmd, id unused) {
    (void)cmd; (void)unused;
    /* A pending selector retains the context and its subwindow. Do not touch
     * _view here: it is a weak reference that may have disappeared on close. */
    quinta_recover_gl_drawable(self, 1);
}
static void hooked_gl_update_view_parameters(id self, SEL cmd) {
    orig_gl_update_view_parameters(self, cmd);
    quinta_recover_gl_drawable(self, 0);
}
static void quinta_attach_recovered_gl_drawable(void* context) {
    if (!orig_gl_update_view_parameters || !quinta_wayland_enabled() || quinta_cgl_egl_surface(context)) return;
    id current = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSOpenGLContext"),
                                               sel_registerName("currentContext"));
    if (!current || ((void* (*)(id, SEL))objc_msgSend)(current, sel_registerName("CGLContextObj")) != context) return;
    void* surface = __atomic_load_n((void**)((char*)current + quinta_gl_window_offset), __ATOMIC_ACQUIRE);
    if (!surface) return;
    /* Bind on the rendering thread, rather than making the renderer's EGL
     * context current on the timer/main thread. Failed binds are bounded. */
    static struct { id owner; void* surface; unsigned attempts; } bindings[64];
    static unsigned replace;
    static volatile unsigned int binding_lock;
    quinta_lock(&binding_lock);
    int slot = -1;
    for (int i = 0; i < 64; i++) if (bindings[i].owner == current) { slot = i; break; }
    if (slot < 0) slot = (int)(replace++ % 64);
    if (bindings[slot].owner != current || bindings[slot].surface != surface) {
        bindings[slot].owner = current; bindings[slot].surface = surface; bindings[slot].attempts = 0;
    }
    int allowed = bindings[slot].attempts < 4;
    if (allowed) bindings[slot].attempts++;
    quinta_unlock(&binding_lock);
    if (allowed && !quinta_CGLContextMakeCurrentAndAttachToWindow(context, surface))
        write_str("[Quinta Wayland] Attached recovered drawable on the rendering thread\n");
}
extern void* objc_autoreleasePoolPush(void);
extern void objc_autoreleasePoolPop(void*);
extern void* CGColorSpaceCreateDeviceRGB(void);
extern void CGColorSpaceRelease(void*);
extern void* CGBitmapContextCreate(void*, unsigned long, unsigned long,
                                   unsigned long, unsigned long, void*,
                                   unsigned int);
extern void* CGBitmapContextGetData(void*);
extern unsigned long CGBitmapContextGetBytesPerRow(void*);
extern void CGContextRelease(void*);

extern unsigned long CGImageGetWidth(void*);
extern unsigned long CGImageGetHeight(void*);
extern unsigned long CGImageGetBitsPerComponent(void*);
extern unsigned long CGImageGetBitsPerPixel(void*);
extern unsigned long CGImageGetBytesPerRow(void*);
extern unsigned int CGImageGetBitmapInfo(void*);
extern void* CGImageGetDataProvider(void*);
extern void* CGDataProviderCopyData(void*);
extern const unsigned char* CFDataGetBytePtr(void*);
extern long CFDataGetLength(void*);
extern void CFRelease(const void*);

// Read the cursor image's own pixels instead of drawing it through Darling,
// whose compositing corrupts channels of semi-transparent pixels. Returns an
// Xcursor-style premultiplied ARGB buffer (caller frees), or 0 if the format
// is not a plain 8-bit RGB(A) layout.
unsigned int* quinta_cursor_pixels_from_image(
    id image, unsigned long* width_out, unsigned long* height_out) {
    id reps = ((id (*)(id, SEL))objc_msgSend)(image, sel_registerName("representations"));
    unsigned long rep_count = reps
        ? ((unsigned long (*)(id, SEL))objc_msgSend)(reps, sel_registerName("count")) : 0;
    void* cg_image = 0;
    for (unsigned long index = 0; index < rep_count && !cg_image; index++) {
        id rep = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
            reps, sel_registerName("objectAtIndex:"), index);
        if (((QuintaBool (*)(id, SEL, SEL))objc_msgSend)(
                rep, sel_registerName("respondsToSelector:"), sel_registerName("CGImage")))
            cg_image = ((void* (*)(id, SEL))objc_msgSend)(rep, sel_registerName("CGImage"));
    }
    if (!cg_image)
        return 0;
    unsigned long width = CGImageGetWidth(cg_image);
    unsigned long height = CGImageGetHeight(cg_image);
    unsigned long bits_per_pixel = CGImageGetBitsPerPixel(cg_image);
    unsigned long bytes_per_row = CGImageGetBytesPerRow(cg_image);
    unsigned int info = CGImageGetBitmapInfo(cg_image);
    unsigned int alpha_info = info & 0x1FU;
    unsigned int byte_order = info & 0x7000U;
    static volatile long described;
    if (__sync_add_and_fetch(&described, 1) <= 4) {
        write_str("[Quinta Cursor] source ");
        print_num((long long)width);
        write_str("x");
        print_num((long long)height);
        write_str(" bpp=");
        print_num((long long)bits_per_pixel);
        write_str(" bpc=");
        print_num((long long)CGImageGetBitsPerComponent(cg_image));
        write_str(" alpha-info=");
        print_num(alpha_info);
        write_str(" byte-order=");
        print_hex(byte_order);
        write_str("\n");
    }
    if (!width || !height || width > 512 || height > 512 ||
        CGImageGetBitsPerComponent(cg_image) != 8 ||
        (bits_per_pixel != 32 && bits_per_pixel != 24) ||
        (byte_order != 0 && byte_order != 0x2000U && byte_order != 0x4000U))
        return 0;
    void* provider = CGImageGetDataProvider(cg_image);
    void* data = provider ? CGDataProviderCopyData(provider) : 0;
    if (!data)
        return 0;
    const unsigned char* bytes = CFDataGetBytePtr(data);
    if ((unsigned long)CFDataGetLength(data) < bytes_per_row * (height - 1) +
                                                   width * (bits_per_pixel / 8)) {
        CFRelease(data);
        return 0;
    }
    unsigned int* pixels = (unsigned int*)malloc(width * height * 4);
    if (!pixels) {
        CFRelease(data);
        return 0;
    }
    int alpha_first = alpha_info == 2 || alpha_info == 4 || alpha_info == 6;
    int has_alpha = alpha_info >= 1 && alpha_info <= 4;
    int premultiplied = alpha_info == 1 || alpha_info == 2;
    for (unsigned long row = 0; row < height; row++) {
        const unsigned char* source = bytes + row * bytes_per_row;
        for (unsigned long column = 0; column < width; column++) {
            unsigned int c[4] = {0, 0, 0, 0};
            if (bits_per_pixel == 24) {
                c[0] = source[column * 3];
                c[1] = source[column * 3 + 1];
                c[2] = source[column * 3 + 2];
                c[3] = 255;
            } else {
                const unsigned char* pixel = source + column * 4;
                // Logical component order, most significant first.
                unsigned char word[4];
                if (byte_order == 0x2000U) {
                    word[0] = pixel[3]; word[1] = pixel[2];
                    word[2] = pixel[1]; word[3] = pixel[0];
                } else {
                    word[0] = pixel[0]; word[1] = pixel[1];
                    word[2] = pixel[2]; word[3] = pixel[3];
                }
                if (alpha_first) {
                    c[3] = word[0]; c[0] = word[1]; c[1] = word[2]; c[2] = word[3];
                } else {
                    c[0] = word[0]; c[1] = word[1]; c[2] = word[2]; c[3] = word[3];
                }
                if (!has_alpha)
                    c[3] = 255;
            }
            if (!premultiplied) {
                for (int channel = 0; channel < 3; channel++)
                    c[channel] = c[channel] * c[3] / 255;
            }
            // Even malformed premultiplied images must have transparent RGB
            // cleared and each color bounded by alpha before compositing.
            for (int channel = 0; channel < 3; channel++)
                if (c[channel] > c[3]) c[channel] = c[3];
            pixels[row * width + column] =
                (c[3] << 24) | (c[0] << 16) | (c[1] << 8) | c[2];
        }
    }
    CFRelease(data);
    *width_out = width;
    *height_out = height;
    return pixels;
}

static id (*orig_x11_cursor_init_image)(id, SEL, id, QuintaPoint) = 0;
static id hooked_x11_cursor_init_image(id self, SEL cmd, id image,
                                       QuintaPoint hot) {
    QuintaXcursorImage* (*image_create)(int, int) =
        (QuintaXcursorImage* (*)(int, int))
            dlsym(RTLD_DEFAULT, "XcursorImageCreate");
    void (*image_destroy)(QuintaXcursorImage*) =
        (void (*)(QuintaXcursorImage*))
            dlsym(RTLD_DEFAULT, "XcursorImageDestroy");
    unsigned long (*load_cursor)(void*, const QuintaXcursorImage*) =
        (unsigned long (*)(void*, const QuintaXcursorImage*))
            dlsym(RTLD_DEFAULT, "XcursorImageLoadCursor");
    Ivar cursor_ivar = class_getInstanceVariable(object_getClass(self), "_cursor");
    QuintaSize size = image
        ? ((QuintaSize (*)(id, SEL))objc_msgSend)(image, sel_registerName("size"))
        : (QuintaSize){0, 0};
    unsigned long width = (unsigned long)size.width;
    unsigned long height = (unsigned long)size.height;
    if (!image_create || !image_destroy || !load_cursor || !cursor_ivar ||
        !width || !height || width > 512 || height > 512)
        return orig_x11_cursor_init_image(self, cmd, image, hot);

    unsigned long source_width = 0, source_height = 0;
    unsigned int* source_pixels =
        quinta_cursor_pixels_from_image(image, &source_width, &source_height);
    if (source_pixels) {
        id direct_display_object = ((id (*)(id, SEL))objc_msgSend)(
            (id)objc_getClass("NSDisplay"), sel_registerName("currentDisplay"));
        void* direct_display = direct_display_object
            ? ((void* (*)(id, SEL))objc_msgSend)(direct_display_object,
                                                  sel_registerName("display"))
            : 0;
        QuintaXcursorImage* direct = direct_display
            ? image_create((int)source_width, (int)source_height) : 0;
        if (direct) {
            for (unsigned long index = 0; index < source_width * source_height; index++)
                direct->pixels[index] = source_pixels[index];
            // The hot spot is given in image points; the bitmap may be larger.
            double scale_x = (double)source_width / (double)width;
            double scale_y = (double)source_height / (double)height;
            double hot_x = hot.x * scale_x, hot_y = hot.y * scale_y;
            direct->xhot = hot_x < 0 ? 0 : (hot_x >= source_width ? source_width - 1 : (unsigned int)hot_x);
            direct->yhot = hot_y < 0 ? 0 : (hot_y >= source_height ? source_height - 1 : (unsigned int)hot_y);
            unsigned long direct_cursor = load_cursor(direct_display, direct);
            image_destroy(direct);
            if (direct_cursor) {
                free(source_pixels);
                *(unsigned long*)((char*)self + ivar_getOffset(cursor_ivar)) = direct_cursor;
                return self;
            }
        }
        free(source_pixels);
    }

    id display_object = ((id (*)(id, SEL))objc_msgSend)(
        (id)objc_getClass("NSDisplay"), sel_registerName("currentDisplay"));
    void* display = display_object
        ? ((void* (*)(id, SEL))objc_msgSend)(display_object, sel_registerName("display"))
        : 0;
    QuintaXcursorImage* ximage = display ? image_create((int)width, (int)height) : 0;
    void* color_space = ximage ? CGColorSpaceCreateDeviceRGB() : 0;
    // Premultiplied ARGB in host byte order, the XcursorPixel format.
    void* bitmap = color_space
        ? CGBitmapContextCreate(0, width, height, 8, 0, color_space,
                                2U /* PremultipliedFirst */ | 0x2000U /* 32Little */)
        : 0;
    if (color_space)
        CGColorSpaceRelease(color_space);
    if (!bitmap) {
        if (ximage)
            image_destroy(ximage);
        return orig_x11_cursor_init_image(self, cmd, image, hot);
    }

    void* pool = objc_autoreleasePoolPush();
    id context_class = (id)objc_getClass("NSGraphicsContext");
    id graphics = ((id (*)(id, SEL, void*, QuintaBool))objc_msgSend)(
        context_class, sel_registerName("graphicsContextWithGraphicsPort:flipped:"),
        bitmap, 0);
    ((void (*)(id, SEL))objc_msgSend)(context_class, sel_registerName("saveGraphicsState"));
    ((void (*)(id, SEL, id))objc_msgSend)(
        context_class, sel_registerName("setCurrentContext:"), graphics);
    QuintaRect destination = {{0, 0}, {(double)width, (double)height}};
    QuintaRect whole_image = {{0, 0}, {0, 0}};
    ((void (*)(id, SEL, QuintaRect, QuintaRect, unsigned long, double))objc_msgSend)(
        image, sel_registerName("drawInRect:fromRect:operation:fraction:"),
        destination, whole_image, 1UL /* NSCompositeCopy */, 1.0);
    ((void (*)(id, SEL))objc_msgSend)(context_class, sel_registerName("restoreGraphicsState"));
    objc_autoreleasePoolPop(pool);

    const unsigned char* rows = (const unsigned char*)CGBitmapContextGetData(bitmap);
    unsigned long bytes_per_row = CGBitmapContextGetBytesPerRow(bitmap);
    for (unsigned long row = 0; row < height; row++) {
        const unsigned int* source = (const unsigned int*)(rows + row * bytes_per_row);
        for (unsigned long column = 0; column < width; column++)
            ximage->pixels[row * width + column] = source[column];
    }
    CGContextRelease(bitmap);

    // Xcursor expects premultiplied ARGB. Darling's image drawing can leave
    // straight alpha, which shows up as a bright fringe on soft edges. A
    // channel above its alpha is impossible when premultiplied, so use that
    // to detect the format and premultiply only in that case.
    unsigned long pixel_count = width * height;
    int straight_alpha = 0;
    for (unsigned long index = 0; index < pixel_count && !straight_alpha; index++) {
        unsigned int pixel = ximage->pixels[index];
        unsigned int alpha = pixel >> 24;
        if (((pixel >> 16) & 255) > alpha || ((pixel >> 8) & 255) > alpha ||
            (pixel & 255) > alpha)
            straight_alpha = 1;
    }
    if (straight_alpha) {
        for (unsigned long index = 0; index < pixel_count; index++) {
            unsigned int pixel = ximage->pixels[index];
            unsigned int alpha = pixel >> 24;
            unsigned int red = ((pixel >> 16) & 255) * alpha / 255;
            unsigned int green = ((pixel >> 8) & 255) * alpha / 255;
            unsigned int blue = (pixel & 255) * alpha / 255;
            ximage->pixels[index] = (alpha << 24) | (red << 16) | (green << 8) | blue;
        }
    }
    static volatile long dumped_cursors;
    long dump_index = __sync_add_and_fetch(&dumped_cursors, 1) - 1;
    if (dump_index < 4) {
        write_str("[Quinta Cursor] #");
        print_num(dump_index);
        write_str(" size=");
        print_num((long long)width);
        write_str("x");
        print_num((long long)height);
        write_str(straight_alpha ? " straight-alpha (premultiplied now)\n"
                                 : " already premultiplied\n");
    }

    ximage->xhot = hot.x < 0 ? 0 : (hot.x >= width ? width - 1 : (unsigned int)hot.x);
    ximage->yhot = hot.y < 0 ? 0 : (hot.y >= height ? height - 1 : (unsigned int)hot.y);
    unsigned long cursor = load_cursor(display, ximage);
    image_destroy(ximage);
    if (!cursor)
        return orig_x11_cursor_init_image(self, cmd, image, hot);
    *(unsigned long*)((char*)self + ivar_getOffset(cursor_ivar)) = cursor;

    return self;
}

/* Creating a cursor does not select it. This backend setter is reached by
 * NSCursor set/push/pop, hide/unhide and cursor-rectangle resets, so both
 * image construction paths and named/blank cursors follow the same policy. */
static void (*orig_x11_display_set_cursor)(id, SEL, id);
static void hooked_x11_display_set_cursor(id self, SEL cmd, id cursor) {
    unsigned long handle = quinta_native_window_handle(quinta_lock_window());
    orig_x11_display_set_cursor(self, cmd, cursor);
    if (!handle)
        return;
    Ivar cursor_ivar = cursor ? class_getInstanceVariable(object_getClass(cursor), "_cursor") : 0;
    if (cursor && !cursor_ivar)
        return;
    unsigned long selected_cursor = cursor
        ? *(unsigned long*)((char*)cursor + ivar_getOffset(cursor_ivar)) : 0;
    quinta_lock(&quinta_window_cursor_lock);
    int image_changed = quinta_window_cursor_selection.window != handle ||
        quinta_window_cursor_selection.cursor != selected_cursor ||
        quinta_window_cursor_selection.owner != cursor;
    quinta_unlock(&quinta_window_cursor_lock);
    if (image_changed) {
        id current = ((id (*)(id, SEL))objc_msgSend)(
            (id)objc_getClass("NSCursor"), sel_registerName("currentCursor"));
        Ivar platform_ivar = current ? class_getInstanceVariable(object_getClass(current), "_platformCursor") : 0;
        id image = platform_ivar && *(id*)((char*)current + ivar_getOffset(platform_ivar)) == cursor
            ? ((id (*)(id, SEL))objc_msgSend)(current, sel_registerName("image")) : 0;
        unsigned long width = 0, height = 0;
        unsigned int *pixels = image ? quinta_cursor_pixels_from_image(image, &width, &height) : 0;
        QuintaPoint hot = image
            ? ((QuintaPoint (*)(id, SEL))objc_msgSend)(current, sel_registerName("hotSpot")) : (QuintaPoint){0, 0};
        QuintaSize logical = image
            ? ((QuintaSize (*)(id, SEL))objc_msgSend)(image, sel_registerName("size")) : (QuintaSize){0, 0};
        double x = logical.width > 0 ? hot.x * width / logical.width : 0;
        double y = logical.height > 0 ? hot.y * height / logical.height : 0;
        quinta_cursor_overlay_select_image(selected_cursor, pixels, (unsigned int)width, (unsigned int)height,
            __builtin_isfinite(x) && x >= 0 && x < width ? (unsigned int)x : 0,
            __builtin_isfinite(y) && y >= 0 && y < height ? (unsigned int)y : 0);
        free(pixels);
    }
    if (cursor)
        ((id (*)(id, SEL))objc_msgSend)(cursor, sel_registerName("retain"));
    quinta_lock(&quinta_window_cursor_lock);
    id previous = (id)quinta_window_cursor_selection.owner;
    int changed = quinta_cursor_selection_set(&quinta_window_cursor_selection,
                                                handle, selected_cursor, cursor);
    int pending = quinta_window_cursor_selection.dirty;
    quinta_unlock(&quinta_window_cursor_lock);
    id release = changed ? previous : cursor;
    if (release)
        ((void (*)(id, SEL))objc_msgSend)(release, sel_registerName("release"));
    if (pending) {
        quinta_start_xfixes_worker();
        if (__atomic_load_n(&quinta_cursor_worker_ready, __ATOMIC_ACQUIRE))
            quinta_wake_worker(quinta_cursor_wake[1]);
    }
}

// Darling stubs +[NSEvent addLocalMonitorForEventsMatchingMask:handler:].
// Roblox installs local monitors for its input, so implement them the macOS
// way: -[NSApplication sendEvent:] passes each matching event to the handlers
// first; a handler may replace the event or return nil to consume it.
struct QuintaBlock {
    void* isa;
    int flags;
    int reserved;
    id (*invoke)(void*, id);
};
extern void* _Block_copy(const void*);
extern void _Block_release(const void*);
#define QUINTA_MAX_MONITORS 32
static struct {
    unsigned long long mask;
    struct QuintaBlock* block;
} quinta_monitors[QUINTA_MAX_MONITORS];
static volatile int quinta_monitor_lock;

static id event_add_local_monitor(id cls, SEL cmd, unsigned long long mask,
                                  void* handler) {
    (void)cls; (void)cmd;
    if (!handler)
        return 0;
    struct QuintaBlock* block = (struct QuintaBlock*)_Block_copy(handler);
    while (!__sync_bool_compare_and_swap(&quinta_monitor_lock, 0, 1)) {}
    int stored = 0;
    for (int index = 0; index < QUINTA_MAX_MONITORS && !stored; index++) {
        if (!quinta_monitors[index].block) {
            quinta_monitors[index].mask = mask;
            quinta_monitors[index].block = block;
            stored = 1;
        }
    }
    __sync_lock_release(&quinta_monitor_lock);
    write_str("[Quinta Input] addLocalMonitorForEventsMatchingMask mask=");
    print_hex(mask);
    write_str(stored ? "\n" : " (table full, ignored)\n");
    if (!stored) {
        _Block_release(block);
        return 0;
    }
    return (id)block;
}

static void event_remove_monitor(id cls, SEL cmd, id monitor) {
    (void)cls; (void)cmd;
    if (!monitor)
        return;
    while (!__sync_bool_compare_and_swap(&quinta_monitor_lock, 0, 1)) {}
    for (int index = 0; index < QUINTA_MAX_MONITORS; index++) {
        if (quinta_monitors[index].block == (struct QuintaBlock*)monitor) {
            quinta_monitors[index].block = 0;
            quinta_monitors[index].mask = 0;
            __sync_lock_release(&quinta_monitor_lock);
            _Block_release(monitor);
            return;
        }
    }
    __sync_lock_release(&quinta_monitor_lock);
}

// Keyboard state for CGEventSourceKeyState, which Darling lacks and Roblox
// polls in game. Built from the key events AppKit dispatches, and cleared
// when the window loses the keyboard (hooked_post_x_event): X sends the key
// releases to whoever has it then, so a key held during Alt+Tab stayed
// "down" (the character kept walking).
static volatile unsigned char quinta_key_down[128];
extern int quinta_wayland_key_transition(id);
extern int quinta_wayland_dispatch_event(id);
static void quinta_track_key_event(id event, unsigned long type) {
    if (type != 10 && type != 11 && type != 12) // keyDown, keyUp, flagsChanged
        return;
    unsigned short key = ((unsigned short (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("keyCode"));
    if (key >= 128)
        return;
    int transition = quinta_wayland_key_transition(event);
    if (transition) {
        // Explicit transitions distinguish left/right modifiers even when
        // the other Ctrl/Shift key remains held during flagsChanged.
        quinta_key_down[key] = transition == 1;
        return;
    }
    if (type != 12) {
        quinta_key_down[key] = type == 10;
        return;
    }
    unsigned long flags = ((unsigned long (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("modifierFlags"));
    unsigned long bit = 0;
    switch (key) {
    case 56: case 60: bit = 1UL << 17; break; // shift
    case 59: case 62: bit = 1UL << 18; break; // control
    case 58: case 61: bit = 1UL << 19; break; // option
    case 55: case 54: bit = 1UL << 20; break; // command
    case 57: bit = 1UL << 16; break;          // caps lock
    default: return;
    }
    quinta_key_down[key] = (flags & bit) != 0;
}
unsigned char CGEventSourceKeyState(int state_id, unsigned short key) {
    (void)state_id;
    return key < 128 ? quinta_key_down[key] : 0;
}

static int quinta_trace_keys_enabled(void);
static void (*orig_app_send_event)(id, SEL, id) = 0;
static void hooked_app_send_event(id self, SEL cmd, id event) {
    if (event) {
        if (quinta_wayland_dispatch_event(event))
            return;
        unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
            event, sel_registerName("type"));
        quinta_track_key_event(event, type);
        if ((type == 10 || type == 11) && quinta_trace_keys_enabled()) {
            write_str(type == 10 ? "[Quinta Keys] game keyDown code=" : "[Quinta Keys] game keyUp   code=");
            print_num(((unsigned short (*)(id, SEL))objc_msgSend)(event, sel_registerName("keyCode")));
            write_str(((signed char (*)(id, SEL))objc_msgSend)(event, sel_registerName("isARepeat")) ? " repeat\n" : "\n");
        }
        if ((type == 5 || type == 6 || type == 7 || type == 27) &&
            quinta_filter_locked_motion(event))
            return;
        unsigned long long event_mask = type < 64 ? 1ULL << type : 0;
        struct QuintaBlock* handlers[QUINTA_MAX_MONITORS];
        int handler_count = 0;
        while (!__sync_bool_compare_and_swap(&quinta_monitor_lock, 0, 1)) {}
        for (int index = 0; index < QUINTA_MAX_MONITORS; index++) {
            if (quinta_monitors[index].block &&
                (quinta_monitors[index].mask & event_mask))
                // A reference of our own: a handler may remove a monitor
                // (and free its block) while the others still run.
                handlers[handler_count++] = (struct QuintaBlock*)_Block_copy(quinta_monitors[index].block);
        }
        __sync_lock_release(&quinta_monitor_lock);
        for (int index = 0; index < handler_count; index++) {
            if (event)
                event = handlers[index]->invoke(handlers[index], event);
            _Block_release(handlers[index]);
        }
        if (!event)
            return;
    }
    orig_app_send_event(self, cmd, event);
}

// Darling drops pointer motion unless the window accepts mouse-moved events.
// On macOS Roblox receives motion through tracking areas instead, which
// Darling does not deliver here, so the Roblox window always accepts them.
static QuintaBool (*orig_window_accepts_mouse_moved)(id, SEL) = 0;
static QuintaBool hooked_window_accepts_mouse_moved(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 1;
}

// The launcher ends the session as soon as the user asks to quit (the quit
// sentinel; see quinta_write_quit_sentinel). Closing the game window is
// that ask: Roblox's own teardown would otherwise keep the process alive
// for seconds after the window is gone, with the launcher still waiting.
static void (*orig_window_close)(id, SEL) = 0;
static void hooked_window_close(id self, SEL cmd) {
    const char* class_name = object_getClassName(self);
    if (class_name && ascii_strings_equal(class_name, "RBXWindow")) {
        __atomic_store_n(&quinta_mouse_lock_requested, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&quinta_input_focused, 0, __ATOMIC_RELEASE);
        quinta_release_mouse_capture(0);
        quinta_write_quit_sentinel();
    }
    if (orig_window_close)
        orig_window_close(self, cmd);
}
static void (*orig_window_perform_close)(id, SEL, id) = 0;
static void hooked_window_perform_close(id self, SEL cmd, id sender) {
    const char* class_name = object_getClassName(self);
    if (class_name && ascii_strings_equal(class_name, "RBXWindow")) {
        __atomic_store_n(&quinta_mouse_lock_requested, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&quinta_input_focused, 0, __ATOMIC_RELEASE);
        quinta_release_mouse_capture(0);
        quinta_write_quit_sentinel();
    }
    if (orig_window_perform_close)
        orig_window_perform_close(self, cmd, sender);
}

// Darling's NSWindow keeps one mouse-down location for all buttons and sets it
// to NaN whenever any button goes up. AppKit hit-tests that location to find
// the view for drags and for the matching up event. A left click during a
// right-button camera drag therefore left nothing to hit: the game never saw
// the right button go up and kept turning the camera until the menu opened.
// While the other button is still held, put the location back after its up.
static unsigned int quinta_window_buttons_down; // bit 0 left, bit 1 right
static void quinta_window_track_button(id self, unsigned long type, id event,
                                         void (*dispatch)(id, SEL, id), SEL cmd) {
    static long offset = -2;
    if (offset == -2) {
        Ivar ivar = class_getInstanceVariable(objc_getClass("NSWindow"), "_mouseDownLocationInWindow");
        offset = ivar ? ivar_getOffset(ivar) : -1;
    }
    unsigned int button = (type == 1 || type == 2) ? 1u : 2u;
    if (type == 1 || type == 3) {
        quinta_window_buttons_down |= button;
        dispatch(self, cmd, event);
        return;
    }
    quinta_window_buttons_down &= ~button;
    QuintaPoint* location = offset >= 0 ? (QuintaPoint*)((char*)self + offset) : 0;
    QuintaPoint kept = location ? *location : (QuintaPoint){0, 0};
    dispatch(self, cmd, event);
    if (location && quinta_window_buttons_down)
        *location = kept;
}

// Darling's NSWindow sendEvent: has no case for NSOtherMouseDown/Up/Dragged.
// It reports an unimplemented method and drops them, so the middle button and
// the side buttons never reached Roblox. Deliver them as it does the left and
// right buttons: a press to the view under the pointer, drags and the release
// to the view the first press landed on, and no drag without a press.
static unsigned int quinta_other_buttons_down;
static QuintaPoint quinta_other_mouse_location;
static void quinta_window_other_mouse(id self, unsigned long type, id event) {
    static long offset = -2;
    if (offset == -2) {
        Ivar ivar = class_getInstanceVariable(objc_getClass("NSWindow"), "_backgroundView");
        offset = ivar ? ivar_getOffset(ivar) : -1;
    }
    long number = ((long (*)(id, SEL))objc_msgSend)(event, sel_registerName("buttonNumber"));
    unsigned int bit = number >= 0 && number < 32 ? 1u << number : 0;
    QuintaPoint location = ((QuintaPoint (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("locationInWindow"));
    SEL selector;
    if (type == 25) {
        selector = sel_registerName("otherMouseDown:");
        if (!quinta_other_buttons_down)
            quinta_other_mouse_location = location;
        else
            location = quinta_other_mouse_location;
        quinta_other_buttons_down |= bit;
    } else {
        selector = sel_registerName(type == 26 ? "otherMouseUp:" : "otherMouseDragged:");
        if (quinta_other_buttons_down)
            location = quinta_other_mouse_location;
        else if (type == 27)
            return;
        if (type == 26)
            quinta_other_buttons_down &= ~bit;
    }
    id root = offset >= 0 ? *(id*)((char*)self + offset) : 0;
    if (!root) {
        id content = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("contentView"));
        id superview = content ? ((id (*)(id, SEL))objc_msgSend)(
            content, sel_registerName("superview")) : 0;
        root = superview ? superview : content;
    }
    id hit = root ? ((id (*)(id, SEL, QuintaPoint))objc_msgSend)(
        root, sel_registerName("hitTest:"), location) : 0;
    if (hit && ((signed char (*)(id, SEL, SEL))objc_msgSend)(
            hit, sel_registerName("respondsToSelector:"), selector)) {
        ((id (*)(id, SEL))objc_msgSend)(hit, sel_registerName("retain"));
        ((void (*)(id, SEL, id))objc_msgSend)(hit, selector, event);
        ((void (*)(id, SEL))objc_msgSend)(hit, sel_registerName("release"));
    }
}

// QUINTA_TRACE_EVENTS=1: log mouse events as AppKit dispatches them.
// Movement is sampled; button, enter/exit and scroll events are all logged.
static void (*orig_window_send_event)(id, SEL, id) = 0;
static volatile long quinta_traced_motion_events;
static void hooked_window_send_event(id self, SEL cmd, id event) {
    static volatile int enabled = -1;
    quinta_env_cached("QUINTA_TRACE_EVENTS", &enabled);
    if (enabled && event) {
        unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
            event, sel_registerName("type"));
        int is_button = type == 1 || type == 2 || type == 3 || type == 4 ||
                        type == 25 || type == 26;
        int is_motion = type == 5 || type == 6 || type == 7 || type == 27;
        int is_other = type == 8 || type == 9 || type == 22;
        int log = is_button || is_other;
        if (is_motion) {
            long count = __sync_add_and_fetch(&quinta_traced_motion_events, 1);
            log = count <= 20 || count % 50 == 0;
        }
        if (log) {
            QuintaPoint location = ((QuintaPoint (*)(id, SEL))objc_msgSend)(
                event, sel_registerName("locationInWindow"));
            write_str("[Quinta Event] type=");
            print_num((long long)type);
            write_str(" window=");
            write_str(object_getClassName(self));
            write_str(" x=");
            print_num((long long)location.x);
            write_str(" y=");
            print_num((long long)location.y);
            if (is_button) {
                write_str(" button=");
                print_num(((long (*)(id, SEL))objc_msgSend)(
                    event, sel_registerName("buttonNumber")));
                write_str(" clicks=");
                print_num(((long (*)(id, SEL))objc_msgSend)(
                    event, sel_registerName("clickCount")));
                id content = ((id (*)(id, SEL))objc_msgSend)(
                    self, sel_registerName("contentView"));
                id superview = content ? ((id (*)(id, SEL))objc_msgSend)(
                    content, sel_registerName("superview")) : 0;
                id root = superview ? superview : content;
                id hit = root ? ((id (*)(id, SEL, QuintaPoint))objc_msgSend)(
                    root, sel_registerName("hitTest:"), location) : 0;
                write_str(" hit=");
                write_str(hit ? object_getClassName(hit) : "(nil)");
                id responder = ((id (*)(id, SEL))objc_msgSend)(
                    self, sel_registerName("firstResponder"));
                write_str(" first-responder=");
                write_str(responder ? object_getClassName(responder) : "(nil)");
            }
            if (is_motion) {
                write_str(" sample=");
                print_num(quinta_traced_motion_events);
            }
            write_str("\n");
        }
    }
    unsigned long type = event ? ((unsigned long (*)(id, SEL))objc_msgSend)(
        event, sel_registerName("type")) : 0;
    if (type >= 1 && type <= 4)
        quinta_window_track_button(self, type, event, orig_window_send_event, cmd);
    else if (type == 25 || type == 26 || type == 27)
        quinta_window_other_mouse(self, type, event);
    else
        orig_window_send_event(self, cmd, event);
}

// Log where Roblox tries to send the user: an in-app WKWebView page or an
// external URL. Darling's WebKit is a stub, so both currently show nothing.
static void quinta_log_url(const char* prefix, id url) {
    id text = url ? ((id (*)(id, SEL))objc_msgSend)(url, sel_registerName("absoluteString")) : 0;
    const char* utf8 = text ? ((const char* (*)(id, SEL))objc_msgSend)(
                                  text, sel_registerName("UTF8String")) : 0;
    write_str(prefix);
    write_str(utf8 ? utf8 : "(nil)");
    write_str("\n");
}
static id (*orig_web_view_init)(id, SEL, QuintaRect, id) = 0;
static id hooked_web_view_init(id self, SEL cmd, QuintaRect frame, id configuration) {
    write_str("[Quinta Web] WKWebView initWithFrame:configuration:\n");
    return orig_web_view_init(self, cmd, frame, configuration);
}
static id (*orig_web_view_load_request)(id, SEL, id) = 0;
static id hooked_web_view_load_request(id self, SEL cmd, id request) {
    id url = request ? ((id (*)(id, SEL))objc_msgSend)(request, sel_registerName("URL")) : 0;
    quinta_log_url("[Quinta Web] WKWebView loadRequest: ", url);
    return orig_web_view_load_request(self, cmd, request);
}
// Links open in the launcher's browser window when it is there
// (web_bridge.m); roblox:// links go to the client's own URL handler.
extern int quinta_web_open_url(id url);
static QuintaBool (*orig_workspace_open_url)(id, SEL, id) = 0;
static QuintaBool hooked_workspace_open_url(id self, SEL cmd, id url) {
    if (url && quinta_web_open_url(url)) {
        write_str("[Quinta Web] NSWorkspace openURL: shown by the launcher\n");
        return 1;
    }
    QuintaBool result = orig_workspace_open_url(self, cmd, url);
    quinta_log_url(result ? "[Quinta Web] NSWorkspace openURL: (ok) "
                            : "[Quinta Web] NSWorkspace openURL: (failed) ", url);
    return result;
}

// Darling stores the X11 button number (left 1, middle 2, right 3, back 8,
// forward 9) in -[NSEvent buttonNumber]. macOS numbers them left 0, right 1,
// middle 2, then 3 and 4. Roblox therefore saw every left click as the right
// button: GUI hover and press states still worked, but Activated (left button
// only) never fired, and the "right button" started camera mouse capture.
static long (*orig_mouse_event_button_number)(id, SEL) = 0;
static long hooked_mouse_event_button_number(id self, SEL cmd) {
    long x11_button = orig_mouse_event_button_number(self, cmd);
    unsigned long type = ((unsigned long (*)(id, SEL))objc_msgSend)(
        self, sel_registerName("type"));
    switch (type) {
    case 1: case 2: case 6:   // left down, up, dragged
        return 0;
    case 3: case 4: case 7:   // right down, up, dragged
        return 1;
    default:
        break;
    }
    if (x11_button == 2)
        return 2;
    if (x11_button >= 8)
        return x11_button - 5;
    return x11_button;
}

// NSTextInputClient methods that macOS NSTextView provides and Darling's
// lacks. Roblox's InputMethodHandler (an NSTextView subclass) queries them
// when a text box gains focus; the missing hasMarkedText was fatal. These
// report "no IME composition in progress", matching a plain text field.
typedef struct { unsigned long location, length; } QuintaRange;
static QuintaBool text_view_has_marked_text(id self, SEL cmd) {
    (void)self; (void)cmd;
    return 0;
}
static QuintaRange text_view_marked_range(id self, SEL cmd) {
    (void)self; (void)cmd;
    QuintaRange range = {0x7FFFFFFFFFFFFFFFUL /* NSNotFound */, 0};
    return range;
}
static void text_view_unmark_text(id self, SEL cmd) {
    (void)self; (void)cmd;
}
static id text_view_valid_marked_attributes(id self, SEL cmd) {
    (void)self; (void)cmd;
    return ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSArray"),
                                           sel_registerName("array"));
}
static id text_view_attributed_substring(id self, SEL cmd, QuintaRange range,
                                         QuintaRange* actual) {
    (void)cmd;
    if (actual) {
        actual->location = 0x7FFFFFFFFFFFFFFFUL;
        actual->length = 0;
    }
    // Roblox uses this substring to translate UTF-16 selections to UTF-8 offsets.
    id storage = ((id (*)(id, SEL))objc_msgSend)(self,
                                                sel_registerName("textStorage"));
    if (!storage || range.location == 0x7FFFFFFFFFFFFFFFUL)
        return 0;
    unsigned long length = ((unsigned long (*)(id, SEL))objc_msgSend)(
        storage, sel_registerName("length"));
    if (range.location > length)
        return 0;
    // Clamp by subtraction so an oversized proposed range cannot overflow.
    unsigned long available = length - range.location;
    if (range.length > available)
        range.length = available;
    id substring = ((id (*)(id, SEL, QuintaRange))objc_msgSend)(
        storage, sel_registerName("attributedSubstringFromRange:"), range);
    if (substring && actual)
        *actual = range;
    return substring;
}

#include "text_input_trace.h"

// Convenience constructors from macOS 10.12 missing in Darling's AppKit.
// Roblox builds its web challenge window with them.
static id quinta_new_view(const char* class_name) {
    id object = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass(class_name),
                                                sel_registerName("alloc"));
    QuintaRect zero = {{0, 0}, {0, 0}};
    object = ((id (*)(id, SEL, QuintaRect))objc_msgSend)(
        object, sel_registerName("initWithFrame:"), zero);
    return ((id (*)(id, SEL))objc_msgSend)(object, sel_registerName("autorelease"));
}
static id button_with_image_target_action(id cls, SEL cmd, id image, id target,
                                          SEL action) {
    (void)cls; (void)cmd;
    id button = quinta_new_view("NSButton");
    if (!button)
        return 0;
    ((void (*)(id, SEL, id))objc_msgSend)(button, sel_registerName("setImage:"), image);
    ((void (*)(id, SEL, unsigned long))objc_msgSend)(
        button, sel_registerName("setImagePosition:"), 1UL /* NSImageOnly */);
    ((void (*)(id, SEL, id))objc_msgSend)(button, sel_registerName("setTarget:"), target);
    ((void (*)(id, SEL, SEL))objc_msgSend)(button, sel_registerName("setAction:"), action);
    ((void (*)(id, SEL))objc_msgSend)(button, sel_registerName("sizeToFit"));
    return button;
}
static id text_field_label_with_string(id cls, SEL cmd, id string) {
    (void)cls; (void)cmd;
    id label = quinta_new_view("NSTextField");
    if (!label)
        return 0;
    ((void (*)(id, SEL, id))objc_msgSend)(label, sel_registerName("setStringValue:"), string);
    ((void (*)(id, SEL, QuintaBool))objc_msgSend)(label, sel_registerName("setEditable:"), 0);
    ((void (*)(id, SEL, QuintaBool))objc_msgSend)(label, sel_registerName("setSelectable:"), 0);
    ((void (*)(id, SEL, QuintaBool))objc_msgSend)(label, sel_registerName("setBezeled:"), 0);
    ((void (*)(id, SEL, QuintaBool))objc_msgSend)(label, sel_registerName("setBordered:"), 0);
    ((void (*)(id, SEL, QuintaBool))objc_msgSend)(label, sel_registerName("setDrawsBackground:"), 0);
    ((void (*)(id, SEL))objc_msgSend)(label, sel_registerName("sizeToFit"));
    return label;
}

// Darling's Contacts framework is an empty stub. Roblox's home page asks for
// contacts permission (friend finding); report access as denied so it never
// tries to read contacts.
static long contact_store_authorization_denied(id cls, SEL cmd, long entity_type) {
    (void)cls; (void)cmd; (void)entity_type;
    return 2; // CNAuthorizationStatusDenied
}
struct QuintaAccessBlock {
    void* isa;
    int flags;
    int reserved;
    void (*invoke)(void*, QuintaBool, id);
};
static void contact_store_request_access(id self, SEL cmd, long entity_type,
                                         void* completion) {
    (void)self; (void)cmd; (void)entity_type;
    if (completion)
        ((struct QuintaAccessBlock*)completion)->invoke(completion, 0, 0);
}

// Darling's Keychain does not persist SecItemAdd, so Roblox's login (a
// generic password item keyed by kSecAttrAccount) was gone after every
// restart. Keep generic password items as files instead:
// ~/Library/Quinta/Keychain/<hex account>, mode 0600.
// Other item classes still go to Darling's Security framework.
extern int SecItemAdd(id attributes, id* result);
extern int SecItemCopyMatching(id query, id* result);
extern int SecItemDelete(id query);
extern const id kSecClass;
extern const id kSecClassGenericPassword;
extern const id kSecAttrAccount;
extern const id kSecValueData;
extern const id kSecReturnData;
extern int chmod(const char*, unsigned short);
#define QUINTA_ERR_SEC_ITEM_NOT_FOUND (-25300)

static id quinta_keychain_path(id query) {
    id item_class = ((id (*)(id, SEL, id))objc_msgSend)(query, sel_registerName("objectForKey:"), kSecClass);
    id account = ((id (*)(id, SEL, id))objc_msgSend)(query, sel_registerName("objectForKey:"), kSecAttrAccount);
    if (!item_class || !account ||
        !((QuintaBool (*)(id, SEL, id))objc_msgSend)(item_class, sel_registerName("isEqual:"),
                                                        kSecClassGenericPassword))
        return 0;
    const char* name = ((const char* (*)(id, SEL))objc_msgSend)(account, sel_registerName("UTF8String"));
    if (!name)
        return 0;
    // The account in hex; past 100 bytes, the first 100 and a hash of the
    // rest's whole (a file name holds 255 bytes).
    static const char digits[] = "0123456789abcdef";
    char hex[260];
    int length = 0;
    unsigned long long hash = 1469598103934665603ULL; // FNV-1a
    unsigned long bytes = 0;
    for (const unsigned char* c = (const unsigned char*)name; *c; c++, bytes++) {
        hash = (hash ^ *c) * 1099511628211ULL;
        if (bytes < 100) {
            hex[length++] = digits[*c >> 4];
            hex[length++] = digits[*c & 15];
        }
    }
    if (bytes > 100) {
        hex[length++] = '-';
        for (int shift = 60; shift >= 0; shift -= 4)
            hex[length++] = digits[(hash >> shift) & 15];
    }
    hex[length] = 0;
    id home = ((id (*)(void))dlsym(RTLD_DEFAULT, "NSHomeDirectory"))();
    const char* session_directory = getenv("QUINTA_SESSION_DIRECTORY");
    if (!session_directory || !session_directory[0]) session_directory = "Library/Quinta";
    id directory = ((id (*)(id, SEL, id))objc_msgSend)(
        home, sel_registerName("stringByAppendingPathComponent:"),
        ((id (*)(id, SEL, const char*))objc_msgSend)((id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), session_directory));
    directory = ((id (*)(id, SEL, id))objc_msgSend)(directory,
        sel_registerName("stringByAppendingPathComponent:"), @"Keychain");
    ((QuintaBool (*)(id, SEL, id, QuintaBool, id, id*))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSFileManager"), sel_registerName("defaultManager")),
        sel_registerName("createDirectoryAtPath:withIntermediateDirectories:attributes:error:"),
        directory, 1, 0, 0);
    chmod(((const char* (*)(id, SEL))objc_msgSend)(directory, sel_registerName("fileSystemRepresentation")), 0700);
    return ((id (*)(id, SEL, id))objc_msgSend)(
        directory, sel_registerName("stringByAppendingPathComponent:"),
        ((id (*)(id, SEL, const char*))objc_msgSend)((id)objc_getClass("NSString"),
            sel_registerName("stringWithUTF8String:"), hex));
}

static int quinta_SecItemAdd(id attributes, id* result) {
    id path = attributes ? quinta_keychain_path(attributes) : 0;
    if (!path)
        return SecItemAdd(attributes, result);
    id data = ((id (*)(id, SEL, id))objc_msgSend)(attributes, sel_registerName("objectForKey:"), kSecValueData);
    if (!data)
        data = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSData"), sel_registerName("data"));
    // Created 0600 before the secret is in it (the write keeps the mode).
    extern int open(const char*, int, ...);
    extern int close(int);
    const char* file = ((const char* (*)(id, SEL))objc_msgSend)(path, sel_registerName("fileSystemRepresentation"));
    int fd = file ? open(file, 0x1 /* O_WRONLY */ | 0x200 /* O_CREAT */, 0600) : -1;
    if (fd >= 0)
        close(fd);
    chmod(file, 0600);
    QuintaBool written = fd >= 0 && ((QuintaBool (*)(id, SEL, id, QuintaBool))objc_msgSend)(
        data, sel_registerName("writeToFile:atomically:"), path, 0); // atomic writes are broken in Darling
    if (result)
        *result = 0;
    if (!written) {
        write_str("[Quinta Keychain] could not store generic password item\n");
        return -36; // errSecIO
    }
    write_str("[Quinta Keychain] stored generic password item\n");
    return 0;
}
DYLD_INTERPOSE(quinta_SecItemAdd, SecItemAdd);

static int quinta_SecItemCopyMatching(id query, id* result) {
    id path = query ? quinta_keychain_path(query) : 0;
    if (!path)
        return SecItemCopyMatching(query, result);
    id data = ((id (*)(id, SEL, id))objc_msgSend)((id)objc_getClass("NSData"),
                                                 sel_registerName("dataWithContentsOfFile:"), path);
    if (!data)
        return QUINTA_ERR_SEC_ITEM_NOT_FOUND;
    id wants_data = ((id (*)(id, SEL, id))objc_msgSend)(query, sel_registerName("objectForKey:"), kSecReturnData);
    if (result)
        *result = wants_data && ((QuintaBool (*)(id, SEL))objc_msgSend)(wants_data, sel_registerName("boolValue"))
            ? ((id (*)(id, SEL))objc_msgSend)(data, sel_registerName("retain"))  // caller owns (+1)
            : 0;
    return 0;
}
DYLD_INTERPOSE(quinta_SecItemCopyMatching, SecItemCopyMatching);

static int quinta_SecItemDelete(id query) {
    id path = query ? quinta_keychain_path(query) : 0;
    if (!path)
        return SecItemDelete(query);
    QuintaBool removed = ((QuintaBool (*)(id, SEL, id, id*))objc_msgSend)(
        ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSFileManager"), sel_registerName("defaultManager")),
        sel_registerName("removeItemAtPath:error:"), path, 0);
    return removed ? 0 : QUINTA_ERR_SEC_ITEM_NOT_FOUND;
}
DYLD_INTERPOSE(quinta_SecItemDelete, SecItemDelete);

// Records the requested OpenGL profile (gl_profile.c); QUINTA_TRACE_CGL
// logs the attributes (Darling's CGL pixel format keeps almost none of them).
static id (*orig_pixel_format_init)(id, SEL, const unsigned int*) = 0;
static id hooked_pixel_format_init(id self, SEL cmd, const unsigned int* attributes) {
    if (quinta_trace_cgl_enabled()) {
        // Up to the terminating 0 (the array may be on the caller's stack).
        write_str("[Quinta CGL] NSOpenGLPixelFormat attributes:");
        for (int index = 0; attributes && index < 64; index++) {
            write_str(" ");
            print_num(attributes[index]);
            if (!attributes[index])
                break;
        }
        write_str("\n");
    }
    id result = orig_pixel_format_init(self, cmd, attributes);
    quinta_note_pixel_format(result, attributes);
    return result;
}

// Darling's event queue (NSDisplay) fixed to behave like macOS.
//
// -nextEventMatchingMask:untilDate:inMode:dequeue: removed every queued
// event that did not match the mask while looking for one that did. macOS
// leaves them queued. When the game asked for mouse events during a camera
// drag, key releases waiting in front were thrown away: keys stuck ("W
// stayed pressed") or presses were lost. -discardEventsMatchingMask:
// beforeEvent: tested the reference event's type instead of each queued
// event's. The queue (an NSMutableArray) is also shared with the rendering
// thread (shared_current_display), so all three take a lock.
static volatile unsigned int quinta_event_queue_lock;
extern const void *CFRunLoopGetMain(void);
extern const void *kCFRunLoopCommonModes;
extern const void *CFRunLoopSourceCreate(const void *, long, void *);
extern void CFRunLoopAddSource(const void *, const void *, const void *);
extern void CFRunLoopSourceSignal(const void *);
extern void CFRunLoopWakeUp(const void *);
extern int pthread_main_np(void);
static const void *quinta_event_queue_source;
static volatile unsigned int quinta_event_queue_wake_pending;
static void quinta_event_queue_source_perform(void *info) {
    (void)info;
    __atomic_store_n(&quinta_event_queue_wake_pending, 0, __ATOMIC_RELEASE);
    quinta_process_mouse_capture_requests();
}
static void quinta_install_event_queue_source(void) {
    struct {
        long version; void *info;
        const void *(*retain)(const void *); void (*release)(const void *);
        const void *(*description)(const void *);
        unsigned char (*equal)(const void *, const void *); unsigned long (*hash)(const void *);
        void (*schedule)(void *, const void *, const void *);
        void (*cancel)(void *, const void *, const void *); void (*perform)(void *);
    } context = {.perform = quinta_event_queue_source_perform};
    const void *source = CFRunLoopSourceCreate(0, 0, &context);
    if (!source) {
        write_str("[Quinta] Could not create event queue wake source\n");
        return;
    }
    /* Retained for the installed hooks' lifetime. AppKit adds its modal and
     * tracking modes to the main loop's common modes during initialization. */
    CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    __atomic_store_n(&quinta_event_queue_source, source, __ATOMIC_RELEASE);
}
static void quinta_wake_event_queue(void) {
    const void *source = __atomic_load_n(&quinta_event_queue_source, __ATOMIC_ACQUIRE);
    if (!source || __atomic_exchange_n(&quinta_event_queue_wake_pending, 1, __ATOMIC_ACQ_REL))
        return;
    /* NSRunLoop returns after a handled source. A wake by itself can resume
     * waiting with an NSEvent still queued, including when a timer posts it.
     * Collapse repeated posts into one signal; main-thread input needs no IPC. */
    CFRunLoopSourceSignal(source);
    if (!pthread_main_np())
        CFRunLoopWakeUp(CFRunLoopGetMain());
}
static void quinta_lock_event_queue(void) {
    quinta_lock(&quinta_event_queue_lock);
}
static void quinta_unlock_event_queue(void) {
    quinta_unlock(&quinta_event_queue_lock);
}
static id quinta_event_queue(id display) {
    static Ivar queue_ivar;
    if (!queue_ivar)
        queue_ivar = class_getInstanceVariable(objc_getClass("NSDisplay"), "_eventQueue");
    return queue_ivar ? *(id*)((char*)display + ivar_getOffset(queue_ivar)) : (id)0;
}
static unsigned long quinta_event_type(id event) {
    return ((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("type"));
}
static int quinta_mask_matches(unsigned long long mask, unsigned long type) {
    return type < 64 && (mask & (1ULL << type));
}

static id hooked_display_next_event(id self, SEL cmd, unsigned long long mask, id until, id mode,
                                    signed char dequeue) {
    (void)cmd;
    id queue = quinta_event_queue(self);
    SEL count = sel_registerName("count"), object_at = sel_registerName("objectAtIndex:");
    // No waiting when a matching event is queued. Events of other types may
    // wait there for someone else: they must not turn every wait into a spin.
    int matching = 0;
    if (queue) {
        quinta_lock_event_queue();
        unsigned long total = ((unsigned long (*)(id, SEL))objc_msgSend)(queue, count);
        for (unsigned long index = 0; index < total && !matching; index++)
            matching = quinta_mask_matches(mask, quinta_event_type(
                ((id (*)(id, SEL, unsigned long))objc_msgSend)(queue, object_at, index)));
        quinta_unlock_event_queue();
    }
    if (matching)
        until = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSDate"), sel_registerName("date"));
    id run_loop = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSRunLoop"),
                                                  sel_registerName("currentRunLoop"));
    ((signed char (*)(id, SEL, id, id))objc_msgSend)(run_loop, sel_registerName("runMode:beforeDate:"),
                                                     mode, until);
    id result = (id)0;
    if (queue) {
        quinta_lock_event_queue();
        unsigned long total = ((unsigned long (*)(id, SEL))objc_msgSend)(queue, count);
        for (unsigned long index = 0; index < total; index++) {
            id event = ((id (*)(id, SEL, unsigned long))objc_msgSend)(queue, object_at, index);
            if (!quinta_mask_matches(mask, quinta_event_type(event)))
                continue;
            result = ((id (*)(id, SEL))objc_msgSend)(event, sel_registerName("retain"));
            if (dequeue)
                ((void (*)(id, SEL, unsigned long))objc_msgSend)(
                    queue, sel_registerName("removeObjectAtIndex:"), index);
            break;
        }
        /* Nobody may ever ask for some event types; keep the queue bounded. */
        while (((unsigned long (*)(id, SEL))objc_msgSend)(queue, count) > 4096)
            ((void (*)(id, SEL, unsigned long))objc_msgSend)(queue, sel_registerName("removeObjectAtIndex:"), 0);
        quinta_unlock_event_queue();
        if (result)
            result = ((id (*)(id, SEL))objc_msgSend)(result, sel_registerName("autorelease"));
    }
    if (!result) {
        /* As Darling: its "no event" placeholder, type 100, which
         * -[NSApplication nextEventMatchingMask:...] recognizes and keeps
         * waiting (checked in Darling's AppKit). The type 13 used before is a
         * real NSEventTypeAppKitDefined event at (0,0): the run loop sent it
         * to the app and to event monitors, and tracking loops (buttons in
         * alerts) took it as a mouse event outside and gave up. */
        id event = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSEvent"), sel_registerName("alloc"));
        event = ((id (*)(id, SEL, unsigned long, QuintaPoint, unsigned long, id))objc_msgSend)(
            event, sel_registerName("initWithType:location:modifierFlags:window:"), 100,
            (QuintaPoint){0, 0}, 0, (id)0);
        result = ((id (*)(id, SEL))objc_msgSend)(event, sel_registerName("autorelease"));
    }
    return result;
}

static void hooked_display_post_event(id self, SEL cmd, id event, signed char at_start) {
    (void)cmd;
    id queue = quinta_event_queue(self);
    if (!queue || !event)
        return;
    if (quinta_core_motion_type && quinta_is_motion_type(event)) {
        static Ivar type_ivar;
        if (!type_ivar)
            type_ivar = class_getInstanceVariable(objc_getClass("NSEvent"), "_type");
        if (type_ivar)
            *(unsigned long*)((char*)event + ivar_getOffset(type_ivar)) = quinta_core_motion_type;
        ((void (*)(id, SEL, long))objc_msgSend)(event, sel_registerName("_setButtonNumber:"),
                                              (long)quinta_core_motion_button);
    }
    if (quinta_x_key_override >= 0) {
        unsigned long key_type = quinta_event_type(event);
        static Ivar key_code_ivar;
        if (!key_code_ivar) {
            Class keyboard_class = objc_getClass("NSEvent_keyboard");
            if (keyboard_class)
                key_code_ivar = class_getInstanceVariable(keyboard_class, "_keyCode");
        }
        if ((key_type == 10 || key_type == 11) && key_code_ivar) {
            unsigned short* key_code = (unsigned short*)((char*)event + ivar_getOffset(key_code_ivar));
            if (!*key_code)   // Darling's "unmapped": code 0
                *key_code = (unsigned short)quinta_x_key_override;
        }
    }
    quinta_lock_event_queue();
    if (at_start) {
        ((void (*)(id, SEL, id, unsigned long))objc_msgSend)(queue, sel_registerName("insertObject:atIndex:"),
                                                             event, 0);
    } else {
        unsigned long type = quinta_event_type(event);
        // Coalesce mouse motion events during mouse lock: accumulate deltas into the last
        // queued event of the same type. This matches macOS AppKit event coalescing, prevents
        // queue backlog from high polling rate mice, and eliminates input lag when releasing the mouse.
        if (quinta_pointer_grabbed && (type == 5 || type == 6 || type == 7 || type == 27)) {
            unsigned long total = ((unsigned long (*)(id, SEL))objc_msgSend)(queue, sel_registerName("count"));
            if (total > 0) {
                id last = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
                    queue, sel_registerName("objectAtIndex:"), total - 1);
                if (quinta_event_type(last) == type &&
                    ((long (*)(id, SEL))objc_msgSend)(last, sel_registerName("windowNumber")) ==
                        ((long (*)(id, SEL))objc_msgSend)(event, sel_registerName("windowNumber")) &&
                    ((unsigned long (*)(id, SEL))objc_msgSend)(last, sel_registerName("modifierFlags")) ==
                        ((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("modifierFlags")) &&
                    ((long (*)(id, SEL))objc_msgSend)(last, sel_registerName("buttonNumber")) ==
                        ((long (*)(id, SEL))objc_msgSend)(event, sel_registerName("buttonNumber"))) {
                    static Ivar dx_ivar, dy_ivar;
                    if (!dx_ivar) {
                        Class mouse_cls = objc_getClass("NSEvent_mouse");
                        if (mouse_cls) {
                            dx_ivar = class_getInstanceVariable(mouse_cls, "_deltaX");
                            dy_ivar = class_getInstanceVariable(mouse_cls, "_deltaY");
                        }
                    }
                    if (dx_ivar && dy_ivar) {
                        long off_x = (long)ivar_getOffset(dx_ivar);
                        long off_y = (long)ivar_getOffset(dy_ivar);
                        /* A dequeued=NO caller may still hold the old event:
                         * replace it rather than changing its deltas in place. */
                        *(double*)((char*)event + off_x) += *(double*)((char*)last + off_x);
                        *(double*)((char*)event + off_y) += *(double*)((char*)last + off_y);
                        ((void (*)(id, SEL, unsigned long, id))objc_msgSend)(
                            queue, sel_registerName("replaceObjectAtIndex:withObject:"), total - 1, event);
                        quinta_unlock_event_queue();
                        quinta_wake_event_queue();
                        return;
                    }
                }
            }
        }
        ((void (*)(id, SEL, id))objc_msgSend)(queue, sel_registerName("addObject:"), event);
    }
    quinta_unlock_event_queue();
    quinta_wake_event_queue();
}

static void hooked_display_discard_events(id self, SEL cmd, unsigned long long mask, id before) {
    (void)cmd;
    id queue = quinta_event_queue(self);
    if (!queue)
        return;
    quinta_lock_event_queue();
    unsigned long total = ((unsigned long (*)(id, SEL))objc_msgSend)(queue, sel_registerName("count"));
    unsigned long stop = total;
    for (unsigned long index = 0; index < total; index++)
        if (((id (*)(id, SEL, unsigned long))objc_msgSend)(queue, sel_registerName("objectAtIndex:"), index) == before) {
            stop = index;
            break;
        }
    for (unsigned long index = stop; index-- > 0;) {
        id event = ((id (*)(id, SEL, unsigned long))objc_msgSend)(queue, sel_registerName("objectAtIndex:"), index);
        if (quinta_mask_matches(mask, quinta_event_type(event)))
            ((void (*)(id, SEL, unsigned long))objc_msgSend)(queue, sel_registerName("removeObjectAtIndex:"), index);
    }
    quinta_unlock_event_queue();
}

// X11 events as Darling's AppKit receives them (-[X11Display postXEvent:]).
//
// Motion compression: a 1000 Hz mouse sends a motion event per pixel, and
// Darling turns every one into an NSEvent the game handles. It could not
// keep up; a pointer warp during mouse lock reached the game 180-340 events
// late and the camera lagged and jumped (reported on an RTX 3050 laptop).
// A motion event is skipped when the next queued event is a motion event
// of the same window and buttons: Darling computes deltas from positions,
// so the next one carries the skipped movement. While one of our warps is
// on its way (mouse lock), nothing is merged: the lock logic must see the
// warp's motion alone. (The 48 px limit below did not ensure that: the
// warp's own event was merged into the next one whenever that was close.)
// QUINTA_NO_MOTION_COMPRESSION=1 turns this off.
// QUINTA_TRACE_KEYS=1 logs X key presses/releases here and the key events
// the game gets (sendEvent), to find lost or stuck keys.
static void (*orig_post_x_event)(id, SEL, void*);
static int quinta_trace_keys_enabled(void) {
    static volatile int enabled = -1;
    return quinta_env_cached("QUINTA_TRACE_KEYS", &enabled);
}
static int quinta_game_focus_event(id self, void* event) {
    unsigned long xid = *(unsigned long*)((char*)event + 32);
    unsigned long capture = __atomic_load_n(&quinta_cursor_lock_window, __ATOMIC_ACQUIRE);
    id app = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"),
                                             sel_registerName("sharedApplication"));
    id main = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("mainWindow"));
    unsigned long main_handle = quinta_native_window_handle(main);
    if (capture || main_handle)
        return xid == capture || xid == main_handle;
    (void)self;
    return 1; // first activation, before a main window has been established
}
static void quinta_refresh_pointer_state(id self) {
    static int (*query)(void*, unsigned long, unsigned long*, unsigned long*, int*, int*, int*, int*, unsigned int*);
    if (!query)
        query = (int (*)(void*, unsigned long, unsigned long*, unsigned long*, int*, int*, int*, int*, unsigned int*))
            dlsym(RTLD_DEFAULT, "XQueryPointer");
    void* display = quinta_x11_display_connection(self);
    unsigned long window = quinta_native_window_handle(quinta_lock_window());
    unsigned long root, child;
    int rx, ry, x, y;
    unsigned int state;
    if (query && display && window && query(display, window, &root, &child, &rx, &ry, &x, &y, &state)) {
        quinta_x_modifier_flags = quinta_modifiers_for_x_state(state);
        quinta_raw_buttons = quinta_buttons_for_x_state(state);
        quinta_drag_cursor_update_buttons(quinta_raw_buttons);
    }
}
static void hooked_post_x_event_inner(id self, SEL cmd, void* event) {
    int type = *(int*)event;
    if (type != 35 /* raw events */ && type != 6 /* their core motion companions */)
        quinta_flush_raw_motion(self);
    quinta_update_x_input_state(self, event);
    if (type == 34 /* MappingNotify */)
        quinta_refresh_x_modifier_mapping(self, 1);
    // Destroy/UnmapNotify carry event at 32 and the affected window at 40.
    // Release before Darling removes the platform object or focus changes.
    if ((type == 17 /* DestroyNotify */ || type == 18 /* UnmapNotify */) &&
        quinta_capture_window && *(unsigned long*)((char*)event + 40) == quinta_capture_window) {
        __atomic_store_n(&quinta_input_focused, 0, __ATOMIC_RELEASE);
        if (type == 17)
            __atomic_store_n(&quinta_mouse_lock_requested, 0, __ATOMIC_RELEASE);
        quinta_release_mouse_capture(0);
    }
    {
        static volatile int trace_x = -1;
        static long traced_x;
        if (quinta_env_cached("QUINTA_TRACE_XEVENTS", &trace_x) && traced_x++ < 80) {
            write_str("[Quinta X] event type=");
            print_num(type);
            write_str(" display=");
            print_num((long long)(unsigned long)quinta_x11_display_connection(self));
            static char* (*display_string)(void*);
            if (!display_string)
                display_string = (char* (*)(void*))dlsym(RTLD_DEFAULT, "XDisplayString");
            if (display_string && quinta_x11_display_connection(self)) {
                write_str(" ");
                write_str(display_string(quinta_x11_display_connection(self)));
            }
            write_str(quinta_pointer_grabbed ? " locked\n" : "\n");
        }
    }
    if (quinta_raw_mouse_x_event(self, event))
        return;
    if (type == 7 /* EnterNotify */ && quinta_pointer_grabbed && !quinta_raw_mouse_active &&
        *(int*)((char*)event + 80) == 0 /* NotifyNormal */)
        /* The pointer drifted out of the window during a mouse lock and came
         * back. The first motion after it reports the whole distance from the
         * exit point, which would fling the game camera: drop that one. */
        quinta_drop_next_motion = 1;
    if (type == 6 /* MotionNotify */ && quinta_pointer_grabbed &&
        quinta_drop_next_motion) {
        quinta_drop_next_motion = 0;
        return;
    }
    if (type == 33 /* ClientMessage */) {
        /* XClientMessageEvent LP64: window=32, message_type=40, format=48,
         * data.l[0]=56. WM_DELETE_WINDOW is the payload of WM_PROTOCOLS.
         * Only closing the game window should stop the entire client. */
        static unsigned long (*intern_atom)(void*, const char*, int);
        static void* atom_display;
        static unsigned long wm_protocols, wm_delete;
        if (!intern_atom)
            intern_atom = (unsigned long (*)(void*, const char*, int))
                dlsym(RTLD_DEFAULT, "XInternAtom");
        void* display = quinta_x11_display_connection(self);
        if (display && intern_atom && display != atom_display) {
            wm_protocols = intern_atom(display, "WM_PROTOCOLS", 1);
            wm_delete = intern_atom(display, "WM_DELETE_WINDOW", 1);
            atom_display = display;
        }
        if (display && wm_protocols && wm_delete &&
            *(unsigned long*)((char*)event + 40) == wm_protocols &&
            *(int*)((char*)event + 48) == 32 &&
            *(unsigned long*)((char*)event + 56) == wm_delete) {
            id app = ((id (*)(id, SEL))objc_msgSend)(
                (id)objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
            id windows = ((id (*)(id, SEL))objc_msgSend)(app, sel_registerName("windows"));
            unsigned long count = ((unsigned long (*)(id, SEL))objc_msgSend)(windows, sel_registerName("count"));
            for (unsigned long i = 0; i < count; i++) {
                id window = ((id (*)(id, SEL, unsigned long))objc_msgSend)(windows, sel_registerName("objectAtIndex:"), i);
                const char* name = object_getClassName(window);
                if (!name || !ascii_strings_equal(name, "RBXWindow") ||
                    quinta_native_window_handle(window) != *(unsigned long*)((char*)event + 32))
                    continue;
                write_str("[Quinta] Window close requested (WM_DELETE_WINDOW)\n");
                __atomic_store_n(&quinta_mouse_lock_requested, 0, __ATOMIC_RELEASE);
                __atomic_store_n(&quinta_input_focused, 0, __ATOMIC_RELEASE);
                quinta_release_mouse_capture(0);
                quinta_write_quit_sentinel();
                break;
            }
        }
    }
    if (type == 6 /* MotionNotify */) {
        static int compression = -1;
        static int (*queued)(void*, int);
        static int (*peek)(void*, void*);
        static long display_offset = -1;
        if (compression < 0) {
            // XEventsQueued(QueuedAlready): only what Xlib has read already;
            // XPending would flush and read the socket for every motion event.
            queued = (int (*)(void*, int))dlsym(RTLD_DEFAULT, "XEventsQueued");
            peek = (int (*)(void*, void*))dlsym(RTLD_DEFAULT, "XPeekEvent");
            Ivar display_ivar = class_getInstanceVariable(object_getClass(self), "_display");
            display_offset = display_ivar ? (long)ivar_getOffset(display_ivar) : -1;
            compression = !quinta_env_on("QUINTA_NO_MOTION_COMPRESSION") && queued && peek &&
                          display_offset >= 0;
        }
        void* display = compression && !quinta_drop_warp_motion && !quinta_x_batch_last
            ? *(void**)((char*)self + display_offset) : 0;
        if (display && queued(display, 0 /* QueuedAlready */) > 0) {
            unsigned char next[192];
            peek(display, next);
            /* XMotionEvent: window at 32, x/y at 64/68, state at 80 */
            int dx = *(int*)(next + 64) - *(int*)((char*)event + 64);
            int dy = *(int*)(next + 68) - *(int*)((char*)event + 68);
            if (*(int*)next == 6 &&
                *(unsigned long*)(next + 32) == *(unsigned long*)((char*)event + 32) &&
                *(unsigned int*)(next + 80) == *(unsigned int*)((char*)event + 80) &&
                dx <= 48 && dx >= -48 && dy <= 48 && dy >= -48)
                return;
        }
    } else if (type == 10 /* FocusOut */) {
        /* XFocusChangeEvent: detail at 44. Focus moving into a child window
         * of ours (NotifyInferior) keeps the keyboard with us. */
        int mode = *(int*)((char*)event + 40);
        if (mode == 1 /* NotifyGrab */ || mode == 2 /* NotifyUngrab */ ||
            *(int*)((char*)event + 44) == 2 /* NotifyInferior */)
            return;
        if (quinta_game_focus_event(self, event)) {
            for (int key = 0; key < 128; key++)
                quinta_key_down[key] = 0;
            for (int key = 0; key < 256; key++)
                quinta_x_modifier_keys_down[key] = 0;
            quinta_lock(&quinta_window_cursor_lock);
            int button_capture = quinta_drag_cursor.button_capture;
            quinta_unlock(&quinta_window_cursor_lock);
            quinta_lock(&quinta_capture_request_lock);
            __atomic_store_n(&quinta_input_focused, 0, __ATOMIC_RELEASE);
            if (button_capture)
                __atomic_store_n(&quinta_mouse_lock_requested, 0, __ATOMIC_RELEASE);
            quinta_unlock(&quinta_capture_request_lock);
            quinta_release_mouse_capture(0);
            quinta_raw_buttons = 0;
            quinta_window_buttons_down = 0;
            quinta_other_buttons_down = 0;
            quinta_x_modifier_flags = 0;
        }
    } else if (type == 9 /* FocusIn */) {
        int mode = *(int*)((char*)event + 40);
        if (mode == 1 /* NotifyGrab */ || mode == 2 /* NotifyUngrab */ ||
            *(int*)((char*)event + 44) == 2 /* NotifyInferior */)
            return;
    } else if ((type == 2 || type == 3) && quinta_trace_keys_enabled()) {
        /* XKeyEvent: time at 56, keycode at 84 */
        write_str(type == 2 ? "[Quinta Keys] X press   keycode=" : "[Quinta Keys] X release keycode=");
        print_num(*(unsigned int*)((char*)event + 84));
        write_str(" time=");
        print_num((long long)*(unsigned long*)((char*)event + 56));
        /* When Darling handles it, in the same milliseconds scale: if the
         * gap to `time` grows, events wait inside Mac O' Blox. */
        write_str(" handled=");
        print_num((long long)(mach_absolute_time() / 1000000ULL));
        write_str("\n");
    }
    if (type == 6 /* MotionNotify */)
        quinta_core_motion_type = quinta_motion_type(quinta_raw_buttons, &quinta_core_motion_button);
    else if (type == 2 || type == 3)
        quinta_x_key_override = quinta_x_extra_carbon_key(*(unsigned int*)((char*)event + 84));
    @try {
        orig_post_x_event(self, cmd, event);
    } @finally {
        quinta_core_motion_type = quinta_core_motion_button = 0;
        quinta_x_key_override = -1;
    }
    if (type == 9 /* FocusIn */ && quinta_game_focus_event(self, event)) {
        /* Darling must activate the Cocoa window before we resolve its lock
         * anchor. State is queried once on activation, never per raw report. */
        quinta_refresh_pointer_state(self);
        quinta_refresh_x_modifier_mapping(self, 1);
        __atomic_store_n(&quinta_input_focused, 1, __ATOMIC_RELEASE);
        if (!quinta_pointer_grabbed)
            quinta_capture_attempted = quinta_capture_error = 0;
        quinta_lock(&quinta_capture_request_lock);
        int request_ready = quinta_capture_request_ready;
        quinta_unlock(&quinta_capture_request_lock);
        if (request_ready) {
            quinta_process_mouse_capture_requests();
            quinta_apply_mouse_capture(__atomic_load_n(&quinta_mouse_lock_requested, __ATOMIC_ACQUIRE));
        }
    }
}

static void hooked_post_x_event(id self, SEL cmd, void* event) {
    quinta_process_mouse_capture_requests();
    hooked_post_x_event_inner(self, cmd, event);
}

static void (*orig_process_pending_events)(id, SEL);
static void hooked_process_pending_events(id self, SEL cmd) {
    /* XPending inside an unbounded drain can keep importing reports forever.
     * Take one snapshot and give the app a turn after 128 events or 2 ms. */
    if (!pthread_main_np()) {
        quinta_wake_event_queue();
        return;
    }
    unsigned int expected = 0;
    if (!__atomic_compare_exchange_n(&quinta_x_event_draining, &expected, 1, 0,
                                    __ATOMIC_ACQUIRE, __ATOMIC_RELAXED))
        return;
    id pool = 0;
    @try {
        quinta_process_mouse_capture_requests();
        static int (*pending)(void*);
        static int (*next)(void*, void*);
        if (!pending) {
            pending = (int (*)(void*))dlsym(RTLD_DEFAULT, "XPending");
            next = (int (*)(void*, void*))dlsym(RTLD_DEFAULT, "XNextEvent");
        }
        void* display = quinta_x11_display_connection(self);
        if (!pending || !next || !display) {
            orig_process_pending_events(self, cmd);
        } else {
            pool = ((id (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSAutoreleasePool"),
                                                   sel_registerName("new"));
            int total = pending(display);
            if (total > 128) total = 128;
            unsigned long long deadline = quinta_input_now_ns() + 2000000ULL;
            for (int index = 0; index < total; index++) {
                /* Deliver the final core motion even when more arrive. A
                 * compressor waiting for an empty queue could otherwise
                 * suppress every batch of a continuous stream. */
                quinta_x_batch_last = index + 1 == total || quinta_input_now_ns() >= deadline;
                unsigned long event[24]; // XEvent, 192 bytes on x86_64
                if (!next(display, event))
                    ((void (*)(id, SEL, void*))objc_msgSend)(self, sel_registerName("postXEvent:"), event);
                if (quinta_x_batch_last)
                    break;
            }
            quinta_x_batch_last = 0;
            quinta_flush_raw_motion(self);
        }
    } @finally {
        quinta_core_motion_type = quinta_core_motion_button = 0;
        quinta_x_batch_last = 0;
        if (quinta_raw_pending_window) {
            ((void (*)(id, SEL))objc_msgSend)(quinta_raw_pending_window, sel_registerName("release"));
            quinta_raw_pending_window = 0;
            quinta_raw_pending_dx = quinta_raw_pending_dy = 0;
        }
        if (pool)
            ((void (*)(id, SEL))objc_msgSend)(pool, sel_registerName("release"));
        __atomic_store_n(&quinta_x_event_draining, 0, __ATOMIC_RELEASE);
    }
}

// OpenGL subwindows get the screen's visual (gl_profile.c explains why).
#include "x11_drawable_cache.h"

extern unsigned long quinta_replace_gl_subwindow(void* display, unsigned long parent, unsigned long old);
static id (*orig_x11_subwindow_init)(id, SEL, id, QuintaRect);
static id hooked_x11_subwindow_init(id self, SEL cmd, id parent, QuintaRect frame) {
    id result = orig_x11_subwindow_init(self, cmd, parent, frame);
    if (!result || !parent)
        return result;
    Class cls = object_getClass(result);
    Ivar window_ivar = class_getInstanceVariable(cls, "_window");
    Ivar display_ivar = class_getInstanceVariable(cls, "_display");
    if (!window_ivar || !display_ivar)
        return result;
    unsigned long* window = (unsigned long*)((char*)result + ivar_getOffset(window_ivar));
    void* display = *(void**)((char*)result + ivar_getOffset(display_ivar));
    unsigned long parent_handle =
        ((unsigned long (*)(id, SEL))objc_msgSend)(parent, sel_registerName("windowHandle"));
    *window = quinta_replace_gl_subwindow(display, parent_handle, *window);
    return result;
}

// Classes from Darling's X11 backend load after this library initializes, so
// hooks on them are installed again once NSApplication finishes launching.
static void quinta_install_late_hooks(void) {
    quinta_install_surface_scale_hook();
    static volatile int visibility_hooked;
    Class cursor_class = objc_getClass("NSCursor");
    if (cursor_class && !quinta_wayland_enabled() && __sync_bool_compare_and_swap(&visibility_hooked, 0, 1)) {
        Method hide = class_getClassMethod(cursor_class, sel_registerName("hide"));
        Method unhide = class_getClassMethod(cursor_class, sel_registerName("unhide"));
        if (hide && unhide) {
            orig_cursor_hide = (void (*)(id, SEL))method_getImplementation(hide);
            orig_cursor_unhide = (void (*)(id, SEL))method_getImplementation(unhide);
            method_setImplementation(hide, (IMP)hooked_cursor_hide);
            method_setImplementation(unhide, (IMP)hooked_cursor_unhide);
        }
    }
    static volatile int cursor_hooked;
    static volatile int window_events_hooked;
    static volatile int event_queue_hooked;
    Class display_class = objc_getClass("NSDisplay");
    if (display_class && __sync_bool_compare_and_swap(&event_queue_hooked, 0, 1)) {
        Method next = class_getInstanceMethod(display_class,
            sel_registerName("nextEventMatchingMask:untilDate:inMode:dequeue:"));
        Method post = class_getInstanceMethod(display_class, sel_registerName("postEvent:atStart:"));
        Method discard = class_getInstanceMethod(display_class,
            sel_registerName("discardEventsMatchingMask:beforeEvent:"));
        if (next && post && discard && class_getInstanceVariable(display_class, "_eventQueue")) {
            quinta_install_event_queue_source();
            method_setImplementation(next, (IMP)hooked_display_next_event);
            method_setImplementation(post, (IMP)hooked_display_post_event);
            method_setImplementation(discard, (IMP)hooked_display_discard_events);
            write_str("[Quinta] Event queue keeps non-matching events (NSDisplay fix)\n");
        }
    }
    static volatile int x_events_hooked;
    Class x11_display_class = objc_getClass("X11Display");
    if (x11_display_class && __sync_bool_compare_and_swap(&x_events_hooked, 0, 1)) {
        Method cursor = class_getInstanceMethod(x11_display_class, sel_registerName("setCursor:"));
        if (cursor) {
            orig_x11_display_set_cursor = (void (*)(id, SEL, id))method_getImplementation(cursor);
            method_setImplementation(cursor, (IMP)hooked_x11_display_set_cursor);
            write_str("[Quinta] X11 cursor selection follows set/hide/unhide and resets\n");
        }
        Method method = class_getInstanceMethod(x11_display_class, sel_registerName("postXEvent:"));
        if (method) {
            orig_post_x_event = (void (*)(id, SEL, void*))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_post_x_event);
            write_str("[Quinta] Hooked X11Display postXEvent: (motion compression)\n");
        }
        method = class_getInstanceMethod(x11_display_class, sel_registerName("processPendingEvents"));
        if (method) {
            orig_process_pending_events = (void (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_process_pending_events);
            write_str("[Quinta] X11 input drains bounded to 128 events / 2 ms\n");
        }
    }
    static volatile int subwindow_hooked;
    Class x11_subwindow_class = objc_getClass("X11SubWindow");
    quinta_install_x11_drawable_cache(x11_subwindow_class);
    if (x11_subwindow_class && __sync_bool_compare_and_swap(&subwindow_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            x11_subwindow_class, sel_registerName("initWithParentWindow:frame:"));
        if (method) {
            orig_x11_subwindow_init =
                (id (*)(id, SEL, id, QuintaRect))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_x11_subwindow_init);
            write_str("[Quinta] Hooked X11SubWindow initWithParentWindow:frame: (GL visual)\n");
        }
    }
    Class x11_cursor_class = objc_getClass("X11Cursor");
    if (x11_cursor_class &&
        __sync_bool_compare_and_swap(&cursor_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            x11_cursor_class, sel_registerName("initWithImage:hotPoint:"));
        if (method) {
            orig_x11_cursor_init_image =
                (id (*)(id, SEL, id, QuintaPoint))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_x11_cursor_init_image);
            write_str("[Quinta] Replaced X11Cursor initWithImage:hotPoint: (row copy fix)\n");
        }
    }
    static volatile int monitors_hooked;
    Class event_class_for_monitors = objc_getClass("NSEvent");
    Class application_class = objc_getClass("NSApplication");
    if (event_class_for_monitors && application_class &&
        __sync_bool_compare_and_swap(&monitors_hooked, 0, 1)) {
        Method add = class_getClassMethod(
            event_class_for_monitors,
            sel_registerName("addLocalMonitorForEventsMatchingMask:handler:"));
        Method remove = class_getClassMethod(
            event_class_for_monitors, sel_registerName("removeMonitor:"));
        Method send = class_getInstanceMethod(
            application_class, sel_registerName("sendEvent:"));
        if (add && remove && send) {
            method_setImplementation(add, (IMP)event_add_local_monitor);
            method_setImplementation(remove, (IMP)event_remove_monitor);
            orig_app_send_event =
                (void (*)(id, SEL, id))method_getImplementation(send);
            method_setImplementation(send, (IMP)hooked_app_send_event);
            write_str("[Quinta] Implemented NSEvent local event monitors\n");
        }
        Method accepts = class_getInstanceMethod(
            objc_getClass("NSWindow"), sel_registerName("acceptsMouseMovedEvents"));
        if (accepts) {
            orig_window_accepts_mouse_moved =
                (QuintaBool (*)(id, SEL))method_getImplementation(accepts);
            method_setImplementation(accepts, (IMP)hooked_window_accepts_mouse_moved);
            write_str("[Quinta] RBXWindow always accepts mouse-moved events\n");
        }
        Method wclose = class_getInstanceMethod(
            objc_getClass("NSWindow"), sel_registerName("close"));
        if (wclose) {
            orig_window_close = (void (*)(id, SEL))method_getImplementation(wclose);
            method_setImplementation(wclose, (IMP)hooked_window_close);
            write_str("[Quinta] RBXWindow close writes the quit sentinel\n");
        }
        Method wperform = class_getInstanceMethod(
            objc_getClass("NSWindow"), sel_registerName("performClose:"));
        if (wperform) {
            orig_window_perform_close =
                (void (*)(id, SEL, id))method_getImplementation(wperform);
            method_setImplementation(wperform, (IMP)hooked_window_perform_close);
        }
    }
    static volatile int button_number_hooked;
    Class mouse_event_class = objc_getClass("NSEvent_mouse");
    if (mouse_event_class &&
        __sync_bool_compare_and_swap(&button_number_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            mouse_event_class, sel_registerName("buttonNumber"));
        if (method) {
            orig_mouse_event_button_number =
                (long (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_mouse_event_button_number);
            write_str("[Quinta] NSEvent buttonNumber uses macOS numbering\n");
        }
        method = class_getInstanceMethod(mouse_event_class, sel_registerName("deltaX"));
        if (method) {
            orig_mouse_event_delta_x =
                (double (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_mouse_event_delta_x);
        }
        method = class_getInstanceMethod(mouse_event_class, sel_registerName("deltaY"));
        if (method) {
            orig_mouse_event_delta_y =
                (double (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_mouse_event_delta_y);
            write_str("[Quinta] NSEvent motion deltaY uses macOS sign\n");
        }
        method = class_getInstanceMethod(mouse_event_class, sel_registerName("locationInWindow"));
        if (method) {
            orig_event_location_in_window =
                (QuintaPoint (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_event_location_in_window);
        }
        method = class_getInstanceMethod(objc_getClass("NSWindow"),
                                         sel_registerName("mouseLocationOutsideOfEventStream"));
        if (method) {
            orig_window_mouse_location =
                (QuintaPoint (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_window_mouse_location);
        }
        method = class_getClassMethod(objc_getClass("NSEvent"), sel_registerName("mouseLocation"));
        if (method) {
            orig_event_mouse_location =
                (QuintaPoint (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_event_mouse_location);
        }
        write_str("[Quinta] Mouse location freezes during mouse lock\n");
    }
    static volatile int text_input_added;
    Class text_view_class = objc_getClass("NSTextView");
    if (text_view_class &&
        __sync_bool_compare_and_swap(&text_input_added, 0, 1)) {
        struct { const char* name; IMP imp; const char* types; } methods[] = {
            {"hasMarkedText", (IMP)text_view_has_marked_text, "c@:"},
            {"markedRange", (IMP)text_view_marked_range, "{_NSRange=QQ}@:"},
            {"unmarkText", (IMP)text_view_unmark_text, "v@:"},
            {"validAttributesForMarkedText", (IMP)text_view_valid_marked_attributes, "@@:"},
            {"attributedSubstringForProposedRange:actualRange:",
             (IMP)text_view_attributed_substring, "@@:{_NSRange=QQ}^{_NSRange=QQ}"},
        };
        for (unsigned long index = 0; index < sizeof(methods) / sizeof(methods[0]); index++) {
            SEL selector = sel_registerName(methods[index].name);
            if (!class_getInstanceMethod(text_view_class, selector) &&
                class_addMethod(text_view_class, selector, methods[index].imp,
                                methods[index].types)) {
                write_str("[Quinta] Added NSTextView ");
                write_str(methods[index].name);
                write_str("\n");
            }
        }
    }
    quinta_install_text_input_hooks();
    static volatile int constructors_added;
    if (__sync_bool_compare_and_swap(&constructors_added, 0, 1)) {
        Class button_meta = object_getClass((id)objc_getClass("NSButton"));
        Class text_field_meta = object_getClass((id)objc_getClass("NSTextField"));
        SEL button_selector = sel_registerName("buttonWithImage:target:action:");
        SEL label_selector = sel_registerName("labelWithString:");
        if (button_meta && !class_getInstanceMethod(button_meta, button_selector) &&
            class_addMethod(button_meta, button_selector,
                            (IMP)button_with_image_target_action, "@@:@@:"))
            write_str("[Quinta] Added +[NSButton buttonWithImage:target:action:]\n");
        if (text_field_meta && !class_getInstanceMethod(text_field_meta, label_selector) &&
            class_addMethod(text_field_meta, label_selector,
                            (IMP)text_field_label_with_string, "@@:@"))
            write_str("[Quinta] Added +[NSTextField labelWithString:]\n");
    }
    static volatile int contacts_added;
    Class contact_store_class = objc_getClass("CNContactStore");
    if (contact_store_class &&
        __sync_bool_compare_and_swap(&contacts_added, 0, 1)) {
        Class contact_store_meta = object_getClass((id)contact_store_class);
        SEL status = sel_registerName("authorizationStatusForEntityType:");
        SEL request = sel_registerName("requestAccessForEntityType:completionHandler:");
        if (!class_getInstanceMethod(contact_store_meta, status) &&
            class_addMethod(contact_store_meta, status,
                            (IMP)contact_store_authorization_denied, "q@:q"))
            write_str("[Quinta] Added CNContactStore authorization (denied)\n");
        if (!class_getInstanceMethod(contact_store_class, request))
            class_addMethod(contact_store_class, request,
                            (IMP)contact_store_request_access, "v@:q@?");
    }
    static volatile int pixel_format_hooked;
    Class pixel_format_class = objc_getClass("NSOpenGLPixelFormat");
    if (pixel_format_class && __sync_bool_compare_and_swap(&pixel_format_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(pixel_format_class, sel_registerName("initWithAttributes:"));
        if (method) {
            orig_pixel_format_init = (id (*)(id, SEL, const unsigned int*))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_pixel_format_init);
        }
    }
    static volatile int web_hooked;
    Class web_view_class = objc_getClass("WKWebView");
    Class workspace_class = objc_getClass("NSWorkspace");
    if (web_view_class && workspace_class &&
        __sync_bool_compare_and_swap(&web_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            web_view_class, sel_registerName("initWithFrame:configuration:"));
        if (method) {
            orig_web_view_init = (id (*)(id, SEL, QuintaRect, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_web_view_init);
        }
        method = class_getInstanceMethod(web_view_class, sel_registerName("loadRequest:"));
        if (method) {
            orig_web_view_load_request = (id (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_web_view_load_request);
        }
        method = class_getInstanceMethod(workspace_class, sel_registerName("openURL:"));
        if (method) {
            orig_workspace_open_url = (QuintaBool (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_workspace_open_url);
        }
        write_str("[Quinta] Tracing WKWebView and NSWorkspace openURL:\n");
    }
    Class window_class = objc_getClass("NSWindow");
    if (window_class &&
        __sync_bool_compare_and_swap(&window_events_hooked, 0, 1)) {
        Method method = class_getInstanceMethod(
            window_class, sel_registerName("sendEvent:"));
        if (method) {
            orig_window_send_event =
                (void (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_window_send_event);
        }
    }
}

// A direct executable launch has no Apple Event. Darling lacks this selector;
// its generic forwarding path otherwise leaves an invalid object return value.
static id no_current_apple_event(id self, SEL cmd) { (void)self; (void)cmd; return 0; }

// Added in newer Foundation versions than Darling currently implements.
// Build relative file URLs using the older URL and NSString APIs that Darling
// does provide.
static id url_file_with_path_relative_to_url(id cls, SEL cmd, id path, id base_url) {
    (void)cmd;
    if (!path)
        return 0;

    signed char is_absolute = ((signed char (*)(id, SEL))objc_msgSend)(
        path, sel_registerName("isAbsolutePath"));
    if (!base_url || is_absolute)
        return ((id (*)(id, SEL, id))objc_msgSend)(
            cls, sel_registerName("fileURLWithPath:"), path);

    id base_path = ((id (*)(id, SEL))objc_msgSend)(base_url, sel_registerName("path"));
    id combined_path = base_path
        ? ((id (*)(id, SEL, id))objc_msgSend)(
              base_path, sel_registerName("stringByAppendingPathComponent:"), path)
        : path;
    return ((id (*)(id, SEL, id))objc_msgSend)(
        cls, sel_registerName("fileURLWithPath:"), combined_path);
}

static int ascii_equal_case_insensitive(const char* left, const char* right) {
    for (;; left++, right++) {
        char a = *left >= 'A' && *left <= 'Z' ? (char)(*left + 32) : *left;
        char b = *right >= 'A' && *right <= 'Z' ? (char)(*right + 32) : *right;
        if (a != b)
            return 0;
        if (!a)
            return 1;
    }
}

static int ascii_contains_case_insensitive(const char* text, const char* needle) {
    if (!text || !needle || !*needle)
        return 0;
    for (const char* start = text; *start; start++) {
        const char* a = start;
        const char* b = needle;
        while (*a && *b) {
            char ca = (*a >= 'A' && *a <= 'Z') ? *a + ('a' - 'A') : *a;
            char cb = (*b >= 'A' && *b <= 'Z') ? *b + ('a' - 'A') : *b;
            if (ca != cb)
                break;
            a++;
            b++;
        }
        if (!*b)
            return 1;
    }
    return 0;
}

// Cookies. Roblox on macOS keeps the login (.ROBLOSECURITY) in
// NSHTTPCookieStorage: its HTTP goes through libcurl, and it takes cookies
// from the storage (cookies, cookiesForURL:) and puts Set-Cookie results
// back (setCookies:forURL:mainDocumentURL:). Darling gets all of that wrong:
// its cookie parser crashes on a valid host-only Set-Cookie (it copies a
// missing Domain), setCookies:forURL:mainDocumentURL: does nothing,
// cookiesForURL: ignores the URL (every cookie for every URL, login included,
// also over plain http), and nothing is kept on disk. So Set-Cookie headers
// are parsed here (cookies built with +[NSHTTPCookie cookieWithProperties:],
// Domain always set) and the cookies are kept here (quinta_cookie_store):
// the newest value wins, a URL gets only the cookies whose domain, path,
// Secure flag and expiry fit it, and persistent cookies are saved to
// ~/Library/Quinta/Cookies.plist (mode 0600, replaced atomically) and
// loaded back at startup.
#define MSG0(r, o, sel) ((r (*)(id, SEL))objc_msgSend)((id)(o), sel_registerName(sel))
#define MSG1(r, o, sel, a) ((r (*)(id, SEL, id))objc_msgSend)((id)(o), sel_registerName(sel), (a))
#define MSG2(r, o, sel, a, b) ((r (*)(id, SEL, id, id))objc_msgSend)((id)(o), sel_registerName(sel), (a), (b))
static id quinta_nsstring(const char* text) {
    return ((id (*)(id, SEL, const char*))objc_msgSend)(
        (id)objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), text);
}
static id quinta_trimmed(id string) {
    id whitespace = MSG0(id, objc_getClass("NSCharacterSet"), "whitespaceAndNewlineCharacterSet");
    return MSG1(id, string, "stringByTrimmingCharactersInSet:", whitespace);
}
static id quinta_cf_boolean(int value) {
    return ((id (*)(id, SEL, QuintaBool))objc_msgSend)(
        (id)objc_getClass("NSNumber"), sel_registerName("numberWithBool:"), (QuintaBool)(value != 0));
}

static id quinta_http_date(id text) {
    id formatter = MSG0(id, MSG0(id, objc_getClass("NSDateFormatter"), "alloc"), "init");
    MSG1(void, formatter, "setLocale:",
         MSG1(id, objc_getClass("NSLocale"), "localeWithLocaleIdentifier:", quinta_nsstring("en_US_POSIX")));
    MSG1(void, formatter, "setTimeZone:",
         MSG1(id, objc_getClass("NSTimeZone"), "timeZoneWithAbbreviation:", quinta_nsstring("GMT")));
    static const char* formats[] = {"EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd-MMM-yyyy HH:mm:ss zzz",
                                    "EEE, dd-MMM-yy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz"};
    id date = 0;
    for (int index = 0; index < 4 && !date; index++) {
        MSG1(void, formatter, "setDateFormat:", quinta_nsstring(formats[index]));
        date = MSG1(id, formatter, "dateFromString:", text);
    }
    MSG0(void, formatter, "release");
    return date;
}

// Does `host` fall under cookie domain `domain` (both lowercase; a leading
// dot on the domain is ignored)?
static int quinta_domain_matches(id host, id domain) {
    if (!host || !domain)
        return 0;
    if (MSG1(QuintaBool, domain, "hasPrefix:", quinta_nsstring(".")))
        domain = ((id (*)(id, SEL, unsigned long))objc_msgSend)(domain, sel_registerName("substringFromIndex:"), 1);
    if (!MSG0(unsigned long, domain, "length"))
        return 0;
    return MSG1(QuintaBool, host, "isEqualToString:", domain) ||
           MSG1(QuintaBool, host, "hasSuffix:", MSG1(id, quinta_nsstring("."), "stringByAppendingString:", domain));
}

// Build one NSHTTPCookie from a single "name=value; attr; attr=value" string.
static id quinta_cookie_from_string(id line, id url) {
    id parts = MSG1(id, line, "componentsSeparatedByString:", quinta_nsstring(";"));
    unsigned long count = MSG0(unsigned long, parts, "count");
    if (!count)
        return 0;
    id first = quinta_trimmed(MSG1(id, parts, "objectAtIndex:", (id)0));
    unsigned long equals = ((QuintaRange (*)(id, SEL, id))objc_msgSend)(
        first, sel_registerName("rangeOfString:"), quinta_nsstring("=")).location;
    if (equals == 0x7FFFFFFFFFFFFFFFUL || equals == 0)
        return 0;
    id properties = MSG0(id, objc_getClass("NSMutableDictionary"), "dictionary");
    MSG2(void, properties, "setObject:forKey:",
         quinta_trimmed(((id (*)(id, SEL, unsigned long))objc_msgSend)(first, sel_registerName("substringToIndex:"), equals)),
         quinta_nsstring("Name"));
    MSG2(void, properties, "setObject:forKey:",
         ((id (*)(id, SEL, unsigned long))objc_msgSend)(first, sel_registerName("substringFromIndex:"), equals + 1),
         quinta_nsstring("Value"));
    id host = url ? MSG0(id, url, "host") : 0;
    MSG2(void, properties, "setObject:forKey:", host ? host : quinta_nsstring("roblox.com"),
         quinta_nsstring("Domain"));
    MSG2(void, properties, "setObject:forKey:", quinta_nsstring("/"), quinta_nsstring("Path"));
    // Darling's CFHTTPCookieIsSecure reads Secure with CFBooleanGetValue and
    // crashes when it is missing, so it is always set, as a CFBoolean.
    MSG2(void, properties, "setObject:forKey:", quinta_cf_boolean(0), quinta_nsstring("Secure"));
    for (unsigned long index = 1; index < count; index++) {
        id attribute = quinta_trimmed(((id (*)(id, SEL, unsigned long))objc_msgSend)(
            parts, sel_registerName("objectAtIndex:"), index));
        unsigned long split = ((QuintaRange (*)(id, SEL, id))objc_msgSend)(
            attribute, sel_registerName("rangeOfString:"), quinta_nsstring("=")).location;
        id key = split == 0x7FFFFFFFFFFFFFFFUL ? attribute
            : ((id (*)(id, SEL, unsigned long))objc_msgSend)(attribute, sel_registerName("substringToIndex:"), split);
        id value = split == 0x7FFFFFFFFFFFFFFFUL ? quinta_nsstring("")
            : quinta_trimmed(((id (*)(id, SEL, unsigned long))objc_msgSend)(
                  attribute, sel_registerName("substringFromIndex:"), split + 1));
        const char* name = MSG0(const char*, MSG0(id, quinta_trimmed(key), "lowercaseString"), "UTF8String");
        if (!name)
            continue;
        if (ascii_strings_equal(name, "domain") && MSG0(unsigned long, value, "length")) {
            // A server may only set cookies for its own domain (RFC 6265).
            if (host && !quinta_domain_matches(MSG0(id, host, "lowercaseString"),
                                                 MSG0(id, value, "lowercaseString")))
                return 0;
            MSG2(void, properties, "setObject:forKey:", value, quinta_nsstring("Domain"));
        } else if (ascii_strings_equal(name, "path") && MSG0(unsigned long, value, "length")) {
            MSG2(void, properties, "setObject:forKey:", value, quinta_nsstring("Path"));
        } else if (ascii_strings_equal(name, "expires")) {
            id date = quinta_http_date(value);
            if (date && !MSG1(id, properties, "objectForKey:", quinta_nsstring("Max-Age")))
                MSG2(void, properties, "setObject:forKey:", date, quinta_nsstring("Expires"));
        } else if (ascii_strings_equal(name, "max-age")) {
            double seconds = MSG0(double, value, "doubleValue");
            id date = ((id (*)(id, SEL, double))objc_msgSend)(
                (id)objc_getClass("NSDate"), sel_registerName("dateWithTimeIntervalSinceNow:"), seconds);
            MSG2(void, properties, "setObject:forKey:", date, quinta_nsstring("Expires"));
            MSG2(void, properties, "setObject:forKey:", value, quinta_nsstring("Max-Age"));
        } else if (ascii_strings_equal(name, "secure")) {
            MSG2(void, properties, "setObject:forKey:", quinta_cf_boolean(1), quinta_nsstring("Secure"));
        }
    }
    MSG1(void, properties, "removeObjectForKey:", quinta_nsstring("Max-Age"));
    return MSG1(id, objc_getClass("NSHTTPCookie"), "cookieWithProperties:", properties);
}

// Split a combined Set-Cookie header ("a=1; Expires=Wed, 21 Oct ...,b=2")
// at commas that start a new "name=" pair, not at commas inside dates.
static id quinta_split_set_cookie(id header) {
    id result = MSG0(id, objc_getClass("NSMutableArray"), "array");
    const char* text = MSG0(const char*, header, "UTF8String");
    if (!text)
        return result;
    unsigned long start = 0, length = 0;
    while (text[length]) length++;
    for (unsigned long index = 0; index <= length; index++) {
        int boundary = index == length;
        if (!boundary && text[index] == ',') {
            unsigned long probe = index + 1;
            while (text[probe] == ' ') probe++;
            unsigned long name_end = probe;
            while (text[name_end] && text[name_end] != '=' && text[name_end] != ';' &&
                   text[name_end] != ',' && text[name_end] != ' ')
                name_end++;
            boundary = name_end > probe && text[name_end] == '=';
        }
        if (boundary) {
            if (index > start) {
                id piece = ((id (*)(id, SEL, const void*, unsigned long, unsigned long))objc_msgSend)(
                    MSG0(id, objc_getClass("NSString"), "alloc"),
                    sel_registerName("initWithBytes:length:encoding:"), text + start, index - start, 4UL);
                MSG1(void, result, "addObject:", piece);
                MSG0(void, piece, "release");
            }
            start = index + 1;
        }
    }
    return result;
}

static id (*orig_cookies_with_response_headers)(id, SEL, id, id) = 0;
static id cookies_with_response_headers(id cls, SEL cmd, id headers, id url) {
    (void)cls; (void)cmd;
    id cookies = MSG0(id, objc_getClass("NSMutableArray"), "array");
    id keys = headers ? MSG0(id, headers, "allKeys") : 0;
    unsigned long count = keys ? MSG0(unsigned long, keys, "count") : 0;
    for (unsigned long index = 0; index < count; index++) {
        id key = ((id (*)(id, SEL, unsigned long))objc_msgSend)(keys, sel_registerName("objectAtIndex:"), index);
        const char* key_text = key ? MSG0(const char*, key, "UTF8String") : 0;
        if (!key_text || !ascii_equal_case_insensitive(key_text, "set-cookie"))
            continue;
        id value = MSG1(id, headers, "objectForKey:", key);
        id lines = MSG1(QuintaBool, value, "isKindOfClass:", (id)objc_getClass("NSArray"))
            ? value : quinta_split_set_cookie(value);
        unsigned long line_count = MSG0(unsigned long, lines, "count");
        for (unsigned long line = 0; line < line_count; line++) {
            id cookie = quinta_cookie_from_string(
                ((id (*)(id, SEL, unsigned long))objc_msgSend)(lines, sel_registerName("objectAtIndex:"), line), url);
            if (cookie)
                MSG1(void, cookies, "addObject:", cookie);
        }
    }
    return cookies;
}

extern int open(const char*, int, ...);
extern int close(int);
extern int rename(const char*, const char*);
extern int unlink(const char*);

// ~/Library/Quinta/Cookies.plist, the folder made private (0700).
static id quinta_cookie_file(void) {
    static id file;
    if (file)
        return file;
    id home = ((id (*)(void))dlsym(RTLD_DEFAULT, "NSHomeDirectory"))();
    const char* session_directory = getenv("QUINTA_SESSION_DIRECTORY");
    if (!session_directory || !session_directory[0]) session_directory = "Library/Quinta";
    id directory = MSG1(id, home, "stringByAppendingPathComponent:",
                        quinta_nsstring(session_directory));
    ((QuintaBool (*)(id, SEL, id, QuintaBool, id, id*))objc_msgSend)(
        MSG0(id, objc_getClass("NSFileManager"), "defaultManager"),
        sel_registerName("createDirectoryAtPath:withIntermediateDirectories:attributes:error:"),
        directory, 1, 0, 0);
    chmod(MSG0(const char*, directory, "fileSystemRepresentation"), 0700);
    file = MSG0(id, MSG1(id, directory, "stringByAppendingPathComponent:", quinta_nsstring("Cookies.plist")),
                "retain");
    return file;
}

// The store: domain|path|name -> the cookie's properties (as saved), and
// -> the NSHTTPCookie handed out. Session cookies (no expiry date) are kept
// only in memory. Roblox's HTTP threads use it at the same time, so every
// access holds quinta_cookie_lock; the NSMutableDictionary is not
// thread-safe.
static id quinta_cookie_entries, quinta_cookie_objects;
static volatile int quinta_cookie_lock_word, quinta_cookie_write_word;
static void quinta_cookie_lock(void) {
    while (__sync_lock_test_and_set(&quinta_cookie_lock_word, 1))
        quinta_sleep_us(50);
}
static void quinta_cookie_unlock(void) { __sync_lock_release(&quinta_cookie_lock_word); }

static void quinta_cookie_store_init(void) { // with the lock held
    if (!quinta_cookie_entries) {
        quinta_cookie_entries = MSG0(id, MSG0(id, objc_getClass("NSMutableDictionary"), "alloc"), "init");
        quinta_cookie_objects = MSG0(id, MSG0(id, objc_getClass("NSMutableDictionary"), "alloc"), "init");
    }
}

static id quinta_cookie_key(id domain, id path, id name) {
    return ((id (*)(id, SEL, id, ...))objc_msgSend)(
        (id)objc_getClass("NSString"), sel_registerName("stringWithFormat:"),
        quinta_nsstring("%@|%@|%@"), domain ? MSG0(id, domain, "lowercaseString") : quinta_nsstring(""),
        path ? path : quinta_nsstring("/"), name ? name : quinta_nsstring(""));
}

static int quinta_cookie_expired(id expires, id now) {
    return expires && MSG1(long, expires, "compare:", now) != 1 /* NSOrderedDescending */;
}

// Write the persistent cookies: to Cookies.plist.tmp, created 0600, then
// renamed over Cookies.plist, so a crash or a kill during the write never
// leaves a cut-off file (which logged the user out). One writer at a time,
// and the snapshot is taken by the writer, so the last write is the newest.
static void quinta_save_cookies(void) {
    while (__sync_lock_test_and_set(&quinta_cookie_write_word, 1))
        quinta_sleep_us(1000);
    @autoreleasepool {
        id now = MSG0(id, objc_getClass("NSDate"), "date");
        id persistent = MSG0(id, objc_getClass("NSMutableArray"), "array");
        quinta_cookie_lock();
        @try {
            id entries = quinta_cookie_entries ? MSG0(id, quinta_cookie_entries, "allValues") : 0;
            unsigned long count = entries ? MSG0(unsigned long, entries, "count") : 0;
            for (unsigned long index = 0; index < count; index++) {
                id entry = ((id (*)(id, SEL, unsigned long))objc_msgSend)(entries, sel_registerName("objectAtIndex:"), index);
                id expires = MSG1(id, entry, "objectForKey:", quinta_nsstring("Expires"));
                if (expires && !quinta_cookie_expired(expires, now))
                    MSG1(void, persistent, "addObject:", entry);
            }
        } @finally {
            quinta_cookie_unlock();
        }
        id file = quinta_cookie_file();
        id temporary = MSG1(id, file, "stringByAppendingString:", quinta_nsstring(".tmp"));
        const char* temporary_path = MSG0(const char*, temporary, "fileSystemRepresentation");
        const char* file_path = MSG0(const char*, file, "fileSystemRepresentation");
        // Created private before any cookie is in it; the plist write keeps the mode.
        int fd = open(temporary_path, 0x1 /* O_WRONLY */ | 0x200 /* O_CREAT */ | 0x400 /* O_TRUNC */, 0600);
        if (fd >= 0) {
            close(fd);
            chmod(temporary_path, 0600);
            if (((QuintaBool (*)(id, SEL, id, QuintaBool))objc_msgSend)(
                    persistent, sel_registerName("writeToFile:atomically:"), temporary, 0))
                rename(temporary_path, file_path); // Darling leaves atomic writes as .tmpN files
            else
                unlink(temporary_path);
        }
    }
    __sync_lock_release(&quinta_cookie_write_word);
}

// Put `cookie` into the store (or take it out); 1 if a persistent cookie
// changed, i.e. the file must be written.
static int quinta_store_cookie(id cookie, int deleted) {
    if (!cookie)
        return 0;
    id name = MSG0(id, cookie, "name");
    id domain = MSG0(id, cookie, "domain");
    id path = MSG0(id, cookie, "path");
    if (!name || !domain)
        return 0;
    if (!path || !MSG0(unsigned long, path, "length"))
        path = quinta_nsstring("/");
    id key = quinta_cookie_key(domain, path, name);
    id expires = MSG0(id, cookie, "expiresDate");
    id now = MSG0(id, objc_getClass("NSDate"), "date");
    if (quinta_cookie_expired(expires, now))
        deleted = 1; // an expired Set-Cookie is how servers delete cookies
    id entry = 0, object = 0;
    if (!deleted) {
        entry = MSG0(id, objc_getClass("NSMutableDictionary"), "dictionary");
        MSG2(void, entry, "setObject:forKey:", name, quinta_nsstring("Name"));
        id value = MSG0(id, cookie, "value");
        MSG2(void, entry, "setObject:forKey:", value ? value : quinta_nsstring(""), quinta_nsstring("Value"));
        MSG2(void, entry, "setObject:forKey:", domain, quinta_nsstring("Domain"));
        MSG2(void, entry, "setObject:forKey:", path, quinta_nsstring("Path"));
        if (expires)
            MSG2(void, entry, "setObject:forKey:", expires, quinta_nsstring("Expires"));
        id properties = MSG0(id, cookie, "properties");
        id secure = properties ? MSG1(id, properties, "objectForKey:", quinta_nsstring("Secure")) : 0;
        int is_secure = secure && ((QuintaBool (*)(id, SEL, SEL))objc_msgSend)(secure, sel_registerName("respondsToSelector:"), sel_registerName("boolValue"))
            && MSG0(QuintaBool, secure, "boolValue");
        MSG2(void, entry, "setObject:forKey:", quinta_cf_boolean(is_secure), quinta_nsstring("Secure"));
        object = MSG1(id, objc_getClass("NSHTTPCookie"), "cookieWithProperties:", entry);
        if (!object)
            return 0;
    }
    int changed = 0, persistent_changed = 0;
    quinta_cookie_lock();
    @try {
        quinta_cookie_store_init();
        id old = MSG1(id, quinta_cookie_entries, "objectForKey:", key);
        int old_persistent = old && MSG1(id, old, "objectForKey:", quinta_nsstring("Expires"));
        if (deleted) {
            changed = old != 0;
            persistent_changed = old_persistent;
            MSG1(void, quinta_cookie_entries, "removeObjectForKey:", key);
            MSG1(void, quinta_cookie_objects, "removeObjectForKey:", key);
        } else {
            changed = !old || !MSG1(QuintaBool, old, "isEqualToDictionary:", entry);
            persistent_changed = changed && (old_persistent || expires);
            if (changed) {
                MSG2(void, quinta_cookie_entries, "setObject:forKey:", entry, key);
                MSG2(void, quinta_cookie_objects, "setObject:forKey:", object, key);
            }
        }
    } @finally {
        quinta_cookie_unlock();
    }
    if (changed) { // one write per line: HTTP threads log at the same time
        char line[300];
        unsigned long used = 0;
        const char* parts[] = {"[Quinta Cookies] ", deleted ? "delete " : "set ",
                               MSG0(const char*, name, "UTF8String"), " domain=",
                               MSG0(const char*, domain, "UTF8String"),
                               deleted ? "\n" : (expires ? " persistent\n" : " session\n")};
        for (unsigned index = 0; index < sizeof parts / sizeof parts[0]; index++)
            for (const char* c = parts[index] ? parts[index] : "?"; *c && used < sizeof line - 2; c++)
                line[used++] = *c;
        if (used && line[used - 1] != '\n')
            line[used++] = '\n';
        write(2, line, used);
    }
    return persistent_changed;
}

// The store's cookies that fit `url` (all of them without a URL), and after
// them Darling's own that fit and that the store has no newer value of.
static id quinta_cookies_for(id url, id darling_cookies) {
    id host = url ? MSG0(id, MSG0(id, url, "host"), "lowercaseString") : 0;
    if (url && !host)
        return MSG0(id, objc_getClass("NSMutableArray"), "array");
    id url_path = url ? MSG0(id, url, "path") : 0;
    if (!url_path || !MSG0(unsigned long, url_path, "length"))
        url_path = quinta_nsstring("/");
    id scheme = url ? MSG0(id, MSG0(id, url, "scheme"), "lowercaseString") : 0;
    int secure_url = !url || MSG1(QuintaBool, scheme, "isEqualToString:", quinta_nsstring("https")) ||
                     MSG1(QuintaBool, scheme, "isEqualToString:", quinta_nsstring("wss"));
    id now = MSG0(id, objc_getClass("NSDate"), "date");
    id result = MSG0(id, objc_getClass("NSMutableArray"), "array");
    id names = MSG0(id, objc_getClass("NSMutableSet"), "set");
    for (int pass = 0; pass < 2; pass++) {
        id cookies = darling_cookies;
        if (pass == 0) {
            quinta_cookie_lock();
            @try {
                cookies = quinta_cookie_objects ? MSG0(id, quinta_cookie_objects, "allValues") : 0;
            } @finally {
                quinta_cookie_unlock();
            }
        }
        unsigned long count = cookies ? MSG0(unsigned long, cookies, "count") : 0;
        for (unsigned long index = 0; index < count; index++) {
            id cookie = ((id (*)(id, SEL, unsigned long))objc_msgSend)(cookies, sel_registerName("objectAtIndex:"), index);
            id name = MSG0(id, cookie, "name");
            if (!name || (pass == 1 && MSG1(QuintaBool, names, "containsObject:", name)))
                continue;
            if (quinta_cookie_expired(MSG0(id, cookie, "expiresDate"), now))
                continue;
            if (url) {
                if (!quinta_domain_matches(host, MSG0(id, MSG0(id, cookie, "domain"), "lowercaseString")))
                    continue;
                id path = MSG0(id, cookie, "path");
                unsigned long length = path ? MSG0(unsigned long, path, "length") : 0;
                // RFC 6265 path-match: the cookie path, then "/" or the end.
                if (length && !(MSG1(QuintaBool, url_path, "isEqualToString:", path) ||
                                (MSG1(QuintaBool, url_path, "hasPrefix:", path) &&
                                 (MSG1(QuintaBool, path, "hasSuffix:", quinta_nsstring("/")) ||
                                  ((unsigned short (*)(id, SEL, unsigned long))objc_msgSend)(
                                      url_path, sel_registerName("characterAtIndex:"), length) == '/'))))
                    continue;
                id properties = MSG0(id, cookie, "properties");
                id secure = properties ? MSG1(id, properties, "objectForKey:", quinta_nsstring("Secure")) : 0;
                if (!secure_url && secure &&
                    ((QuintaBool (*)(id, SEL, SEL))objc_msgSend)(secure, sel_registerName("respondsToSelector:"), sel_registerName("boolValue")) &&
                    MSG0(QuintaBool, secure, "boolValue"))
                    continue;
            }
            MSG1(void, result, "addObject:", cookie);
            MSG1(void, names, "addObject:", name);
        }
    }
    return result;
}

static void (*orig_cookie_storage_set)(id, SEL, id) = 0;
static void hooked_cookie_storage_set(id self, SEL cmd, id cookie) {
    orig_cookie_storage_set(self, cmd, cookie);
    int save;
    @autoreleasepool {
        save = quinta_store_cookie(cookie, 0);
    }
    if (save)
        quinta_save_cookies();
}
static void (*orig_cookie_storage_set_many)(id, SEL, id, id, id) = 0;
static void hooked_cookie_storage_set_many(id self, SEL cmd, id cookies, id url, id main_url) {
    orig_cookie_storage_set_many(self, cmd, cookies, url, main_url);
    int save = 0;
    @autoreleasepool {
        unsigned long count = cookies ? MSG0(unsigned long, cookies, "count") : 0;
        for (unsigned long index = 0; index < count; index++)
            save |= quinta_store_cookie(((id (*)(id, SEL, unsigned long))objc_msgSend)(
                cookies, sel_registerName("objectAtIndex:"), index), 0);
    }
    if (save)
        quinta_save_cookies(); // once per batch
}
static void (*orig_cookie_storage_delete)(id, SEL, id) = 0;
static void hooked_cookie_storage_delete(id self, SEL cmd, id cookie) {
    orig_cookie_storage_delete(self, cmd, cookie);
    int save;
    @autoreleasepool {
        save = quinta_store_cookie(cookie, 1);
    }
    if (save)
        quinta_save_cookies();
}

static id (*orig_cookie_storage_for_url)(id, SEL, id) = 0;
static id hooked_cookie_storage_for_url(id self, SEL cmd, id url) {
    id darling = orig_cookie_storage_for_url(self, cmd, url);
    if (!url)
        return darling;
    id result;
    @autoreleasepool {
        result = MSG0(id, quinta_cookies_for(url, darling), "copy");
    }
    return MSG0(id, result, "autorelease");
}

static id (*orig_cookie_storage_cookies)(id, SEL) = 0;
static id hooked_cookie_storage_cookies(id self, SEL cmd) {
    id darling = orig_cookie_storage_cookies(self, cmd);
    id result;
    @autoreleasepool {
        result = MSG0(id, quinta_cookies_for(0, darling), "copy");
    }
    return MSG0(id, result, "autorelease");
}

// Only into this store, not Darling's: Darling hands out every cookie it
// has for every URL.
static void quinta_load_cookies(void) {
    int loaded = 0;
    @autoreleasepool {
        id entries = MSG1(id, objc_getClass("NSArray"), "arrayWithContentsOfFile:", quinta_cookie_file());
        unsigned long count = entries ? MSG0(unsigned long, entries, "count") : 0;
        id now = MSG0(id, objc_getClass("NSDate"), "date");
        quinta_cookie_lock();
        @try {
            quinta_cookie_store_init();
            for (unsigned long index = 0; index < count; index++) {
                id entry = ((id (*)(id, SEL, unsigned long))objc_msgSend)(entries, sel_registerName("objectAtIndex:"), index);
                if (!MSG1(QuintaBool, entry, "isKindOfClass:", (id)objc_getClass("NSDictionary")))
                    continue;
                id expires = MSG1(id, entry, "objectForKey:", quinta_nsstring("Expires"));
                if (!expires || quinta_cookie_expired(expires, now))
                    continue;
                id cookie = MSG1(id, objc_getClass("NSHTTPCookie"), "cookieWithProperties:", entry);
                if (!cookie)
                    continue;
                id key = quinta_cookie_key(MSG1(id, entry, "objectForKey:", quinta_nsstring("Domain")),
                                             MSG1(id, entry, "objectForKey:", quinta_nsstring("Path")),
                                             MSG1(id, entry, "objectForKey:", quinta_nsstring("Name")));
                MSG2(void, quinta_cookie_entries, "setObject:forKey:", entry, key);
                MSG2(void, quinta_cookie_objects, "setObject:forKey:", cookie, key);
                loaded++;
            }
        } @finally {
            quinta_cookie_unlock();
        }
    }
    write_str("[Quinta Cookies] loaded ");
    print_num(loaded);
    write_str(" saved cookies\n");
}

// Cocotron stores NSDisplay in thread-local state. Its X11 backend cannot open
// a second display for Roblox's rendering worker, although the main thread's
// display is already valid. Share the first successfully created display.
static id (*orig_current_display)(id, SEL) = 0;
static void *quinta_shared_display;
static volatile int quinta_display_lock;
static id shared_current_display(id cls, SEL cmd) {
    id shared = (id)__atomic_load_n(&quinta_shared_display, __ATOMIC_ACQUIRE);
    if (shared)
        return shared;
    while (__sync_lock_test_and_set(&quinta_display_lock, 1))
        quinta_sleep_us(1000);
    @try {
        shared = (id)__atomic_load_n(&quinta_shared_display, __ATOMIC_RELAXED);
        if (!shared) {
            id display = quinta_wayland_enabled() ? quinta_wayland_display()
                                                    : orig_current_display(cls, cmd);
            if (display) {
                shared = ((id (*)(id, SEL))objc_msgSend)(
                    display, sel_registerName("retain"));
                __atomic_store_n(&quinta_shared_display, (void *)shared, __ATOMIC_RELEASE);
            }
        }
    } @finally {
        // Backend initialization may raise an exception. Let a caller retry
        // without leaving every display request waiting on this lock.
        __sync_lock_release(&quinta_display_lock);
    }
    return shared;
}

__attribute__((constructor))
static void install_swizzles(void) {
    extern const char* getprogname(void);
    const char *prog = getprogname();
    if (prog && ascii_strings_equal(prog, "RobloxCrashHandler")) {
        write_str("[Quinta] Crashpad handler started.\n");
        return;
    }

    write_str("[Quinta] Compatibility shim loaded.\n");
    long slide = _dyld_get_image_vmaddr_slide(0);
    write_str("[Quinta] Main executable ASLR slide: ");
    print_hex(slide);
    write_str("\n");

    // Let Darling and Crashpad own signals unless diagnosis is explicitly requested.
    if (quinta_crash_diagnostics_enabled()) {
        struct darwin_sigaction debug_action = {crash_handler, 0, 0x0040};
        const int fatal_signals[] = {4, 5, 6, 10, 11};
        for (unsigned int index = 0; index < sizeof(fatal_signals) / sizeof(fatal_signals[0]); index++)
            sigaction(fatal_signals[index], &debug_action, 0);
    }

    Class eventManager = objc_getClass("NSAppleEventManager");
    SEL currentEvent = sel_registerName("currentAppleEvent");
    if (eventManager && !class_getInstanceMethod(eventManager, currentEvent)) {
        class_addMethod(eventManager, currentEvent, (IMP)no_current_apple_event, "@@:");
        write_str("[Quinta] Added currentAppleEvent=nil for direct launch\n");
    }

    Class url_class = objc_getClass("NSURL");
    SEL relative_file_url = sel_registerName("fileURLWithPath:relativeToURL:");
    if (url_class && !class_getClassMethod(url_class, relative_file_url)) {
        Class url_meta_class = object_getClass((id)url_class);
        if (url_meta_class && class_addMethod(url_meta_class, relative_file_url,
                                              (IMP)url_file_with_path_relative_to_url,
                                              "@@:@@"))
            write_str("[Quinta] Added NSURL fileURLWithPath:relativeToURL:\n");
    }

    Class event_class = objc_getClass("NSEvent");
    if (event_class) {
        SEL phase = sel_registerName("phase");
        SEL momentum_phase = sel_registerName("momentumPhase");
        if (!class_getInstanceMethod(event_class, phase) &&
            class_addMethod(event_class, phase, (IMP)event_phase_none, "Q@:"))
            write_str("[Quinta] Added NSEvent phase=None\n");
        if (!class_getInstanceMethod(event_class, momentum_phase) &&
            class_addMethod(event_class, momentum_phase,
                            (IMP)event_phase_none, "Q@:"))
            write_str("[Quinta] Added NSEvent momentumPhase=None\n");
    }

    Class process_info_class = objc_getClass("NSProcessInfo");
    if (process_info_class) {
        SEL thermal_state = sel_registerName("thermalState");
        SEL low_power = sel_registerName("isLowPowerModeEnabled");
        if (!class_getInstanceMethod(process_info_class, thermal_state) &&
            class_addMethod(process_info_class, thermal_state,
                            (IMP)process_info_thermal_state_nominal, "q@:"))
            write_str("[Quinta] Added NSProcessInfo thermalState=nominal\n");
        if (!class_getInstanceMethod(process_info_class, low_power) &&
            class_addMethod(process_info_class, low_power,
                            (IMP)process_info_low_power_mode_disabled, "B@:"))
            write_str("[Quinta] Added NSProcessInfo lowPowerMode=false\n");
    }

    Class catalog_color = objc_getClass("NSColor_catalog");
    if (catalog_color) {
        Method dealloc = class_getInstanceMethod(catalog_color, sel_registerName("dealloc"));
        if (dealloc && !orig_catalog_color_dealloc) {
            orig_catalog_color_dealloc = (void (*)(id, SEL))method_setImplementation(dealloc, (IMP)catalog_color_dealloc);
            write_str("[Quinta] NSColor_catalog dealloc releases only owned ivars\n");
        }
    }

    Class cg_color = objc_getClass("NSColor_CGColor");
    if (cg_color) {
        SEL by_name = sel_registerName("colorUsingColorSpaceName:");
        SEL by_space = sel_registerName("colorUsingColorSpace:");
        int added = 0;
        if (class_addMethod(cg_color, by_name, (IMP)cgcolor_using_color_space, "@@:@")) added++;
        if (class_addMethod(cg_color, by_space, (IMP)cgcolor_using_color_space, "@@:@")) added++;
        if (added) write_str("[Quinta] NSColor_CGColor converts colour spaces\n");
    }
    Class screen_class = objc_getClass("NSScreen");
    if (screen_class) {
        SEL max_fps = sel_registerName("maximumFramesPerSecond");
        SEL min_interval = sel_registerName("minimumRefreshInterval");
        SEL max_interval = sel_registerName("maximumRefreshInterval");
        if (!class_getInstanceMethod(screen_class, max_fps) &&
            class_addMethod(screen_class, max_fps, (IMP)screen_maximum_frames_per_second, "q@:")) {
            write_str("[Quinta] Added NSScreen maximumFramesPerSecond=");
            print_num(quinta_display_hz());
            write_str("\n");
        }
        if (!class_getInstanceMethod(screen_class, min_interval))
            class_addMethod(screen_class, min_interval, (IMP)screen_refresh_interval, "d@:");
        if (!class_getInstanceMethod(screen_class, max_interval))
            class_addMethod(screen_class, max_interval, (IMP)screen_refresh_interval, "d@:");
    }

    Class gl_context_class = objc_getClass("NSOpenGLContext");
    if (gl_context_class) {
        if (quinta_wayland_enabled()) {
            Method update = class_getInstanceMethod(gl_context_class, sel_registerName("updateViewParameters"));
            Ivar child = class_getInstanceVariable(gl_context_class, "_subwindow");
            Ivar surface = class_getInstanceVariable(gl_context_class, "_cglWindow");
            if (update && child && surface && ivar_getOffset(child) > 0 && ivar_getOffset(surface) > 0 &&
                class_addMethod(gl_context_class, sel_registerName("_ciderRetryWaylandDrawable:"),
                                (IMP)quinta_retry_gl_drawable, "v@:@")) {
                quinta_gl_subwindow_offset = ivar_getOffset(child);
                quinta_gl_window_offset = ivar_getOffset(surface);
                orig_gl_update_view_parameters = (void (*)(id, SEL))method_getImplementation(update);
                method_setImplementation(update, (IMP)hooked_gl_update_view_parameters);
                write_str("[Quinta Wayland] Bounded recovery for initially unavailable EGL drawables enabled\n");
            }
        }
        Method method = class_getInstanceMethod(
            gl_context_class, sel_registerName("initWithFormat:shareContext:"));
        if (method) {
            orig_gl_context_init =
                (id (*)(id, SEL, id, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_gl_context_init);
        }
        method = class_getInstanceMethod(gl_context_class, sel_registerName("setView:"));
        if (method) {
            orig_gl_context_set_view =
                (void (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_gl_context_set_view);
        }
        method = class_getInstanceMethod(
            gl_context_class, sel_registerName("makeCurrentContext"));
        if (method) {
            orig_gl_context_make_current =
                (void (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_gl_context_make_current);
        }
        method = class_getInstanceMethod(gl_context_class, sel_registerName("flushBuffer"));
        if (method) {
            orig_gl_context_flush =
                (void (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_gl_context_flush);
        }
        write_str("[Quinta] Tracing NSOpenGLContext drawable presentation\n");
    }

    Class layer_context_class = objc_getClass("CALayerContext");
    if (layer_context_class) {
        Method method = class_getInstanceMethod(
            layer_context_class, sel_registerName("renderLayer:"));
        if (method) {
            orig_layer_context_render_layer =
                (void (*)(id, SEL, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_layer_context_render_layer);
            write_str("[Quinta] Hooked CALayerContext renderLayer: (restores GL context)\n");
        }
    }

    Class ca_renderer_class = objc_getClass("CARenderer");
    if (ca_renderer_class) {
        Method method = class_getInstanceMethod(
            ca_renderer_class, sel_registerName("_renderLayer:z:currentTime:"));
        if (method) {
            orig_ca_renderer_render_layer =
                (void (*)(id, SEL, id, double, double))method_getImplementation(method);
            method_setImplementation(method, (IMP)hooked_ca_renderer_render_layer);
            write_str("[Quinta] Hooked CARenderer image upload (empty layers remain transparent)\n");
        }
    }

    Class scroll_event_class = objc_getClass("NSEvent");
    if (scroll_event_class) {
        struct { const char* name; IMP imp; const char* types; } event_methods[] = {
            {"hasPreciseScrollingDeltas", (IMP)event_has_precise_scrolling_deltas, "c@:"},
            {"isDirectionInvertedFromDevice", (IMP)event_is_direction_inverted, "c@:"},
            {"scrollingDeltaX", (IMP)event_scrolling_delta_x, "d@:"},
            {"scrollingDeltaY", (IMP)event_scrolling_delta_y, "d@:"},
        };
        for (unsigned long index = 0;
             index < sizeof(event_methods) / sizeof(event_methods[0]); index++) {
            SEL selector = sel_registerName(event_methods[index].name);
            if (!class_getInstanceMethod(scroll_event_class, selector) &&
                class_addMethod(scroll_event_class, selector, event_methods[index].imp,
                                event_methods[index].types)) {
                write_str("[Quinta] Added NSEvent ");
                write_str(event_methods[index].name);
                write_str("\n");
            }
        }
    }

    quinta_install_late_hooks();

    Class archiver_meta = object_getClass((id)objc_getClass("NSKeyedArchiver"));
    Class unarchiver_meta = object_getClass((id)objc_getClass("NSKeyedUnarchiver"));
    SEL archive = sel_registerName("archivedDataWithRootObject:requiringSecureCoding:error:");
    SEL unarchive = sel_registerName("unarchivedObjectOfClass:fromData:error:");
    if (archiver_meta && !class_getInstanceMethod(archiver_meta, archive) &&
        class_addMethod(archiver_meta, archive, (IMP)keyed_archiver_archived_data, "@@:@c^@"))
        write_str("[Quinta] Added +[NSKeyedArchiver archivedDataWithRootObject:requiringSecureCoding:error:]\n");
    if (unarchiver_meta && !class_getInstanceMethod(unarchiver_meta, unarchive) &&
        class_addMethod(unarchiver_meta, unarchive, (IMP)keyed_unarchiver_unarchived_object, "@@:#@^@"))
        write_str("[Quinta] Added +[NSKeyedUnarchiver unarchivedObjectOfClass:fromData:error:]\n");

    const char* hide_menu = getenv("QUINTA_HIDE_MENU_BAR");
    Class menu_view_class = objc_getClass("NSMainMenuView");
    if (hide_menu && hide_menu[0] == '1' && menu_view_class) {
        Method method = class_getClassMethod(menu_view_class, sel_registerName("menuHeight"));
        if (method) {
            method_setImplementation(method, (IMP)quinta_zero_menu_height);
            write_str("[Quinta] Menu bar hidden\n");
        }
    }

    Class cookie_class = objc_getClass("NSHTTPCookie");
    if (cookie_class) {
        SEL parse_cookies = sel_registerName("cookiesWithResponseHeaderFields:forURL:");
        Method method = class_getClassMethod(cookie_class, parse_cookies);
        if (method) {
            orig_cookies_with_response_headers =
                (id (*)(id, SEL, id, id))method_getImplementation(method);
            method_setImplementation(method, (IMP)cookies_with_response_headers);
            write_str("[Quinta] Hooked NSHTTPCookie response parser\n");
        }
        Class storage_class = objc_getClass("NSHTTPCookieStorage");
        Method set_method = storage_class
            ? class_getInstanceMethod(storage_class, sel_registerName("setCookie:")) : 0;
        Method delete_method = storage_class
            ? class_getInstanceMethod(storage_class, sel_registerName("deleteCookie:")) : 0;
        if (set_method && delete_method) {
            orig_cookie_storage_set = (void (*)(id, SEL, id))method_getImplementation(set_method);
            method_setImplementation(set_method, (IMP)hooked_cookie_storage_set);
            orig_cookie_storage_delete = (void (*)(id, SEL, id))method_getImplementation(delete_method);
            method_setImplementation(delete_method, (IMP)hooked_cookie_storage_delete);
            Method for_url = class_getInstanceMethod(storage_class, sel_registerName("cookiesForURL:"));
            if (for_url) {
                orig_cookie_storage_for_url = (id (*)(id, SEL, id))method_getImplementation(for_url);
                method_setImplementation(for_url, (IMP)hooked_cookie_storage_for_url);
            }
            Method all = class_getInstanceMethod(storage_class, sel_registerName("cookies"));
            if (all) {
                orig_cookie_storage_cookies = (id (*)(id, SEL))method_getImplementation(all);
                method_setImplementation(all, (IMP)hooked_cookie_storage_cookies);
            }
            Method set_many = class_getInstanceMethod(
                storage_class, sel_registerName("setCookies:forURL:mainDocumentURL:"));
            if (set_many) {
                orig_cookie_storage_set_many =
                    (void (*)(id, SEL, id, id, id))method_getImplementation(set_many);
                method_setImplementation(set_many, (IMP)hooked_cookie_storage_set_many);
            }
            quinta_load_cookies();
        }
    }

    Class display_class = objc_getClass("NSDisplay");
    if (display_class) {
        SEL current_display = sel_registerName("currentDisplay");
        Method method = class_getClassMethod(display_class, current_display);
        if (method) {
            orig_current_display = (id (*)(id, SEL))method_getImplementation(method);
            method_setImplementation(method, (IMP)shared_current_display);
            write_str("[Quinta] Sharing NSDisplay across rendering threads\n");
        }
    }

    Class web_preferences_class = objc_getClass("WebPreferences");
    if (web_preferences_class) {
        class_addMethod(web_preferences_class, sel_registerName("setPlugInsEnabled:"),
                        (IMP)web_preferences_set_plugins_enabled, "v@:c");
        class_addMethod(web_preferences_class, sel_registerName("plugInsEnabled"),
                        (IMP)web_preferences_plugins_enabled, "c@:");
    }
    SEL standard_preferences = sel_registerName("standardPreferences");
    if (web_preferences_class &&
        !class_getClassMethod(web_preferences_class, standard_preferences)) {
        Class web_preferences_meta_class = object_getClass((id)web_preferences_class);
        if (web_preferences_meta_class &&
            class_addMethod(web_preferences_meta_class, standard_preferences,
                            (IMP)web_preferences_standard_preferences, "@@:"))
            write_str("[Quinta] Added WebPreferences standardPreferences\n");
    }

    Class capture_device_class = objc_getClass("AVCaptureDevice");
    if (capture_device_class) {
        Class capture_device_meta_class = object_getClass((id)capture_device_class);
        SEL devices = sel_registerName("devices");
        SEL devices_for_type = sel_registerName("devicesWithMediaType:");
        SEL default_for_type = sel_registerName("defaultDeviceWithMediaType:");
        if (!class_getClassMethod(capture_device_class, devices) &&
            class_addMethod(capture_device_meta_class, devices,
                            (IMP)empty_capture_devices, "@@:"))
            write_str("[Quinta] Added empty AVCaptureDevice devices inventory\n");
        if (!class_getClassMethod(capture_device_class, devices_for_type) &&
            class_addMethod(capture_device_meta_class, devices_for_type,
                            (IMP)empty_capture_devices_for_media_type, "@@:@"))
            write_str("[Quinta] Added empty AVCaptureDevice devicesWithMediaType:\n");
        if (!class_getClassMethod(capture_device_class, default_for_type) &&
            class_addMethod(capture_device_meta_class, default_for_type,
                            (IMP)no_default_capture_device, "@@:@"))
            write_str("[Quinta] Added AVCaptureDevice defaultDeviceWithMediaType:=nil\n");
        // Voice chat asks for microphone permission through these (Darling
        // has neither): granted, the host's own permissions apply.
        SEL authorization = sel_registerName("authorizationStatusForMediaType:");
        SEL request_access = sel_registerName("requestAccessForMediaType:completionHandler:");
        if (!class_getClassMethod(capture_device_class, authorization) &&
            class_addMethod(capture_device_meta_class, authorization,
                            (IMP)capture_authorization_status, "q@:@") &&
            class_addMethod(capture_device_meta_class, request_access,
                            (IMP)capture_request_access, "v@:@@?"))
            write_str("[Quinta] Added AVCaptureDevice media permission (granted)\n");
    }

    Class layerCls = objc_getClass("CALayer");
    if (layerCls && !class_getInstanceMethod(layerCls, sel_registerName("setContentsScale:"))
                 && !class_getInstanceMethod(layerCls, sel_registerName("contentsScale"))) {
        class_addMethod(layerCls, sel_registerName("setContentsScale:"), (IMP)layer_set_contents_scale, "v@:d");
        class_addMethod(layerCls, sel_registerName("contentsScale"), (IMP)layer_contents_scale, "d@:");
        write_str("[Quinta] Added CALayer contentsScale state (1x rendering only)\n");
    }

    Class viewCls = objc_getClass("NSView");
    if (viewCls && !class_getInstanceMethod(viewCls, sel_registerName("setAllowedTouchTypes:"))
                && !class_getInstanceMethod(viewCls, sel_registerName("allowedTouchTypes"))) {
        class_addMethod(viewCls, sel_registerName("setAllowedTouchTypes:"), (IMP)view_set_allowed_touch_types, "v@:Q");
        class_addMethod(viewCls, sel_registerName("allowedTouchTypes"), (IMP)view_allowed_touch_types, "Q@:");
        write_str("[Quinta] Added NSView allowedTouchTypes state (no touch synthesis)\n");
    }
    SEL backingSize = sel_registerName("convertSizeToBacking:");
    if (viewCls && !class_getInstanceMethod(viewCls, backingSize)) {
        class_addMethod(viewCls, backingSize, (IMP)backing_size_1x,
                        "{CGSize=dd}@:{CGSize=dd}");
        write_str("[Quinta] Added NSView convertSizeToBacking: (experimental 1x)\n");
    }


    Class window_class = objc_getClass("NSWindow");
    if (window_class) {
        SEL rect_from_screen = sel_registerName("convertRectFromScreen:");
        SEL rect_to_screen = sel_registerName("convertRectToScreen:");
        const char* rect_conversion_types =
            "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}";
        if (!class_getInstanceMethod(window_class, rect_from_screen) &&
            class_addMethod(window_class, rect_from_screen,
                            (IMP)window_convert_rect_from_screen,
                            rect_conversion_types))
            write_str("[Quinta] Added NSWindow convertRectFromScreen:\n");
        if (!class_getInstanceMethod(window_class, rect_to_screen) &&
            class_addMethod(window_class, rect_to_screen,
                            (IMP)window_convert_rect_to_screen,
                            rect_conversion_types))
            write_str("[Quinta] Added NSWindow convertRectToScreen:\n");
        struct { const char* name; IMP imp; const char* types; } titlebar_methods[] = {
            {"setTitlebarAppearsTransparent:", (IMP)window_set_titlebar_appears_transparent, "v@:c"},
            {"titlebarAppearsTransparent", (IMP)window_titlebar_appears_transparent, "c@:"},
            {"setTitleVisibility:", (IMP)window_set_title_visibility, "v@:q"},
            {"titleVisibility", (IMP)window_title_visibility, "q@:"},
            // Window restoration (Qt/Studio): Darling never restores windows.
            {"setRestorable:", (IMP)window_ignore_flag, "v@:c"},
            {"isRestorable", (IMP)window_flag_no, "c@:"},
            {"setRestorationClass:", (IMP)window_ignore_object, "v@:#"},
            {"restorationClass", (IMP)window_object_nil, "#@:"},
            {"invalidateRestorableState", (IMP)window_ignore_none, "v@:"},
            {"setTabbingMode:", (IMP)window_ignore_integer, "v@:q"},
            {"setAnimationBehavior:", (IMP)window_ignore_integer, "v@:q"},
        };
        int titlebar_added = 0;
        for (unsigned long i = 0; i < sizeof titlebar_methods / sizeof titlebar_methods[0]; i++) {
            SEL selector = sel_registerName(titlebar_methods[i].name);
            if (!class_getInstanceMethod(window_class, selector) &&
                class_addMethod(window_class, selector, titlebar_methods[i].imp, titlebar_methods[i].types))
                titlebar_added++;
        }
        if (titlebar_added)
            write_str("[Quinta] Added NSWindow title bar options missing in this Darling\n");
        SEL win_at_pt = sel_registerName("windowNumberAtPoint:belowWindowWithWindowNumber:");
        Method mWinAtPt = class_getClassMethod(window_class, win_at_pt);
        if (mWinAtPt) {
            method_setImplementation(mWinAtPt, (IMP)window_number_at_point);
        } else {
            class_addMethod(object_getClass((id)window_class), win_at_pt,
                            (IMP)window_number_at_point, "q@:{CGPoint=dd}q");
        }
        write_str("[Quinta] Implemented +[NSWindow windowNumberAtPoint:belowWindowWithWindowNumber:]\n");
    }

    Class ccls = objc_getClass("NSConcreteScanner");
    if (ccls) {
        Method m = class_getInstanceMethod(ccls, sel_registerName("initWithString:"));
        if (m) {
            orig_concrete_initWithString = (id (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_concrete_initWithString);
            write_str("[Quinta] Hooked NSConcreteScanner initWithString:\n");
        }
    }

    Class appCls = objc_getClass("NSApplication");
    if (appCls) {
        Method mRun = class_getInstanceMethod(appCls, sel_registerName("run"));
        if (mRun) {
            orig_app_run = (void (*)(id, SEL))method_getImplementation(mRun);
            method_setImplementation(mRun, (IMP)hooked_app_run);
            write_str("[Quinta] Hooked NSApplication run\n");
        }
        Method mFinish = class_getInstanceMethod(appCls, sel_registerName("finishLaunching"));
        if (mFinish) {
            orig_app_finish_launching =
                (void (*)(id, SEL))method_getImplementation(mFinish);
            method_setImplementation(mFinish, (IMP)hooked_app_finish_launching);
            write_str("[Quinta] Hooked NSApplication finishLaunching\n");
        }
        Method mTerm = class_getInstanceMethod(appCls, sel_registerName("terminate:"));
        if (mTerm) {
            orig_app_terminate = (void (*)(id, SEL, id))method_getImplementation(mTerm);
            method_setImplementation(mTerm, (IMP)hooked_app_terminate);
            write_str("[Quinta] Hooked NSApplication terminate:\n");
        }
        Method mCheck = class_getInstanceMethod(appCls, sel_registerName("_checkForTerminate"));
        if (mCheck) {
            method_setImplementation(mCheck, (IMP)hooked_app_check_for_terminate);
            write_str("[Quinta] Neutralized NSApplication _checkForTerminate\n");
        }
        Method mDel = class_getInstanceMethod(appCls, sel_registerName("setDelegate:"));
        if (mDel) {
            orig_app_setDelegate = (void (*)(id, SEL, id))method_getImplementation(mDel);
            method_setImplementation(mDel, (IMP)hooked_app_setDelegate);
            write_str("[Quinta] Hooked NSApplication setDelegate:\n");
        }
    }

    Class bndlCls = objc_getClass("NSBundle");
    if (bndlCls) {
        Method mNib = class_getClassMethod(bndlCls, sel_registerName("loadNibNamed:owner:"));
        if (mNib) {
            orig_loadNibNamed = (signed char (*)(id, SEL, id, id))method_getImplementation(mNib);
            method_setImplementation(mNib, (IMP)hooked_loadNibNamed);
            write_str("[Quinta] Hooked NSBundle loadNibNamed:owner:\n");
        }
    }

    Class nibCls = objc_getClass("NSNib");
    if (nibCls) {
        Method mInst = class_getInstanceMethod(nibCls, sel_registerName("instantiateNibWithExternalNameTable:"));
        if (mInst) {
            orig_instantiateNib = (signed char (*)(id, SEL, id))method_getImplementation(mInst);
            method_setImplementation(mInst, (IMP)hooked_instantiateNib);
            write_str("[Quinta] Hooked NSNib instantiateNibWithExternalNameTable:\n");
        }
    }

    Class unarchCls = objc_getClass("NSKeyedUnarchiver");
    if (unarchCls) {
        Method m = class_getInstanceMethod(unarchCls, sel_registerName("decodeObjectForKey:"));
        if (m) {
            orig_decodeObjectForKey = (id (*)(id, SEL, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_decodeObjectForKey);
            write_str("[Quinta] Hooked NSKeyedUnarchiver decodeObjectForKey:\n");
        }
    }

    quinta_install_startup_diagnostics();

    Class wtCls = objc_getClass("NSWindowTemplate");
    if (wtCls) {
        Method mWT = class_getInstanceMethod(wtCls, sel_registerName("initWithCoder:"));
        if (mWT) {
            orig_wt_initWithCoder = (id (*)(id, SEL, id))method_getImplementation(mWT);
            method_setImplementation(mWT, (IMP)hooked_wt_initWithCoder);
            write_str("[Quinta] Hooked NSWindowTemplate initWithCoder:\n");
        }
    }

    Class odCls = objc_getClass("NSIBObjectData");
    if (odCls) {
        Method mOD = class_getInstanceMethod(odCls, sel_registerName("initWithCoder:"));
        if (mOD) {
            orig_od_initWithCoder = (id (*)(id, SEL, id))method_getImplementation(mOD);
            method_setImplementation(mOD, (IMP)hooked_od_initWithCoder);
            write_str("[Quinta] Hooked NSIBObjectData initWithCoder:\n");
        }
        Method mODE = class_getInstanceMethod(odCls, sel_registerName("establishConnections"));
        if (mODE) {
            orig_od_establish = (void (*)(id, SEL))method_getImplementation(mODE);
            method_setImplementation(mODE, (IMP)hooked_od_establish);
            write_str("[Quinta] Hooked NSIBObjectData establishConnections\n");
        }
    }

    Class connCls = objc_getClass("NSNibConnector");
    if (connCls) {
        Method mC = class_getInstanceMethod(connCls, sel_registerName("establishConnection"));
        if (mC) {
            orig_conn_establish = (void (*)(id, SEL))method_getImplementation(mC);
            method_setImplementation(mC, (IMP)hooked_conn_establish);
            write_str("[Quinta] Hooked NSNibConnector establishConnection\n");
        }
    }

    Class winCls = objc_getClass("NSWindow");
    if (winCls) {
        Method mW = class_getInstanceMethod(winCls, sel_registerName("initWithContentRect:styleMask:backing:defer:"));
        if (mW) {
            orig_win_init = (id (*)(id, SEL, QuintaRect, unsigned long, unsigned long, QuintaBool))method_getImplementation(mW);
            method_setImplementation(mW, (IMP)hooked_win_init);
            write_str("[Quinta] Hooked NSWindow initWithContentRect:...\n");
        }
    }
}

__attribute__((objc_root_class))
@interface NSObject { Class isa; }
@end

// Foundation Objective-C classes
@interface NSBackgroundActivityScheduler : NSObject @end
@implementation NSBackgroundActivityScheduler @end

// Foundation constants
const void* NSHTTPCookieDomain = @"Domain";
const void* NSHTTPCookieExpires = @"Expires";
const void* NSHTTPCookieName = @"Name";
const void* NSHTTPCookiePath = @"Path";
const void* NSHTTPCookieSecure = @"Secure";
const void* NSHTTPCookieValue = @"Value";
const void* NSHTTPCookieVersion = @"Version";
// Foundation's value (Darling's CoreFoundation exports the same string; with
// a flat namespace this definition wins, so it must be equal).
const void* NSLocalizedDescriptionKey = @"NSLocalizedDescription";
const void* NSProcessInfoThermalStateDidChangeNotification = @"NSProcessInfoThermalStateDidChangeNotification";
const void* NSProcessInfoPowerStateDidChangeNotification = @"NSProcessInfoPowerStateDidChangeNotification";

// Carbon constants
const void* kTISNotifySelectedKeyboardInputSourceChanged = @"kTISNotifySelectedKeyboardInputSourceChanged";
const void* kTISPropertyInputSourceLanguages = @"kTISPropertyInputSourceLanguages";
const void* kTISPropertyUnicodeKeyLayoutData = @"kTISPropertyUnicodeKeyLayoutData";

#include "keyboard_labels.h"

// The original Carbon compatibility framework returned NULL for the current
// keyboard source and all of its properties. Roblox copies the Unicode layout
// data during startup, so that placeholder becomes CFDataCreateCopy(NULL) and
// crashes in CFDataGetLength. Keep real Objective-C objects alive for the
// process and provide a valid ANSI fallback resource for key-label queries.
static id quinta_keyboard_source;
static id quinta_keyboard_layout_data;
static id quinta_keyboard_languages;

// Built by one thread; the source is published last, so a thread that sees
// it also sees the layout data (another thread used to get a NULL layout,
// the very crash this avoids).
static void quinta_initialize_keyboard_source(void) {
    static volatile int state; // 0 new, 1 building, 2 done
    if (state == 2)
        return;
    if (!__sync_bool_compare_and_swap(&state, 0, 1)) {
        while (state != 2)
            quinta_sleep_us(100);
        return;
    }
    Class object_class = objc_getClass("NSObject");
    Class data_class = objc_getClass("NSData");
    Class array_class = objc_getClass("NSArray");
    if (object_class && data_class && array_class) {
        QuintaKeyboardLabels layout;
        quinta_build_keyboard_labels(&layout);
        id data = ((id (*)(id, SEL, const void*, unsigned long))objc_msgSend)(
            (id)data_class, sel_registerName("dataWithBytes:length:"), &layout, sizeof layout);
        quinta_keyboard_layout_data = data
            ? ((id (*)(id, SEL))objc_msgSend)(data, sel_registerName("retain")) : 0;
        id languages = ((id (*)(id, SEL, id))objc_msgSend)(
            (id)array_class, sel_registerName("arrayWithObject:"), @"en");
        quinta_keyboard_languages = languages
            ? ((id (*)(id, SEL))objc_msgSend)(languages, sel_registerName("retain")) : 0;
        id source = ((id (*)(id, SEL))objc_msgSend)((id)object_class, sel_registerName("new"));
        __sync_synchronize();
        quinta_keyboard_source = source;
        if (source && quinta_keyboard_layout_data)
            write_str("[Quinta] Carbon key labels use a valid ANSI fallback layout\n");
    }
    __sync_synchronize();
    state = 2;
}

void* TISCopyCurrentKeyboardInputSource(void) {
    quinta_initialize_keyboard_source();
    return quinta_keyboard_source
        ? ((id (*)(id, SEL))objc_msgSend)(quinta_keyboard_source, sel_registerName("retain")) : 0;
}

void* TISCopyCurrentKeyboardLayoutInputSource(void) {
    return TISCopyCurrentKeyboardInputSource();
}

const void* TISGetInputSourceProperty(void* source, const void* key) {
    (void)source;
    quinta_initialize_keyboard_source();
    if (key == kTISPropertyInputSourceLanguages)
        return quinta_keyboard_languages;
    if (key == kTISPropertyUnicodeKeyLayoutData)
        return quinta_keyboard_layout_data;
    return 0;
}

// Roblox uses this API for UI key names, separately from AppKit text input.
// Never report successful empty translation for a printable key such as E.
int UCKeyTranslate(const void* layout, unsigned short key_code,
                   unsigned short key_action, unsigned int modifiers,
                   unsigned int keyboard_type, unsigned int options,
                   unsigned int* dead_key_state,
                   unsigned long max_length,
                   unsigned long* actual_length,
                   unsigned short* unicode_string) {
    if (quinta_is_keyboard_labels(layout))
        return quinta_translate_keyboard_label(layout, key_code, key_action, modifiers,
            dead_key_state, max_length, actual_length, unicode_string);
    int (*real_translate)(const void*, unsigned short, unsigned short, unsigned int,
        unsigned int, unsigned int, unsigned int*, unsigned long, unsigned long*, unsigned short*) =
        QUINTA_NEXT(int (*)(const void*, unsigned short, unsigned short, unsigned int,
            unsigned int, unsigned int, unsigned int*, unsigned long, unsigned long*, unsigned short*),
            "UCKeyTranslate");
    if (real_translate && real_translate != UCKeyTranslate && layout && actual_length &&
        dead_key_state && unicode_string && key_code < 128 && key_action <= 3 && max_length)
        return real_translate(layout, key_code, key_action, modifiers, keyboard_type, options,
            dead_key_state, max_length, actual_length, unicode_string);
    if (actual_length) *actual_length = 0;
    return -50;
}

// CoreServices constants
const void* kUTTagClassFilenameExtension = @"public.filename-extension";
const void* kUTTypeImage = @"public.image";
const void* kUTTypeMovie = @"public.movie";

// CoreVideo constants
const void* kCVPixelBufferCGBitmapContextCompatibilityKey = @"kCVPixelBufferCGBitmapContextCompatibilityKey";
const void* kCVPixelBufferCGImageCompatibilityKey = @"kCVPixelBufferCGImageCompatibilityKey";

// GameController constants
const void* GCControllerDidConnectNotification = @"GCControllerDidConnectNotification";
const void* GCControllerDidDisconnectNotification = @"GCControllerDidDisconnectNotification";

// SystemConfiguration constants
const void* kSCNetworkInterfaceTypeEthernet = @"Ethernet";
const void* kSCNetworkInterfaceTypeIEEE80211 = @"IEEE80211";

// VideoToolbox constants
const void* kVTDecompressionPropertyKey_RealTime = @"RealTime";
const void* kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder = @"RequireHardwareAcceleratedVideoDecoder";
const void* kVTVideoEncoderList_CodecType = @"CodecType";
const void* kVTVideoEncoderList_EncoderName = @"EncoderName";
