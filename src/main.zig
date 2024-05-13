const std = @import("std");
const mem = std.mem;
const posix = std.posix;

const Tree = @import("tree.zig").Tree;
const OutputInfo = @import("surface.zig").OutputInfo;
const Surface = @import("surface.zig").Surface;
const Seat = @import("seat.zig").Seat;
const Result = @import("tree.zig").Result;
const Config = @import("config.zig").Config;

const handleKey = @import("seat.zig").handleKey;

const xdgOutputListener = @import("surface.zig").xdgOutputListener;
const layerSurfaceListener = @import("surface.zig").layerSurfaceListener;
const seatListener = @import("seat.zig").seatListener;

const cairo = @import("cairo");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const zxdg = wayland.client.zxdg;

const EventInterfaces = enum {
    wl_shm,
    wl_compositor,
    zwlr_layer_shell_v1,
    wl_output,
    wl_seat,
    zxdg_output_manager_v1,
};

pub const Seto = struct {
    shm: ?*wl.Shm = null,
    compositor: ?*wl.Compositor = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    output_manager: ?*zxdg.OutputManagerV1 = null,

    seat: Seat,
    outputs: std.ArrayList(Surface),
    alloc: mem.Allocator,
    config: Config,

    depth: usize = 0,
    redraw: bool = false,
    first_draw: bool = true,
    exit: bool = false,

    const Self = @This();

    fn new(alloc: mem.Allocator) Self {
        const config = Config.load(alloc) catch @panic("");
        return .{
            .seat = Seat.new(alloc),
            .outputs = std.ArrayList(Surface).init(alloc),
            .alloc = alloc,
            .config = config,
        };
    }

    fn getDimensions(self: *Self) [2]i32 {
        var x: [2]i32 = .{ 0, 0 };
        var y: [2]i32 = .{ 0, 0 };
        for (self.outputs.items) |output| {
            if (!output.isConfigured()) continue;
            const info = output.output_info;

            if (info.x < x[0]) x[0] = info.x;
            if (info.y < y[0]) y[0] = info.y;
            if (info.x + info.width > x[1]) x[1] = info.x + info.width;
            if (info.y + info.height > y[1]) y[1] = info.y + info.height;
        }

        return .{ x[1] - x[0], y[1] - y[0] };
    }

    fn getIntersections(self: *Seto) ![][2]usize {
        const dimensions = self.getDimensions();
        const width: u32 = @intCast(dimensions[0]);
        const height: u32 = @intCast(dimensions[1]);

        var intersections = std.ArrayList([2]usize).init(self.alloc);
        defer intersections.deinit();
        const grid = self.config.grid;
        var i: isize = @mod(grid.offset[0], grid.size[0]);
        while (i <= width) : (i += grid.size[0]) {
            var j: isize = @mod(grid.offset[1], grid.size[1]);
            while (j <= height) : (j += grid.size[1]) {
                try intersections.append(.{ @intCast(i), @intCast(j) });
            }
        }

        return try intersections.toOwnedSlice();
    }

    fn updateDepth(self: *Self, intersections: [][2]usize, keys: []const u8) void {
        const items_len: f64 = @floatFromInt(intersections.len);
        const keys_len: f64 = @floatFromInt(keys.len);
        const depth = std.math.log(f64, keys_len, items_len);
        self.depth = @intFromFloat(std.math.ceil(depth));
    }

    fn drawGrid(self: *Self, width: u32, height: u32, context: *const *cairo.Context) void {
        const grid = self.config.grid;
        var i: isize = @mod(grid.offset[0], grid.size[0]);
        context.*.setSourceRgb(grid.color[0], grid.color[1], grid.color[2]);
        while (i <= width) : (i += grid.size[0]) {
            context.*.moveTo(@floatFromInt(i), 0);
            context.*.lineTo(@floatFromInt(i), @floatFromInt(height));
        }

        i = @mod(grid.offset[1], grid.size[1]);
        while (i <= width) : (i += grid.size[1]) {
            context.*.moveTo(0, @floatFromInt(i));
            context.*.lineTo(@floatFromInt(width), @floatFromInt(i));
        }

        context.*.stroke();
    }

    fn createSurfaces(self: *Self) !void {
        if (!self.drawSurfaces()) return;

        const dimensions = self.getDimensions();
        const width: u32 = @intCast(dimensions[0]);
        const height: u32 = @intCast(dimensions[1]);

        const intersections = try self.getIntersections();
        defer self.alloc.free(intersections);

        self.updateDepth(intersections, self.config.keys.search);

        var tree = Tree.new(self.alloc, self.config.keys.search, self.depth, intersections);
        defer tree.alloc.deinit();
        _ = tree.find(self.seat.buffer.items) catch |err| {
            switch (err) {
                error.KeyNotFound => _ = self.seat.buffer.popOrNull(),
                error.EndNotReached => {},
            }
        };

        const cairo_surface = try cairo.ImageSurface.create(.argb32, @intCast(width), @intCast(height));
        defer cairo_surface.destroy();
        const ctx = try cairo.Context.create(cairo_surface.asSurface());
        defer ctx.destroy();

        self.drawGrid(width, height, &ctx);

        const bg_color = self.config.background_color;
        ctx.setSourceRgb(bg_color[0], bg_color[1], bg_color[2]);
        ctx.paintWithAlpha(bg_color[3]);

        const branch_info = try tree.iter(self.config.keys.search);
        for (branch_info) |branch| {
            var matching: u8 = 0;
            for (self.seat.buffer.items, 0..) |char, i| {
                if (mem.eql(u8, char[0..1], branch.path[i .. i + 1])) {
                    matching += 1;
                    continue;
                }

                matching = 0;
                break;
            }

            ctx.moveTo(@floatFromInt(branch.pos[0] + 5), @floatFromInt(branch.pos[1] + 15));
            const font = self.config.font;
            ctx.selectFontFace(font.family, .Normal, .Normal);
            ctx.setFontSize(font.size);
            for (0..self.depth) |i| {
                ctx.setSourceRgb(font.color[0], font.color[1], font.color[2]);
                if (i < matching) {
                    ctx.setSourceRgb(font.highlight_color[0], font.highlight_color[1], font.highlight_color[2]);
                }
                var positions: [2]u8 = undefined;
                positions[0] = branch.path[i];
                positions[1] = 0;
                ctx.showText(positions[0..1 :0]);
            }
        }

        const size: i32 = @intCast(width * height * 4);

        const shm = self.shm orelse return error.NoWlShm;

        // TODO: make it more output agnostic (trying to sound smart)
        for (self.outputs.items) |*output| {
            if (!output.isConfigured()) continue;

            const info = output.output_info;
            const output_surface = try cairo.ImageSurface.create(.argb32, @intCast(info.width), @intCast(info.height));
            defer output_surface.destroy();
            const output_ctx = try cairo.Context.create(output_surface.asSurface());
            defer output_ctx.destroy();

            output_ctx.setSourceSurface(cairo_surface.asSurface(), @floatFromInt(-info.x), @floatFromInt(info.y));
            output_ctx.paint();

            const data = try output_surface.getData();

            const fd = try posix.memfd_create("seto", 0);
            defer posix.close(fd);
            try posix.ftruncate(fd, @intCast(size));
            const pool = try shm.createPool(fd, size);
            defer pool.destroy();
            try output.draw(pool, fd, data);
        }
    }

    fn drawSurfaces(self: *Self) bool {
        const draw = self.redraw or self.first_draw;
        self.first_draw = false;
        return draw;
    }

    fn destroy(self: *Self) void {
        self.compositor.?.destroy();
        self.layer_shell.?.destroy();
        self.shm.?.destroy();
        self.output_manager.?.destroy();
        for (self.outputs.items) |*output| {
            output.destroy();
        }
        self.outputs.deinit();
        self.seat.destroy();
        self.config.keys.bindings.deinit();
    }
};

