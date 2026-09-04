//! Unit tests for pixel_effects.zig. Tests live beside the module they
//! cover (docs/TESTING.md); anything they reach into is `pub` in
//! pixel_effects.zig.

const std = @import("std");
const vaxis = @import("vaxis");

const pixel_effects = @import("pixel_effects.zig");
const pacman = @import("pacman.zig");
const shadowbox = @import("shadowbox.zig");
const Engine = pixel_effects.Engine;
const Scene = pixel_effects.Scene;
const framebufferSize = pixel_effects.framebufferSize;
const renderDemo = pixel_effects.renderDemo;
const renderScene = pixel_effects.renderScene;

test {
    std.testing.refAllDecls(pixel_effects);
}

test "framebuffer follows the window aspect within the encoding budget" {
    const wide = framebufferSize(200, 50, 8, 16, .plasma);
    try std.testing.expectEqual(@as(u16, 400), wide.width);
    try std.testing.expectEqual(@as(u16, 200), wide.height);
    const tiny = framebufferSize(40, 12, 8, 16, .plasma);
    try std.testing.expectEqual(@as(u16, 160), tiny.width);
    try std.testing.expect(tiny.height >= 32);
    const zero = framebufferSize(0, 0, 0, 0, .plasma);
    try std.testing.expect(zero.width >= 1 and zero.height >= 32);
}

