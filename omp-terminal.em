// A focused terminal surface for the local OMP ConPTY host.
using namespace std;
using namespace render;

int64 cols = 100;
int64 rows = 30;
int64 cursor_x = 0;
int64 cursor_y = 0;
bool cursor_visible = false;
bool connected = false;
bool focused = false;
bool keyboard_hook_enabled = true;
bool previous_left = false;
bool minimized = false;
bool ball_pressed = false;
bool ball_dragged = false;
float64 hover_time = 0.0;
float ball_hover = 0.0f;
float minimize_hover = 0.0f;
float compose_hover = 0.0f;
float paste_hover = 0.0f;
float screenshot_hover = 0.0f;
float attach_hover = 0.0f;
float settings_hover = 0.0f;
float settings_keyboard_hover = 0.0f;
float settings_reset_hover = 0.0f;
bool settings_open = false;
float keyboard_hover = 0.0f;
bool virtual_keyboard = false;
bool virtual_shift = false;
bool virtual_ctrl = false;
float virtual_key_hover[64] = {};
vec2 ball_center = vec2(0, 0);
vec2 ball_press_at = vec2(0, 0);
vec2 ball_press_center = vec2(0, 0);
float64 minimize_started_at = -1000.0;
bool dragging = false;
int64 resize_x = 0;
int64 resize_y = 0;
vec2 resize_start = vec2(0, 0);
float resize_origin_x = 0.0f;
float resize_origin_y = 0.0f;
int64 resize_origin_cols = 0;
int64 resize_origin_rows = 0;
int64 resize_next_tick = 0;
float resize_left = 0.0f;
float resize_top = 0.0f;
int64 resize_cols = 0;
int64 resize_rows = 0;
float px = 48.0f;
float py = 56.0f;
float drag_x = 0.0f;
float drag_y = 0.0f;
float cell_w = 8.0f;
float cell_h = 20.0f;
int64 font_mono = 0;
int64 font_ui = 0;
int64 tick = 0;
string last_paint = "";
string status_text = "";
int64 previous_snip = 0;
int64 scroll_offset = 0;
int64 history_rows = 0;
int64 history_anchor = 0;
bool layout_loaded = false;
string saved_layout = "";
bool ball_remembered = false;
int64 selection_first = -1;
int64 selection_last = -1;
bool selecting_text = false;
bool selection_dragged = false;
bool previous_right = false;
vec2 selection_press = vec2(0, 0);
float latest_hover = 0.0f;
int64 selection_mode = 0;
int64 selection_deadline = 0;
vec2 selection_start = vec2(0, 0);
int64 selection_left = 0;
int64 selection_top = 0;
vector<int64> run_row;
vector<int64> run_col;
vector<int64> run_width;
vector<int64> run_fg;
vector<int64> run_bg;
vector<string> run_text;


int64 hex4(string s, int64 pos)
{
    int64 v = 0;
    for (int64 i = 0; i < 4; i++)
    {
        int64 c = s[pos + i];
        int64 d = -1;
        if (c >= '0' && c <= '9')      d = c - '0';
        else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
        if (d < 0) return -1;
        v = v * 16 + d;
    }
    return v;
}

string utf8_encode(int64 cp)
{
    string out = "";
    if (cp < 0x80)
        out += chr(cp);
    else if (cp < 0x800)
    {
        out += chr(0xC0 | (cp >> 6));
        out += chr(0x80 | (cp & 0x3F));
    }
    else if (cp < 0x10000)
    {
        out += chr(0xE0 | (cp >> 12));
        out += chr(0x80 | ((cp >> 6) & 0x3F));
        out += chr(0x80 | (cp & 0x3F));
    }
    else
    {
        out += chr(0xF0 | (cp >> 18));
        out += chr(0x80 | ((cp >> 12) & 0x3F));
        out += chr(0x80 | ((cp >> 6) & 0x3F));
        out += chr(0x80 | (cp & 0x3F));
    }
    return out;
}

int64 json_skip_space(string body, int64 i)
{
    while (i < body.length())
    {
        int64 c = body[i];
        if (c != 32 && c != 9 && c != 10 && c != 13) break;
        i++;
    }
    return i;
}

// Find the value of a named member while skipping over quoted values.
int64 json_member_start(string body, string key)
{
    for (int64 i = 0; i < body.length(); i++)
    {
        if (body[i] != 34) continue;
        int64 begin = ++i;
        while (i < body.length() && body[i] != 34)
        {
            if (body[i] == 92) i++;
            i++;
        }
        if (i >= body.length()) return -1;
        if (i - begin != key.length() || body.substr(begin, i - begin) != key) continue;
        int64 colon = json_skip_space(body, i + 1);
        if (colon < body.length() && body[colon] == 58)
            return json_skip_space(body, colon + 1);
    }
    return -1;
}

string extract_json_string(string body, string key)
{
    int64 p = json_member_start(body, key);
    if (p < 0 || p >= body.length() || body[p] != 34) return "";
    int64 i = p + 1;
    string out = "";
    while (i < body.length())
    {
        string c = body.substr(i, 1);
        if (c == "\"") return out;
        if (c == "\\")
        {
            if (i + 1 >= body.length()) return out;
            string n = body.substr(i + 1, 1);
            if (n == "u" && i + 5 < body.length())
            {
                int64 cp = hex4(body, i + 2);
                if (cp >= 0)
                {
                    if (cp >= 0xD800 && cp <= 0xDBFF && i + 11 < body.length() && body.substr(i + 6, 2) == "\\u")
                    {
                        int64 low = hex4(body, i + 8);
                        if (low >= 0xDC00 && low <= 0xDFFF)
                        {
                            cp = 0x10000 + (cp - 0xD800) * 1024 + low - 0xDC00;
                            i += 6;
                        }
                    }
                    if (cp >= 0xD800 && cp <= 0xDFFF) cp = 0xFFFD;
                    out += utf8_encode(cp);
                    i += 6;
                    continue;
                }
            }
            else if (n == "n")  { out += "\n"; i += 2; continue; }
            else if (n == "r")  { out += "\r"; i += 2; continue; }
            else if (n == "t")  { out += "\t"; i += 2; continue; }
            else if (n == "\"") { out += "\""; i += 2; continue; }
            else if (n == "\\") { out += "\\"; i += 2; continue; }
            else if (n == "/")  { out += "/";  i += 2; continue; }
            out += c;
            i += 1;
            continue;
        }
        out += c;
        i += 1;
    }
    return out;
}

// ---------- API ----------
// 提取 JSON 数字（"key":123）
int64 extract_json_number(string body, string key)
{
    int64 i = json_member_start(body, key);
    if (i < 0) return -1;
    bool negative = i < body.length() && body[i] == 45;
    if (negative) i++;
    int64 v = 0;
    bool any = false;
    while (i < body.length())
    {
        int64 c = body[i];
        if (c >= '0' && c <= '9')
        {
            v = v * 10 + (c - '0');
            any = true;
            i++;
        }
        else
            break;
    }
    return any ? (negative ? -v : v) : -1;
}


