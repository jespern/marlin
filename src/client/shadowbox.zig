//! "ShadowBoX" — after Jani Ylikangas' 1029-byte js1k 2019 entry
//! (https://js1k.com/2019-x/demo/4146), a paper-cutout landscape in layers,
//! reworked to follow the real sun over the user's machine. The original had
//! two static moods (a sunset that snaps to a snowy night) plus a bat and a
//! lightning bolt; this one derives everything from the sun's true altitude
//! and azimuth for the current instant, so the sky, the light on the water,
//! the mist, the stars and the clouds move through a whole day without a
//! seam — and days are long in summer, short in winter, endless past the
//! polar circles.
//!
//! Where the machine is comes from its time zone: the zone name from `TZ`,
//! the `/etc/localtime` link, or `/etc/timezone`; its coordinates from the
//! zone database's own `zone1970.tab`/`zone.tab`. Failing that, the zone's
//! area (Europe/…, Australia/…) gives a latitude and the UTC offset a
//! longitude. `MARLIN_SHADOWBOX_LATLON=lat,lon` overrides all of it. The sun
//! is placed with the NOAA solar position algorithm (declination, equation
//! of time, hour angle → altitude and azimuth); the moon is the anti-sun.
//!
//! Kept from the original: the 1900×900 composition scaled per axis, the
//! faint mountain ranges from a random walk mirrored in the water, five
//! recursive curve trees in graded grays that sway in the night wind, the
//! reed clusters and the black ground band, the sun's shimmer on the water,
//! and the mist trick (two translucent dots scaled up 300× and blurred by
//! the browser's bilinear filter, sampled here the same way).
//!
//! Everything is rasterized with area-coverage anti-aliasing: the original's
//! faint ranges come from sub-pixel fillRect widths, which coverage
//! reproduces.

const std = @import("std");
const effect = @import("effect.zig");

pub const scene_w: f32 = 1900;
pub const scene_h: f32 = 900;
/// The waterline: ranges mirror around it, the sky reflects below it.
pub const horizon_y: f32 = 600;

/// The original's clock: C starts at 50 and grows 2 per 50 ms frame. Our
/// tick is 33 ms. It drives motion only (sway, twinkle, drift).
pub fn sceneClock(frame: u64) f32 {
    return 50.0 + @as(f32, @floatFromInt(frame)) * (2.0 * 20.0 / 30.0);
}

pub const black = [3]u8{ 0, 0, 0 };
const white = [3]u8{ 0xff, 0xff, 0xff };
/// '#fff5': white at 0x55/0xff.
const haze_alpha: f32 = 0x55.0 / 255.0;

// ------------------------------------------------------------- daylight --

/// Where the two lights stand, as the renderer wants them: elevation as the
/// sine of altitude (-1 midnight .. 1 zenith, nudged by refraction so
/// sunset shows as the disc touches the water) and screen x as 0..1.
pub const Sky = struct {
    sun_elevation: f32,
    sun_x: f32,
    moon_elevation: f32,
    moon_x: f32,
    /// 1 when the light is in front of the viewer, fading to 0 behind: a
    /// glow behind you is not on your screen, and it hides the point where
    /// the left-to-right mapping of a full circle has to wrap (due north at
    /// local midnight up north).
    sun_front: f32 = 1,
    moon_front: f32 = 1,

    pub const noon: Sky = .{ .sun_elevation = 1, .sun_x = 0.5, .moon_elevation = -1, .moon_x = 0.5 };

    /// The simple model — sunrise 06:00, sunset 18:00, sun left to right —
    /// for tests and previews without a place.
    pub fn forHour(hour_in: f32) Sky {
        const hour = @mod(hour_in, 24.0);
        const e = @sin((hour - 6.0) / 24.0 * 2.0 * std.math.pi);
        const sun_progress = std.math.clamp((hour - 5.5) / 13.0, 0.0, 1.0);
        const moon_progress = std.math.clamp(@mod(hour - 17.5 + 24.0, 24.0) / 13.0, 0.0, 1.0);
        return .{
            .sun_elevation = e,
            .sun_x = 0.12 + 0.76 * sun_progress,
            .moon_elevation = -e,
            .moon_x = 0.12 + 0.76 * moon_progress,
        };
    }
};

/// Everything the sky decides for the renderer.
pub const Light = struct {
    /// Sun elevation, -1 (midnight) .. 1 (zenith).
    elevation: f32,
    /// 0 at night .. 1 in full day, and its complement.
    day: f32,
    night: f32,
    /// Scene positions and visibilities of the two lights.
    sun_x: f32,
    sun_y: f32,
    sun_vis: f32,
    moon_x: f32,
    moon_y: f32,
    moon_vis: f32,
    zenith: [3]f32,
    horizon: [3]f32,
    sun_glow: [3]f32,
};

const SkyKey = struct { e: f32, zenith: [3]f32, horizon: [3]f32 };
/// Sky palette by elevation: deep night, late dusk, twilight (the
/// original's #957), sunset (its #c94), golden hour, day, noon.
const sky_keys = [_]SkyKey{
    .{ .e = -1.00, .zenith = .{ 4, 6, 20 }, .horizon = .{ 34, 34, 51 } },
    .{ .e = -0.40, .zenith = .{ 12, 12, 40 }, .horizon = .{ 55, 45, 80 } },
    .{ .e = -0.15, .zenith = .{ 36, 28, 78 }, .horizon = .{ 153, 85, 119 } },
    .{ .e = 0.00, .zenith = .{ 88, 62, 122 }, .horizon = .{ 204, 153, 68 } },
    .{ .e = 0.18, .zenith = .{ 96, 140, 205 }, .horizon = .{ 236, 196, 150 } },
    .{ .e = 0.45, .zenith = .{ 62, 128, 220 }, .horizon = .{ 190, 214, 238 } },
    .{ .e = 1.00, .zenith = .{ 52, 132, 236 }, .horizon = .{ 198, 224, 246 } },
};

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn lerp3(a: [3]f32, b: [3]f32, t: f32) [3]f32 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
}

