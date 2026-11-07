/* Darling calls EGL through Mach-O trampolines. Load MangoHud's host EGL
 * hooks directly, without its process-wide OpenGL dlsym/preload hooks. */
#include "graphics_context.h"
extern void quinta_frame_presented(void *, void *, unsigned int);
extern void quinta_forget_gl_context(void *);
extern void *dlsym(void *, const char *);
extern char *getenv(const char *);
extern long write(int, const void *, unsigned long);
extern int snprintf(char *, unsigned long, const char *, ...);
extern unsigned int eglSwapBuffers(void *, void *);
extern unsigned int eglDestroyContext(void *, void *);

static volatile unsigned int initialized;
static unsigned int (*hud_swap)(void *, void *);
static unsigned int (*hud_destroy)(void *, void *);

static void initialize_overlay(void) {
    const char *library = getenv("QUINTA_MANGOHUD_OPENGL");
    if (!library || !*library)
        return;
    struct elf_head {
        void *(*open)(const char *, int);
        int (*close)(void *);
        void *(*symbol)(void *, const char *);
    } **elf = dlsym((void *)-2 /* RTLD_DEFAULT */, "_elfcalls");
    if (elf && *elf) {
        void *handle = (*elf)->open(library, 2 /* RTLD_NOW */);
        void *(*find)(const char *) = handle
            ? (*elf)->symbol(handle, "mangohud_find_egl_ptr") : 0;
        if (find) {
            hud_swap = find("eglSwapBuffers");
            hud_destroy = find("eglDestroyContext");
        }
    }
    static const char ready[] = "[MangoHud] Native OpenGL overlay enabled\n";
    static const char missing[] = "[MangoHud] OpenGL overlay unavailable; continuing without overlay\n";
    if (hud_swap) write(2, ready, sizeof(ready) - 1);
    else write(2, missing, sizeof(missing) - 1);
}

extern void *eglGetCurrentSurface(int);
extern void *eglGetCurrentContext(void);
extern unsigned int eglMakeCurrent(void *, void *, void *, void *);
/* Darling recreates a view's child window and EGL surface when the app
 * attaches the view again, but the context stays bound to the destroyed
 * surface: drawing went nowhere and presenting the new one failed with
 * EGL_BAD_SURFACE (Studio's whole interface stayed black). Bind the surface
 * being presented to the current context first; later frames draw into it. */
static void quinta_bind_presented_surface(void *display, void *surface) {
    void *context = eglGetCurrentContext();
    if (!context || !surface || eglGetCurrentSurface(0x3059 /* EGL_DRAW */) == surface)
        return;
    eglMakeCurrent(display, surface, surface, context);
}

