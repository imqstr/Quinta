#ifndef QUINTA_X11_DRAWABLE_CACHE_H
#define QUINTA_X11_DRAWABLE_CACHE_H

/* Include after the shim's Objective-C and QuintaRect declarations. This
 * removes repeated child-window requests without bypassing NSOpenGLContext's
 * preparation or its main-thread updateViewParameters call. */
extern Method *class_copyMethodList(Class, unsigned int *);
extern unsigned int method_getNumberOfArguments(Method);
extern void method_getArgumentType(Method, unsigned int, char *, unsigned long);
extern void method_getReturnType(Method, char *, unsigned long);
extern const char *ivar_getTypeEncoding(Ivar);
extern unsigned long class_getInstanceSize(Class);
extern id objc_getAssociatedObject(id, const void *);
extern void objc_setAssociatedObject(id, const void *, id, unsigned long);
extern void free(void *);
extern int pthread_main_np(void);

typedef struct {
    void *display;
    unsigned long child, parent_window;
    id parent;
    unsigned long long epoch;
    int x, y;
    unsigned int width, height;
    int frame_known, visibility_known, visible;
} QuintaDrawableState;

static Class quinta_drawable_class, quinta_drawable_parent_class;
static long quinta_drawable_display_offset, quinta_drawable_window_offset;
static long quinta_drawable_parent_offset;
static SEL quinta_drawable_convert_selector, quinta_drawable_handle_selector;
static QuintaRect (*quinta_drawable_convert_original)(id, SEL, QuintaRect);
static void (*quinta_drawable_frame_original)(id, SEL, QuintaRect);
static void (*quinta_drawable_show_original)(id, SEL);
static void (*quinta_drawable_hide_original)(id, SEL);
static int quinta_drawable_install_state;
static unsigned int quinta_drawable_off_main_active;
static unsigned long long quinta_drawable_off_main_epoch;
static unsigned long long quinta_drawable_main_calls; /* main thread only */
static char quinta_drawable_state_key;

static int quinta_drawable_equal(const char *a, const char *b) {
    if (!a || !b) return 0;
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

/* Ignore struct names, but require exactly two nested pairs of doubles.
 * A size-only check could accidentally accept a different 32-byte ABI. */
static const char *quinta_drawable_struct_fields(const char *type) {
    if (!type || *type++ != '{') return 0;
    while (*type && *type != '=') {
        if (*type == '{' || *type == '}') return 0;
        type++;
    }
    return *type == '=' ? type + 1 : 0;
}

static int quinta_drawable_rect_type(const char *type) {
    const char *fields = quinta_drawable_struct_fields(type);
    if (!fields) return 0;
    for (int pair = 0; pair < 2; pair++) {
        fields = quinta_drawable_struct_fields(fields);
        if (!fields || fields[0] != 'd' || fields[1] != 'd' || fields[2] != '}') return 0;
        fields += 3;
    }
    return fields[0] == '}' && !fields[1];
}

static int quinta_drawable_method_abi(Method method, int rect_argument, int rect_return) {
    if (!method || method_getNumberOfArguments(method) != (rect_argument ? 3U : 2U)) return 0;
    char type[256] = {0};
    method_getReturnType(method, type, sizeof type);
    type[sizeof type - 1] = 0;
    if (rect_return ? !quinta_drawable_rect_type(type) : !quinta_drawable_equal(type, "v")) return 0;
    method_getArgumentType(method, 0, type, sizeof type);
    type[sizeof type - 1] = 0;
    if (!quinta_drawable_equal(type, "@")) return 0;
    method_getArgumentType(method, 1, type, sizeof type);
    type[sizeof type - 1] = 0;
    if (!quinta_drawable_equal(type, ":")) return 0;
    if (rect_argument) {
        method_getArgumentType(method, 2, type, sizeof type);
        type[sizeof type - 1] = 0;
        if (!quinta_drawable_rect_type(type)) return 0;
    }
    return 1;
}

static int quinta_drawable_owned(Class cls, Method method) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    int owned = 0;
    for (unsigned int index = 0; methods && index < count; index++)
        if (methods[index] == method) { owned = 1; break; }
    free(methods);
    return owned;
}

