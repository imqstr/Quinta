#include <assert.h>
#include <stdio.h>
#include "../native/drag_cursor.h"
int main(void) {
    QuintaDragCursor state={0};
    quinta_drag_cursor_buttons(&state,QUINTA_RIGHT_BUTTON);
    assert(!quinta_drag_cursor_visible(&state));
    quinta_drag_cursor_capture(&state,1);
    assert(quinta_drag_cursor_visible(&state));
    assert(state.button_capture);
    quinta_drag_cursor_capture(&state,1); // repeated per-frame request
    quinta_drag_cursor_buttons(&state,QUINTA_RIGHT_BUTTON|(1u<<1));
    assert(quinta_drag_cursor_visible(&state));
    quinta_drag_cursor_buttons(&state,QUINTA_RIGHT_BUTTON); // left released first
    assert(quinta_drag_cursor_visible(&state));
    quinta_drag_cursor_buttons(&state,1u<<1); // right released first
    assert(!quinta_drag_cursor_visible(&state));
    assert(state.button_capture); // a lost-focus drag must not be restored
    quinta_drag_cursor_buttons(&state,QUINTA_RIGHT_BUTTON); // existing capture stays classified
    assert(!quinta_drag_cursor_visible(&state));
    quinta_drag_cursor_capture(&state,0);
    assert(!quinta_drag_cursor_visible(&state));
    quinta_drag_cursor_capture(&state,1);
    assert(quinta_drag_cursor_visible(&state));
    quinta_drag_cursor_buttons(&state,0); // focus loss / no pressed buttons
    quinta_drag_cursor_capture(&state,0);
    quinta_drag_cursor_capture(&state,1); // resumed capture without held RMB
    assert(!quinta_drag_cursor_visible(&state));
    assert(!state.button_capture);
    quinta_drag_cursor_buttons(&state,QUINTA_RIGHT_BUTTON);
    assert(!quinta_drag_cursor_visible(&state)); // Shift Lock / first-person already active
    quinta_drag_cursor_capture(&state,0);
    quinta_drag_cursor_buttons(&state,1u<<1);
    quinta_drag_cursor_capture(&state,1);
    assert(!quinta_drag_cursor_visible(&state)); // left-only capture
    assert(quinta_drag_cursor_arrow(0,0)>>24);
    assert(!quinta_drag_cursor_arrow(11,0));
    assert(!quinta_drag_cursor_arrow(1,17));
    puts("PASS: right-drag visibility, both release orders, repeated capture, focus reset and existing capture policy");
}
