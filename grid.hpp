#pragma once

#include <vterm.h>
#include <algorithm>
#include <cstdint>
#include <deque>
#include <cstdio>
#include <new>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

// Owned by the host. Access from the reader and HTTP threads is serialized
// by the host so a snapshot cannot observe a partially applied VT sequence.
class TerminalGrid {
    VTerm* term_;
    VTermState* state_;
    VTermScreen* screen_;
    VTermScreenCallbacks callbacks_{};
    int cols_, rows_;
    bool cursorVisible_ = true;
    std::string replies_;
    std::deque<std::vector<VTermScreenCell>> history_;
    uint64_t historySerial_ = 0;
    static constexpr size_t historyLimit = 5000;

    static int pushHistory(int cols, const VTermScreenCell* cells, void* self) {
        auto* grid = static_cast<TerminalGrid*>(self);
        auto& history = grid->history_;
        if (history.size() == historyLimit) history.pop_front();
        history.emplace_back(cells, cells + cols);
        ++grid->historySerial_;
        return 1;
    }
    VTermScreenCell viewCell(int row, int col, int offset) const {
        const int line = int(history_.size()) - offset + row;
        if (line < int(history_.size())) {
            const auto& saved = history_[line];
            if (col < int(saved.size())) return saved[col];
        }
        VTermScreenCell cell{};
        if (line >= int(history_.size()))
            vterm_screen_get_cell(screen_, {line - int(history_.size()), col}, &cell);
        return cell;
    }

