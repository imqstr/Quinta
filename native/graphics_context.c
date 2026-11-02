#include "graphics_context.h"
#include "shim_lock.h"

extern void *malloc(unsigned long);
extern unsigned int eglBindAPI(unsigned int);
extern int eglGetError(void);
extern void *CGLGetCurrentContext(void);
extern int CGLSetCurrentContext(void *);

#define EGL_OPENGL_API 0x30A2
#define EGL_SUCCESS 0x3000
#define CGL_BAD_CONTEXT 10004
#define CGL_BAD_DRAWABLE 10005

static __thread unsigned long binding_serial, swap_serial;
static __thread int binding_failed, swap_failed;
static __thread int binding_error, swap_error, pending_error;
static __thread void *current_egl_context;
static __thread int draw_checked;
static void *draw_contexts[256];
static unsigned int draw_next;
static volatile unsigned int draw_lock;

/* Logging/rollback must not consume the EGL error the application expects. */
int quinta_capture_egl_error(void) {
    int error = eglGetError();
    pending_error = error;
    return error;
}

static int quinta_eglGetError(void) {
    if (pending_error) {
        int error = pending_error;
        pending_error = 0;
        return error;
    }
    return eglGetError();
}

#ifdef __APPLE__
__attribute__((used, section("__DATA,__interpose")))
static const void *error_interpose[] = {(void *)quinta_eglGetError, (void *)eglGetError};
#endif

/* Also callable by the native regression without Mach-O interposition. */
int quinta_graphics_get_error(void) {
    return quinta_eglGetError();
}

int quinta_bind_desktop_gl(void) {
    if (eglBindAPI(EGL_OPENGL_API))
        return 1;
    quinta_capture_egl_error();
    return 0;
}

void quinta_record_egl_binding(unsigned int succeeded, void *context) {
    binding_serial++;
    binding_failed = !succeeded;
    binding_error = succeeded ? EGL_SUCCESS : quinta_capture_egl_error();
    if (succeeded && context != current_egl_context) {
        current_egl_context = context;
        draw_checked = 0;
    }
}

void quinta_forget_egl_context(void *context) {
    if (!context)
        return;
    quinta_lock(&draw_lock);
    for (unsigned int i = 0; i < 256; i++)
        if (draw_contexts[i] == context)
            draw_contexts[i] = 0;
    quinta_unlock(&draw_lock);
}

void quinta_register_egl_context(void *context) {
    quinta_forget_egl_context(context);
}

int quinta_graphics_first_draw(void) {
    if (!current_egl_context || draw_checked)
        return 0;
    int first = 1;
    quinta_lock(&draw_lock);
    for (unsigned int i = 0; i < 256; i++)
        if (draw_contexts[i] == current_egl_context) {
            first = 0;
            break;
        }
    if (first) {
        draw_contexts[draw_next] = current_egl_context;
        draw_next = (draw_next + 1) % 256;
    }
    quinta_unlock(&draw_lock);
    draw_checked = 1;
    return first;
}

int quinta_egl_binding_error(void) {
    return binding_error;
}

int quinta_begin_context_change(quinta_context_change *change) {
    change->previous = CGLGetCurrentContext();
    change->binding_serial = binding_serial;
    change->surface_slot = 0;
    change->previous_surface = 0;
    return quinta_bind_desktop_gl();
}

int quinta_finish_context_change(const quinta_context_change *change, int cgl_error) {
    if (binding_serial == change->binding_serial || !binding_failed)
        return cgl_error;
    int error = binding_error;
    if (change->surface_slot)
        *change->surface_slot = change->previous_surface;
    /* Darling changes its CGL TLS even when EGL rejects the new context.
     * Restore both through its original entry point; EGL failures themselves
     * leave the old driver context current. NULL restores an unbound thread. */
    CGLSetCurrentContext(change->previous);
    pending_error = error;
    return CGL_BAD_CONTEXT;
}

void quinta_record_egl_swap(unsigned int succeeded) {
    swap_serial++;
    swap_failed = !succeeded;
    swap_error = succeeded ? EGL_SUCCESS : quinta_capture_egl_error();
}

int quinta_last_egl_swap_error(void) {
    return swap_failed ? swap_error : EGL_SUCCESS;
}

unsigned long quinta_egl_swap_serial(void) {
    return swap_serial;
}

int quinta_finish_cgl_swap(unsigned long serial, int cgl_error) {
    if (swap_serial != serial && swap_failed) {
        pending_error = swap_error;
        return CGL_BAD_DRAWABLE;
    }
    return cgl_error;
}

static int attribute_takes_value(int attribute) {
    switch (attribute) {
    case 7: case 8: case 11: case 12: case 13: case 14: case 55: case 56:
    case 70: case 84: case 99: case 128:
        return 1;
    default:
        return 0;
    }
}

int *quinta_copy_pixel_attributes(const int *attributes) {
    if (!attributes)
        return 0;
    unsigned long count = 0;
    while (count < 1024 && attributes[count]) {
        if (attribute_takes_value(attributes[count]))
            count++;
        count++;
    }
    if (count >= 1024)
        return 0;
    int *copy = malloc((count + 1) * sizeof(*copy));
    if (copy)
        for (unsigned long i = 0; i <= count; i++)
            copy[i] = attributes[i];
    return copy;
}
