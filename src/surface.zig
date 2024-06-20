const std = @import("std");
const mem = std.mem;
const posix = std.posix;

const wayland = @import("wayland");
const zwlr = wayland.client.zwlr;
const wl = wayland.client.wl;
const zxdg = wayland.client.zxdg;
const c = @import("ffi.zig");

const Mode = @import("main.zig").Mode;
const Seto = @import("main.zig").Seto;
const Config = @import("config.zig").Config;
const Tree = @import("tree.zig").Tree;
const EglSurface = @import("egl.zig").EglSurface;

pub const OutputInfo = struct {
    id: u32,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    height: i32 = 0,
    width: i32 = 0,
    x: i32 = 0,
    y: i32 = 0,

    const Self = @This();

    fn destroy(self: *Self, alloc: mem.Allocator) void {
        alloc.free(self.name.?);
        alloc.free(self.description.?);
    }
};

pub const Surface = struct {
    egl: EglSurface,
    layer_surface: *zwlr.LayerSurfaceV1,
    surface: *wl.Surface,
    alloc: mem.Allocator,
    output_info: OutputInfo,
    xdg_output: *zxdg.OutputV1,
    config: *const Config,

    const Self = @This();

    pub fn new(
        egl: EglSurface,
        surface: *wl.Surface,
        layer_surface: *zwlr.LayerSurfaceV1,
        alloc: mem.Allocator,
        xdg_output: *zxdg.OutputV1,
        output_info: OutputInfo,
        config_ptr: *Config,
    ) Self {
        return .{
            .config = config_ptr,
            .egl = egl,
            .surface = surface,
            .layer_surface = layer_surface,
            .alloc = alloc,
            .output_info = output_info,
            .xdg_output = xdg_output,
        };
    }

    pub fn posInSurface(self: Self, coordinates: [2]i32) bool {
        const info = self.output_info;
        return coordinates[0] < info.x + info.width and coordinates[0] >= info.x and coordinates[1] < info.y + info.height and coordinates[1] >= info.y;
    }

    pub fn cmp(_: Self, a: Self, b: Self) bool {
        if (a.output_info.x != b.output_info.x)
            return a.output_info.x < b.output_info.x
        else
            return a.output_info.y < b.output_info.y;
    }

    pub fn draw(self: *Self, start_pos: [2]?i32, mode: Mode, border_mode: bool) [2]?i32 {
        const info = self.output_info;
        const grid = self.config.grid;

        const width: f32 = @floatFromInt(info.width);
        const height: f32 = @floatFromInt(info.height);

        var vertices = std.ArrayList(f32).init(self.alloc);
        defer vertices.deinit();

        c.glEnableVertexAttribArray(0);

        defer switch (mode) {
            .Region => |position| if (position) |pos| {
                const f_position: [2]f32 = .{ @floatFromInt(pos[0]), @floatFromInt(pos[1]) };
                const f_p: [2]f32 = .{ @floatFromInt(info.x), @floatFromInt(info.y) };

                var selected_vertices: [8]f32 =
                    if (mode.withinBounds(info)) .{
                    2 * ((f_position[0] - f_p[0]) / width) - 1, -1,
                    2 * ((f_position[0] - f_p[0]) / width) - 1, 1,
                    -1,                                         -(2 * ((f_position[1] - f_p[1]) / height) - 1),
                    1,                                          -(2 * ((f_position[1] - f_p[1]) / height) - 1),
                } else if (mode.yWithinBounds(info)) .{
                    -1, -(2 * ((f_position[1] - f_p[1]) / height) - 1),
                    1,  -(2 * ((f_position[1] - f_p[1]) / height) - 1),
                    0,  0,
                    0,  0,
                } else if (mode.xWithinBounds(info)) .{
                    2 * ((f_position[0] - f_p[0]) / width) - 1, -1,
                    2 * ((f_position[0] - f_p[0]) / width) - 1, 1,
                    0,                                          0,
                    0,                                          0,
                } else unreachable;

                const selected_color = self.config.grid.selected_color;
                c.glUniform4f(0, selected_color[0], selected_color[1], selected_color[2], selected_color[3]);
                c.glLineWidth(self.config.grid.selected_line_width);

                c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, 0, @ptrCast(&selected_vertices));
                c.glDrawArrays(c.GL_LINES, 0, @intCast(selected_vertices.len >> 1));
            },
            .Single => {},
        };

        c.glLineWidth(self.config.grid.line_width);

        if (border_mode) {
            vertices.append(1) catch @panic("OOM");
            vertices.append(1) catch @panic("OOM");

            vertices.append(1) catch @panic("OOM");
            vertices.append(-1) catch @panic("OOM");

            vertices.append(-1) catch @panic("OOM");
            vertices.append(-1) catch @panic("OOM");

            vertices.append(-1) catch @panic("OOM");
            vertices.append(1) catch @panic("OOM");

            c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, 0, @ptrCast(vertices.items));
            c.glDrawArrays(c.GL_LINE_LOOP, 0, @intCast(vertices.items.len >> 1));

            return .{ null, null };
        }

        var pos_x = if (start_pos[0]) |pos| pos else grid.offset[0];
        while (pos_x <= info.width) : (pos_x += grid.size[0]) {
            vertices.append(2 * (@as(f32, @floatFromInt(pos_x)) / width) - 1) catch @panic("OOM");
            vertices.append(1) catch @panic("OOM");
            vertices.append(2 * (@as(f32, @floatFromInt(pos_x)) / width) - 1) catch @panic("OOM");
            vertices.append(-1) catch @panic("OOM");
        }

        var pos_y = if (start_pos[1]) |pos| pos else grid.offset[1];
        while (pos_y <= info.height) : (pos_y += grid.size[1]) {
            vertices.append(-1) catch @panic("OOM");
            vertices.append(2 * ((height - @as(f32, @floatFromInt(pos_y))) / height) - 1) catch @panic("OOM");
            vertices.append(1) catch @panic("OOM");
            vertices.append(2 * ((height - @as(f32, @floatFromInt(pos_y))) / height) - 1) catch @panic("OOM");
        }

        c.glVertexAttribPointer(0, 2, c.GL_FLOAT, c.GL_FALSE, 0, @ptrCast(vertices.items));
        c.glDrawArrays(c.GL_LINES, 0, @intCast(vertices.items.len >> 1));

        return .{ pos_x - info.width, pos_y - info.height };
    }

    pub fn isConfigured(self: *const Self) bool {
        return self.output_info.width > 0 and self.output_info.height > 0;
    }

    pub fn destroy(self: *Self) void {
        self.layer_surface.destroy();
        self.surface.destroy();
        self.output_info.destroy(self.alloc);
        self.xdg_output.destroy();
    }
};