/// Height in the frame for an elevation: an ease-out, quick off the horizon
/// and slow near the zenith, with a finite slope at the horizon so the rise
/// never looks like a jump; below the horizon the light keeps sinking.
fn lightHeight(e: f32) f32 {
    const ce = std.math.clamp(e, 0.0, 1.0);
    const up = 1.0 - (1.0 - ce) * (1.0 - ce);
    return horizon_y - 40.0 - 480.0 * up + 250.0 * @max(0.0, -e);
}

pub fn lightForSky(state: Sky) Light {
    const e = std.math.clamp(state.sun_elevation, -1.0, 1.0);
    const day = smoothstep(-0.15, 0.25, e);

    var zenith = sky_keys[sky_keys.len - 1].zenith;
    var horizon = sky_keys[sky_keys.len - 1].horizon;
    var k: usize = 0;
    while (k + 1 < sky_keys.len) : (k += 1) {
        const a = sky_keys[k];
        const b = sky_keys[k + 1];
        if (e <= b.e) {
            const t = std.math.clamp((e - a.e) / (b.e - a.e), 0.0, 1.0);
            zenith = lerp3(a.zenith, b.zenith, t);
            horizon = lerp3(a.horizon, b.horizon, t);
            break;
        }
    }

    return .{
        .elevation = e,
        .day = day,
        .night = 1.0 - day,
        .sun_x = scene_w * state.sun_x,
        .sun_y = lightHeight(e),
        .sun_vis = smoothstep(-0.14, 0.04, e) * state.sun_front,
        .moon_x = scene_w * state.moon_x,
        .moon_y = lightHeight(std.math.clamp(state.moon_elevation, -1.0, 1.0)),
        .moon_vis = smoothstep(0.12, -0.12, e) * smoothstep(-0.14, 0.04, state.moon_elevation) * state.moon_front,
        .zenith = zenith,
        .horizon = horizon,
        .sun_glow = lerp3(.{ 255, 196, 110 }, .{ 255, 250, 232 }, std.math.clamp(e, 0.0, 1.0)),
    };
}

/// Sky color at a scene point: a zenith→horizon gradient with the sun's and
/// the moon's glows, mirrored and dimmed below the waterline as water.
pub fn skyAt(light: Light, x: f32, y_in: f32, aspect: f32) [3]f32 {
    const below = y_in > horizon_y;
    const y = if (below) 2.0 * horizon_y - y_in else y_in;
    const t = std.math.clamp(y / horizon_y, 0.0, 1.0);
    var col = lerp3(light.zenith, light.horizon, t * t);
    col = glow(col, light.sun_glow, x, y, light.sun_x, light.sun_y, light.sun_vis, 0.9, 0.62, aspect);
    col = glow(col, .{ 214, 222, 248 }, x, y, light.moon_x, light.moon_y, light.moon_vis, 0.7, 0.42, aspect);
    if (below) {
        const dim: f32 = 0.80;
        col = .{ col[0] * dim, col[1] * dim, col[2] * dim + 4 };
    }
    return col;
}

/// A radial halo of `strength` around a white disc, radius as a fraction of
/// the diagonal; both scale with the light's visibility.
fn glow(col: [3]f32, color: [3]f32, x: f32, y: f32, lx: f32, ly: f32, vis: f32, strength: f32, radius: f32, aspect: f32) [3]f32 {
    if (vis <= 0) return col;
    // Normalize with the window's aspect so the glow is round on screen.
    const nx = (x - lx) / scene_w * aspect;
    const ny = (y - ly) / scene_h;
    const d = @sqrt(nx * nx + ny * ny) / @sqrt(aspect * aspect + 1.0);
    const g = std.math.clamp(1.0 - d / radius, 0.0, 1.0);
    const core = std.math.clamp(1.0 - d / 0.045, 0.0, 1.0);
    var out = lerp3(col, color, vis * g * g * strength);
    out = lerp3(out, .{ 255, 255, 255 }, vis * core * core);
    return out;
}

// -------------------------------------------------------------- the sun --

pub const SunPosition = struct {
    /// Degrees above the horizon (negative below).
    altitude: f64,
    /// Degrees clockwise from north.
    azimuth: f64,
};

fn rad(deg_v: f64) f64 {
    return deg_v * std.math.pi / 180.0;
}

fn deg(rad_v: f64) f64 {
    return rad_v * 180.0 / std.math.pi;
}

fn wrap360(v: f64) f64 {
    return @mod(v, 360.0);
}