string encode_input(string s)
{
    string out = "";
    string hex = "0123456789abcdef";
    for (int64 i = 0; i < s.length(); i++)
    {
        int64 b = s[i] & 255;
        if (b < 32)
            out += "\\u00" + hex.substr(b / 16, 1) + hex.substr(b % 16, 1);
        else if (b == 34 || b == 92) out += "\\" + s.substr(i, 1);
        else out += s.substr(i, 1);
    }
    return out;
}

http_response_t post_local(string path, string body)
{
    unordered_map<string, string> headers;
    return http_post("http://127.0.0.1:17844" + path, "application/json", body, headers, 250);
}

int64 field_number(string s, int64 &i, int64 radix, int64 separator)
{
    int64 value = 0;
    int64 start = i;
    while (i < s.length() && s[i] != separator)
    {
        int64 c = s[i];
        int64 digit = -1;
        if (c >= 48 && c <= 57) digit = c - 48;
        if (c >= 65 && c <= 70) digit = c - 65 + 10;
        if (c >= 97 && c <= 102) digit = c - 97 + 10;
        if (digit < 0 || digit >= radix || i - start >= 8) return -1;
        value = value * radix + digit;
        i++;
    }
    if (i == start || i == s.length()) return -1;
    i++;
    return value;
}

void update_paint(string paint)
{
    if (paint == last_paint) return;
    last_paint = paint;
    run_text.clear();
    run_width.clear();
    run_fg.clear();
    run_bg.clear();
    int64 p = 0;
    run_row.clear();
    run_col.clear();
    while (p < paint.length())
    {
        int64 row = field_number(paint, p, 10, 44);
        int64 col = field_number(paint, p, 10, 44);
        int64 fg = field_number(paint, p, 16, 44);
        int64 bg = field_number(paint, p, 16, 44);
        int64 width = field_number(paint, p, 10, 9);
        if (row < 0 || row >= rows || col < 0 || col >= cols ||
            fg < 0 || bg < 0 || width < 1 || width > cols - col) break;
        int64 begin = p;
        while (p < paint.length() && paint[p] != 10) p++;
        run_text.push_back(paint.substr(begin, p - begin));
        run_width.push_back(width);
        run_fg.push_back(fg);
        run_bg.push_back(bg);
        run_col.push_back(col);
        run_row.push_back(row);
        p++;
    }
}

bool screen_flag(string body, string name)
{
    int64 start = json_member_start(body, name);
    if (start < 0 || start >= body.length()) return false;
    return body[start] == 49 || body.substr(start, 4) == "true";
}

bool refresh_screen()
{
    http_response_t response = post_local("/screen", "{\"scroll\":" + to_string(scroll_offset)
        + ",\"anchor\":" + to_string(history_anchor)
        + (focused ? ",\"keyboard\":true}" : "}"));
    if (!response.ok())
    {
        status_text = "OMP host unreachable. Check the host setup.";
        return false;
    }
    string body = response.body;
    string diagnostic = extract_json_string(body, "diagnostic");
    if (diagnostic.length() > 0)
    {
        status_text = diagnostic;
        return false;
    }
    if (focused && extract_json_number(body, "keyboard") != 1) focused = false;
    int64 c = extract_json_number(body, "cols");
    int64 r = extract_json_number(body, "rows");
    if (c < 1 || c > 180 || r < 1 || r > 80)
    {
        status_text = "Invalid terminal size";
        return false;
    }
    if (c != cols || r != rows)
    {
        selection_first = -1;
        selection_last = -1;
        selecting_text = false;
        last_paint = "";
    }
    cols = c;
    rows = r;
    cursor_x = extract_json_number(body, "cursorX");
    cursor_y = extract_json_number(body, "cursorY");
    cursor_visible = screen_flag(body, "cursorVisible");
    history_rows = extract_json_number(body, "history");
    history_anchor = extract_json_number(body, "historySerial");
    if (history_anchor < 0) history_anchor = 0;
    if (history_rows < 0) history_rows = 0;
    int64 applied_scroll = extract_json_number(body, "scroll");
    scroll_offset = applied_scroll > 0 ? applied_scroll : 0;
    if (!connected) status_text = "";
    update_paint(extract_json_string(body, "paint"));
    int64 snip = extract_json_number(body, "snip");
    if (selection_mode == 3 && (snip == 2 || snip == 4)) selection_mode = 0;
    if (snip != previous_snip)
    {
        if (snip == 1) status_text = "Drag to select. Esc to cancel";
        if (snip == 2)
        {
            status_text = "Click terminal, then press Enter";
        }
        if (snip == 3) status_text = "File selection canceled";
        if (snip == 4)
        {
            string reason = extract_json_string(body, "attachmentDiagnostic");
            status_text = reason.length() > 0 ? reason : "Could not attach file";
        }
        if (snip == 6) status_text = "Choose a file to attach";
        previous_snip = snip;
    }
    return true;
}

