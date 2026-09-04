//! Unit tests for shadowbox.zig. Tests live beside the module they cover
//! (docs/TESTING.md); anything they reach into is `pub` in shadowbox.zig.

const std = @import("std");

const shadowbox = @import("shadowbox.zig");
const Observer = shadowbox.Observer;
const Raster = shadowbox.Raster;
const Sky = shadowbox.Sky;
const areaLatitude = shadowbox.areaLatitude;
const black = shadowbox.black;
const horizon_y = shadowbox.horizon_y;
const lightForSky = shadowbox.lightForSky;
const localClock = shadowbox.localClock;
const observerFromSystem = shadowbox.observerFromSystem;
const parseIso6709 = shadowbox.parseIso6709;
const parseLatLon = shadowbox.parseLatLon;
const parseZoneTable = shadowbox.parseZoneTable;
const render = shadowbox.render;
const scene_w = shadowbox.scene_w;
const skyAt = shadowbox.skyAt;
const skyFor = shadowbox.skyFor;
const sunPosition = shadowbox.sunPosition;

test {
    std.testing.refAllDecls(shadowbox);
}

fn pixel(rgb: []const u8, width: u16, x: usize, y: usize) [3]u8 {
    const i = (y * width + x) * 3;
    return .{ rgb[i], rgb[i + 1], rgb[i + 2] };
}

test "the sky sets the light: noon blue, sunset orange, midnight dark with a moon" {
    const aspect: f32 = 16.0 / 9.0;
    const noon = lightForSky(Sky.forHour(12));
    try std.testing.expect(noon.elevation > 0.99 and noon.day > 0.99 and noon.moon_vis == 0);
    const noon_sky = skyAt(noon, 200, 100, aspect); // away from the sun
    try std.testing.expect(noon_sky[2] > noon_sky[0] + 60); // blue
    try std.testing.expect(noon.sun_y < 150 and noon.sun_x > 700 and noon.sun_x < 1200);
    const sun = skyAt(noon, noon.sun_x, noon.sun_y, aspect);
    try std.testing.expect(sun[0] > 245 and sun[1] > 245 and sun[2] > 245);

    const sunset = lightForSky(Sky.forHour(18));
    try std.testing.expect(@abs(sunset.elevation) < 0.01);
    try std.testing.expect(sunset.sun_x > scene_w * 0.8); // setting on the right
    try std.testing.expect(sunset.sun_y > 500 and sunset.sun_y <= horizon_y); // on the waterline
    const far_horizon = skyAt(sunset, scene_w * 0.1, 590, aspect); // away from the sun
    try std.testing.expect(far_horizon[0] > far_horizon[1] and far_horizon[1] > far_horizon[2]); // orange

    const midnight = lightForSky(Sky.forHour(0));
    try std.testing.expect(midnight.elevation < -0.99 and midnight.night > 0.99 and midnight.sun_vis == 0);
    try std.testing.expect(midnight.moon_y < 150 and midnight.moon_vis > 0.99);
    const dark = skyAt(midnight, scene_w * 0.9, 300, aspect);
    try std.testing.expect(dark[0] < 60 and dark[1] < 60 and dark[2] < 80);
    const moon = skyAt(midnight, midnight.moon_x, midnight.moon_y, aspect);
    try std.testing.expect(moon[0] > 240 and moon[1] > 240 and moon[2] > 240);
    // Water reflects the sky, dimmed.
    const above = skyAt(noon, 400, 500, aspect);
    const below = skyAt(noon, 400, 700, aspect);
    try std.testing.expect(below[0] < above[0] and below[1] < above[1]);
}