test "scenes render deterministically and fill every channel" {
    const gpa = std.testing.allocator;
    const w: u16 = 32;
    const h: u16 = 18;
    const a = try gpa.alloc(u8, @as(usize, w) * h * 3);
    defer gpa.free(a);
    const b = try gpa.alloc(u8, a.len);
    defer gpa.free(b);
    const scratch = try gpa.alloc(u8, a.len);
    defer gpa.free(scratch);
    inline for (std.meta.fields(Scene)) |field| {
        const scene: Scene = @enumFromInt(field.value);
        renderScene(scene, a, w, h, 37);
        renderScene(scene, b, w, h, 37);
        try std.testing.expectEqualSlices(u8, a, b);
    }
    renderDemo(a, scratch, w, h, 30 * 6 - 5); // inside a transition: blends two scenes
    renderDemo(b, scratch, w, h, 30 * 6 - 5);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "engine sizes its buffers and advances frames" {
    var engine = Engine.init(std.testing.allocator, .tunnel, 9);
    defer engine.deinit();
    try engine.reset(120, 40, 9);
    try std.testing.expectEqual(@as(usize, @as(usize, engine.width) * engine.height * 3), engine.rgb.len);
    try std.testing.expectEqual(std.base64.standard.Encoder.calcSize(engine.rgb.len), engine.encoded.len);
    engine.tick();
    try std.testing.expectEqual(@as(u64, 1), engine.frame);
    try engine.resize(120, 40); // same dimensions: buffers retained
    try std.testing.expect(engine.rgb.len > 0);
    try std.testing.expect(!engine.hasImage());
}

test "one image per tick, placed by render, freed on the next tick and on release" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var vx = try vaxis.Vaxis.init(threaded.io(), gpa, &env, .{});
    defer vx.deinit(gpa, &out.writer);
    vx.caps.kitty_graphics = true;
    try vx.resize(gpa, &out.writer, .{ .rows = 24, .cols = 80, .x_pixel = 640, .y_pixel = 384 });

    var engine = Engine.init(gpa, .tunnel, 1);
    defer engine.deinit();
    engine.setCellPixels(8, 16);
    try engine.reset(80, 24, 1);
    out.clearRetainingCapacity();

    try engine.transmit(&vx, &out.writer);
    engine.draw(vx.window(), .full_screen, 255);
    try vx.render(&out.writer);
    const first = out.written();
    try std.testing.expect(std.mem.indexOf(u8, first, "\x1b_Ga=t,f=24,s=240,v=144,i=1,q=2,m=1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\x1b_Ga=p,i=1,r=24,c=80,C=1\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "z=") == null);
    // The transmit precedes the placement.
    try std.testing.expect(std.mem.indexOf(u8, first, "a=t,").? < std.mem.indexOf(u8, first, "a=p,").?);

    // A redraw within the same tick (a key, a daemon event) ships nothing new.
    out.clearRetainingCapacity();
    try engine.transmit(&vx, &out.writer);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);

    // Next tick: transmit and place image 2. Image 1 stays alive until image
    // 2 has been placed, so the screen is never without an image.
    engine.tick();
    try engine.transmit(&vx, &out.writer);
    engine.draw(vx.window(), .full_screen, 255);
    try vx.render(&out.writer);
    const second = out.written();
    try std.testing.expect(std.mem.indexOf(u8, second, "\x1b_Ga=t,f=24,s=240,v=144,i=2,q=2,m=1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\x1b_Ga=p,i=2,r=24,c=80,C=1\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "a=p,i=1,") == null);
    try std.testing.expect(std.mem.indexOf(u8, second, "a=d,d=I") == null);

    // The tick after that frees image 1 before transmitting image 3.
    out.clearRetainingCapacity();
    engine.tick();
    try engine.transmit(&vx, &out.writer);
    const third = out.written();
    const freed = std.mem.indexOf(u8, third, "\x1b_Ga=d,d=I,i=1,q=2;\x1b\\").?;
    const sent = std.mem.indexOf(u8, third, "\x1b_Ga=t,f=24,s=240,v=144,i=3,q=2,m=1;").?;
    try std.testing.expect(freed < sent);

    // Ending the effect frees what is left: images 2 and 3.
    out.clearRetainingCapacity();
    engine.release(&vx, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b_Ga=d,d=I,i=2,q=2;\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b_Ga=d,d=I,i=3,q=2;\x1b\\") != null);
    try std.testing.expect(!engine.hasImage());

    // Without the capability, transmit says so instead of writing garbage.
    vx.caps.kitty_graphics = false;
    try std.testing.expectError(error.NoGraphicsCapability, engine.transmit(&vx, &out.writer));
}

test "pacman shapes its maze to the window, sizes a 16 px framebuffer, and ships zlib frames" {
    const gpa = std.testing.allocator;
    // 80×24 cells at 8×16 px: a 45×27 maze at 16 px per tile.
    const dims = framebufferSize(80, 24, 8, 16, .pacman);
    try std.testing.expectEqual(@as(u16, 720), dims.width);
    try std.testing.expectEqual(@as(u16, 432), dims.height);
    const wide = framebufferSize(300, 20, 8, 16, .pacman); // 2400×320: width-capped, letterboxed
    try std.testing.expectEqual(@as(u16, 1600), wide.width);
    try std.testing.expectEqual(@as(u16, 432), wide.height);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var vx = try vaxis.Vaxis.init(threaded.io(), gpa, &env, .{});
    defer vx.deinit(gpa, &out.writer);
    vx.caps.kitty_graphics = true;
    try vx.resize(gpa, &out.writer, .{ .rows = 24, .cols = 80, .x_pixel = 640, .y_pixel = 384 });

    var engine = Engine.init(gpa, .pacman, 3);
    defer engine.deinit();
    engine.setCellPixels(8, 16);
    try engine.reset(80, 24, 3);
    try std.testing.expectEqual(dims.width, engine.width);
    try std.testing.expectEqual(@as(u16, 45), engine.game.cols);
    try std.testing.expectEqual(@as(u16, 27), engine.game.rows);
    try std.testing.expectEqual(@as(u8, 1), engine.transmit_every);

    out.clearRetainingCapacity();
    try engine.transmit(&vx, &out.writer);
    const bytes = out.written();
    const head = std.mem.indexOf(u8, bytes, "\x1b_Ga=t,f=24,s=720,v=432,i=1,q=2,o=z,m=1;").?;
    // The payload is a zlib stream: its first byte decodes to 0x78.
    const payload = bytes[head + "\x1b_Ga=t,f=24,s=720,v=432,i=1,q=2,o=z,m=1;".len ..];
    var first: [3]u8 = undefined;
    try std.base64.standard.Decoder.decode(&first, payload[0..4]);
    try std.testing.expectEqual(@as(u8, 0x78), first[0]);
    // Flat art compresses hard: well under a tenth of the raw frame.
    try std.testing.expect(bytes.len < engine.rgb.len / 10);
    try std.testing.expectEqual(engine.game.generation, engine.background_generation);

    const dots_before = engine.game.dots_left;
    var i: usize = 0;
    while (i < pacman.step_ticks * 3) : (i += 1) engine.tick();
    try std.testing.expect(engine.game.dots_left < dots_before or engine.game.freeze > 0);
}

test "shadowbox renders near window size and ships compressed frames at half rate" {
    const gpa = std.testing.allocator;
    const dims = framebufferSize(80, 24, 8, 16, .shadowbox);
    try std.testing.expectEqual(@as(u16, 640), dims.width);
    try std.testing.expectEqual(@as(u16, 384), dims.height);
    const tall = framebufferSize(60, 60, 8, 16, .shadowbox); // 480×960: height-capped
    try std.testing.expectEqual(@as(u16, 540), tall.height);

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var vx = try vaxis.Vaxis.init(threaded.io(), gpa, &env, .{});
    defer vx.deinit(gpa, &out.writer);
    vx.caps.kitty_graphics = true;
    try vx.resize(gpa, &out.writer, .{ .rows = 24, .cols = 80, .x_pixel = 640, .y_pixel = 384 });

    var engine = Engine.init(gpa, .shadowbox, 3);
    defer engine.deinit();
    engine.setCellPixels(8, 16);
    engine.setSky(shadowbox.Sky.forHour(19.5));
    try engine.reset(80, 24, 3);
    try std.testing.expectEqual(@as(u8, 2), engine.transmit_every);
    out.clearRetainingCapacity();
    try engine.transmit(&vx, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1b_Ga=t,f=24,s=640,v=384,i=1,q=2,o=z,m=1;") != null);
    try std.testing.expect(out.written().len < engine.rgb.len);
    // Odd ticks reuse the shipped image; even ticks ship again.
    engine.tick();
    out.clearRetainingCapacity();
    try engine.transmit(&vx, &out.writer);
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
    engine.tick();
    try engine.transmit(&vx, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), ",i=2,q=2,o=z,m=1;") != null);
}
