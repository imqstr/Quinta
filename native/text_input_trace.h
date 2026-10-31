#ifndef QUINTA_TEXT_INPUT_TRACE_H
#define QUINTA_TEXT_INPUT_TRACE_H

/* Included after the shim's Objective-C declarations and QuintaRange.
 * Only InputMethodHandler is instrumented. No text, characters, key codes,
 * notification contents, or object addresses are written to the log. */
extern unsigned int method_getNumberOfArguments(Method);
extern void method_getArgumentType(Method, unsigned int, char*, unsigned long);
extern void method_getReturnType(Method, char*, unsigned long);
extern Method* class_copyMethodList(Class, unsigned int*);
extern Ivar* class_copyIvarList(Class, unsigned int*);
extern const char* ivar_getTypeEncoding(Ivar);
extern unsigned long class_getInstanceSize(Class);

static Class quinta_text_input_class;
static long quinta_text_selection_origin_offset = -1;
static volatile unsigned long quinta_text_trace_sequence;
static volatile unsigned long quinta_text_event_sequence;
static __thread unsigned long quinta_text_current_event;
static IMP quinta_text_key_down_original;
static IMP quinta_text_insert_original;
static IMP quinta_text_selection_original;
static IMP quinta_text_replace_original;
static IMP quinta_text_notification_original;
static IMP quinta_text_commit_original;
static IMP quinta_text_clear_original;
static IMP quinta_text_update_original;

static int quinta_text_trace_enabled(void) {
    static volatile int enabled = -1;
    return quinta_env_cached("QUINTA_TRACE_TEXT_INPUT", &enabled);
}

static int quinta_text_range_type(const char* type) {
    if (!type || *type++ != '{')
        return 0;
    while (*type && *type != '=') type++;
    return *type == '=' && ascii_strings_equal(type + 1, "QQ}");
}

/* Validate every argument before casting an IMP; reuse the runtime's original
 * encoding when adding an inherited method to the subclass. */
static int quinta_text_method_types(Method method, const char* kinds) {
    unsigned int count = 0;
    while (kinds[count]) count++;
    if (!method || method_getNumberOfArguments(method) != count)
        return 0;
    char type[96] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (!ascii_strings_equal(type, "v"))
        return 0;
    for (unsigned int index = 0; index < count; index++) {
        type[0] = 0;
        method_getArgumentType(method, index, type, sizeof(type));
        if (kinds[index] == 'R') {
            if (!quinta_text_range_type(type)) return 0;
        } else if (kinds[index] == 'b') {
            if (!ascii_strings_equal(type, "c") && !ascii_strings_equal(type, "B")) return 0;
        } else if (kinds[index] == 'i') {
            if (!ascii_strings_equal(type, "i") && !ascii_strings_equal(type, "I")) return 0;
        } else if (kinds[index] == 'q') {
            if (!ascii_strings_equal(type, "q") && !ascii_strings_equal(type, "Q")) return 0;
        } else if (type[0] != kinds[index] || type[1]) {
            return 0;
        }
    }
    return 1;
}

static int quinta_text_hook(const char* name, const char* kinds,
                              IMP replacement, IMP* original) {
    SEL selector = sel_registerName(name);
    Method method = class_getInstanceMethod(quinta_text_input_class, selector);
    if (!quinta_text_method_types(method, kinds))
        return 0;
    *original = method_getImplementation(method);
    if (class_addMethod(quinta_text_input_class, selector, replacement,
                        method_getTypeEncoding(method)))
        return 1;
    /* class_getInstanceMethod may return a superclass method. Change its IMP
     * only after proving that this subclass owns it. */
    unsigned int count = 0;
    Method* methods = class_copyMethodList(quinta_text_input_class, &count);
    int owned = 0;
    for (unsigned int index = 0; index < count; index++)
        if (methods[index] == method) owned = 1;
    free(methods);
    if (owned)
        method_setImplementation(method, replacement);
    return owned;
}

static void quinta_text_print_range(QuintaRange range) {
    write_str("(");
    if (range.location == 0x7FFFFFFFFFFFFFFFUL) write_str("not-found");
    else print_num((long long)range.location);
    write_str(",");
    print_num((long long)range.length);
    write_str(")");
}

static long quinta_text_length(id object) {
    @try {
        return object ? (long)((unsigned long (*)(id, SEL))objc_msgSend)(
            object, sel_registerName("length")) : 0;
    } @catch (id exception) {
        (void)exception;
        return -1;
    }
}

