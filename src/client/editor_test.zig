//! Unit tests for editor.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in editor.zig.

const std = @import("std");
const vaxis = @import("vaxis");

const editor = @import("editor.zig");
const Editor = editor.Editor;
const clear = editor.clear;
const deinit = editor.deinit;
const deleteAfter = editor.deleteAfter;
const deleteRange = editor.deleteRange;
const deleteToLineStart = editor.deleteToLineStart;
const deleteWordAfter = editor.deleteWordAfter;
const deleteWordBefore = editor.deleteWordBefore;
const deleteWordBeforeWhitespace = editor.deleteWordBeforeWhitespace;
const delimRange = editor.delimRange;
const displayHeight = editor.displayHeight;
const findOnLine = editor.findOnLine;
const histDown = editor.histDown;
const histUp = editor.histUp;
const init = editor.init;
const innerWordRange = editor.innerWordRange;
const insertImagePlaceholder = editor.insertImagePlaceholder;
const insertNewline = editor.insertNewline;
const insertSlice = editor.insertSlice;
const isEmpty = editor.isEmpty;
const layoutRows = editor.layoutRows;
const lineRangeAt = editor.lineRangeAt;
const linesRange = editor.linesRange;
const max_history_entries = editor.max_history_entries;
const max_history_entry_bytes = editor.max_history_entry_bytes;
const moveDown = editor.moveDown;
const moveLeft = editor.moveLeft;
const moveLineStart = editor.moveLineStart;
const moveUp = editor.moveUp;
const moveWordLeft = editor.moveWordLeft;
const moveWordRight = editor.moveWordRight;
const moveWordStart = editor.moveWordStart;
const openLine = editor.openLine;
const paste = editor.paste;
const pushHistory = editor.pushHistory;
const pushUndo = editor.pushUndo;
const quoteRange = editor.quoteRange;
const redo = editor.redo;
const replaceUnderCursor = editor.replaceUnderCursor;
const takeExpanded = editor.takeExpanded;
const takeExpandedSensitive = editor.takeExpandedSensitive;
const takeExpandedWithImages = editor.takeExpandedWithImages;
const toggleCaseUnderCursor = editor.toggleCaseUnderCursor;
const undo = editor.undo;
const wordBackRange = editor.wordBackRange;
const wordForwardRange = editor.wordForwardRange;

test {
    std.testing.refAllDecls(editor);
}

const testing = std.testing;

test "insert, newline, expand-free submit round trip" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("hello");
    ed.insertNewline();
    ed.insertSlice("world");
    const out = try ed.takeExpanded();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello\nworld", out);
    try testing.expect(ed.isEmpty());
}

test "big paste becomes chip and expands on submit" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    var big: [600]u8 = undefined;
    @memset(&big, 'x');
    ed.insertSlice("see: ");
    ed.paste(&big);
    try testing.expect(std.mem.indexOf(u8, ed.text.items, "[paste #1:") != null);
    const out = try ed.takeExpanded();
    defer testing.allocator.free(out);
    try testing.expect(out.len == "see: ".len + 600);
    try testing.expect(std.mem.startsWith(u8, out, "see: xxxx"));
}

test "sensitive submit clears editor and paste storage" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    var secret: [600]u8 = undefined;
    @memset(&secret, 's');
    ed.paste(&secret);
    try testing.expectEqual(@as(usize, 1), ed.pastes.items.len);
    const out = try ed.takeExpandedSensitive();
    defer {
        @memset(out, 0);
        testing.allocator.free(out);
    }
    try testing.expectEqualSlices(u8, &secret, out);
    try testing.expect(ed.isEmpty());
    try testing.expectEqual(@as(usize, 0), ed.text.capacity);
    try testing.expectEqual(@as(usize, 0), ed.pastes.items.len);
    try testing.expectEqual(@as(usize, 0), ed.undo_stack.items.len);
    try testing.expectEqual(@as(usize, 0), ed.redo_stack.items.len);
}

test "small paste inserts inline" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.paste("just a line");
    try testing.expectEqualStrings("just a line", ed.text.items);
}

test "mangled chip label passes through verbatim" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("[paste #9: 4 lines]"); // no such paste
    const out = try ed.takeExpanded();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("[paste #9: 4 lines]", out);
}

