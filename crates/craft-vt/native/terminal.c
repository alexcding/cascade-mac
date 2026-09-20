#include <ghostty/vt.h>

// Keep upstream enum/layout details on the C side of the Rust boundary. These
// functions use the exact renderer revision; snapshots are not a stable disk ABI.
void *craft_vt_new(uint16_t cols, uint16_t rows) {
    GhosttyTerminal terminal = NULL;
    if (ghostty_terminal_new(NULL, &terminal, cols, rows) != GHOSTTY_SUCCESS) return NULL;
    const size_t continuation = 1024 * 1024;
    const size_t scrollback = 8 * 1024 * 1024;
    if (ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation) != GHOSTTY_SUCCESS ||
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback) != GHOSTTY_SUCCESS) {
        ghostty_terminal_free(terminal);
        return NULL;
    }
    return terminal;
}

void craft_vt_free(void *terminal) { ghostty_terminal_free(terminal); }
void craft_vt_feed(void *terminal, const uint8_t *bytes, size_t len) {
    ghostty_terminal_vt_write(terminal, bytes, len);
}

typedef struct {
    GhosttyWriterFn write;
    void *userdata;
    bool failed;
    GhosttyString version;
    int color_scheme;
} CraftResponseSink;

static bool craft_color_scheme(GhosttyTerminal terminal, void *userdata, GhosttyColorScheme *out) {
    (void)terminal;
    int value = ((CraftResponseSink *)userdata)->color_scheme;
    if (value < 0 || value > 1) return false;
    *out = (GhosttyColorScheme)value;
    return true;
}
static GhosttyString craft_version(GhosttyTerminal terminal, void *userdata) {
    (void)terminal;
    return ((CraftResponseSink *)userdata)->version;
}
static bool craft_device_attributes(GhosttyTerminal terminal, void *userdata,
                                     GhosttyDeviceAttributes *out) {
    (void)terminal; (void)userdata;
    // The native profile uses Ghostty's default clipboard-write=allow policy.
    *out = (GhosttyDeviceAttributes){
        .primary = { .conformance_level = 62, .features = {22, 52}, .num_features = 2 },
        .secondary = { .device_type = 1, .firmware_version = 10, .rom_cartridge = 0 },
    };
    return true;
}

static void craft_write_response(GhosttyTerminal terminal, void *userdata,
                                  const uint8_t *bytes, size_t len) {
    (void)terminal;
    CraftResponseSink *sink = userdata;
    if (!sink->failed && len > 0 && !sink->write(sink->userdata, bytes, len)) sink->failed = true;
}

// Geometry is read from the parser, including after snapshot restoration. Only
// complete cell metrics can produce pixel reports; zero/rounded sizes must not
// be presented as measurements from the native surface.
int craft_vt_geometry(void *terminal, uint16_t *cols, uint16_t *rows,
                        uint32_t *cell_width, uint32_t *cell_height) {
    uint32_t width = 0, height = 0;
    int result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, cols);
    if (result == GHOSTTY_SUCCESS)
        result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, rows);
    if (result == GHOSTTY_SUCCESS)
        result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_WIDTH_PX, &width);
    if (result == GHOSTTY_SUCCESS)
        result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_HEIGHT_PX, &height);
    if (result != GHOSTTY_SUCCESS) return result;
    if (*cols == 0 || *rows == 0 || width == 0 || height == 0 ||
        width % *cols != 0 || height % *rows != 0) return GHOSTTY_INVALID_VALUE;
    *cell_width = width / *cols;
    *cell_height = height / *rows;
    return GHOSTTY_SUCCESS;
}
static bool craft_size(GhosttyTerminal terminal, void *userdata,
                         GhosttySizeReportSize *out) {
    if (craft_vt_geometry(terminal, &out->columns, &out->rows,
                           &out->cell_width, &out->cell_height) == GHOSTTY_SUCCESS) return true;
    ((CraftResponseSink *)userdata)->failed = true;
    return false;
}