static void quinta_text_trace(id self, const char* phase,
                                const QuintaRange* requested, long inserted) {
    if (!quinta_text_trace_enabled())
        return;
    unsigned long sequence = __sync_add_and_fetch(&quinta_text_trace_sequence, 1);
    if (sequence > 2048) {
        if (sequence == 2049) write_str("[Quinta Text] trace limit reached\n");
        return;
    }
    /* Diagnostic getters must not introduce or replace an application exception. */
    @try {
        id storage = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("textStorage"));
        QuintaRange selected = ((QuintaRange (*)(id, SEL))objc_msgSend)(
            self, sel_registerName("selectedRange"));
        QuintaRange marked = ((QuintaRange (*)(id, SEL))objc_msgSend)(
            self, sel_registerName("markedRange"));
        int has_marked = ((QuintaBool (*)(id, SEL))objc_msgSend)(
            self, sel_registerName("hasMarkedText")) != 0;
        int clearing = -1;
        SEL clear_selector = sel_registerName("processingClearComposition");
        if (class_getInstanceMethod(object_getClass(self), clear_selector))
            clearing = ((unsigned char (*)(id, SEL))objc_msgSend)(self, clear_selector) != 0;
        write_str("[Quinta Text] seq="); print_num((long long)sequence);
        write_str(" event="); print_num((long long)quinta_text_current_event);
        write_str(" "); write_str(phase);
        write_str(" utf16="); print_num(quinta_text_length(storage));
        write_str(" selected="); quinta_text_print_range(selected);
        if (requested) { write_str(" requested="); quinta_text_print_range(*requested); }
        if (inserted >= 0) { write_str(" insertedUtf16="); print_num(inserted); }
        write_str(" marked="); quinta_text_print_range(marked);
        write_str(" hasMarked="); print_num(has_marked);
        write_str(" clearing="); print_num(clearing);
        if (quinta_text_selection_origin_offset >= 0) {
            write_str(" origin=");
            print_num((long long)*(unsigned long*)((char*)self + quinta_text_selection_origin_offset));
        }
        write_str("\n");
    } @catch (id exception) {
        (void)exception;
    }
}

static void quinta_text_key_down(id self, SEL cmd, id event) {
    unsigned long previous = quinta_text_current_event;
    quinta_text_current_event = __sync_add_and_fetch(&quinta_text_event_sequence, 1);
    quinta_text_trace(self, "keyDown.before", 0, -1);
    int completed = 0;
    @try {
        ((void (*)(id, SEL, id))quinta_text_key_down_original)(self, cmd, event);
        completed = 1;
    } @finally {
        quinta_text_trace(self, completed ? "keyDown.after" : "keyDown.unwound", 0, -1);
        quinta_text_current_event = previous;
    }
}

static void quinta_text_insert(id self, SEL cmd, id object) {
    long length = quinta_text_length(object);
    quinta_text_trace(self, "insert.before", 0, length);
    ((void (*)(id, SEL, id))quinta_text_insert_original)(self, cmd, object);
    quinta_text_trace(self, "insert.after", 0, length);
}

static void quinta_text_replace(id self, SEL cmd, QuintaRange range, id object) {
    long length = quinta_text_length(object);
    quinta_text_trace(self, "replace.before", &range, length);
    ((void (*)(id, SEL, QuintaRange, id))quinta_text_replace_original)(self, cmd, range, object);
    quinta_text_trace(self, "replace.after", &range, length);
}

static void quinta_text_selection_begin(id self, id ranges, QuintaBool still_selecting) {
    if (!quinta_text_trace_enabled()) return;
    @try {
        if (((unsigned long (*)(id, SEL))objc_msgSend)(ranges, sel_registerName("count"))) {
            id first = ((id (*)(id, SEL, unsigned long))objc_msgSend)(
                ranges, sel_registerName("objectAtIndex:"), 0);
            QuintaRange requested = ((QuintaRange (*)(id, SEL))objc_msgSend)(
                first, sel_registerName("rangeValue"));
            quinta_text_trace(self, still_selecting ? "selection.continuing.before" : "selection.before",
                                &requested, -1);
        }
    } @catch (id exception) { (void)exception; }
}

static void quinta_text_selection_end(id self, QuintaBool still_selecting) {
    if (!still_selecting && quinta_text_selection_origin_offset >= 0) {
        @try {
            QuintaRange final = ((QuintaRange (*)(id, SEL))objc_msgSend)(
                self, sel_registerName("selectedRange"));
            id storage = ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("textStorage"));
            long length = quinta_text_length(storage);
            unsigned long* origin = (unsigned long*)((char*)self + quinta_text_selection_origin_offset);
            /* Darling stores collapsedRange.length here (zero). Repair only
             * that observed state, after the delegate chooses its final range. */
            if (length >= 0 && final.length == 0 && final.location > 0 &&
                final.location <= (unsigned long)length && *origin == 0) {
                *origin = final.location;
                quinta_text_trace(self, "selection.anchor-repaired", &final, -1);
            }
        } @catch (id exception) { (void)exception; }
    }
    quinta_text_trace(self, still_selecting ? "selection.continuing.after" : "selection.after", 0, -1);
}