test "image placeholders are visible drafts and stripped on submit" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("compare");
    ed.insertImagePlaceholder(1);
    ed.insertImagePlaceholder(2);
    ed.insertSlice("these");
    try testing.expectEqualStrings("compare [image #1] [image #2] these", ed.text.items);

    const out = try ed.takeExpandedWithImages(2);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("compare these", out);
}

test "image placeholder without a staged attachment remains literal" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("look [image #2]");
    const out = try ed.takeExpandedWithImages(1);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("look [image #2]", out);
}

test "history walk saves and restores draft" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.pushHistory("first");
    ed.pushHistory("second");
    ed.insertSlice("draft in progress");
    ed.histUp();
    try testing.expectEqualStrings("second", ed.text.items);
    ed.histUp();
    try testing.expectEqualStrings("first", ed.text.items);
    ed.histDown();
    try testing.expectEqualStrings("second", ed.text.items);
    ed.histDown();
    try testing.expectEqualStrings("draft in progress", ed.text.items);
}

test "history dedupes to the newest occurrence" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.pushHistory("same");
    ed.pushHistory("different");
    ed.pushHistory("same");
    try testing.expectEqual(@as(usize, 2), ed.history.items.len);
    try testing.expectEqualStrings("different", ed.history.items[0]);
    try testing.expectEqualStrings("same", ed.history.items[1]);
}

test "history evicts old entries and refuses megabyte submissions" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    var buf: [32]u8 = undefined;
    for (0..max_history_entries + 10) |i| {
        const entry = try std.fmt.bufPrint(&buf, "entry-{d}", .{i});
        ed.pushHistory(entry);
    }
    try testing.expectEqual(max_history_entries, ed.history.items.len);
    try testing.expectEqualStrings("entry-10", ed.history.items[0]);

    const huge = try testing.allocator.alloc(u8, max_history_entry_bytes + 1);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');
    ed.pushHistory(huge);
    try testing.expectEqual(max_history_entries, ed.history.items.len);
}

test "vertical movement and edge detection" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("one\ntwo\nthree");
    // cursor at end (row 2)
    try testing.expect(ed.moveUp(40)); // -> row 1
    try testing.expect(ed.moveUp(40)); // -> row 0
    try testing.expect(!ed.moveUp(40)); // at top: history's turn
    try testing.expect(ed.moveDown(40));
    try testing.expect(ed.moveDown(40));
    try testing.expect(!ed.moveDown(40)); // at bottom
}

test "soft wrap heights" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    try testing.expectEqual(@as(usize, 1), ed.displayHeight(10));
    ed.insertSlice("aaaaaaaaaaaaaaaaaaaaaaaaa"); // 25 chars at width 10 = 3 rows
    try testing.expectEqual(@as(usize, 3), ed.displayHeight(10));
}

test "soft wrap moves whole words to the next row" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("hello marlin"); // width 10: "marlin" must not split
    const rows = ed.layoutRows(10);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("hello ", ed.text.items[rows[0].start..rows[0].end]);
    try testing.expectEqualStrings("marlin", ed.text.items[rows[1].start..rows[1].end]);

    // A word longer than the row still hard-splits rather than looping.
    var long = Editor.init(testing.allocator);
    defer long.deinit();
    long.insertSlice("abcdefghijklmnop");
    try testing.expectEqual(@as(usize, 2), long.layoutRows(10).len);
}

test "delete word and line ops" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("git commit -m wip");
    ed.deleteWordBeforeWhitespace();
    try testing.expectEqualStrings("git commit -m ", ed.text.items);
    ed.deleteToLineStart();
    try testing.expectEqualStrings("", ed.text.items);
}

test "word deletion uses readline boundaries" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("hello-world café");

    ed.deleteWordBefore();
    try testing.expectEqualStrings("hello-world ", ed.text.items);
    ed.deleteWordBefore();
    try testing.expectEqualStrings("hello-", ed.text.items);

    ed.moveLineStart();
    ed.deleteWordAfter();
    try testing.expectEqualStrings("-", ed.text.items);
}

test "utf8 cursor movement" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("aé漢");
    ed.moveLeft(); // before 漢
    ed.moveLeft(); // before é
    ed.deleteAfter(); // delete é
    try testing.expectEqualStrings("a漢", ed.text.items);
}