static int quinta_drawable_ivar(Class cls, const char *name, char kind, long *offset) {
    Ivar ivar = class_getInstanceVariable(cls, name);
    const char *type = ivar ? ivar_getTypeEncoding(ivar) : 0;
    if (!type || type[0] != kind || (kind == 'Q' && type[1])) return 0;
    long position = ivar_getOffset(ivar);
    unsigned long size = class_getInstanceSize(cls);
    if (position < (long)sizeof(void *) || (unsigned long)position % sizeof(void *) ||
        size < sizeof(void *) || (unsigned long)position > size - sizeof(void *)) return 0;
    *offset = position;
    return 1;
}

static int quinta_drawable_epoch_valid(unsigned long long epoch) {
    return !__atomic_load_n(&quinta_drawable_off_main_active, __ATOMIC_ACQUIRE) &&
        __atomic_load_n(&quinta_drawable_off_main_epoch, __ATOMIC_ACQUIRE) == epoch;
}

static void quinta_drawable_off_main_begin(void) {
    __atomic_add_fetch(&quinta_drawable_off_main_active, 1, __ATOMIC_ACQ_REL);
    __atomic_add_fetch(&quinta_drawable_off_main_epoch, 1, __ATOMIC_ACQ_REL);
}

static void quinta_drawable_off_main_end(void) {
    __atomic_add_fetch(&quinta_drawable_off_main_epoch, 1, __ATOMIC_RELEASE);
    __atomic_sub_fetch(&quinta_drawable_off_main_active, 1, __ATOMIC_RELEASE);
}

static int quinta_drawable_identity(id self, QuintaDrawableState *state) {
    if (!self || object_getClass(self) != quinta_drawable_class) return 0;
    state->display = *(void **)((char *)self + quinta_drawable_display_offset);
    state->child = *(unsigned long *)((char *)self + quinta_drawable_window_offset);
    state->parent = *(id *)((char *)self + quinta_drawable_parent_offset);
    if (!state->display || !state->child || !state->parent ||
        object_getClass(state->parent) != quinta_drawable_parent_class) return 0;
    state->parent_window = ((unsigned long (*)(id, SEL))objc_msgSend)(
        state->parent, quinta_drawable_handle_selector);
    return state->parent_window != 0;
}

static int quinta_drawable_same_identity(const QuintaDrawableState *a,
                                           const QuintaDrawableState *b) {
    return a->display == b->display && a->child == b->child &&
        a->parent == b->parent && a->parent_window == b->parent_window;
}

/* Only the main thread reads or changes the association. Atomic retain gives
 * the returned immutable NSData its normal safe getter lifetime. */
static void quinta_drawable_load(id self, QuintaDrawableState *state) {
    id data = objc_getAssociatedObject(self, &quinta_drawable_state_key);
    if (!data || ((unsigned long (*)(id, SEL))objc_msgSend)(data, sel_registerName("length")) != sizeof *state)
        return;
    const unsigned char *bytes = ((const unsigned char *(*)(id, SEL))objc_msgSend)(data, sel_registerName("bytes"));
    if (!bytes) return;
    QuintaDrawableState cached;
    for (unsigned long index = 0; index < sizeof cached; index++)
        ((unsigned char *)&cached)[index] = bytes[index];
    if (cached.epoch == state->epoch && quinta_drawable_same_identity(&cached, state) &&
        quinta_drawable_epoch_valid(state->epoch))
        *state = cached;
}

static void quinta_drawable_publish(id self, const QuintaDrawableState *state,
                                     unsigned long long call) {
    if (quinta_drawable_main_calls != call || !quinta_drawable_epoch_valid(state->epoch)) return;
    QuintaDrawableState current = {0};
    if (!quinta_drawable_identity(self, &current) || !quinta_drawable_same_identity(state, &current)) return;
    id data = ((id (*)(id, SEL, const void *, unsigned long))objc_msgSend)(
        (id)objc_getClass("NSData"), sel_registerName("dataWithBytes:length:"), state, sizeof *state);
    if (data && quinta_drawable_main_calls == call && quinta_drawable_epoch_valid(state->epoch)) {
        objc_setAssociatedObject(self, &quinta_drawable_state_key, data,
                                 01401UL /* OBJC_ASSOCIATION_RETAIN, atomic */);
        /* A worker may start between the last check and publication. Its
         * changed epoch makes this state unusable; never inspect it there. */
        if (!quinta_drawable_epoch_valid(state->epoch))
            objc_setAssociatedObject(self, &quinta_drawable_state_key, 0, 01401UL);
    }
}