static unsigned int quinta_hud_swap(void *display, void *surface) {
    quinta_bind_presented_surface(display, surface);
    {   /* QUINTA_TRACE_SWAP=1: sample the centre pixel of big surfaces before presenting. */
        static volatile long sampled;
        const char *t = getenv("QUINTA_TRACE_SWAP");
        if (t && t[0] == '1' && (__sync_add_and_fetch(&sampled, 1) % 200) == 1) {
            extern unsigned int eglQuerySurface(void *, void *, int, int *);
            extern void *dlsym(void *, const char *);
            int w = 0, h = 0; eglQuerySurface(display, surface, 0x3057, &w); eglQuerySurface(display, surface, 0x3056, &h);
            void (*read_pixels)(int, int, int, int, unsigned, unsigned, void *) = dlsym((void *)-1, "glReadPixels");
            void (*get_integer)(unsigned, int *) = dlsym((void *)-1, "glGetIntegerv");
            unsigned char px[4] = {0}; int fb = -1;
            if (w > 400 && h > 400 && read_pixels && get_integer) {
                get_integer(0x8CAA /* READ_FRAMEBUFFER_BINDING */, &fb);
                read_pixels(w / 2, h / 2, 1, 1, 0x1908 /* RGBA */, 0x1401 /* UNSIGNED_BYTE */, px);
                char line[160]; int n = snprintf(line, sizeof line, "[Quinta Pixel] %dx%d fb=%d centre=%u,%u,%u,%u\n", w, h, fb, px[0], px[1], px[2], px[3]);
                if (n > 0) write(2, line, (unsigned long)n);
            }
        }
    }
    if (!__atomic_load_n(&initialized, __ATOMIC_ACQUIRE) &&
        __sync_bool_compare_and_swap(&initialized, 0, 1)) {
        initialize_overlay();
        __atomic_store_n(&initialized, 2, __ATOMIC_RELEASE);
    }
    /* A concurrent first swap can proceed normally while loading the overlay.
     * Publication only happens after all function pointers are initialized. */
    unsigned int result = __atomic_load_n(&initialized, __ATOMIC_ACQUIRE) == 2 && hud_swap
        ? hud_swap(display, surface) : eglSwapBuffers(display, surface);
    quinta_record_egl_swap(result);
    quinta_frame_presented(display, surface, result);
    static void *seen[64];
    static int seen_count;
    const char *trace = getenv("QUINTA_TRACE_SWAP");
    int first = 0;
    if (trace && trace[0] == '1') {
        first = 1;
        for (int i = 0; i < seen_count; i++) if (seen[i] == surface) { first = 0; break; }
        if (first && seen_count < 64) seen[seen_count++] = surface;
    }
    if (first) {
        extern unsigned int eglQuerySurface(void *, void *, int, int *);
        extern int quinta_last_egl_swap_error(void);
        int width = 0, height = 0;
        eglQuerySurface(display, surface, 0x3057 /* EGL_WIDTH */, &width);
        eglQuerySurface(display, surface, 0x3056 /* EGL_HEIGHT */, &height);
        char line[160];
        int n = snprintf(line, sizeof line, "[Quinta Swap] surface %p %dx%d result %u error 0x%x\n",
                         surface, width, height, result, quinta_last_egl_swap_error());
        if (n > 0) write(2, line, (unsigned long)n);
    }
    return result;
}

static unsigned int quinta_hud_destroy(void *display, void *context) {
    unsigned int result = __atomic_load_n(&initialized, __ATOMIC_ACQUIRE) == 2 && hud_destroy
        ? hud_destroy(display, context) : eglDestroyContext(display, context);
    if (result) {
        quinta_forget_egl_context(context);
        quinta_forget_gl_context(context);
    }
    return result;
}

#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const void *pair_##replacement[] = {(void *)replacement, (void *)original};
INTERPOSE(quinta_hud_swap, eglSwapBuffers)
INTERPOSE(quinta_hud_destroy, eglDestroyContext)

/* QUINTA_TRACE_SWAP=1: also log how drawables are created (window or pbuffer). */
extern void *eglCreatePbufferSurface(void *, void *, const int *);
extern void *eglCreatePlatformWindowSurface(void *, void *, void *, const long *);
static int quinta_trace_swap(void) { const char *t = getenv("QUINTA_TRACE_SWAP"); return t && t[0] == '1'; }
static void *quinta_trace_pbuffer(void *display, void *config, const int *attributes) {
    void *surface = eglCreatePbufferSurface(display, config, attributes);
    if (quinta_trace_swap()) {
        int width = 0, height = 0;
        for (const int *a = attributes; a && a[0] != 0x3038 /* EGL_NONE */; a += 2) {
            if (a[0] == 0x3057) width = a[1];
            if (a[0] == 0x3056) height = a[1];
        }
        char line[120];
        int n = snprintf(line, sizeof line, "[Quinta Swap] pbuffer %dx%d -> %p\n", width, height, surface);
        if (n > 0) write(2, line, (unsigned long)n);
    }
    return surface;
}
static void *quinta_trace_platform_window(void *display, void *config, void *native, const long *attributes) {
    void *surface = eglCreatePlatformWindowSurface(display, config, native, attributes);
    if (quinta_trace_swap()) {
        char line[120];
        int n = snprintf(line, sizeof line, "[Quinta Swap] platform window %p (xid 0x%lx) -> %p\n",
                         native, native ? *(unsigned long *)native : 0UL, surface);
        if (n > 0) write(2, line, (unsigned long)n);
    }
    return surface;
}
INTERPOSE(quinta_trace_pbuffer, eglCreatePbufferSurface)
INTERPOSE(quinta_trace_platform_window, eglCreatePlatformWindowSurface)
