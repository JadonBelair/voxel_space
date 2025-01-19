const std = @import("std");
const sokol = @import("sokol");
const sapp = sokol.app;
const sg = sokol.gfx;
const slog = sokol.log;
const sglue = sokol.glue;

const zigimg = @import("zigimg");

const shader = @import("shader/texture.glsl.zig");

const WIDTH: u32 = 800;
const HEIGHT: u32 = 600;

const state = struct {
    var pass_action: sg.PassAction = .{};
    var bind: sg.Bindings = .{};
    var pip: sg.Pipeline = .{};

    var pixel_buffer: [WIDTH*4*HEIGHT]u8 = [_]u8 {0} ** (WIDTH*4*HEIGHT);

    var map_data: []MapData = undefined;
    var current_map: usize = 0;
    
    var phi: f32 = 0.0;
    var pos: Point = .{.x = 0.0, .y = 0.0};
    var height: i32 = 150;
};

const KEYS = enum {
    W,
    A,
    S,
    D,
    Q,
    E,
    SPACE,
    SHIFT,
    COMMA,
    PERIOD,
};

const keys = struct {
    var is_down: [10]bool = [_]bool {false} ** 10;
    var is_just_down: [10]bool = [_]bool {false} ** 10;
    var is_just_up: [10]bool = [_]bool {false} ** 10;
};

const Point = struct {
    x: f32,
    y: f32,
};

const Map = struct {
    data: zigimg.Image,
    name: []const u8,
};

const MapData = struct {
    map_name: []const u8 = undefined,
    height_map: zigimg.Image = .{},
    color_maps: []Map = undefined,
};

const maps = struct {
    var maps: []MapData = undefined;
};

export fn init() void {
    sg.setup(.{
        .environment = sglue.environment(),
        .logger = .{ .func = slog.func },
    });

    const vertex_buffer: [16]f32 = [16]f32 {
        -1.0, -1.0,   0.0, 1.0,
         1.0, -1.0,   1.0, 1.0,
         1.0,  1.0,   1.0, 0.0,
        -1.0,  1.0,   0.0, 0.0,
    };

    const index_buffer: [6]u16 = [6]u16 {
        0, 1, 2,
        0, 2, 3,
    };

    state.bind.vertex_buffers[0] = sg.makeBuffer(.{
        .data = sg.asRange(&vertex_buffer),
    });

    state.bind.index_buffer = sg.makeBuffer(.{
        .type = .INDEXBUFFER,
        .data = sg.asRange(&index_buffer),
    });

    state.bind.samplers[shader.SMP_smp] = sg.makeSampler(.{
        .min_filter = .LINEAR,
        .mag_filter = .NEAREST,
    });

    var pipe_desc: sg.PipelineDesc = .{
        .shader = sg.makeShader(shader.textureShaderDesc(sg.queryBackend())),
        .index_type = .UINT16,
    };

    pipe_desc.layout.attrs[shader.ATTR_texture_position].format = .FLOAT2;
    pipe_desc.layout.attrs[shader.ATTR_texture_texIn].format = .FLOAT2;
    pipe_desc.colors[0] = .{
        .blend = .{
            .enabled = true,
            .src_factor_rgb = .SRC_ALPHA,
            .dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
            .op_rgb = .ADD,
            .src_factor_alpha = .SRC_ALPHA,
            .dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
            .op_alpha = .ADD,
        },
    };

    state.pip = sg.makePipeline(pipe_desc);

    state.bind.images[shader.IMG_tex] = sg.makeImage(.{
        .usage = .STREAM,
        .pixel_format = .RGBA8,
        .width = WIDTH,
        .height = HEIGHT,
    });

    state.pass_action.colors[0] = .{
        .load_action = .CLEAR,
        .clear_value = .{ .r = 0.03, .g = 0.0, .b = 0.04, .a = 1.0 },
    };

    inner_init() catch return;
}