static int quinta_drawable_geometry(QuintaRect rect, QuintaDrawableState *state) {
    if (!(rect.origin.x >= -2147483648.0 && rect.origin.x <= 2147483647.0 &&
          rect.origin.y >= -2147483648.0 && rect.origin.y <= 2147483647.0 &&
          rect.size.width >= 1.0 && rect.size.width <= 4294967295.0 &&
          rect.size.height >= 1.0 && rect.size.height <= 4294967295.0)) return 0;
    state->x = (int)rect.origin.x;
    state->y = (int)rect.origin.y;
    state->width = (unsigned int)rect.size.width;
    state->height = (unsigned int)rect.size.height;
    return 1;
}

static int quinta_drawable_same_geometry(const QuintaDrawableState *a,
                                          const QuintaDrawableState *b) {
    return a->x == b->x && a->y == b->y && a->width == b->width && a->height == b->height;
}

static void quinta_drawable_set_frame(id self, SEL cmd, QuintaRect frame) {
    if (!pthread_main_np()) {
        quinta_drawable_off_main_begin();
        @try { quinta_drawable_frame_original(self, cmd, frame); }
        @finally { quinta_drawable_off_main_end(); }
        return;
    }
    QuintaDrawableState state = {0};
    state.epoch = __atomic_load_n(&quinta_drawable_off_main_epoch, __ATOMIC_ACQUIRE);
    int supported = __atomic_load_n(&quinta_drawable_install_state, __ATOMIC_ACQUIRE) == 2 &&
        quinta_drawable_identity(self, &state) && quinta_drawable_epoch_valid(state.epoch);
    QuintaDrawableState requested = state;
    if (supported) {
        quinta_drawable_load(self, &state);
        /* Calling the original IMP handles CGRect's structure-return ABI and
         * includes the parent's current frame height and border style. */
        supported = quinta_drawable_geometry(
            quinta_drawable_convert_original(self, quinta_drawable_convert_selector, frame), &requested);
        if (supported && state.frame_known && quinta_drawable_same_geometry(&state, &requested) &&
            quinta_drawable_epoch_valid(state.epoch)) return;
    }
    objc_setAssociatedObject(self, &quinta_drawable_state_key, 0, 01401UL);
    unsigned long long call = ++quinta_drawable_main_calls;
    quinta_drawable_frame_original(self, cmd, frame);
    /* Exceptions above propagate with the previous success state removed. */
    if (supported && quinta_drawable_epoch_valid(state.epoch)) {
        QuintaDrawableState after = requested;
        if (quinta_drawable_geometry(
                quinta_drawable_convert_original(self, quinta_drawable_convert_selector, frame), &after) &&
            quinta_drawable_same_geometry(&requested, &after)) {
            state.x = requested.x; state.y = requested.y;
            state.width = requested.width; state.height = requested.height;
            state.frame_known = 1;
            quinta_drawable_publish(self, &state, call);
        }
    }
}

static void quinta_drawable_visibility(id self, SEL cmd, int visible) {
    void (*original)(id, SEL) = visible ? quinta_drawable_show_original : quinta_drawable_hide_original;
    if (!pthread_main_np()) {
        quinta_drawable_off_main_begin();
        @try { original(self, cmd); }
        @finally { quinta_drawable_off_main_end(); }
        return;
    }
    QuintaDrawableState state = {0};
    state.epoch = __atomic_load_n(&quinta_drawable_off_main_epoch, __ATOMIC_ACQUIRE);
    int supported = __atomic_load_n(&quinta_drawable_install_state, __ATOMIC_ACQUIRE) == 2 &&
        quinta_drawable_identity(self, &state) && quinta_drawable_epoch_valid(state.epoch);
    if (supported) {
        quinta_drawable_load(self, &state);
        if (state.visibility_known && state.visible == visible && quinta_drawable_epoch_valid(state.epoch)) return;
    }
    objc_setAssociatedObject(self, &quinta_drawable_state_key, 0, 01401UL);
    unsigned long long call = ++quinta_drawable_main_calls;
    original(self, cmd);
    if (supported) {
        state.visibility_known = 1;
        state.visible = visible;
        quinta_drawable_publish(self, &state, call);
    }
}