/// NOAA's solar position algorithm (Meeus, low-precision series): good to a
/// small fraction of a degree, which is far more than a landscape needs.
pub fn sunPosition(unix_seconds: f64, lat_deg: f64, lon_deg: f64) SunPosition {
    const jd = unix_seconds / 86400.0 + 2440587.5;
    const t = (jd - 2451545.0) / 36525.0; // Julian centuries from J2000
    const l0 = wrap360(280.46646 + t * (36000.76983 + t * 0.0003032)); // mean longitude
    const m = wrap360(357.52911 + t * (35999.05029 - 0.0001537 * t)); // mean anomaly
    const ecc = 0.016708634 - t * (0.000042037 + 0.0000001267 * t);
    const mr = rad(m);
    const center = @sin(mr) * (1.914602 - t * (0.004817 + 0.000014 * t)) +
        @sin(2.0 * mr) * (0.019993 - 0.000101 * t) +
        @sin(3.0 * mr) * 0.000289;
    const true_long = l0 + center;
    const omega = 125.04 - 1934.136 * t;
    const apparent_long = true_long - 0.00569 - 0.00478 * @sin(rad(omega));
    const eps0 = 23.0 + (26.0 + (21.448 - t * (46.815 + t * (0.00059 - t * 0.001813))) / 60.0) / 60.0;
    const eps = rad(eps0 + 0.00256 * @cos(rad(omega)));
    const decl = std.math.asin(@sin(eps) * @sin(rad(apparent_long)));
    const y = @tan(eps / 2.0) * @tan(eps / 2.0);
    const l0r = rad(l0);
    const eq_time = 4.0 * deg(y * @sin(2.0 * l0r) - 2.0 * ecc * @sin(mr) + 4.0 * ecc * y * @sin(mr) * @cos(2.0 * l0r) -
        0.5 * y * y * @sin(4.0 * l0r) - 1.25 * ecc * ecc * @sin(2.0 * mr)); // minutes
    const minutes_utc = @mod(unix_seconds, 86400.0) / 60.0;
    const true_solar = @mod(minutes_utc + eq_time + 4.0 * lon_deg, 1440.0);
    const hour_angle = rad(true_solar / 4.0 - 180.0);
    const lat = rad(lat_deg);
    const sin_alt = std.math.clamp(@sin(lat) * @sin(decl) + @cos(lat) * @cos(decl) * @cos(hour_angle), -1.0, 1.0);
    const from_south = std.math.atan2(@sin(hour_angle), @cos(hour_angle) * @sin(lat) - @tan(decl) * @cos(lat));
    return .{
        .altitude = deg(std.math.asin(sin_alt)),
        .azimuth = wrap360(deg(from_south) + 180.0),
    };
}

pub const Placement = struct { x: f32, front: f32 };

/// Screen x for an azimuth: the viewer faces the equator (south in the
/// north, north in the south), and the angle off that heading maps to x
/// through a tanh so the whole path stays in frame — sunrise on the left in
/// the northern hemisphere, on the right in the southern. `front` fades a
/// light out as it swings behind the viewer (more than 120° off heading).
pub fn placeOnScreen(azimuth_deg: f64, lat_deg: f64) Placement {
    const facing: f64 = if (lat_deg >= 0) 180.0 else 0.0;
    var rel = azimuth_deg - facing;
    if (rel > 180.0) rel -= 360.0;
    if (rel <= -180.0) rel += 360.0;
    return .{
        .x = @floatCast(0.5 + 0.47 * std.math.tanh(rel / 100.0)),
        .front = smoothstep(180.0, 120.0, @floatCast(@abs(rel))),
    };
}

/// The sky over an observer at a UTC instant. The moon is the anti-sun.
pub fn skyFor(unix_seconds: f64, observer: Observer) Sky {
    const sun = sunPosition(unix_seconds, observer.lat, observer.lon);
    const refraction = 0.833;
    const sun_place = placeOnScreen(sun.azimuth, observer.lat);
    const moon_place = placeOnScreen(wrap360(sun.azimuth + 180.0), observer.lat);
    return .{
        .sun_elevation = @floatCast(@sin(rad(sun.altitude + refraction))),
        .sun_x = sun_place.x,
        .sun_front = sun_place.front,
        .moon_elevation = @floatCast(@sin(rad(-sun.altitude + refraction))),
        .moon_x = moon_place.x,
        .moon_front = moon_place.front,
    };
}

// --------------------------------------------------------- the observer --

pub const Observer = struct {
    lat: f64,
    lon: f64,
    source: Source,
    zone_len: u8 = 0,
    zone_buf: [96]u8 = undefined,

    pub const Source = enum { override, zone_table, zone_area, utc_offset };

    pub fn zone(self: *const Observer) []const u8 {
        return self.zone_buf[0..self.zone_len];
    }

    fn setZone(self: *Observer, name: []const u8) void {
        const n = @min(name.len, self.zone_buf.len);
        @memcpy(self.zone_buf[0..n], name[0..n]);
        self.zone_len = @intCast(n);
    }
};

/// Locate the machine from its time zone; see the module doc for the chain.
pub fn observerFromSystem(gpa: std.mem.Allocator, io: std.Io, environ: ?*const std.process.Environ.Map) Observer {
    const clock = localClock(io);
    var observer: Observer = .{
        .lat = 40,
        .lon = @as(f64, @floatFromInt(clock.gmtoff_std)) / 3600.0 * 15.0,
        .source = .utc_offset,
    };
    if (environ) |env| {
        if (env.get("MARLIN_SHADOWBOX_LATLON")) |value| {
            if (parseLatLon(value)) |ll| {
                observer.lat = ll[0];
                observer.lon = ll[1];
                observer.source = .override;
                return observer;
            }
        }
    }
    var name_buf: [128]u8 = undefined;
    var dir_buf: [256]u8 = undefined;
    const zone = zoneFromSystem(io, environ, &name_buf, &dir_buf) orelse return observer;
    observer.setZone(zone.name);
    if (zoneCoordinates(gpa, io, zone.dir, zone.name)) |coords| {
        observer.lat = coords[0];
        observer.lon = coords[1];
        observer.source = .zone_table;
    } else if (areaLatitude(zone.name)) |lat| {
        observer.lat = lat;
        observer.source = .zone_area;
    }
    return observer;
}

