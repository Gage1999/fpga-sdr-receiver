#include "test_helpers.h"
#include "ui_state.h"

T_CASE(default_values_in_bounds) {
    ui_state_t s;
    ui_state_default(&s);
    T_EXPECT_EQ(s.version, (uint8_t)UI_STATE_VERSION);
    T_EXPECT(s.volume <= 100);
    T_EXPECT(s.brightness <= 100);
    T_EXPECT_EQ(s.active_button, (uint8_t)UI_BTN_NONE);
    T_EXPECT((s.flags & UI_FLAG_LINK_LOCK) != 0);
    T_EXPECT_EQ(s.rds_text[0], '\0');
    return 0;
}

T_CASE(struct_size_under_1kb) {
    T_EXPECT(sizeof(ui_state_t) <= 1024);
    return 0;
}

int main(void) {
    T_RUN(default_values_in_bounds);
    T_RUN(struct_size_under_1kb);
    T_FINISH();
}
