/* A right-button drag may keep its software cursor visible. Latch the cause
 * only when capture starts: pressing RMB during existing Shift Lock or
 * first-person capture must not change that capture's cursor policy. */
#ifndef QUINTA_DRAG_CURSOR_H
#define QUINTA_DRAG_CURSOR_H
typedef struct {
    unsigned buttons;
    int captured, right_drag, button_capture;
} QuintaDragCursor;
#define QUINTA_RIGHT_BUTTON (1u << 3)
static inline int quinta_drag_cursor_visible(const QuintaDragCursor *state) {
    return state->captured && state->right_drag && (state->buttons & QUINTA_RIGHT_BUTTON);
}
static inline void quinta_drag_cursor_buttons(QuintaDragCursor *state,unsigned buttons) {
    state->buttons=buttons;
    if(!(buttons & QUINTA_RIGHT_BUTTON))state->right_drag=0;
}
static inline void quinta_drag_cursor_capture(QuintaDragCursor *state,int captured) {
    if(state->captured==captured)return;
    state->captured=captured;
    state->button_capture=captured && state->buttons;
    state->right_drag=captured && (state->buttons & QUINTA_RIGHT_BUTTON);
}
/* Last resort when no selected bitmap or desktop cursor theme is available. */
static inline unsigned quinta_drag_cursor_arrow(unsigned x,unsigned y) {
    static const char *rows[]={"X", "XX", "XOX", "XOOX", "XOOOX", "XOOOOX",
        "XOOOOOX", "XOOOOOOX", "XOOOOOOOX", "XOOOOOOOOX", "XOOOOXXXXX",
        "XOOXOX", "XOX XOX", "XX  XOX", "X    XOX", "     XOX", "      XX"};
    if(y>=sizeof rows/sizeof rows[0])return 0;
    const char *row=rows[y];
    for(unsigned i=0;i<x;i++)if(!row[i])return 0;
    return row[x]=='X'?0xff000000u:row[x]=='O'?0xffffffffu:0;
}
#endif