pub const SurfaceIterator = struct {
    position: [2]i32,
    outputs: []Surface,
    index: u8 = 0,

    const Self = @This();

    pub fn new(outputs: []Surface) Self {
        return Self{ .outputs = outputs, .position = .{ outputs[0].output_info.x, outputs[0].output_info.y } };
    }

    pub fn isNewline(self: *Self) bool {
        if (self.index == 0) return false;
        return self.outputs[self.index].output_info.x <= self.outputs[self.index - 1].output_info.x;
    }

    pub fn next(self: *Self) ?std.meta.Tuple(&.{ Surface, [2]i32, bool }) {
        if (self.index >= self.outputs.len or !self.outputs[self.index].isConfigured()) return null;
        const output = self.outputs[self.index];

        if (self.isNewline()) {
            self.position = .{ 0, self.outputs[self.index - 1].output_info.height };
        }

        defer self.index += 1;
        defer self.position[0] += output.output_info.width;

        return .{ output, self.position, self.isNewline() };
    }
};

pub fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, surface: *Surface) void {
    defer callback.destroy();
    if (event == .done) surface.draw() catch return;
}

pub fn layerSurfaceListener(lsurf: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, seto: *Seto) void {
    switch (event) {
        .configure => |configure| {
            for (seto.outputs.items) |*surface| {
                if (surface.layer_surface == lsurf) {
                    surface.layer_surface.setSize(configure.width, configure.height);
                    surface.layer_surface.ackConfigure(configure.serial);
                    surface.egl.resize(.{ configure.width, configure.height });
                }
            }
        },
        .closed => {},
    }
}

pub fn xdgOutputListener(
    output: *zxdg.OutputV1,
    event: zxdg.OutputV1.Event,
    seto: *Seto,
) void {
    for (seto.outputs.items) |*surface| {
        if (surface.xdg_output == output) {
            switch (event) {
                .name => |e| {
                    surface.output_info.name = seto.alloc.dupe(u8, mem.span(e.name)) catch @panic("OOM");
                },
                .description => |e| {
                    surface.output_info.description = seto.alloc.dupe(u8, mem.span(e.description)) catch @panic("OOM");
                },
                .logical_position => |pos| {
                    surface.output_info.x = pos.x;
                    surface.output_info.y = pos.y;
                },
                .logical_size => |size| {
                    surface.output_info.height = size.height;
                    surface.output_info.width = size.width;

                    seto.updateDimensions();
                    seto.sortOutputs();

                    if (seto.tree) |tree| tree.arena.deinit();
                    seto.tree = Tree.new(
                        seto.config.keys.search,
                        seto.alloc,
                        seto.config.grid,
                        seto.outputs.items,
                    );
                },
                .done => {},
            }
        }
    }
}