    static void output(const char* bytes, size_t n, void* self) {
        static_cast<TerminalGrid*>(self)->replies_.append(bytes, n);
    }
    static int property(VTermProp prop, VTermValue* val, void* self) {
        if (prop == VTERM_PROP_CURSORVISIBLE)
            static_cast<TerminalGrid*>(self)->cursorVisible_ = val->boolean != 0;
        return 1;
    }
    static void appendCodepoint(std::string& s, uint32_t c) {
        if (c > 0x10ffff || (c >= 0xd800 && c <= 0xdfff)) c = 0xfffd;
        if (c < 0x80) { s.push_back(static_cast<char>(c)); return; }
        if (c < 0x800) s.push_back(static_cast<char>(0xc0 | (c >> 6)));
        else {
            if (c < 0x10000) s.push_back(static_cast<char>(0xe0 | (c >> 12)));
            else {
                s.push_back(static_cast<char>(0xf0 | (c >> 18)));
                s.push_back(static_cast<char>(0x80 | ((c >> 12) & 0x3f)));
            }
            s.push_back(static_cast<char>(0x80 | ((c >> 6) & 0x3f)));
        }
        s.push_back(static_cast<char>(0x80 | (c & 0x3f)));
    }
    static void appendCell(std::string& s, const VTermScreenCell& cell) {
        if (!cell.chars[0]) { s.push_back(' '); return; }
        for (uint32_t ch : cell.chars) {
            if (!ch || ch == UINT32_MAX) break;
            appendCodepoint(s, ch);
        }
    }
    uint32_t rgb(VTermColor color) const {
        vterm_screen_convert_color_to_rgb(screen_, &color);
        return (uint32_t(color.rgb.red) << 16) | (uint32_t(color.rgb.green) << 8) | color.rgb.blue;
    }
    VTermPos cursor() const {
        VTermPos pos{}; vterm_state_get_cursorpos(state_, &pos); return pos;
    }
public:
    TerminalGrid(int cols, int rows)
        : term_(vterm_new(rows, cols)), cols_(cols), rows_(rows) {
        if (!term_) throw std::bad_alloc();
        vterm_set_utf8(term_, 1);
        vterm_output_set_callback(term_, output, this);
        state_ = vterm_obtain_state(term_);
        screen_ = vterm_obtain_screen(term_);
        callbacks_.settermprop = property;
        callbacks_.sb_pushline = pushHistory;
        vterm_screen_set_callbacks(screen_, &callbacks_, this);
        vterm_screen_enable_altscreen(screen_, 1);
        vterm_screen_reset(screen_, 1);
        VTermColor fg{}, bg{};
        vterm_color_rgb(&fg, 224, 227, 231);
        vterm_color_rgb(&bg, 20, 22, 26);
        vterm_screen_set_default_colors(screen_, &fg, &bg);
        vterm_state_set_bold_highbright(state_, 1);
    }
    ~TerminalGrid() { vterm_free(term_); }
    TerminalGrid(const TerminalGrid&) = delete;
    TerminalGrid& operator=(const TerminalGrid&) = delete;
    std::string feed(std::string_view raw) {
        vterm_input_write(term_, raw.data(), raw.size());
        vterm_screen_flush_damage(screen_);
        return std::exchange(replies_, {});
    }
    int columns() const { return cols_; }
    int rows() const { return rows_; }
    void resize(int cols, int rows) {
        cols_ = cols;
        rows_ = rows;
        vterm_set_size(term_, rows, cols);
    }
    int cursorX() const { return cursor().col; }
    int cursorY() const { return cursor().row; }
    bool cursorVisible() const { return cursorVisible_; }
    int historySize() const { return int(history_.size()); }
    uint64_t historySerial() const { return historySerial_; }
    void clearHistory() { history_.clear(); historySerial_ = 0; }
    std::string selectedText(int offset, int first, int last) const {
        offset = std::clamp(offset, 0, historySize());
        if (first > last) std::swap(first, last);
        first = std::clamp(first, 0, rows_ * cols_ - 1);
        last = std::clamp(last, 0, rows_ * cols_ - 1);
        std::string output;
        for (int row = first / cols_; row <= last / cols_; ++row) {
            int left = row == first / cols_ ? first % cols_ : 0;
            int right = row == last / cols_ ? last % cols_ : cols_ - 1;
            std::string line;
            if (left > 0 && viewCell(row, left, offset).chars[0] == UINT32_MAX) --left;
            for (int col = left; col <= right;) {
                auto cell = viewCell(row, col, offset);
                const auto width = std::max<int>(1, cell.width);
                if (cell.attrs.conceal) line.append(width, ' ');
                else appendCell(line, cell);
                col += width;
            }
            if (row != last / cols_) {
                const auto end = line.find_last_not_of(' ');
                if (end != std::string::npos) line.resize(end + 1);
                else line.clear();
                line += "\r\n";
            }
            output += line;
        }
        return output;
    }
    std::vector<std::string> lines(int offset = 0) const {
        offset = std::clamp(offset, 0, historySize());
        std::vector<std::string> out(rows_);
        for (int r = 0; r < rows_; ++r) {
            for (int c = 0; c < cols_;) {
                const auto cell = viewCell(r, c, offset);
                if (cell.attrs.conceal) out[r].append(std::max<int>(1, cell.width), ' ');
                else appendCell(out[r], cell);
                c += std::max<int>(1, cell.width);
            }
            const auto end = out[r].find_last_not_of(' ');
            out[r].resize(end == std::string::npos ? 0 : end + 1);
        }
        return out;
    }
    // One run per line: row,col,fgRGB,bgRGB,cellWidth TAB printable UTF-8.
    std::string paint(int offset = 0) const {
        offset = std::clamp(offset, 0, historySize());
        std::string result;
        for (int row = 0; row < rows_; ++row) {
            int start = 0;
            uint32_t fg = 0, bg = 0;
            std::string text;
            auto emit = [&](int end) {
                if (text.empty()) return;
                char fields[80];
                std::snprintf(fields, sizeof(fields), "%d,%d,%06X,%06X,%d\t",
                    row, start, fg, bg, end - start);
                result += fields; result += text; result += '\n'; text.clear();
            };
            for (int col = 0; col < cols_;) {
                const auto cell = viewCell(row, col, offset);
                auto f = rgb(cell.fg), b = rgb(cell.bg);
                if (cell.attrs.reverse) std::swap(f, b);
                if (text.empty() || f != fg || b != bg) {
                    emit(col); start = col; fg = f; bg = b;
                }
                int width = std::max<int>(1, cell.width);
                if (cell.attrs.conceal) text.append(width, ' ');
                else appendCell(text, cell);
                col += width;
            }
            emit(cols_);
        }
        return result;
    }
};