pub fn parseLatLon(value: []const u8) ?[2]f64 {
    const comma = std.mem.indexOfScalar(u8, value, ',') orelse return null;
    const lat = std.fmt.parseFloat(f64, std.mem.trim(u8, value[0..comma], " ")) catch return null;
    const lon = std.fmt.parseFloat(f64, std.mem.trim(u8, value[comma + 1 ..], " ")) catch return null;
    if (lat < -90 or lat > 90 or lon < -180 or lon > 180) return null;
    return .{ lat, lon };
}

const Zone = struct { name: []const u8, dir: ?[]const u8 };

/// The IANA zone name: `TZ` when it names a zone, else the `/etc/localtime`
/// link target (whose directory also tells us where the tables are), else
/// `/etc/timezone`.
fn zoneFromSystem(io: std.Io, environ: ?*const std.process.Environ.Map, name_buf: *[128]u8, dir_buf: *[256]u8) ?Zone {
    if (environ) |env| {
        if (env.get("TZ")) |raw| {
            const tz = if (raw.len > 0 and raw[0] == ':') raw[1..] else raw;
            if (tz.len > 0 and tz.len <= name_buf.len and std.mem.indexOfScalar(u8, tz, '/') != null and std.mem.indexOfScalar(u8, tz, ',') == null) {
                @memcpy(name_buf[0..tz.len], tz);
                return .{ .name = name_buf[0..tz.len], .dir = null };
            }
        }
    }
    if (std.Io.Dir.readLinkAbsolute(io, "/etc/localtime", dir_buf)) |len| {
        const target = dir_buf[0..len];
        if (std.mem.indexOf(u8, target, "zoneinfo/")) |i| {
            const name = target[i + "zoneinfo/".len ..];
            if (name.len > 0 and name.len <= name_buf.len) {
                @memcpy(name_buf[0..name.len], name);
                return .{ .name = name_buf[0..name.len], .dir = target[0 .. i + "zoneinfo/".len] };
            }
        }
    } else |_| {}
    if (std.Io.Dir.cwd().readFile(io, "/etc/timezone", name_buf)) |text| {
        const name = std.mem.trim(u8, text, " \r\n\t");
        if (name.len > 0) return .{ .name = name, .dir = null };
    } else |_| {}
    return null;
}

/// Coordinates for a zone from `zone1970.tab`/`zone.tab`, looked for next to
/// the zone files and in the usual places.
fn zoneCoordinates(gpa: std.mem.Allocator, io: std.Io, dir: ?[]const u8, name: []const u8) ?[2]f64 {
    const dirs = [_]?[]const u8{ dir, "/usr/share/zoneinfo/", "/var/db/timezone/zoneinfo/", "/usr/share/lib/zoneinfo/" };
    const files = [_][]const u8{ "zone1970.tab", "zone.tab" };
    var path_buf: [320]u8 = undefined;
    for (dirs) |maybe_dir| {
        const d = maybe_dir orelse continue;
        for (files) |file| {
            const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ d, file }) catch continue;
            const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(512 * 1024)) catch continue;
            defer gpa.free(text);
            if (parseZoneTable(text, name)) |coords| return coords;
        }
    }
    return null;
}

/// `CC<TAB>+DDMM+DDDMM<TAB>Area/City<TAB>comment` lines; '#' comments.
pub fn parseZoneTable(text: []const u8, name: []const u8) ?[2]f64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        _ = fields.next() orelse continue; // country codes
        const coords = fields.next() orelse continue;
        const zone = fields.next() orelse continue;
        if (std.mem.eql(u8, std.mem.trimEnd(u8, zone, "\r"), name)) return parseIso6709(coords);
    }
    return null;
}

/// ISO 6709 `±DDMM±DDDMM` or `±DDMMSS±DDDMMSS` → degrees.
pub fn parseIso6709(s: []const u8) ?[2]f64 {
    if (s.len < 2) return null;
    var split: usize = 1;
    while (split < s.len and s[split] != '+' and s[split] != '-') : (split += 1) {}
    if (split >= s.len) return null;
    const lat = parseSexagesimal(s[0..split], 2) orelse return null;
    const lon = parseSexagesimal(s[split..], 3) orelse return null;
    return .{ lat, lon };
}

fn parseSexagesimal(s: []const u8, degree_digits: usize) ?f64 {
    if (s.len < 1 + degree_digits) return null;
    const sign: f64 = if (s[0] == '-') -1 else 1;
    const digits = s[1..];
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return null;
    const d = std.fmt.parseFloat(f64, digits[0..degree_digits]) catch return null;
    var value = d;
    if (digits.len >= degree_digits + 2) {
        value += (std.fmt.parseFloat(f64, digits[degree_digits .. degree_digits + 2]) catch return null) / 60.0;
    }
    if (digits.len >= degree_digits + 4) {
        value += (std.fmt.parseFloat(f64, digits[degree_digits + 2 .. degree_digits + 4]) catch return null) / 3600.0;
    }
    return sign * value;
}

