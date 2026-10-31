#ifndef QUINTA_GRAPHICS_CONTEXT_H
#define QUINTA_GRAPHICS_CONTEXT_H

/* EGL outcomes are recorded before Darling discards them in its CGL layer. */
typedef struct {
    void *previous;
    unsigned long binding_serial;
    void **surface_slot;
    void *previous_surface;
} quinta_context_change;

int quinta_begin_context_change(quinta_context_change *change);
int quinta_finish_context_change(const quinta_context_change *change, int cgl_error);
void quinta_record_egl_binding(unsigned int succeeded, void *context);
void quinta_register_egl_context(void *context);
void quinta_forget_egl_context(void *context);
int quinta_graphics_first_draw(void);
void quinta_record_egl_swap(unsigned int succeeded);
unsigned long quinta_egl_swap_serial(void);
int quinta_finish_cgl_swap(unsigned long serial, int cgl_error);
int quinta_bind_desktop_gl(void);
int quinta_egl_binding_error(void);
int quinta_capture_egl_error(void);
int quinta_graphics_get_error(void);

/* Return an owned, terminated copy, or NULL on allocation/invalid input. */
int *quinta_copy_pixel_attributes(const int *attributes);

#endif