static void quinta_text_selection32(id self, SEL cmd, id ranges, int affinity,
                                      QuintaBool still_selecting) {
    quinta_text_selection_begin(self, ranges, still_selecting);
    ((void (*)(id, SEL, id, int, QuintaBool))quinta_text_selection_original)(
        self, cmd, ranges, affinity, still_selecting);
    quinta_text_selection_end(self, still_selecting);
}

static void quinta_text_selection64(id self, SEL cmd, id ranges, long affinity,
                                      QuintaBool still_selecting) {
    quinta_text_selection_begin(self, ranges, still_selecting);
    ((void (*)(id, SEL, id, long, QuintaBool))quinta_text_selection_original)(
        self, cmd, ranges, affinity, still_selecting);
    quinta_text_selection_end(self, still_selecting);
}

#define QUINTA_TEXT_PLAIN_HOOK(name, label) \
    static void quinta_text_##name(id self, SEL cmd) { \
        quinta_text_trace(self, label ".before", 0, -1); \
        ((void (*)(id, SEL))quinta_text_##name##_original)(self, cmd); \
        quinta_text_trace(self, label ".after", 0, -1); \
    }
QUINTA_TEXT_PLAIN_HOOK(commit, "commit")
QUINTA_TEXT_PLAIN_HOOK(clear, "clearAsync")
QUINTA_TEXT_PLAIN_HOOK(update, "updateIME")
#undef QUINTA_TEXT_PLAIN_HOOK

static void quinta_text_notification(id self, SEL cmd, id notification) {
    quinta_text_trace(self, "selectionNotification.before", 0, -1);
    ((void (*)(id, SEL, id))quinta_text_notification_original)(self, cmd, notification);
    quinta_text_trace(self, "selectionNotification.after", 0, -1);
}

static void quinta_install_text_input_hooks(void) {
    static volatile int installed;
    Class input = objc_getClass("InputMethodHandler");
    if (!input || !__sync_bool_compare_and_swap(&installed, 0, 1)) return;
    quinta_text_input_class = input;
    Class text_view = objc_getClass("NSTextView");
    Ivar origin = text_view ? class_getInstanceVariable(text_view, "_selectionOrigin") : 0;
    unsigned int count = 0;
    Ivar* ivars = text_view ? class_copyIvarList(text_view, &count) : 0;
    int owned = 0;
    for (unsigned int index = 0; index < count; index++)
        if (ivars[index] == origin) owned = 1;
    free(ivars);
    if (owned && class_getInstanceVariable(input, "_selectionOrigin") == origin &&
        class_getInstanceSize(input) >= class_getInstanceSize(text_view) &&
        ascii_strings_equal(ivar_getTypeEncoding(origin), "Q")) {
        long offset = ivar_getOffset(origin);
        unsigned long size = class_getInstanceSize(text_view);
        if (offset >= 0 && (unsigned long)offset % sizeof(unsigned long) == 0 &&
            (unsigned long)offset <= size && size - (unsigned long)offset >= sizeof(unsigned long))
            quinta_text_selection_origin_offset = offset;
    }
    int tracing = quinta_text_trace_enabled();
    unsigned int trace_hooks = 0;
    if (tracing || quinta_text_selection_origin_offset >= 0) {
        const char* selector = "setSelectedRanges:affinity:stillSelecting:";
        int hooked = quinta_text_hook(selector, "@:@ib", (IMP)quinta_text_selection32,
                                        &quinta_text_selection_original);
        if (!hooked) hooked = quinta_text_hook(selector, "@:@qb", (IMP)quinta_text_selection64,
                                                &quinta_text_selection_original);
        trace_hooks += hooked;
        if (hooked && quinta_text_selection_origin_offset >= 0)
            write_str("[Quinta] InputMethodHandler collapsed selection anchor repair enabled\n");
    }
    if (!tracing) return;
    trace_hooks += quinta_text_hook("keyDown:", "@:@", (IMP)quinta_text_key_down, &quinta_text_key_down_original);
    trace_hooks += quinta_text_hook("insertText:", "@:@", (IMP)quinta_text_insert, &quinta_text_insert_original);
    trace_hooks += quinta_text_hook("replaceCharactersInRange:withString:", "@:R@", (IMP)quinta_text_replace, &quinta_text_replace_original);
    trace_hooks += quinta_text_hook("textViewDidChangeSelection:", "@:@", (IMP)quinta_text_notification, &quinta_text_notification_original);
    trace_hooks += quinta_text_hook("commitCompositionRBXEvent", "@:", (IMP)quinta_text_commit, &quinta_text_commit_original);
    trace_hooks += quinta_text_hook("clearCompositionAsync", "@:", (IMP)quinta_text_clear, &quinta_text_clear_original);
    trace_hooks += quinta_text_hook("updateInputMethodRBXEvent", "@:", (IMP)quinta_text_update, &quinta_text_update_original);
    write_str("[Quinta Text] range tracing enabled; hooks="); print_num(trace_hooks);
    write_str("/8, limit=2048, no text content\n");
}

#endif