/// A latitude for a zone's area when the tables are missing: coarse, but
/// it gets the hemisphere and the length of the days about right.
pub fn areaLatitude(name: []const u8) ?f64 {
    const areas = [_]struct { prefix: []const u8, lat: f64 }{
        .{ .prefix = "Europe/", .lat = 50 },
        .{ .prefix = "Asia/", .lat = 30 },
        .{ .prefix = "Africa/", .lat = 5 },
        .{ .prefix = "America/", .lat = 35 },
        .{ .prefix = "Australia/", .lat = -30 },
        .{ .prefix = "Pacific/", .lat = -10 },
        .{ .prefix = "Indian/", .lat = -10 },
        .{ .prefix = "Atlantic/", .lat = 30 },
        .{ .prefix = "Arctic/", .lat = 75 },
        .{ .prefix = "Antarctica/", .lat = -75 },
    };
    for (areas) |area| if (std.mem.startsWith(u8, name, area.prefix)) return area.lat;
    return null;
}

// -------------------------------------------------------------- render --

pub fn render(rgb: []u8, width: u16, height: u16, frame: u64, seed: u64, sky_state: Sky) void {
    if (width == 0 or height == 0) return;
    var r = Raster{
        .rgb = rgb,
        .width = width,
        .height = height,
        .sx = @as(f32, @floatFromInt(width)) / scene_w,
        .sy = @as(f32, @floatFromInt(height)) / scene_h,
    };
    const c = sceneClock(frame);
    const light = lightForSky(sky_state);

    sky(&r, light);
    stars(&r, light, c, seed);
    clouds(&r, light, c, seed);
    ranges(&r, light, seed);
    reeds(&r, seed);
    trees(&r, light, c);
    shimmer(&r, light, c, seed);
    mist(&r, light, c);
}

fn sky(r: *Raster, light: Light) void {
    const aspect = @as(f32, @floatFromInt(r.width)) / @as(f32, @floatFromInt(r.height));
    var i: usize = 0;
    var y: u32 = 0;
    while (y < r.height) : (y += 1) {
        const sy = (@as(f32, @floatFromInt(y)) + 0.5) / r.sy;
        var x: u32 = 0;
        while (x < r.width) : (x += 1) {
            const sx = (@as(f32, @floatFromInt(x)) + 0.5) / r.sx;
            const col = skyAt(light, sx, sy, aspect);
            r.rgb[i] = @intFromFloat(@round(std.math.clamp(col[0], 0, 255)));
            r.rgb[i + 1] = @intFromFloat(@round(std.math.clamp(col[1], 0, 255)));
            r.rgb[i + 2] = @intFromFloat(@round(std.math.clamp(col[2], 0, 255)));
            i += 3;
        }
    }
}

/// A -1..1 value fixed per (seed, n): the original used sin(i⁹).
fn noise(seed: u64, n: u64) f32 {
    const bits = effect.hash(seed ^ (n *% 0x9e3779b97f4a7c15));
    return @as(f32, @floatFromInt(bits >> 40)) / @as(f32, @floatFromInt(@as(u64, 1) << 23)) - 1.0;
}

fn unit(seed: u64, n: u64) f32 {
    return (noise(seed, n) + 1.0) * 0.5;
}

/// Stars above the waterline, fading in as the sun sets, each twinkling on
/// its own phase.
fn stars(r: *Raster, light: Light, c: f32, seed: u64) void {
    const vis = smoothstep(0.02, -0.22, light.elevation);
    if (vis <= 0) return;
    var k: u64 = 0;
    while (k < 180) : (k += 1) {
        const x = unit(seed, 900 + k * 3) * scene_w;
        const y = unit(seed, 901 + k * 3) * 560.0;
        const size = 1.2 + unit(seed, 902 + k * 3) * 2.2;
        const twinkle = 0.65 + 0.35 * @sin(c / 7.0 + @as(f32, @floatFromInt(k)) * 1.7);
        r.fillRect(x, y, size, size, white, vis * twinkle * (0.5 + 0.5 * (size - 1.2) / 2.2));
    }
}

/// Five soft clouds drifting right, white by day, lit from the horizon at
/// dusk, barely there at night.
fn clouds(r: *Raster, light: Light, c: f32, seed: u64) void {
    const tint = lerp3(.{ 255, 255, 255 }, light.horizon, 0.45);
    const dusk = 1.0 - @abs(std.math.clamp(light.elevation, -1.0, 1.0));
    const color_f = lerp3(tint, lerp3(light.horizon, .{ 255, 255, 255 }, 0.25), dusk * 0.5);
    const color = [3]u8{
        @intFromFloat(std.math.clamp(color_f[0], 0, 255)),
        @intFromFloat(std.math.clamp(color_f[1], 0, 255)),
        @intFromFloat(std.math.clamp(color_f[2], 0, 255)),
    };
    const alpha = 0.55 * (0.12 + 0.88 * light.day);
    var k: u64 = 0;
    while (k < 5) : (k += 1) {
        const base_x = unit(seed, 700 + k * 7) * (scene_w + 600.0) - 300.0;
        const y = 120.0 + unit(seed, 701 + k * 7) * 300.0;
        const speed = 0.15 + unit(seed, 702 + k * 7) * 0.3;
        const x = @mod(base_x + c * speed + 300.0, scene_w + 600.0) - 300.0;
        const rx = 110.0 + unit(seed, 703 + k * 7) * 110.0;
        const ry = 34.0 + unit(seed, 704 + k * 7) * 30.0;
        r.softEllipse(x, y, rx, ry, color, alpha);
        r.softEllipse(x - rx * 0.55, y + ry * 0.25, rx * 0.6, ry * 0.8, color, alpha);
        r.softEllipse(x + rx * 0.5, y + ry * 0.2, rx * 0.65, ry * 0.85, color, alpha);
    }
}