test "wordwise cursor movement crosses punctuation and unicode" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("one, two café");

    ed.moveWordLeft();
    try testing.expectEqual(@as(usize, "one, two ".len), ed.cursor);
    ed.moveWordLeft();
    try testing.expectEqual(@as(usize, "one, ".len), ed.cursor);
    ed.moveWordLeft();
    try testing.expectEqual(@as(usize, 0), ed.cursor);

    ed.moveWordRight();
    try testing.expectEqual(@as(usize, "one".len), ed.cursor);
    ed.moveWordRight();
    try testing.expectEqual(@as(usize, "one, two".len), ed.cursor);
    ed.moveWordRight();
    try testing.expectEqual(@as(usize, "one, two café".len), ed.cursor);
}

test "operator ranges: words, lines, quotes, brackets" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("zig build test");
    ed.cursor = 0;
    var r = ed.wordForwardRange();
    try testing.expectEqualStrings("zig ", ed.text.items[r.start..r.end]);
    ed.cursor = 9; // inside "build"? no: "zig build test": 9 = ' ' after build
    ed.cursor = 5; // inside "build"
    r = ed.innerWordRange(false).?;
    try testing.expectEqualStrings("build", ed.text.items[r.start..r.end]);
    r = ed.innerWordRange(true).?;
    try testing.expectEqualStrings("build ", ed.text.items[r.start..r.end]);
    r = ed.wordBackRange();
    try testing.expectEqualStrings("b", ed.text.items[r.start..r.end]);

    ed.clear();
    ed.insertSlice("say \"hello there\" now");
    ed.cursor = 8; // inside the quotes
    r = ed.quoteRange('"', false).?;
    try testing.expectEqualStrings("hello there", ed.text.items[r.start..r.end]);
    r = ed.quoteRange('"', true).?;
    try testing.expectEqualStrings("\"hello there\"", ed.text.items[r.start..r.end]);

    ed.clear();
    ed.insertSlice("f(a, g(b), c)");
    ed.cursor = 7; // inside g(...)
    r = ed.delimRange('(', ')', false).?;
    try testing.expectEqualStrings("b", ed.text.items[r.start..r.end]);
    ed.cursor = 3; // inside f's parens
    r = ed.delimRange('(', ')', false).?;
    try testing.expectEqualStrings("a, g(b), c", ed.text.items[r.start..r.end]);

    ed.clear();
    ed.insertSlice("one\ntwo\nthree");
    ed.cursor = 5; // on "two"
    r = ed.lineRangeAt(true);
    try testing.expectEqualStrings("two\n", ed.text.items[r.start..r.end]);
    ed.deleteRange(r.start, r.end);
    try testing.expectEqualStrings("one\nthree", ed.text.items);
    try testing.expectEqual(@as(usize, 4), ed.cursor);
}

test "undo groups and redo round trip" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("hello");
    ed.pushUndo();
    ed.insertSlice(" world");
    try testing.expect(ed.undo());
    try testing.expectEqualStrings("hello", ed.text.items);
    try testing.expect(ed.redo());
    try testing.expectEqualStrings("hello world", ed.text.items);
    try testing.expect(ed.redo() == false);
}

test "vim helpers: word start, lines range, find, replace, open" {
    var ed = Editor.init(testing.allocator);
    defer ed.deinit();
    ed.insertSlice("zig build test");
    ed.cursor = 0;
    ed.moveWordStart();
    try testing.expectEqual(@as(usize, 4), ed.cursor); // start of "build"

    try testing.expectEqual(@as(?usize, 10), ed.findOnLine('t', true, 1));
    try testing.expectEqual(@as(?usize, 13), ed.findOnLine('t', true, 2));
    try testing.expectEqual(@as(?usize, null), ed.findOnLine('z', true, 1));

    ed.cursor = 4;
    ed.replaceUnderCursor("B");
    try testing.expectEqualStrings("zig Build test", ed.text.items);
    ed.toggleCaseUnderCursor();
    try testing.expectEqualStrings("zig build test", ed.text.items);

    ed.clear();
    ed.insertSlice("one\ntwo\nthree");
    ed.cursor = 5;
    const two = ed.linesRange(2, true);
    try testing.expectEqualStrings("two\nthree", ed.text.items[two.start..two.end]);
    ed.openLine(true);
    try testing.expectEqualStrings("one\ntwo\n\nthree", ed.text.items);
    try testing.expectEqual(@as(usize, 8), ed.cursor);
}