// Effect callbacks are synchronous. Their stack-owned context must be removed
// before returning, including after allocation/buffer failure in the receiver.
// The parser still consumes the whole input on a receiver failure: callers must
// not retry these bytes, since doing so would apply terminal state twice.
int craft_vt_feed_with_responses(void *terminal, const uint8_t *bytes, size_t len,
                                 GhosttyWriterFn write, void *userdata,
                                 const uint8_t *version, size_t version_len, bool geometry, int color_scheme) {
    CraftResponseSink sink = { .write = write, .userdata = userdata, .failed = false,
                                .version = { .ptr = version, .len = version_len }, .color_scheme = color_scheme };
    int result = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, &sink);
    if (result == GHOSTTY_SUCCESS) {
        result = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                                     (const void *)craft_write_response);
    }
    if (result == GHOSTTY_SUCCESS && version != NULL) {
        const GhosttyString name = { .ptr = (const uint8_t *)"xterm-ghostty", .len = 13 };
        result = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &name);
        if (result == GHOSTTY_SUCCESS)
            result = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
                                          (const void *)craft_device_attributes);
        if (result == GHOSTTY_SUCCESS)
            result = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION,
                                          (const void *)craft_version);
    }
    if (result == GHOSTTY_SUCCESS && color_scheme >= 0)
        result = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, (const void *)craft_color_scheme);
    if (result == GHOSTTY_SUCCESS && geometry)
        result = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE,
                                     (const void *)craft_size);
    if (result == GHOSTTY_SUCCESS) {
        ghostty_terminal_vt_write(terminal, bytes, len);
        if (sink.failed) result = GHOSTTY_OUT_OF_SPACE;
    }
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, NULL);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, NULL);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, NULL);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, NULL);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, NULL);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE, NULL);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, NULL);
    return result;
}
int craft_vt_resize(void *terminal, uint16_t cols, uint16_t rows) {
    return ghostty_terminal_resize(terminal, cols, rows, 0, 0);
}
int craft_vt_resize_geometry(void *terminal, uint16_t cols, uint16_t rows,
                               uint32_t cell_width, uint32_t cell_height,
                               GhosttyWriterFn write, void *userdata) {
    uint16_t old_cols = 0, old_rows = 0;
    uint32_t old_width = 0, old_height = 0;
    if (craft_vt_geometry(terminal, &old_cols, &old_rows, &old_width, &old_height) == GHOSTTY_SUCCESS &&
        old_cols == cols && old_rows == rows && old_width == cell_width && old_height == cell_height)
        return GHOSTTY_SUCCESS;

    CraftResponseSink sink = { .write = write, .userdata = userdata };
    int result = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, &sink);
    if (result == GHOSTTY_SUCCESS)
        result = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                                     (const void *)craft_write_response);
    if (result == GHOSTTY_SUCCESS) {
        // Ghostty emits mode 2048 here, including for pixel-only changes. Do
        // not separately encode another notification for the same resize.
        result = ghostty_terminal_resize(terminal, cols, rows, cell_width, cell_height);
        if (result == GHOSTTY_SUCCESS && sink.failed) result = GHOSTTY_OUT_OF_SPACE;
    }
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, NULL);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, NULL);
    return result;
}
int craft_vt_snapshot(void *terminal, GhosttyWriterFn write, void *userdata) {
    return ghostty_snapshot_encode(terminal, (GhosttyWriter){ .write = write, .userdata = userdata });
}
void *craft_vt_restore(const uint8_t *bytes, size_t len) {
    GhosttySnapshotDecoder decoder = NULL;
    GhosttyTerminal terminal = NULL;
    if (ghostty_snapshot_decoder_new_buf(NULL, &decoder, bytes, len) != GHOSTTY_SUCCESS) return NULL;
    size_t continuation = 1024 * 1024;
    bool retain = true;
    size_t consumed = 0;
    bool valid = ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, &continuation) == GHOSTTY_SUCCESS &&
        ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, &retain) == GHOSTTY_SUCCESS &&
        ghostty_snapshot_decoder_decode(decoder, &terminal) == GHOSTTY_SUCCESS &&
        ghostty_snapshot_decoder_get(decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET, &consumed) == GHOSTTY_SUCCESS && consumed == len;
    ghostty_snapshot_decoder_free(decoder);
    if (!valid) { ghostty_terminal_free(terminal); return NULL; }
    return terminal;
}
int craft_vt_format(void *terminal, GhosttyWriterFn write, void *userdata) {
    GhosttyFormatter formatter = NULL;
    GhosttyFormatterTerminalOptions options = {
        .size = sizeof(options), .emit = GHOSTTY_FORMATTER_FORMAT_VT, .unwrap = false, .trim = false,
        .extra = {
            .size = sizeof(GhosttyFormatterTerminalExtra), .palette = true, .modes = true,
            .scrolling_region = true, .tabstops = true, .pwd = true, .keyboard = true,
            .screen = { .size = sizeof(GhosttyFormatterScreenExtra), .cursor = true, .style = true,
                .hyperlink = true, .protection = true, .kitty_keyboard = true, .charsets = true },
        },
    };
    int result = ghostty_formatter_terminal_new(NULL, &formatter, terminal, options);
    if (result == GHOSTTY_SUCCESS) result = ghostty_formatter_format(formatter, (GhosttyWriter){ .write = write, .userdata = userdata });
    ghostty_formatter_free(formatter);
    return result;
}
int craft_vt_cursor(void *terminal, uint16_t *x, uint16_t *y) {
    int result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, x);
    if (result == GHOSTTY_SUCCESS) result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, y);
    return result;
}
int craft_vt_mode(void *terminal, uint16_t number, bool ansi, bool *value) {
    GhosttyTerminalModeConfig mode = { .mode = ghostty_mode_new(number, ansi) };
    int result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode);
    if (result == GHOSTTY_SUCCESS) *value = mode.value;
    return result;
}

// The wire array is 256 palette RGB values, foreground/background/cursor, scheme.
// Defaults change without overwriting explicit OSC color overrides.
int craft_vt_set_appearance(void *terminal, const uint32_t *values, bool notify,
                               GhosttyWriterFn write, void *userdata) {
    GhosttyColorRgb palette[256];
    for (size_t i = 0; i < 256; ++i)
        palette[i] = (GhosttyColorRgb){ .r = values[i] >> 16, .g = values[i] >> 8, .b = values[i] };
    int result = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, palette);
    const GhosttyTerminalOption options[] = { GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND,
        GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR };
    for (size_t i = 0; i < 3 && result == GHOSTTY_SUCCESS; ++i) {
        uint32_t value = values[256 + i];
        GhosttyColorRgb rgb = { .r = value >> 16, .g = value >> 8, .b = value };
        result = ghostty_terminal_set(terminal, options[i], value == UINT32_MAX ? NULL : &rgb);
    }
    if (result != GHOSTTY_SUCCESS || !notify) return result;
    GhosttyTerminalModeConfig mode = { .mode = ghostty_mode_new(2031, false) };
    result = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode);
    if (result != GHOSTTY_SUCCESS || !mode.value) return result;
    char bytes[16];
    size_t count = 0;
    result = ghostty_color_scheme_report_encode((GhosttyColorScheme)values[259], bytes, sizeof(bytes), &count);
    if (result == GHOSTTY_SUCCESS && !write(userdata, (const uint8_t *)bytes, count)) result = GHOSTTY_OUT_OF_SPACE;
    return result;
}