fn inner_init() !void {
    const maps_dir = try std.fs.cwd().openDir("maps", .{ .iterate = true });
    var maps_iter = maps_dir.iterate();

    var maps_data = std.ArrayList(MapData).init(std.heap.page_allocator);
    defer maps_data.deinit();

    while (try maps_iter.next()) |next| {
        const map_name = try std.heap.page_allocator.dupe(u8, next.name);
        std.debug.print("Loading {s}\n", .{map_name});

        const map_dir = try maps_dir.openDir(map_name, .{ .iterate = true });
        var map_iter = map_dir.iterate();

        var map_data: MapData = .{
            .map_name = map_name,
        };

        var color_maps = std.ArrayList(Map).init(std.heap.page_allocator);
        defer color_maps.deinit();

        while (try map_iter.next()) |map_file| {
            var map_path = std.ArrayList(u8).init(std.heap.page_allocator);
            defer map_path.deinit();
            try map_path.writer().print("./maps/{s}/{s}", .{ map_name, map_file.name });

            const map_path_slice = try map_path.toOwnedSlice();

            if (std.mem.eql(u8, map_file.name, "heightmap.png")) {
                var height_map = try zigimg.Image.fromFilePath(std.heap.page_allocator, map_path_slice);
                try height_map.convert(.grayscale8);

                map_data.height_map = height_map;
            } else {
                var color_map = try zigimg.Image.fromFilePath(std.heap.page_allocator, map_path_slice);
                try color_map.convert(.rgb24);

                try color_maps.append(.{
                    .name = try std.heap.page_allocator.dupe(u8, map_file.name),
                    .data = color_map,
                });
            }
        }

        map_data.color_maps = try color_maps.toOwnedSlice();

        try maps_data.append(map_data);
    }

    std.debug.print("Done loading all maps\n", .{});

    state.map_data = try maps_data.toOwnedSlice();
}

export fn frame() void {

    state.pixel_buffer = [_]u8 {0} ** (WIDTH*4*HEIGHT);

    if (is_key_just_pressed(KEYS.COMMA)) {
        state.current_map = @as(u32, @intCast(@mod(@as(i32, @intCast(state.current_map)) - 1, @as(i32, @intCast(state.map_data.len)))));
        std.debug.print("Now showing {s}\n", .{ state.map_data[state.current_map].map_name });
    }
    if (is_key_just_pressed(KEYS.PERIOD)) {
        state.current_map = @as(u32, @intCast(@mod(@as(i32, @intCast(state.current_map)) + 1, @as(i32, @intCast(state.map_data.len)))));
        std.debug.print("Now showing {s}\n", .{ state.map_data[state.current_map].map_name });
    }

    if (is_key_down(KEYS.Q)) {
        state.phi += 0.01;
    }

    if (is_key_down(KEYS.E)) {
        state.phi -= 0.01;
    }

    if (is_key_down(KEYS.W)) {
        const dx = -@sin(state.phi);
        const dy = -@cos(state.phi);

        state.pos.x += dx * 1.2;
        state.pos.y += dy * 1.2;
    }

    if (is_key_down(KEYS.S)) {
        const dx = @sin(state.phi);
        const dy = @cos(state.phi);

        state.pos.x += dx * 1.2;
        state.pos.y += dy * 1.2;
    }

    if (is_key_down(KEYS.A)) {
        const dx = -@cos(state.phi);
        const dy = @sin(state.phi);

        state.pos.x += dx * 1.2;
        state.pos.y += dy * 1.2;
    }

    if (is_key_down(KEYS.D)) {
        const dx = @cos(state.phi);
        const dy = -@sin(state.phi);

        state.pos.x += dx * 1.2;
        state.pos.y += dy * 1.2;
    }

    if (is_key_down(KEYS.SPACE)) {
        state.height += 1;
    }

    if (is_key_down(KEYS.SHIFT)) {
        state.height -= 1;
    }

    render(state.pos, state.phi, state.height, 120, 120 , 600);

    var texture_data: sg.ImageData = .{};
    texture_data.subimage[0][0] = sg.asRange(&state.pixel_buffer);
    sg.updateImage(state.bind.images[shader.IMG_tex], texture_data);
    sg.beginPass(.{ .action = state.pass_action, .swapchain = sglue.swapchain() });
    sg.applyPipeline(state.pip);
    sg.applyBindings(state.bind);
    sg.draw(0, 6, 1);
    sg.endPass();
    sg.commit();

    keys.is_just_down = [_]bool {false} ** 10;
    keys.is_just_up = [_]bool {false} ** 10;
}

export fn event(ev: [*c]const sapp.Event) void {
    switch (ev.*.type) {
        .KEY_UP => {
            if (key_code_to_key(ev.*.key_code)) |key| {
                const index = @intFromEnum(key);
                keys.is_down[index] = false;
                keys.is_just_up[index] = true;
            }
        },
        .KEY_DOWN => {
            if (key_code_to_key(ev.*.key_code)) |key| {
                const index = @intFromEnum(key);
                if (!keys.is_down[index]) {
                    keys.is_just_down[index] = true;
                }
                keys.is_down[index] = true;
            }
        },
        else => {}
    }
}

export fn cleanup() void {
    sg.shutdown();
}

fn key_code_to_key(key_code: sapp.Keycode) ?KEYS {
        return switch (key_code) {
            .LEFT_SHIFT => KEYS.SHIFT,
            .PERIOD     => KEYS.PERIOD,
            .COMMA      => KEYS.COMMA,
            .SPACE      => KEYS.SPACE,
            .W          => KEYS.W,
            .A          => KEYS.A,
            .S          => KEYS.S,
            .D          => KEYS.D,
            .Q          => KEYS.Q,
            .E          => KEYS.E,
            else        => null
        };
}