test "the simple day is continuous: no seam in the sky between neighboring minutes" {
    const aspect: f32 = 16.0 / 9.0;
    var hour: f32 = 0;
    var prev = skyAt(lightForSky(Sky.forHour(0)), scene_w * 0.5, 200, aspect);
    while (hour < 24.0) : (hour += 1.0 / 60.0) {
        const cur = skyAt(lightForSky(Sky.forHour(hour)), scene_w * 0.5, 200, aspect);
        inline for (0..3) |k| try std.testing.expect(@abs(cur[k] - prev[k]) < 6.0);
        prev = cur;
    }
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn utc(y: i64, m: i64, d: i64, hh: i64, mm: i64) f64 {
    return @floatFromInt(daysFromCivil(y, m, d) * 86_400 + hh * 3600 + mm * 60);
}

test "the sun is where the almanac puts it" {
    // Copenhagen, midsummer 2026: solar noon ≈ 11:07 UTC, altitude ≈ 57.7°.
    const cph_lat = 55.68;
    const cph_lon = 12.57;
    const noon = sunPosition(utc(2026, 6, 21, 11, 7), cph_lat, cph_lon);
    try std.testing.expect(noon.altitude > 56.5 and noon.altitude < 58.9);
    try std.testing.expect(@abs(noon.azimuth - 180.0) < 4.0);
    // Sunrise ≈ 04:25 local (02:25 UTC): below at 02:00, above at 03:00.
    try std.testing.expect(sunPosition(utc(2026, 6, 21, 2, 0), cph_lat, cph_lon).altitude < 0);
    try std.testing.expect(sunPosition(utc(2026, 6, 21, 3, 0), cph_lat, cph_lon).altitude > 0);
    // Morning sun in the east, afternoon in the west.
    try std.testing.expect(sunPosition(utc(2026, 6, 21, 7, 0), cph_lat, cph_lon).azimuth < 170);
    try std.testing.expect(sunPosition(utc(2026, 6, 21, 15, 0), cph_lat, cph_lon).azimuth > 190);
    // Midwinter: sunrise ≈ 08:37 local (07:37 UTC), noon altitude ≈ 10.9°.
    try std.testing.expect(sunPosition(utc(2026, 12, 21, 7, 0), cph_lat, cph_lon).altitude < 0);
    try std.testing.expect(sunPosition(utc(2026, 12, 21, 8, 0), cph_lat, cph_lon).altitude > 0);
    const winter_noon = sunPosition(utc(2026, 12, 21, 11, 7), cph_lat, cph_lon);
    try std.testing.expect(winter_noon.altitude > 9.5 and winter_noon.altitude < 12.5);
    // Equator, Greenwich, near the equinox at 12:00 UTC: nearly overhead; midnight: nearly underfoot.
    try std.testing.expect(sunPosition(utc(2026, 3, 20, 12, 0), 0, 0).altitude > 85);
    try std.testing.expect(sunPosition(utc(2026, 3, 20, 0, 0), 0, 0).altitude < -85);
    // Sydney at local noon in June: low in the NORTH.
    const syd = sunPosition(utc(2026, 6, 21, 2, 0), -33.87, 151.21);
    try std.testing.expect(syd.altitude > 31 and syd.altitude < 34.5);
    try std.testing.expect(syd.azimuth < 20 or syd.azimuth > 340);
}

test "the sky follows the sun across the frame without jumps, east on the left up north" {
    var observer: Observer = .{ .lat = 55.68, .lon = 12.57, .source = .override };
    const start = utc(2026, 6, 21, 0, 0);
    var prev = skyFor(start, observer);
    var minute: f64 = 1;
    var saw_night = false;
    var saw_day = false;
    while (minute < 1440) : (minute += 1) {
        const cur = skyFor(start + minute * 60.0, observer);
        // The mapping wraps behind the viewer (due north at midnight); the
        // glow is faded out there, so only a visible sun must not jump.
        if (cur.sun_front > 0.05 and prev.sun_front > 0.05) try std.testing.expect(@abs(cur.sun_x - prev.sun_x) < 0.01);
        try std.testing.expect(@abs(cur.sun_elevation - prev.sun_elevation) < 0.01);
        if (cur.sun_elevation < 0) saw_night = true;
        if (cur.sun_elevation > 0.8) saw_day = true;
        prev = cur;
    }
    try std.testing.expect(saw_night and saw_day);
    // 07:00 UTC (09:00 local): morning sun left of center; 15:00 UTC: right of center.
    try std.testing.expect(skyFor(utc(2026, 6, 21, 7, 0), observer).sun_x < 0.45);
    try std.testing.expect(skyFor(utc(2026, 6, 21, 15, 0), observer).sun_x > 0.55);
    // A Scandinavian midsummer night never gets fully dark, and the sun,
    // due north behind the viewer around solar midnight (≈ 23:07 UTC), is
    // faded out rather than shown wrapping.
    const small_hours = skyFor(utc(2026, 6, 20, 23, 0), observer);
    try std.testing.expect(small_hours.sun_elevation > -0.3);
    try std.testing.expect(small_hours.sun_front < 0.05);
    try std.testing.expect(skyFor(utc(2026, 6, 21, 0, 30), observer).sun_elevation > -0.3);
    try std.testing.expect(skyFor(utc(2026, 6, 21, 11, 0), observer).sun_front > 0.99);
    // Down south the morning sun is on the right.
    observer = .{ .lat = -33.87, .lon = 151.21, .source = .override };
    try std.testing.expect(skyFor(utc(2026, 6, 21, 22, 0), observer).sun_x > 0.55); // 08:00 AEST
    try std.testing.expect(skyFor(utc(2026, 6, 21, 6, 0), observer).sun_x < 0.45); // 16:00 AEST
}

test "zone tables and ISO 6709 coordinates parse" {
    try std.testing.expectEqual(@as(f64, 40.4), parseIso6709("+4024-00341").?[0]);
    try std.testing.expect(@abs(parseIso6709("+4024-00341").?[1] - (-3.6833)) < 0.001);
    const ny = parseIso6709("+404251-0740023").?;
    try std.testing.expect(@abs(ny[0] - 40.7142) < 0.001 and @abs(ny[1] - (-74.0064)) < 0.001);
    const syd = parseIso6709("-3352+15113").?;
    try std.testing.expect(@abs(syd[0] - (-33.8667)) < 0.001 and @abs(syd[1] - 151.2167) < 0.001);
    try std.testing.expect(parseIso6709("garbage") == null);
    const table =
        "# comment line\n" ++
        "AU\t-3352+15113\tAustralia/Sydney\tNew South Wales (most areas)\n" ++
        "DK\t+5540+01235\tEurope/Copenhagen\n" ++
        "ES\t+4024-00341\tEurope/Madrid\tSpain (mainland)\n";
    const cph = parseZoneTable(table, "Europe/Copenhagen").?;
    try std.testing.expect(@abs(cph[0] - 55.6667) < 0.001 and @abs(cph[1] - 12.5833) < 0.001);
    try std.testing.expect(parseZoneTable(table, "Europe/Oslo") == null);
    try std.testing.expectEqual(@as(?f64, -30), areaLatitude("Australia/Perth"));
    try std.testing.expectEqual(@as(?f64, null), areaLatitude("UTC"));
    try std.testing.expectEqual([2]f64{ 55.7, 12.6 }, parseLatLon("55.7, 12.6").?);
    try std.testing.expect(parseLatLon("95,0") == null);
}

test "the machine has a place and a clock" {
    const gpa = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const observer = observerFromSystem(gpa, io, null);
    try std.testing.expect(observer.lat >= -90 and observer.lat <= 90 and observer.lon >= -180 and observer.lon <= 180);
    const clock = localClock(io);
    try std.testing.expect(clock.hour >= 0 and clock.hour < 24);
    try std.testing.expect(clock.seconds_of_day >= 0 and clock.seconds_of_day < 86_400);
    // Whatever the place, the sky for now is a valid state.
    const state = skyFor(@floatFromInt(clock.unix), observer);
    try std.testing.expect(state.sun_x >= 0 and state.sun_x <= 1 and state.sun_elevation >= -1 and state.sun_elevation <= 1);
}

test "a frame is deterministic per seed and sky, and layers land where they should" {
    const gpa = std.testing.allocator;
    const w: u16 = 380;
    const h: u16 = 180;
    const rgb = try gpa.alloc(u8, @as(usize, w) * h * 3);
    defer gpa.free(rgb);
    render(rgb, w, h, 0, 7, Sky.forHour(12));
    // The near trunk (tree at scene x 1801, width 66) at the bottom edge is a dark gray.
    const trunk = pixel(rgb, w, @intFromFloat(1801.0 / scene_w * @as(f32, w)), h - 2);
    try std.testing.expect(trunk[0] <= 0x30 and trunk[0] == trunk[1] and trunk[1] == trunk[2]);
    const again = try gpa.dupe(u8, rgb);
    defer gpa.free(again);
    render(rgb, w, h, 0, 7, Sky.forHour(12));
    try std.testing.expectEqualSlices(u8, again, rgb);
    render(rgb, w, h, 0, 8, Sky.forHour(12)); // another seed: other hills, stars, clouds
    try std.testing.expect(!std.mem.eql(u8, again, rgb));
    render(rgb, w, h, 0, 7, Sky.forHour(2)); // another sky
    try std.testing.expect(!std.mem.eql(u8, again, rgb));
    render(rgb, w, h, 90, 7, Sky.forHour(12)); // the clock moves the clouds
    try std.testing.expect(!std.mem.eql(u8, again, rgb));
    // At 02:00 the trees darken below the noon grays.
    render(rgb, w, h, 0, 7, Sky.forHour(2));
    const night_trunk = pixel(rgb, w, @intFromFloat(1801.0 / scene_w * @as(f32, w)), h - 2);
    try std.testing.expect(night_trunk[0] < trunk[0]);
}

test "raster primitives: sub-pixel rects are faint, soft ellipses fade to their rim" {
    const gpa = std.testing.allocator;
    const w: u16 = 40;
    const h: u16 = 20;
    const rgb = try gpa.alloc(u8, @as(usize, w) * h * 3);
    defer gpa.free(rgb);
    @memset(rgb, 255);
    var r = Raster{ .rgb = rgb, .width = w, .height = h, .sx = 1, .sy = 1 };
    // A quarter-pixel-wide black bar leaves the pixel three-quarters white.
    r.fillRect(2, 2, 0.25, 1, black, 1);
    try std.testing.expectEqual(@as(u8, 191), pixel(rgb, w, 2, 2)[0]);
    // A soft ellipse is solid at its center and untouched beyond its rim.
    r.softEllipse(30, 10, 6, 4, black, 1);
    try std.testing.expect(pixel(rgb, w, 30, 10)[0] < 20);
    try std.testing.expectEqual(@as(u8, 255), pixel(rgb, w, 30, 2)[0]);
    try std.testing.expect(pixel(rgb, w, 33, 10)[0] > pixel(rgb, w, 30, 10)[0]);
}