static void quinta_drawable_show(id self, SEL cmd) { quinta_drawable_visibility(self, cmd, 1); }
static void quinta_drawable_hide(id self, SEL cmd) { quinta_drawable_visibility(self, cmd, 0); }

static void quinta_install_x11_drawable_cache(Class cls) {
    if (!cls || quinta_wayland_enabled()) return;
    int expected = 0;
    if (!__atomic_compare_exchange_n(&quinta_drawable_install_state, &expected, 1, 0,
                                     __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) return;
    SEL convert_selector = sel_registerName("convertFrame:");
    Method convert = class_getInstanceMethod(cls, convert_selector);
    Method frame = class_getInstanceMethod(cls, sel_registerName("setFrame:"));
    Method show = class_getInstanceMethod(cls, sel_registerName("show"));
    Method hide = class_getInstanceMethod(cls, sel_registerName("hide"));
    Class parent_class = objc_getClass("X11Window");
    SEL handle_selector = sel_registerName("windowHandle");
    Method handle = parent_class ? class_getInstanceMethod(parent_class, handle_selector) : 0;
    char type[32] = {0};
    if (handle) method_getReturnType(handle, type, sizeof type);
    int valid = sizeof(QuintaRect) == 32 && __alignof__(QuintaRect) == 8 && sizeof(void *) == 8 &&
        quinta_drawable_owned(cls, convert) && quinta_drawable_owned(cls, frame) &&
        quinta_drawable_owned(cls, show) && quinta_drawable_owned(cls, hide) &&
        quinta_drawable_method_abi(convert, 1, 1) && quinta_drawable_method_abi(frame, 1, 0) &&
        quinta_drawable_method_abi(show, 0, 0) && quinta_drawable_method_abi(hide, 0, 0) &&
        handle && quinta_drawable_owned(parent_class, handle) &&
        method_getNumberOfArguments(handle) == 2 && quinta_drawable_equal(type, "Q") &&
        objc_getClass("NSData") &&
        quinta_drawable_ivar(cls, "_display", '^', &quinta_drawable_display_offset) &&
        quinta_drawable_ivar(cls, "_window", 'Q', &quinta_drawable_window_offset) &&
        quinta_drawable_ivar(cls, "_parent", '@', &quinta_drawable_parent_offset) &&
        quinta_drawable_display_offset != quinta_drawable_window_offset &&
        quinta_drawable_display_offset != quinta_drawable_parent_offset &&
        quinta_drawable_window_offset != quinta_drawable_parent_offset;
    if (valid) {
        method_getArgumentType(handle, 0, type, sizeof type);
        valid = quinta_drawable_equal(type, "@");
        method_getArgumentType(handle, 1, type, sizeof type);
        valid = valid && quinta_drawable_equal(type, ":");
    }
    if (!valid || !method_getImplementation(convert) || !method_getImplementation(frame) ||
        !method_getImplementation(show) || !method_getImplementation(hide)) {
        __atomic_store_n(&quinta_drawable_install_state, 3, __ATOMIC_RELEASE);
        write_str("[Quinta] X11 drawable cache skipped: unsupported backend ABI\n");
        return;
    }
    quinta_drawable_class = cls;
    quinta_drawable_parent_class = parent_class;
    quinta_drawable_convert_selector = convert_selector;
    quinta_drawable_handle_selector = handle_selector;
    quinta_drawable_convert_original = (QuintaRect (*)(id, SEL, QuintaRect))method_getImplementation(convert);
    quinta_drawable_frame_original = (void (*)(id, SEL, QuintaRect))method_getImplementation(frame);
    quinta_drawable_show_original = (void (*)(id, SEL))method_getImplementation(show);
    quinta_drawable_hide_original = (void (*)(id, SEL))method_getImplementation(hide);
    method_setImplementation(frame, (IMP)quinta_drawable_set_frame);
    method_setImplementation(show, (IMP)quinta_drawable_show);
    method_setImplementation(hide, (IMP)quinta_drawable_hide);
    __atomic_store_n(&quinta_drawable_install_state, 2, __ATOMIC_RELEASE);
    write_str("[Quinta] X11 drawable updates skip unchanged geometry and visibility\n");
}
#endif