/// Three ranges from one random walk over x: a faint far range mirrored in
/// the water, an even fainter shadow below the waterline, and the solid
/// ground band around y=850. The slope re-rolls every 14 px. The original
/// halved the faint widths at night; here they fade with the light.
fn ranges(r: *Raster, light: Light, seed: u64) void {
    const thin: f32 = 1.0 / 16.0 + (1.0 / 8.0 - 1.0 / 16.0) * light.day;
    var h: f32 = 0;
    var slope: f32 = 0;
    var i: i32 = 1899;
    while (i >= 0) : (i -= 1) {
        const fi: f32 = @floatFromInt(i);
        if (@mod(i, 14) == 0) slope = noise(seed, @intCast(i));
        h += slope;
        r.fillRect(fi - 800, horizon_y - h, 2 * thin, h * 2, black, 1);
        r.fillRect(fi - 400, horizon_y, thin, h * 2, black, 1);
        r.fillRect(fi, 850 - h, 1, h * 2, black, 1);
    }
}

/// Nine reed clusters, each a fan of strokes that lengthen and thicken
/// downward.
fn reeds(r: *Raster, seed: u64) void {
    var i: i32 = 98;
    while (i >= 0) : (i -= 1) {
        const fi: f32 = @floatFromInt(i);
        const column = @mod(fi * fi / 7.0, 9.0) * 99.0 + fi + 600.0;
        const jitter = noise(seed, 5000 + @as(u64, @intCast(i))) * 2.0;
        var d: i32 = i - 1;
        while (d >= 1) : (d -= 1) {
            const fd: f32 = @floatFromInt(d);
            r.fillRect(@sin(fi + fd / 9.0) * 4.0 + column + jitter, 700 + fd * 3, fd / 20.0, fd, black, 1);
        }
    }
}

/// The five trees, drawn back to front in graded grays that darken toward
/// night so they stay silhouettes against a dark sky. The original toggles
/// a horizontal mirror before each one; `mirror` folds that in. Sway is the
/// original's night wind, eased in with the dark.
fn trees(r: *Raster, light: Light, c: f32) void {
    const Tree = struct { x: f32, y: f32, depth: u8, gray: f32, mirror: f32 };
    const list = [_]Tree{
        .{ .x = -396, .y = 800, .depth = 5, .gray = 0x44, .mirror = -1 },
        .{ .x = 1702, .y = 850, .depth = 7, .gray = 0x33, .mirror = 1 },
        .{ .x = -198, .y = 850, .depth = 7, .gray = 0x22, .mirror = -1 },
        .{ .x = 1801, .y = 900, .depth = 8, .gray = 0x11, .mirror = 1 },
        .{ .x = -99, .y = 900, .depth = 8, .gray = 0x11, .mirror = -1 },
    };
    const sway = (0.35 + 0.65 * light.night) / 32.0;
    for (list, 0..) |t, n| {
        const i: f32 = @floatFromInt(4 - n);
        const angle = 66.0 + sway * @sin(c / 32.0 + i);
        const g: u8 = @intFromFloat(t.gray * (1.0 - 0.65 * light.night));
        branch(r, t.x, t.y, angle, t.depth, .{ g, g, g }, t.mirror);
    }
}

/// One curved branch and its two children: reach 32+3d², width d²+2, the
/// control point pushed d² to the side so branches bow.
fn branch(r: *Raster, x: f32, y: f32, h: f32, d: u8, color: [3]u8, mirror: f32) void {
    if (d == 0) return;
    const fd: f32 = @floatFromInt(d);
    const reach = 32.0 + fd * fd * 3.0;
    const nx = x + @sin(h) * reach;
    const ny = y + @sin(h + 7.7) * reach;
    const cpx = (x + nx) / 2.0 + fd * fd;
    const cpy = @floor((y + ny) / 2.0);
    r.strokeQuad(mirror * x, y, mirror * cpx, cpy, mirror * nx, ny, fd * fd + 2.0, color, 1);
    branch(r, nx, ny, h - 0.2, d - 1, color, mirror);
    branch(r, nx, ny, h + 0.5, d - 1, color, mirror);
}

/// Light on the water under whichever light is up: a translucent cone
/// widening down from the waterline, its edge wavering with the clock.
/// Strongest when the sun sits low.
fn shimmer(r: *Raster, light: Light, c: f32, seed: u64) void {
    const slope = noise(seed, 0);
    const sun_a = haze_alpha * light.sun_vis * (0.45 + 0.55 * (1.0 - std.math.clamp(light.elevation, 0.0, 1.0)));
    const moon_a = haze_alpha * 0.6 * light.moon_vis;
    if (sun_a > 0.002) cone(r, light.sun_x, sun_a, c, slope, white);
    if (moon_a > 0.002) cone(r, light.moon_x, moon_a, c, slope + 1.3, .{ 214, 222, 248 });
}

fn cone(r: *Raster, cx: f32, alpha: f32, c: f32, slope: f32, color: [3]u8) void {
    var i: i32 = 299;
    while (i >= 1) : (i -= 1) {
        const fi: f32 = @floatFromInt(i);
        const d = slope * 99.0 + fi + c / 99.0;
        const width = fi * 3.0;
        r.fillRect(cx - width / 2.0 + @sin(d) * 25.0, horizon_y + 10.0 + fi, width, 16.0 / fi, color, alpha);
    }
}