color rgb_color(int64 rgb)
{
    return color((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255, 255);
}

void text_at(string value, float x, float y, color ink, int64 font)
{
    draw_text(value, vec2(x, y), ink, font, 0, color(0, 0, 0, 0), 1.0);
}

void fill_at(float x, float y, float w, float h, color ink)
{
    draw_rect_filled(vec2(x, y), vec2(w, h), ink, 0.0f, 15);
}

void lerp_hover(float &value, bool active, float amount)
{
    float target = active ? 1.0f : 0.0f;
    value += (target - value) * amount;
}

color lerp_hover_color(int64 from, int64 to, float amount)
{
    int64 r = (from >> 16) & 255;
    int64 g = (from >> 8) & 255;
    int64 b = from & 255;
    return color(
        int64(float(r) + float(((to >> 16) & 255) - r) * amount + 0.5f),
        int64(float(g) + float(((to >> 8) & 255) - g) * amount + 0.5f),
        int64(float(b) + float((to & 255) - b) * amount + 0.5f), 255);
}

int64 resize_edge(float pointer, float low, float high)
{
    if (abs(pointer - low) <= 10.0f) return -1;
    if (abs(pointer - high) <= 10.0f) return 1;
    return 0;
}

float64 resize_draw_time = 0.0;
float corner_strength[4] = {0.0f, 0.0f, 0.0f, 0.0f};

void draw_resize_corners(float x, float y, float w, float h)
{
    float64 now = time_ms();
    float64 delta_time = resize_draw_time > 0.0 ? (now - resize_draw_time) / 1000.0 : 0.0;
    resize_draw_time = now;
    float blend = float(min<float64>(1.0, max<float64>(0.0, delta_time * 14.0)));
    for (int64 corner = 0; corner < 4; corner++)
    {
        bool right = corner % 2 == 1;
        bool bottom = corner >= 2;
        int64 sx = right ? 1 : -1;
        int64 sy = bottom ? 1 : -1;
        float selected = sx == resize_x && sy == resize_y ? 1.0f : 0.0f;
        float amount = corner_strength[corner] + (selected - corner_strength[corner]) * blend;
        corner_strength[corner] = amount;
        float arm = 13.0f;
        float anchor_x = x + (right ? w - 0.75f : 0.75f);
        float anchor_y = y + (bottom ? h - 0.75f : 0.75f);
        color ink = color(int64(156.0f - 69.0f * amount), int64(161.0f + 20.0f * amount),
                          int64(168.0f + 87.0f * amount), 255);
        vec2 corner_point = vec2(anchor_x, anchor_y);
        draw_line(corner_point, vec2(anchor_x - float(sx) * arm, anchor_y), ink, 1.5);
        draw_line(corner_point, vec2(anchor_x, anchor_y - float(sy) * arm), ink, 1.5);
    }
}

bool resize_window(vec2 mouse, bool pressed, bool clicked, float w, float h)
{
    if (resize_x == 0 && connected && clicked)
    {
        int64 edge_x = resize_edge(mouse.x, px, px + w);
        int64 edge_y = resize_edge(mouse.y, py, py + h);
        if (edge_x != 0 && edge_y != 0)
        {
            resize_x = edge_x;
            resize_y = edge_y;
            resize_start = mouse;
            resize_origin_x = px;
            resize_origin_y = py;
            resize_origin_cols = cols;
            resize_origin_rows = rows;
            resize_next_tick = tick;
            dragging = false;
        }
    }
    if (resize_x == 0) return false;

    resize_cols = int64(float(resize_origin_cols) + float(resize_x) * (mouse.x - resize_start.x) / cell_w + 0.5f);
    resize_rows = int64(float(resize_origin_rows) + float(resize_y) * (mouse.y - resize_start.y) / cell_h + 0.5f);
    int64 max_cols = 160;
    int64 max_rows = 60;
    if (resize_x < 0) max_cols = int64(float(resize_origin_cols) + (resize_origin_x - 48.0f) / cell_w);
    if (resize_y < 0) max_rows = int64(float(resize_origin_rows) + resize_origin_y / cell_h);
    if (max_cols > 160) max_cols = 160;
    if (max_rows > 60) max_rows = 60;
    resize_cols = resize_cols < 36 ? 36 : (resize_cols > max_cols ? max_cols : resize_cols);
    resize_rows = resize_rows < 10 ? 10 : (resize_rows > max_rows ? max_rows : resize_rows);
    resize_left = resize_x < 0 ? resize_origin_x + float(resize_origin_cols - resize_cols) * cell_w : resize_origin_x;
    resize_top = resize_y < 0 ? resize_origin_y + float(resize_origin_rows - resize_rows) * cell_h : resize_origin_y;
    if (!pressed)
    {
        resize_x = 0;
        resize_y = 0;
    }
    else if (tick < resize_next_tick) return true;
    if (resize_cols == cols && resize_rows == rows) return true;
    resize_next_tick = tick + 5;
    string body = "{\"cols\":" + to_string(resize_cols) + ",\"rows\":" + to_string(resize_rows) + "}";
    if (post_local("/resize", body).ok())
    {
        px = resize_left;
        py = resize_top;
        refresh_screen();
    }
    else status_text = "Could not resize terminal";
    return true;
}

// Keep terminal block art on the cell grid without relying on the font atlas.
bool draw_block_run(string part, float x, float y, color ink, color background)
{
    bool has_blocks = false;
    for (int64 i = 0; i < part.length(); i++)
    {
        if ((part[i] & 255) < 128) continue;
        if (i + 2 >= part.length() || (part[i] & 255) != 226 || (part[i + 1] & 255) != 150)
            return false;
        int64 code = part[i + 2] & 255;
        if (code != 128 && code != 132 && code != 136 && code != 145 && code != 146 && code != 147)
            return false;
        has_blocks = true;
        i += 2;
    }
    if (!has_blocks) return false;
    float left = x;
    for (int64 i = 0; i < part.length();)
    {
        if ((part[i] & 255) < 128)
        {
            int64 begin = i;
            while (i < part.length() && (part[i] & 255) < 128) i++;
            text_at(part.substr(begin, i - begin), left, y, ink, font_mono);
            left += cell_w * float(i - begin);
            continue;
        }
        int64 code = part[i + 2] & 255;
        float half = cell_h / 2.0f;
        if (code == 128) fill_at(left, y, cell_w, half, ink);
        else if (code == 132) fill_at(left, y + half, cell_w, half, ink);
        else if (code == 136) fill_at(left, y, cell_w, cell_h, ink);
        else
        {
            fill_at(left, y, cell_w, cell_h, ink);
            for (int64 cell = 0; cell < 8; cell++)
            {
                if ((cell + cell / 2) % 2 == 0 || (code == 145 && cell % 2 == 0))
                    fill_at(left + float(cell % 2) * cell_w / 2.0f, y + float(cell / 2) * cell_h / 4.0f,
                        cell_w / 2.0f, cell_h / 4.0f, background);
            }
        }
        i += 3;
        left += cell_w;
    }
    return true;
}

void set_keyboard_capture(bool enabled)
{
    if (enabled && !keyboard_hook_enabled) return;
    if (!enabled && !focused) return;
    http_response_t result = post_local("/keyboard", enabled ? "{\"enabled\":true}" : "{\"enabled\":false}");
    focused = enabled && result.ok() && extract_json_number(result.body, "captured") == 1;
    if (enabled)
    {
        if (focused)
        {
            scroll_offset = 0;
            status_text = "";
        }
        else status_text = "Could not capture keyboard";
    }
}

string overlay_layout()
{
    return "{\"x\":" + to_string(int64(px)) + ",\"y\":" + to_string(int64(py))
        + ",\"ballX\":" + to_string(ball_remembered ? int64(ball_center.x) : 0)
        + ",\"ballY\":" + to_string(ball_remembered ? int64(ball_center.y) : 0)
        + ",\"minimized\":" + to_string(minimized ? 1 : 0)
        + ",\"keyboardHook\":" + to_string(keyboard_hook_enabled ? 1 : 0)
        + ",\"cols\":" + to_string(cols) + ",\"rows\":" + to_string(rows) + "}";
}

void load_overlay_layout()
{
    http_response_t result = post_local("/layout", "{}");
    if (!result.ok()) return;
    int64 x = extract_json_number(result.body, "x");
    int64 y = extract_json_number(result.body, "y");
    float screen_w = float(get_view_width());
    float screen_h = float(get_view_height());
    if (x >= 0) px = max<float32>(48.0f, min<float32>(float(x), screen_w - 200.0f));
    if (y >= 0) py = max<float32>(21.0f, min<float32>(float(y), screen_h - 150.0f));
    int64 bx = extract_json_number(result.body, "ballX");
    int64 by = extract_json_number(result.body, "ballY");
    if (bx > 0 && by > 0)
    {
        ball_remembered = true;
        ball_center = vec2(max<float32>(18.0f, min<float32>(float(bx), screen_w - 18.0f)),
                           max<float32>(18.0f, min<float32>(float(by), screen_h - 18.0f)));
    }
    keyboard_hook_enabled = extract_json_number(result.body, "keyboardHook") != 0;
    layout_loaded = true;
    saved_layout = extract_json_number(result.body, "minimized") == 1 ? "" : overlay_layout();
}

void store_overlay_layout()
{
    if (!layout_loaded) return;
    string layout = overlay_layout();
    if (layout != saved_layout && post_local("/layout", layout).ok()) saved_layout = layout;
}

int64 text_cell(vec2 pointer)
{
    int64 col = int64((pointer.x - px - 8.0f) / cell_w);
    int64 row = int64((pointer.y - py - 32.0f) / cell_h);
    col = col < 0 ? 0 : (col >= cols ? cols - 1 : col);
    row = row < 0 ? 0 : (row >= rows ? rows - 1 : row);
    return row * cols + col;
}

void draw_text_selection(float sx, float sy)
{
    if (selection_first < 0 || selection_last < 0 || (selecting_text && !selection_dragged)) return;
    int64 first = selection_first < selection_last ? selection_first : selection_last;
    int64 last = selection_first > selection_last ? selection_first : selection_last;
    for (int64 row = first / cols; row <= last / cols; row++)
    {
        int64 lo = row == first / cols ? first % cols : 0;
        int64 hi = row == last / cols ? last % cols : cols - 1;
        fill_at(sx + float(lo) * cell_w, sy + float(row) * cell_h,
            float(hi - lo + 1) * cell_w, cell_h, color(87, 169, 237, 100));
    }
}

void draw_virtual_key(string label, string value, float x, float y, float w,
    vec2 mouse, bool clicked, float blend, int64 index)
{
    bool hot = mouse.x >= x && mouse.x < x + w && mouse.y >= y && mouse.y < y + 30.0f;
    lerp_hover(virtual_key_hover[index], hot, blend);
    bool active = (label == "Shift" && virtual_shift) || (label == "Ctrl" && virtual_ctrl);
    int64 base = active ? 0x365573 : (label == "Enter" ? 0x31485D : 0x2A2D32);
    color shade = lerp_hover_color(base, 0x497098, virtual_key_hover[index]);
    draw_rect_filled(vec2(x, y + 2.0f), vec2(w, 30.0f), rgb_color(0x15171B), 4.0f, 15);
    draw_rect_filled(vec2(x, y), vec2(w, 30.0f), shade, 4.0f, 15);
    float text_w = float(get_text_width(font_mono, label, 0, 0));
    text_at(label, x + (w - text_w) / 2.0f, y + 6.0f, rgb_color(0xE8EDF3), font_mono);
    if (!clicked || !hot || !connected) return;
    if (label == "Shift") { virtual_shift = !virtual_shift; return; }
    if (label == "Ctrl") { virtual_ctrl = !virtual_ctrl; return; }
    if (virtual_ctrl && value.length() == 1)
    {
        int64 ch = value[0] & 255;
        if ((ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122)) value = chr(ch & 31);
        virtual_ctrl = false;
    }
    http_response_t result = post_local("/input", "{\"text\":\"" + encode_input(value) + "\"}");
    if (result.ok()) scroll_offset = 0;
    else status_text = "Could not send key";
}

void draw_virtual_keyboard(float x, float y, float width, vec2 mouse, bool clicked, float blend)
{
    // QWERTY rows adapted from simple-keyboard's MIT-licensed default layout.
    draw_rect_filled(vec2(x, y), vec2(width, 184.0f), rgb_color(0x3A3E45), 7.0f, 15);
    draw_rect_filled(vec2(x + 1.0f, y + 1.0f), vec2(width - 2.0f, 182.0f),
        rgb_color(0x1C1E22), 6.0f, 15);
    string esc = chr(27);
    int64 index = 0;
    float inner = width - 16.0f;
    for (int64 row = 0; row < 4; row++)
    {
        string keys;
        string left = "";
        string right = "";
        string left_value = "";
        string right_value = "";
        float left_units = 0.0f;
        float right_units = 0.0f;
        if (row == 0)
        {
            keys = virtual_shift ? "~!@#$%^&*()_+" : "`1234567890-=";
            right = "Bksp"; right_value = chr(127); right_units = 2.0f;
        }
        else if (row == 1)
        {
            keys = virtual_shift ? "QWERTYUIOP{}|" : "qwertyuiop[]\\";
            left = "Tab"; left_value = chr(9); left_units = 1.8f;
        }
        else if (row == 2)
        {
            keys = virtual_shift ? "ASDFGHJKL:\"" : "asdfghjkl;'";
            left = "Esc"; left_value = esc; left_units = 1.8f;
            right = "Enter"; right_value = chr(13); right_units = 2.5f;
        }
        else
        {
            keys = virtual_shift ? "ZXCVBNM<>?" : "zxcvbnm,./";
            left = "Shift"; left_units = 2.6f;
            right = "Shift"; right_units = 2.6f;
        }
        float step = inner / (float(keys.length()) + left_units + right_units);
        float key_x = x + 8.0f;
        float key_y = y + 8.0f + float(row) * 35.0f;
        if (left_units > 0.0f)
        {
            draw_virtual_key(left, left_value, key_x, key_y, step * left_units - 4.0f, mouse, clicked, blend, index++);
            key_x += step * left_units;
        }
        for (int64 i = 0; i < keys.length(); i++)
        {
            string key = keys.substr(i, 1);
            draw_virtual_key(key, key, key_x, key_y, step - 4.0f, mouse, clicked, blend, index++);
            key_x += step;
        }
        if (right_units > 0.0f)
            draw_virtual_key(right, right_value, key_x, key_y, step * right_units - 4.0f, mouse, clicked, blend, index++);
    }
    float step = inner / 12.0f;
    float key_x = x + 8.0f;
    float key_y = y + 148.0f;
    draw_virtual_key("Ctrl", "", key_x, key_y, step * 2.0f - 4.0f, mouse, clicked, blend, index++);
    draw_virtual_key("Space", " ", key_x + step * 2.0f, key_y, step * 6.0f - 4.0f, mouse, clicked, blend, index++);
    draw_virtual_key("<", esc + "[D", key_x + step * 8.0f, key_y, step - 4.0f, mouse, clicked, blend, index++);
    draw_virtual_key("v", esc + "[B", key_x + step * 9.0f, key_y, step - 4.0f, mouse, clicked, blend, index++);
    draw_virtual_key("^", esc + "[A", key_x + step * 10.0f, key_y, step - 4.0f, mouse, clicked, blend, index++);
    draw_virtual_key(">", esc + "[C", key_x + step * 11.0f, key_y, step - 4.0f, mouse, clicked, blend, index++);
}

void draw_terminal_content(float sx, float sy, float width)
{
    clip_push(vec2(sx, sy), vec2(width, float(rows) * cell_h));
    for (int64 i = 0; i < run_text.size(); i++)
    {
        float rx = sx + cell_w * float(run_col[i]);
        float ry = sy + cell_h * float(run_row[i]);
        fill_at(rx, ry, cell_w * float(run_width[i]), cell_h, rgb_color(run_bg[i]));
        string part = run_text[i];
        bool ascii = true;
        for (int64 j = 0; j < part.length(); j++)
            if ((part[j] & 255) >= 128) { ascii = false; break; }
        if (part.length() > 0 &&
            (ascii || !draw_block_run(part, rx, ry, rgb_color(run_fg[i]), rgb_color(run_bg[i]))))
            text_at(part, rx, ry, rgb_color(run_fg[i]), ascii ? font_mono : font_ui);
    }
    clip_pop();
}

color motion_color(int64 rgb, float opacity)
{
    return color((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255, int64(opacity * 255.0f));
}

void draw_window_motion(float w, float h, float ball_amount)
{
    float x = px + (ball_center.x - 18.0f - px) * ball_amount;
    float y = py + (ball_center.y - 18.0f - py) * ball_amount;
    float width = w + (36.0f - w) * ball_amount;
    float height = h + (36.0f - h) * ball_amount;
    float radius = 18.0f * ball_amount;
    draw_rect_filled(vec2(x, y), vec2(width, height), rgb_color(0x393C40), radius, 15);
    draw_rect_filled(vec2(x + 1.0f, y + 1.0f), vec2(width - 2.0f, height - 2.0f),
        lerp_hover_color(0x14161A, 0x202124, ball_amount), max<float32>(0.0f, radius - 1.0f), 15);
    float opacity = 1.0f - ball_amount;
    float scale = min<float32>(width / w, height / h);
    if (opacity > 0.03f)
    {
        float sx = x + (width - w * scale) / 2.0f;
        float sy = y + (height - h * scale) / 2.0f;
        clip_push(vec2(x + 1.0f, y + 1.0f), vec2(width - 2.0f, height - 2.0f));
        fill_at(x + 1.0f, y + 1.0f, width - 2.0f, 27.0f * scale, motion_color(0x202124, opacity));
        draw_text("OMP", vec2(sx + 8.0f * scale, sy + 4.0f * scale), motion_color(0xE5E5E5, opacity),
            font_mono, 0, color(0, 0, 0, 0), scale);
        for (int64 i = 0; i < run_text.size(); i++)
        {
            float rx = sx + (8.0f + cell_w * float(run_col[i])) * scale;
            float ry = sy + (32.0f + cell_h * float(run_row[i])) * scale;
            fill_at(rx, ry, cell_w * float(run_width[i]) * scale, cell_h * scale, motion_color(run_bg[i], opacity));
            string part = run_text[i];
            if (part.length() == 0) continue;
            bool ascii = true;
            for (int64 j = 0; j < part.length(); j++)
                if ((part[j] & 255) >= 128) { ascii = false; break; }
            draw_text(part, vec2(rx, ry), motion_color(run_fg[i], opacity),
                ascii ? font_mono : font_ui, 0, color(0, 0, 0, 0), scale);
        }
        clip_pop();
    }
    if (ball_amount > 0.87f)
        text_at(">_", x + width / 2.0f - cell_w, y + height / 2.0f - 9.0f,
            color(229, 229, 229, int64((ball_amount - 0.87f) * 1961.0f)), font_mono);
}

void render_terminal(int64 data)
{
    tick++;
    if (tick == 1 || tick % (connected ? 5 : 60) == 0)
    {
        connected = refresh_screen();
        if (!connected) set_keyboard_capture(false);
        else if (!layout_loaded) load_overlay_layout();
    }
    float w = float(cols) * cell_w + 16.0f;
    float h = float(rows) * cell_h + 40.0f;
    vec2 mouse = get_mouse_pos();
    bool pressed = key_down(1);
    bool clicked = pressed && !previous_left;
    previous_left = pressed;
    bool right_pressed = key_down(2);
    bool right_clicked = right_pressed && !previous_right;
    previous_right = right_pressed;
    if (connected && !pressed) store_overlay_layout();
    float center_x = px + w / 2.0f;
    float minimize_y = py >= 21.0f ? py - 21.0f : py + 2.0f;
    float64 now = time_ms();
    float64 hover_delta = hover_time > 0.0 ? (now - hover_time) / 1000.0 : 0.0;
    hover_time = now;
    float hover_blend = float(min<float64>(1.0, max<float64>(0.0, hover_delta * 15.0)));
    float progress = float((now - minimize_started_at) / (minimized ? 185.0 : 220.0));
    if (progress < 1.0f)
    {
        if (progress < 0.0f) progress = 0.0f;
        float ease = progress * progress * (3.0f - 2.0f * progress);
        draw_window_motion(w, h, minimized ? ease : 1.0f - ease);
        return;
    }
    if (minimized)
    {
        float dx = mouse.x - ball_center.x;
        float dy = mouse.y - ball_center.y;
        bool over_ball = dx * dx + dy * dy <= 18.0f * 18.0f;
        lerp_hover(ball_hover, over_ball || ball_pressed, hover_blend);
        if (clicked && over_ball)
        {
            ball_pressed = true;
            ball_dragged = false;
            ball_press_at = mouse;
            ball_press_center = ball_center;
        }
        if (ball_pressed)
        {
            float offset_x = mouse.x - ball_press_at.x;
            float offset_y = mouse.y - ball_press_at.y;
            if (offset_x * offset_x + offset_y * offset_y >= 25.0f) ball_dragged = true;
            if (ball_dragged)
                ball_center = vec2(max<float32>(18.0f, min<float32>(ball_press_center.x + offset_x,
                                       float(get_view_width()) - 18.0f)),
                                   max<float32>(18.0f, min<float32>(ball_press_center.y + offset_y,
                                       float(get_view_height()) - 18.0f)));
            if (!pressed)
            {
                ball_pressed = false;
                if (!ball_dragged && over_ball)
                {
                    px = max<float32>(48.0f, min<float32>(ball_center.x - w / 2.0f,
                        float(get_view_width()) - w));
                    py = max<float32>(21.0f, min<float32>(ball_center.y - h / 2.0f,
                        float(get_view_height()) - h));
                    minimized = false;
                    minimize_started_at = now;
                }
            }
        }
        draw_rect_filled(vec2(ball_center.x - 18.0f, ball_center.y - 18.0f), vec2(36.0f, 36.0f),
            lerp_hover_color(0x393C40, 0x4C657D, ball_hover), 18.0f, 15);
        draw_rect_filled(vec2(ball_center.x - 17.0f, ball_center.y - 17.0f), vec2(34.0f, 34.0f),
            lerp_hover_color(0x202124, 0x2E4052, ball_hover), 17.0f, 15);
        text_at(">_", ball_center.x - cell_w, ball_center.y - 9.0f, rgb_color(0xE5E5E5), font_mono);
        return;
    }
    float settings_x = px + w - 32.0f;
    float menu_x = settings_x - 164.0f;
    float menu_y = py + 30.0f;
    bool over_settings = mouse.x >= settings_x && mouse.x < settings_x + 26.0f
        && mouse.y >= py + 2.0f && mouse.y < py + 26.0f;
    bool over_menu = settings_open && mouse.x >= menu_x && mouse.x < menu_x + 190.0f
        && mouse.y >= menu_y && mouse.y < menu_y + 62.0f;
    bool over_menu_keyboard = connected && over_menu && mouse.y < menu_y + 31.0f;
    bool over_menu_reset = connected && over_menu && mouse.y >= menu_y + 31.0f;
    lerp_hover(settings_hover, over_settings || settings_open, hover_blend);
    lerp_hover(settings_keyboard_hover, over_menu_keyboard, hover_blend);
    lerp_hover(settings_reset_hover, over_menu_reset, hover_blend);
    if (selection_mode == 0 && clicked && resize_x == 0 && (over_settings || over_menu))
    {
        clicked = false;
        set_keyboard_capture(false);
        if (over_settings) settings_open = !settings_open;
        else if (over_menu_keyboard)
        {
            keyboard_hook_enabled = !keyboard_hook_enabled;
            status_text = "";
            store_overlay_layout();
        }
        else if (over_menu_reset)
        {
            if (post_local("/resize", "{\"cols\":100,\"rows\":30}").ok())
            {
                px = 48.0f;
                py = 56.0f;
                ball_remembered = false;
                selection_first = -1;
                selection_last = -1;
                refresh_screen();
                store_overlay_layout();
            }
            else status_text = "Could not reset layout";
            settings_open = false;
            return;
        }
    }
    else if (clicked) settings_open = false;
    if (selection_mode != 0)
    {
        if (selection_mode == 3)
        {
            if (tick < selection_deadline) return;
            selection_mode = 0;
            status_text = "Capture timed out";
            return;
        }
        if (key_fired(27) || key_fired(2))
        {
            selection_mode = 0;
            status_text = "Capture canceled";
            return;
        }
        if (selection_mode == 1 && clicked)
        {
            http_response_t start = post_local("/cursor", "{}");
            if (!start.ok())
            {
                selection_mode = 0;
                status_text = "Could not read cursor position";
                return;
            }
            selection_start = mouse;
            selection_left = extract_json_number(start.body, "x");
            selection_top = extract_json_number(start.body, "y");
            selection_mode = 2;
        }
        if (selection_mode == 2)
        {
            if (!pressed)
            {
                selection_mode = 0;
                http_response_t end = post_local("/cursor", "{}");
                if (end.ok())
                {
                    int64 x = extract_json_number(end.body, "x");
                    int64 y = extract_json_number(end.body, "y");
                    int64 left = x < selection_left ? x : selection_left;
                    int64 top = y < selection_top ? y : selection_top;
                    int64 right = x > selection_left ? x : selection_left;
                    int64 bottom = y > selection_top ? y : selection_top;
                    string region = "{\"left\":" + to_string(left) + ",\"top\":" + to_string(top)
                        + ",\"right\":" + to_string(right) + ",\"bottom\":" + to_string(bottom) + "}";
                    http_response_t result = post_local("/screenshot", region);
                    if (result.ok())
                    {
                        previous_snip = 1;
                        selection_mode = 3;
                        selection_deadline = tick + 300;
                    }
                    else status_text = "Capture failed. Try again";
                }
                else status_text = "Could not read cursor position";
                return;
            }
            float x = mouse.x < selection_start.x ? mouse.x : selection_start.x;
            float y = mouse.y < selection_start.y ? mouse.y : selection_start.y;
            float width = abs(mouse.x - selection_start.x);
            float height = abs(mouse.y - selection_start.y);
            color border = rgb_color(0x65BFFF);
            fill_at(x, y, width, 2.0f, border);
            fill_at(x, y + height, width, 2.0f, border);
            fill_at(x, y, 2.0f, height, border);
            fill_at(x + width, y, 2.0f, height, border);
        }
        else
        {
            fill_at(px, py, 243.0f, 28.0f, rgb_color(0x263341));
            text_at("Drag to select. Esc to cancel", px + 10.0f, py + 3.0f, rgb_color(0xE5EEF7), font_ui);
        }
        return;
    }
    bool over_minimize = mouse.x >= center_x - 18.0f && mouse.x < center_x + 18.0f
        && mouse.y >= minimize_y && mouse.y < minimize_y + 19.0f;
    if (clicked && over_minimize && resize_x == 0)
    {
        set_keyboard_capture(false);
        minimized = true;
        ball_hover = 0.0f;
        if (!ball_remembered)
        {
            ball_center = vec2(max<float32>(18.0f, min<float32>(center_x, float(get_view_width()) - 18.0f)),
                max<float32>(18.0f, min<float32>(py + 18.0f, float(get_view_height()) - 18.0f)));
            ball_remembered = true;
        }
        minimize_started_at = now;
        focused = false;
        dragging = false;
        draw_window_motion(w, h, 0.0f);
        return;
    }
    bool in_box = mouse.x >= px && mouse.x < px + w && mouse.y >= py && mouse.y < py + h;
    bool resizing = resize_window(mouse, pressed, clicked, w, h);
    w = float(cols) * cell_w + 16.0f;
    h = float(rows) * cell_h + 40.0f;
    if (connected && in_box)
    {
        float wheel = get_scroll_delta();
        if (wheel != 0.0f)
        {
            selecting_text = false;
            selection_first = -1;
            selection_last = -1;
            int64 steps = int64(abs(wheel) * 3.0f + 0.5f);
            if (steps < 1) steps = 1;
            int64 requested = scroll_offset + (wheel > 0.0f ? steps : -steps);
            scroll_offset = requested < 0 ? 0 : (requested > history_rows ? history_rows : requested);
        }
    }
    bool in_header = in_box && mouse.y < py + 28.0f;
    float button_x = px - 48.0f;
    float paste_y = py + 17.0f;
    float screenshot_y = paste_y + 48.0f;
    float keyboard_y = screenshot_y + 48.0f;
    float attach_y = keyboard_y + 48.0f;
    bool over_toolbar = mouse.x >= button_x && mouse.x < button_x + 40.0f;
    bool wants_paste = over_toolbar && mouse.y >= paste_y && mouse.y < paste_y + 40.0f;
    bool wants_screenshot = over_toolbar && mouse.y >= screenshot_y && mouse.y < screenshot_y + 40.0f;
    bool wants_keyboard = over_toolbar && mouse.y >= keyboard_y && mouse.y < keyboard_y + 40.0f;
    bool wants_attach = over_toolbar && mouse.y >= attach_y && mouse.y < attach_y + 40.0f;
    float keyboard_width = min<float32>(w - 16.0f, 680.0f);
    float panel_x = max<float32>(4.0f, min<float32>(px + (w - keyboard_width) / 2.0f,
        float(get_view_width()) - keyboard_width - 4.0f));
    float panel_y = py + h + 8.0f;
    bool over_keyboard_panel = virtual_keyboard && mouse.x >= panel_x && mouse.x < panel_x + keyboard_width
        && mouse.y >= panel_y && mouse.y < panel_y + 184.0f;
    float latest_x = px + w - 160.0f;
    float latest_y = py + h - 35.0f;
    bool over_latest = scroll_offset > 0 && mouse.x >= latest_x && mouse.x < latest_x + 151.0f
        && mouse.y >= latest_y && mouse.y < latest_y + 26.0f;
    lerp_hover(latest_hover, over_latest, hover_blend);
    bool click_latest = clicked && over_latest && !resizing;
    if (click_latest)
    {
        scroll_offset = 0;
        selection_first = -1;
        selection_last = -1;
        refresh_screen();
    }
    bool over_text = connected && mouse.x >= px + 8.0f && mouse.x < px + w - 8.0f
        && mouse.y >= py + 32.0f && mouse.y < py + 32.0f + float(rows) * cell_h;
    if (clicked && over_text && !click_latest && !resizing && !over_keyboard_panel)
    {
        selecting_text = true;
        selection_dragged = false;
        selection_press = mouse;
        selection_first = text_cell(mouse);
        selection_last = selection_first;
    }
    if (selecting_text)
    {
        float dx = mouse.x - selection_press.x;
        float dy = mouse.y - selection_press.y;
        if (!selection_dragged && dx * dx + dy * dy >= 16.0f)
        {
            selection_dragged = true;
            set_keyboard_capture(false);
        }
        if (selection_dragged) selection_last = text_cell(mouse);
        if (!pressed)
        {
            selecting_text = false;
            if (!selection_dragged)
            {
                selection_first = -1;
                selection_last = -1;
                set_keyboard_capture(over_text);
            }
            else status_text = "Right-click to copy selection";
        }
    }
    if (right_clicked && in_box && selection_first >= 0 && selection_last >= 0 && !selecting_text)
    {
        string range = "{\"first\":" + to_string(selection_first) + ",\"last\":" + to_string(selection_last)
            + ",\"scroll\":" + to_string(scroll_offset) + ",\"anchor\":" + to_string(history_anchor) + "}";
        status_text = post_local("/copy", range).ok() ? "Selection copied" : "Could not copy selection";
    }
    float compose_width = float(get_text_width(font_mono, "IME input", 0, 0)) + 12.0f;
    float compose_x = px + w - compose_width - 36.0f;
    bool wants_compose = in_header && mouse.x >= compose_x && mouse.x < compose_x + compose_width
        && mouse.y >= py + 2.0f && mouse.y < py + 26.0f;
    lerp_hover(minimize_hover, over_minimize, hover_blend);
    lerp_hover(compose_hover, wants_compose, hover_blend);
    lerp_hover(paste_hover, wants_paste, hover_blend);
    lerp_hover(screenshot_hover, wants_screenshot, hover_blend);
    lerp_hover(keyboard_hover, wants_keyboard || virtual_keyboard, hover_blend);
    lerp_hover(attach_hover, wants_attach, hover_blend);
    if (clicked && !resizing && wants_keyboard)
    {
        set_keyboard_capture(false);
        virtual_keyboard = !virtual_keyboard;
        virtual_shift = false;
        virtual_ctrl = false;
    }
    else if (clicked && !resizing && !over_keyboard_panel && !selecting_text && !click_latest)
    {
        set_keyboard_capture(false);
        dragging = in_header && !wants_compose && !wants_paste && !wants_screenshot;
        drag_x = mouse.x - px;
        drag_y = mouse.y - py;
        if (connected && wants_attach)
        {
            http_response_t result = post_local("/attach", "{}");
            status_text = result.ok() ? "Choose a file to attach" : "Could not open file picker";
        }
        else if (connected && wants_screenshot)
        {
            focused = false;
            selection_mode = 1;
            return;
        }
        if (connected && wants_paste)
        {
            http_response_t result = post_local("/paste", "{}");
            status_text = result.ok() ? "Pasted" : "No clipboard text";
            focused = false;
        }
        else if (connected && wants_compose)
        {
            focused = false;
            http_response_t compose = post_local("/compose", "{}");
            status_text = compose.ok() ? "Confirm in the input window" : "Could not open IME input";
        }
    }
    if (!pressed) dragging = false;
    if (dragging)
    {
        px = mouse.x - drag_x;
        if (px < 48.0f) px = 48.0f;
        py = mouse.y - drag_y;
        button_x = px - 48.0f;
        paste_y = py + 17.0f;
        screenshot_y = paste_y + 48.0f;
        keyboard_y = screenshot_y + 48.0f;
        attach_y = keyboard_y + 48.0f;
        panel_x = max<float32>(4.0f, min<float32>(px + (w - keyboard_width) / 2.0f,
            float(get_view_width()) - keyboard_width - 4.0f));
        panel_y = py + h + 8.0f;
    }
    float sx = px + 8.0f;
    float sy = py + 32.0f;
    fill_at(px, py, w, h, rgb_color(focused ? 0x55585E : 0x393C40));
    fill_at(px + 1.0f, py + 1.0f, w - 2.0f, h - 2.0f, rgb_color(0x14161A));
    fill_at(px + 1.0f, py + 1.0f, w - 2.0f, 26.0f, rgb_color(0x202124));
    fill_at(px + 1.0f, py + 27.0f, w - 2.0f, 1.0f, rgb_color(0x35373B));
    text_at("OMP", sx, py + 4.0f, rgb_color(0xE5E5E5), font_mono);
    string hint = !connected ? status_text : (focused ? "Keyboard captured. Shift+F8 to release"
        : (keyboard_hook_enabled ? "Click terminal to type" : "Keyboard hook off"));
    if (connected && status_text.length() > 0 && (!focused || previous_snip == 2)) hint = status_text;
    if (wants_paste) hint = "Paste text";
    if (wants_screenshot) hint = "Capture and attach an area";
    if (wants_keyboard) hint = virtual_keyboard ? "Close keyboard" : "Open keyboard";
    if (wants_attach) hint = "Attach a local file";
    if (scroll_offset > 0 && selection_first < 0 && !wants_paste && !wants_screenshot && !wants_keyboard && !wants_attach)
        hint = "Scrollback: " + to_string(scroll_offset) + " lines above bottom";
    bool diagnostic_visible = !connected || (previous_snip == 4 && status_text.length() > 0);
    if (diagnostic_visible) hint = status_text;
    compose_x = px + w - compose_width - 36.0f;
    clip_push(vec2(px + 53.0f, py + 2.0f), vec2(compose_x - px - 61.0f, 24.0f));
    text_at(hint, px + 53.0f, py + 4.0f, rgb_color(diagnostic_visible ? 0xE5AA74 : 0xA7A9AD), font_mono);
    clip_pop();
    if (compose_hover > 0.002f)
        fill_at(compose_x, py + 2.0f, compose_width, 24.0f,
            lerp_hover_color(0x202124, 0x35373B, compose_hover));
    text_at("IME input", compose_x + 6.0f, py + 4.0f, rgb_color(0xD4D4D4), font_mono);
    color paste_bg = lerp_hover_color(0x202124, 0x393C40, paste_hover);
    color shot_bg = lerp_hover_color(0x202124, 0x393C40, screenshot_hover);
    color icon = rgb_color(0xE5EEF7);
    fill_at(button_x, paste_y, 40.0f, 40.0f, rgb_color(0x393C40));
    fill_at(button_x + 1.0f, paste_y + 1.0f, 38.0f, 38.0f, paste_bg);
    fill_at(button_x + 12.0f, paste_y + 12.0f, 16.0f, 19.0f, icon);
    fill_at(button_x + 14.0f, paste_y + 14.0f, 12.0f, 15.0f, paste_bg);
    fill_at(button_x + 16.0f, paste_y + 9.0f, 8.0f, 6.0f, icon);
    fill_at(button_x + 17.0f, paste_y + 19.0f, 6.0f, 2.0f, icon);
    fill_at(button_x + 17.0f, paste_y + 24.0f, 6.0f, 2.0f, icon);
    fill_at(button_x, screenshot_y, 40.0f, 40.0f, rgb_color(0x393C40));
    fill_at(button_x + 1.0f, screenshot_y + 1.0f, 38.0f, 38.0f, shot_bg);
    for (int64 corner = 0; corner < 4; corner++)
    {
        float x = button_x + (corner % 2 == 0 ? 10.0f : 24.0f);
        float y = screenshot_y + (corner < 2 ? 10.0f : 24.0f);
        fill_at(x, y + (corner < 2 ? 0.0f : 4.0f), 6.0f, 2.0f, icon);
        fill_at(x + (corner % 2 == 0 ? 0.0f : 4.0f), y, 2.0f, 6.0f, icon);
    }
    fill_at(button_x + 18.0f, screenshot_y + 18.0f, 4.0f, 4.0f, icon);
    color key_bg = lerp_hover_color(0x202124, 0x344F69, keyboard_hover);
    fill_at(button_x, keyboard_y, 40.0f, 40.0f, rgb_color(0x393C40));
    fill_at(button_x + 1.0f, keyboard_y + 1.0f, 38.0f, 38.0f, key_bg);
    fill_at(button_x + 8.0f, keyboard_y + 12.0f, 24.0f, 16.0f, icon);
    fill_at(button_x + 10.0f, keyboard_y + 14.0f, 20.0f, 12.0f, key_bg);
    for (int64 dot = 0; dot < 4; dot++)
        fill_at(button_x + 12.0f + float(dot) * 5.0f, keyboard_y + 16.0f, 2.0f, 2.0f, icon);
    fill_at(button_x + 14.0f, keyboard_y + 22.0f, 12.0f, 2.0f, icon);
    fill_at(button_x, attach_y, 40.0f, 40.0f, rgb_color(0x393C40));
    fill_at(button_x + 1.0f, attach_y + 1.0f, 38.0f, 38.0f,
        lerp_hover_color(0x202124, 0x344F69, attach_hover));
    vec2 hook_a = vec2(button_x + 13.0f, attach_y + 21.0f);
    vec2 hook_b = vec2(button_x + 24.0f, attach_y + 10.0f);
    vec2 hook_c = vec2(button_x + 31.0f, attach_y + 17.0f);
    vec2 hook_d = vec2(button_x + 17.0f, attach_y + 31.0f);
    vec2 hook_e = vec2(button_x + 10.0f, attach_y + 24.0f);
    draw_line(hook_a, hook_b, icon, 1.6);
    draw_line(hook_b, hook_c, icon, 1.6);
    draw_line(hook_c, hook_d, icon, 1.6);
    draw_line(hook_d, hook_e, icon, 1.6);
    draw_line(hook_e, vec2(button_x + 24.0f, attach_y + 14.0f), icon, 1.6);
    draw_terminal_content(sx, sy, w - 16.0f);
    draw_text_selection(sx, sy);
    if (scroll_offset > 0)
    {
        latest_x = px + w - 160.0f;
        latest_y = py + h - 35.0f;
        fill_at(latest_x, latest_y, 151.0f, 26.0f, rgb_color(0x425568));
        fill_at(latest_x + 1.0f, latest_y + 1.0f, 149.0f, 24.0f,
            lerp_hover_color(0x273441, 0x3C536A, latest_hover));
        text_at("Jump to latest", latest_x + 7.0f, latest_y + 4.0f, rgb_color(0xECF5FF), font_mono);
    }
    if (connected && scroll_offset == 0 && cursor_visible && cursor_x >= 0 && cursor_x < cols && cursor_y >= 0 && cursor_y < rows)
        fill_at(sx + float(cursor_x) * cell_w, sy + float(cursor_y + 1) * cell_h - 2.0f, cell_w, 2.0f, rgb_color(0xE0E0E0));
    draw_resize_corners(px, py, w, h);
    center_x = px + w / 2.0f;
    minimize_y = py >= 21.0f ? py - 21.0f : py + 2.0f;
    fill_at(center_x - 18.0f, minimize_y, 36.0f, 19.0f, rgb_color(0x393C40));
    fill_at(center_x - 17.0f, minimize_y + 1.0f, 34.0f, 17.0f,
        lerp_hover_color(0x202124, 0x343C45, minimize_hover));
    fill_at(center_x - 5.0f, minimize_y + 9.0f, 10.0f, 2.0f, rgb_color(0xC9CDD1));
    if (virtual_keyboard)
        draw_virtual_keyboard(panel_x, panel_y, keyboard_width, mouse,
            clicked && over_keyboard_panel && !resizing && !wants_keyboard, hover_blend);
    settings_x = px + w - 32.0f;
    fill_at(settings_x, py + 2.0f, 26.0f, 24.0f,
        lerp_hover_color(0x202124, 0x374657, settings_hover));
    float gx = settings_x + 13.0f;
    float gy = py + 14.0f;
    color gear = rgb_color(0xC9CDD1);
    draw_line(vec2(gx - 8.0f, gy), vec2(gx + 8.0f, gy), gear, 2.0f);
    draw_line(vec2(gx, gy - 8.0f), vec2(gx, gy + 8.0f), gear, 2.0f);
    draw_line(vec2(gx - 5.5f, gy - 5.5f), vec2(gx + 5.5f, gy + 5.5f), gear, 2.0f);
    draw_line(vec2(gx + 5.5f, gy - 5.5f), vec2(gx - 5.5f, gy + 5.5f), gear, 2.0f);
    draw_rect_filled(vec2(gx - 6.0f, gy - 6.0f), vec2(12.0f, 12.0f), gear, 6.0f, 15);
    draw_rect_filled(vec2(gx - 3.0f, gy - 3.0f), vec2(6.0f, 6.0f),
        lerp_hover_color(0x202124, 0x374657, settings_hover), 3.0f, 15);
    if (settings_open)
    {
        menu_x = settings_x - 164.0f;
        menu_y = py + 30.0f;
        fill_at(menu_x, menu_y, 190.0f, 62.0f, rgb_color(0x3A3E45));
        fill_at(menu_x + 1.0f, menu_y + 1.0f, 188.0f, 30.0f,
            lerp_hover_color(0x202124, 0x374657, settings_keyboard_hover));
        fill_at(menu_x + 1.0f, menu_y + 32.0f, 188.0f, 29.0f,
            lerp_hover_color(0x202124, 0x374657, settings_reset_hover));
        text_at(keyboard_hook_enabled ? "Keyboard hook: On" : "Keyboard hook: Off",
            menu_x + 9.0f, menu_y + 7.0f, connected ? gear : rgb_color(0x777A80), font_mono);
        text_at("Reset window layout", menu_x + 9.0f, menu_y + 37.0f,
            connected ? gear : rgb_color(0x777A80), font_mono);
    }
}

int64 main()
{
    font_mono = create_font("C:/Windows/Fonts/CascadiaMono.ttf", 16.0f, true, false, {});
    if (font_mono == 0)
        font_mono = create_font("C:/Windows/Fonts/consola.ttf", 16.0f, true, false, {});
    font_ui = create_font("C:/Windows/Fonts/msyh.ttc", 16.0f, true, false, {});
    if (font_mono == 0) font_mono = get_font20();
    if (font_ui == 0) font_ui = font_mono;
    float measure = get_text_width(font_mono, "MMMMMMMMMM", 0, 0);
    if (measure >= 60.0f && measure <= 150.0f) cell_w = measure / 10.0f;
    if (register_routine(reinterpret_cast<int64>(render_terminal), 0) == -1) return 0;
    return 1;
}

void on_unload()
{
    store_overlay_layout();
    set_keyboard_capture(false);
}