pub fn main() !void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    defer registry.destroy();

    var dbg_gpa = if (@import("builtin").mode == .Debug) std.heap.GeneralPurposeAllocator(.{}){} else {};
    defer if (@TypeOf(dbg_gpa) != void) {
        _ = dbg_gpa.deinit();
    };
    const alloc = if (@TypeOf(dbg_gpa) != void) dbg_gpa.allocator() else std.heap.c_allocator;

    var seto = Seto.new(alloc);
    defer seto.destroy();

    registry.setListener(*Seto, registryListener, &seto);
    if (display.roundtrip() != .SUCCESS) return error.DispatchFailed;
    while (!seto.exit) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        if (seto.seat.repeatKey()) {
            handleKey(&seto);
        }
        try seto.createSurfaces();
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, seto: *Seto) void {
    switch (event) {
        .global => |global| {
            const event_str = std.meta.stringToEnum(EventInterfaces, mem.span(global.interface)) orelse return;
            switch (event_str) {
                .wl_shm => {
                    seto.shm = registry.bind(global.name, wl.Shm, wl.Shm.generated_version) catch |err| @panic(@errorName(err));
                },
                .wl_compositor => {
                    seto.compositor = registry.bind(global.name, wl.Compositor, wl.Compositor.generated_version) catch |err| @panic(@errorName(err));
                },
                .zwlr_layer_shell_v1 => {
                    seto.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, zwlr.LayerShellV1.generated_version) catch |err| @panic(@errorName(err));
                },
                .wl_output => {
                    const global_output = registry.bind(
                        global.name,
                        wl.Output,
                        wl.Output.generated_version,
                    ) catch |err| @panic(@errorName(err));

                    const compositor = seto.compositor orelse @panic("Compositor not bound");
                    const surface = compositor.createSurface() catch |err| @panic(@errorName(err));

                    const layer_surface = seto.layer_shell.?.getLayerSurface(surface, global_output, .overlay, "seto") catch |err| @panic(@errorName(err));
                    layer_surface.setListener(*Seto, layerSurfaceListener, seto);
                    layer_surface.setAnchor(.{
                        .top = true,
                        .right = true,
                        .bottom = true,
                        .left = true,
                    });
                    layer_surface.setExclusiveZone(-1);
                    layer_surface.setKeyboardInteractivity(.exclusive);
                    surface.commit();

                    const xdg_output = seto.output_manager.?.getXdgOutput(global_output) catch |err| @panic(@errorName(err));

                    const output_info = OutputInfo{ .alloc = seto.alloc, .wl = global_output };
                    const output = Surface.new(surface, layer_surface, seto.alloc, xdg_output, output_info, global.name);

                    xdg_output.setListener(*Seto, xdgOutputListener, seto);

                    seto.outputs.append(output) catch |err| @panic(@errorName(err));
                },
                .wl_seat => {
                    const wl_seat = registry.bind(global.name, wl.Seat, wl.Seat.generated_version) catch |err| @panic(@errorName(err));
                    seto.seat.wl_seat = wl_seat;
                    wl_seat.setListener(*Seto, seatListener, seto);
                },
                .zxdg_output_manager_v1 => {
                    seto.output_manager = registry.bind(
                        global.name,
                        zxdg.OutputManagerV1,
                        zxdg.OutputManagerV1.generated_version,
                    ) catch |err| @panic(@errorName(err));
                },
            }
        },

        .global_remove => |global_removed| {
            for (seto.outputs.items, 0..) |output, i| {
                if (output.name == global_removed.name) _ = seto.outputs.swapRemove(i);
            }
        },
    }
}