/// The original paints two dots of '#fff5' at (901,1) 1×1 and (902,2) 2×2,
/// then drawImage()s the 6×6 patch at (900,0) onto (300,530)–(2200,1080):
/// bilinear upscaling turns them into soft haze. This samples that patch,
/// drifting slowly, gathering from dusk and full at night.
fn mist(r: *Raster, light: Light, c: f32) void {
    const strength = smoothstep(0.3, -0.05, light.elevation);
    if (strength <= 0.01) return;
    const patch = [6][6]f32{
        .{ 0, 0, 0, 0, 0, 0 },
        .{ 0, 1, 0, 0, 0, 0 },
        .{ 0, 0, 1, 1, 0, 0 },
        .{ 0, 0, 1, 1, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 0, 0, 0, 0 },
    };
    const drift = @sin(c / 240.0) * 120.0;
    const x0: i32 = @intFromFloat(@floor(@max(0.0, 300.0 + drift) * r.sx));
    const x1: i32 = @intFromFloat(@ceil(@min(2200.0 + drift, scene_w) * r.sx));
    const y0: i32 = @intFromFloat(@floor(530.0 * r.sy));
    const y1: i32 = @intFromFloat(@ceil(@min(1080.0, scene_h) * r.sy));
    var py = y0;
    while (py < y1) : (py += 1) {
        const sy_scene = (@as(f32, @floatFromInt(py)) + 0.5) / r.sy;
        const v = (sy_scene - 530.0) / (550.0 / 6.0) - 0.5;
        var px = x0;
        while (px < x1) : (px += 1) {
            const sx_scene = (@as(f32, @floatFromInt(px)) + 0.5) / r.sx;
            const u = (sx_scene - 300.0 - drift) / (1900.0 / 6.0) - 0.5;
            const a = sampleBilinear(&patch, u, v) * haze_alpha * strength;
            if (a > 0.002) r.blend(px, py, white, a);
        }
    }
}

fn sampleBilinear(patch: *const [6][6]f32, u: f32, v: f32) f32 {
    const fu = @floor(u);
    const fv = @floor(v);
    const tu = u - fu;
    const tv = v - fv;
    const iu: i32 = @intFromFloat(fu);
    const iv: i32 = @intFromFloat(fv);
    const at = struct {
        fn get(p: *const [6][6]f32, x: i32, y: i32) f32 {
            if (x < 0 or y < 0 or x >= 6 or y >= 6) return 0;
            return p[@intCast(y)][@intCast(x)];
        }
    };
    const a = at.get(patch, iu, iv) * (1 - tu) + at.get(patch, iu + 1, iv) * tu;
    const b = at.get(patch, iu, iv + 1) * (1 - tu) + at.get(patch, iu + 1, iv + 1) * tu;
    return a * (1 - tv) + b * tv;
}

// ------------------------------------------------------------ the clock --

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const std.c.time_t, result: *Tm) ?*Tm;

pub const LocalClock = struct {
    /// UTC seconds and milliseconds since the epoch.
    unix: i64,
    unix_ms: i64,
    /// Local seconds since local midnight.
    seconds_of_day: i64,
    /// Local time of day in hours.
    hour: f32,
    /// UTC offset now, and with daylight saving removed.
    gmtoff: i32,
    gmtoff_std: i32,
};

/// The wall clock through libc's zone database; UTC if that fails.
pub fn localClock(io: std.Io) LocalClock {
    const ts = std.Io.Timestamp.now(io, .real);
    const unix_ms: i64 = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_ms));
    const unix: i64 = @divFloor(unix_ms, 1000);
    var clock: LocalClock = .{
        .unix = unix,
        .unix_ms = unix_ms,
        .seconds_of_day = @mod(unix, 86_400),
        .hour = @as(f32, @floatFromInt(@mod(unix, 86_400))) / 3600.0,
        .gmtoff = 0,
        .gmtoff_std = 0,
    };
    const t: std.c.time_t = @intCast(unix);
    var tm: Tm = undefined;
    if (localtime_r(&t, &tm)) |_| {
        clock.seconds_of_day = @as(i64, tm.hour) * 3600 + @as(i64, tm.min) * 60 + tm.sec;
        clock.hour = @as(f32, @floatFromInt(clock.seconds_of_day)) / 3600.0;
        clock.gmtoff = @intCast(tm.gmtoff);
        clock.gmtoff_std = clock.gmtoff - (if (tm.isdst > 0) @as(i32, 3600) else 0);
    }
    return clock;
}

// ------------------------------------------------------------- raster --