fn is_key_down(key: KEYS) bool {
    return keys.is_down[@intFromEnum(key)];
}

fn is_key_just_pressed(key: KEYS) bool {
    return keys.is_just_down[@intFromEnum(key)];
}

fn is_key_just_released(key: KEYS) bool {
    return keys.is_just_up[@intFromEnum(key)];
}

fn get_heightmap_value(x: isize, y: isize) f32 {
    const wrapped_y = @as(u32, @intCast(@mod(y, @as(i32, @intCast(state.map_data[state.current_map].height_map.height)))));
    const wrapped_x = @as(u32, @intCast(@mod(x, @as(i32, @intCast(state.map_data[state.current_map].height_map.width)))));

    const index = wrapped_y * state.map_data[state.current_map].height_map.width + wrapped_x;

    return @floatFromInt(state.map_data[state.current_map].height_map.pixels.grayscale8[index].value);
}

fn get_color(x: isize, y: isize) sg.Color {
    const wrapped_y = @as(u32, @intCast(@mod(y, @as(i32, @intCast(state.map_data[state.current_map].height_map.height)))));
    const wrapped_x = @as(u32, @intCast(@mod(x, @as(i32, @intCast(state.map_data[state.current_map].height_map.width)))));

    const index = wrapped_y * state.map_data[state.current_map].height_map.width + wrapped_x;

    const color = state.map_data[state.current_map].color_maps[0].data.pixels.rgb24[index];

    return .{
        .r = @as(f32, @floatFromInt(color.r)) / 255.0,
        .g = @as(f32, @floatFromInt(color.g)) / 255.0,
        .b = @as(f32, @floatFromInt(color.b)) / 255.0,
        .a = 1.0,
    };
}

fn draw_vertical_line(x: usize, top: isize, bottom: isize, color: sg.Color) void {
    var y = top;
    while (y < bottom) : (y += 1) {
        const clamped_y = @as(usize, @intCast(@min(HEIGHT, @max(0, y))));
        set_pixel(x, clamped_y, color);
    }
}

fn render(p: Point, phi: f32, height: i32, horizon: i32, scale_height: i32, distance: i32) void {
    const sinphi = @sin(phi);
    const cosphi = @cos(phi);

    var height_mask: [WIDTH]f32 = [_]f32 {HEIGHT} ** WIDTH;
    var dz: f32 = 1.0;
    var z: f32 = 1.0;
    while (z <= @as(f32, @floatFromInt(distance))) : ({z += dz; dz += 0.05;}) {
        var pleft: Point = .{
            .x = (-cosphi*z - sinphi*z) + p.x,
            .y = ( sinphi*z - cosphi*z) + p.y,
        };
        const pright: Point = .{
            .x = ( cosphi*z - sinphi*z) + p.x,
            .y = (-sinphi*z - cosphi*z) + p.y,
        };

        const dx = (pright.x - pleft.x) / WIDTH;
        const dy = (pright.y - pleft.y) / HEIGHT;

        for (0..WIDTH) |i| {
            const heightmap_value = get_heightmap_value(@intFromFloat(pleft.x), @intFromFloat(pleft.y)) * 1.5;
            const height_on_screen = (@as(f32, @floatFromInt(height)) - heightmap_value) / z * @as(f32, @floatFromInt(scale_height)) + @as(f32, @floatFromInt(horizon));

            if (height_mask[i] > height_on_screen) {
                draw_vertical_line(i, @intFromFloat(height_on_screen), @intFromFloat(height_mask[i]), get_color(@intFromFloat(pleft.x), @intFromFloat(pleft.y)));
                height_mask[i] = height_on_screen;
            }

            pleft.x += dx;
            pleft.y += dy;
        }
    }
}

fn set_pixel(x: usize, y: usize, color: sg.Color) void {
    const index = (y * WIDTH + x) * 4;
    state.pixel_buffer[index + 0] = @as(u8, @intFromFloat(color.r * 255.0));
    state.pixel_buffer[index + 1] = @as(u8, @intFromFloat(color.g * 255.0));
    state.pixel_buffer[index + 2] = @as(u8, @intFromFloat(color.b * 255.0));
    state.pixel_buffer[index + 3] = @as(u8, @intFromFloat(color.a * 255.0));
}

pub fn main() !void {
    sapp.run(.{
        .init_cb = init,
        .frame_cb = frame,
        .event_cb = event,
        .cleanup_cb = cleanup,
        .window_title = "Voxel Space Renderer",
        .width = WIDTH,
        .height = HEIGHT,
        .icon = .{ .sokol_default = true },
        .logger = .{ .func = slog.func },
    });
}