pub const Raster = struct {
    rgb: []u8,
    width: u16,
    height: u16,
    sx: f32,
    sy: f32,

    fn blend(self: *Raster, x: i32, y: i32, color: [3]u8, alpha: f32) void {
        if (alpha <= 0 or x < 0 or y < 0 or x >= self.width or y >= self.height) return;
        const a = @min(alpha, 1.0);
        const i = (@as(usize, @intCast(y)) * self.width + @as(usize, @intCast(x))) * 3;
        inline for (0..3) |k| {
            const under: f32 = @floatFromInt(self.rgb[i + k]);
            const over: f32 = @floatFromInt(color[k]);
            self.rgb[i + k] = @intFromFloat(@round(under + (over - under) * a));
        }
    }

    /// Scene-space rectangle with exact area coverage per pixel, so a 0.125
    /// px wide bar lands as a faint line, as on a canvas.
    pub fn fillRect(self: *Raster, x: f32, y: f32, w: f32, h: f32, color: [3]u8, alpha: f32) void {
        if (!std.math.isFinite(w) or !std.math.isFinite(h) or w == 0 or h == 0) return;
        var x0 = x * self.sx;
        var x1 = (x + w) * self.sx;
        var y0 = y * self.sy;
        var y1 = (y + h) * self.sy;
        if (x1 < x0) std.mem.swap(f32, &x0, &x1);
        if (y1 < y0) std.mem.swap(f32, &y0, &y1);
        const px0: i32 = @intFromFloat(@floor(@max(x0, 0)));
        const px1: i32 = @intFromFloat(@ceil(@min(x1, @as(f32, @floatFromInt(self.width)))));
        const py0: i32 = @intFromFloat(@floor(@max(y0, 0)));
        const py1: i32 = @intFromFloat(@ceil(@min(y1, @as(f32, @floatFromInt(self.height)))));
        var py = py0;
        while (py < py1) : (py += 1) {
            const fy: f32 = @floatFromInt(py);
            const cy = @max(0, @min(y1, fy + 1) - @max(y0, fy));
            if (cy <= 0) continue;
            var px = px0;
            while (px < px1) : (px += 1) {
                const fx: f32 = @floatFromInt(px);
                const cx = @max(0, @min(x1, fx + 1) - @max(x0, fx));
                if (cx > 0) self.blend(px, py, color, alpha * cx * cy);
            }
        }
    }

    /// Device-space segment with round caps.
    fn capsule(self: *Raster, x0: f32, y0: f32, x1: f32, y1: f32, radius: f32, color: [3]u8, alpha: f32) void {
        const rr = @max(radius, 0.35);
        const bx0: i32 = @intFromFloat(@floor(@min(x0, x1) - rr - 1));
        const bx1: i32 = @intFromFloat(@ceil(@max(x0, x1) + rr + 1));
        const by0: i32 = @intFromFloat(@floor(@min(y0, y1) - rr - 1));
        const by1: i32 = @intFromFloat(@ceil(@max(y0, y1) + rr + 1));
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len2 = dx * dx + dy * dy;
        var py = @max(by0, 0);
        const py_end = @min(by1, @as(i32, self.height));
        const px_start = @max(bx0, 0);
        const px_end = @min(bx1, @as(i32, self.width));
        while (py < py_end) : (py += 1) {
            const cy = @as(f32, @floatFromInt(py)) + 0.5;
            var px = px_start;
            while (px < px_end) : (px += 1) {
                const cx = @as(f32, @floatFromInt(px)) + 0.5;
                var t: f32 = 0;
                if (len2 > 0) t = std.math.clamp(((cx - x0) * dx + (cy - y0) * dy) / len2, 0.0, 1.0);
                const ex = x0 + dx * t - cx;
                const ey = y0 + dy * t - cy;
                const dist = @sqrt(ex * ex + ey * ey);
                const a = std.math.clamp(rr - dist + 0.5, 0.0, 1.0);
                if (a > 0) self.blend(px, py, color, alpha * a);
            }
        }
    }

    /// Scene-space quadratic curve, flattened into capsules.
    fn strokeQuad(self: *Raster, x0: f32, y0: f32, cx: f32, cy: f32, x1: f32, y1: f32, width: f32, color: [3]u8, alpha: f32) void {
        const half = width * (self.sx + self.sy) / 4.0;
        const span = @abs(x1 - x0) * self.sx + @abs(y1 - y0) * self.sy;
        const n: usize = @intFromFloat(std.math.clamp(span / 5.0, 2.0, 24.0));
        var px = x0 * self.sx;
        var py = y0 * self.sy;
        var k: usize = 1;
        while (k <= n) : (k += 1) {
            const t: f32 = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(n));
            const mt = 1 - t;
            const qx = (mt * mt * x0 + 2 * mt * t * cx + t * t * x1) * self.sx;
            const qy = (mt * mt * y0 + 2 * mt * t * cy + t * t * y1) * self.sy;
            self.capsule(px, py, qx, qy, half, color, alpha);
            px = qx;
            py = qy;
        }
    }

    /// Scene-space ellipse fading from full alpha at the center to nothing
    /// at the rim (clouds).
    pub fn softEllipse(self: *Raster, cx: f32, cy: f32, rx: f32, ry: f32, color: [3]u8, alpha: f32) void {
        const dcx = cx * self.sx;
        const dcy = cy * self.sy;
        const drx = rx * self.sx;
        const dry = ry * self.sy;
        if (drx <= 0 or dry <= 0) return;
        const bx0: i32 = @intFromFloat(@floor(dcx - drx - 1));
        const bx1: i32 = @intFromFloat(@ceil(dcx + drx + 1));
        const by0: i32 = @intFromFloat(@floor(dcy - dry - 1));
        const by1: i32 = @intFromFloat(@ceil(dcy + dry + 1));
        var py = @max(by0, 0);
        const py_end = @min(by1, @as(i32, self.height));
        const px_start = @max(bx0, 0);
        const px_end = @min(bx1, @as(i32, self.width));
        while (py < py_end) : (py += 1) {
            const dy = (@as(f32, @floatFromInt(py)) + 0.5 - dcy) / dry;
            var px = px_start;
            while (px < px_end) : (px += 1) {
                const dx = (@as(f32, @floatFromInt(px)) + 0.5 - dcx) / drx;
                const d = @sqrt(dx * dx + dy * dy);
                if (d >= 1) continue;
                const fall = (1 - d) * (1 - d) * (3.0 - 2.0 * (1 - d)); // smoothstep in
                self.blend(px, py, color, alpha * fall);
            }
        }
    }
};
