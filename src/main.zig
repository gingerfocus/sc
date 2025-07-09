const std = @import("std");

const Server = @import("Server.zig");
const rpc = @import("rpc.zig");
const sys = @import("sys.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try Args.init(alloc);
    defer args.deinit(alloc);

    switch (args) {
        .server => {
            var server = try Server.init(alloc);
            defer server.deinit();
            try server.run();
        },
        .fg => |id| try fg(alloc, id),
        .bg => |argv| try bg(alloc, argv),
        .kill => |id| try kill(alloc, id),
        .help => {
            std.debug.print("usage: sc [server|fg|bg|kill]\n", .{});
            return;
        },
    }
}

/// Bring a job to the foreground for the current shell.
fn fg(alloc: std.mem.Allocator, id: usize) !void {
    _ = alloc;

    var stream = try std.net.connectUnixSocket(rpc.SOCKET);
    defer stream.close();

    try std.json.stringify(rpc.ServerMsg{ .fg = id }, .{}, stream.writer());

    const stdin = std.io.getStdIn();
    const stdout = std.io.getStdOut();

    var term_settings: sys.termios = undefined;
    _ = sys.tcgetattr(stdin.handle, &term_settings);

    var raw_settings = term_settings;
    sys.cfmakeraw(&raw_settings);

    // TODO the TCSA.NOW might be broken
    _ = sys.tcsetattr(stdin.handle, @intFromEnum(std.posix.TCSA.NOW), &raw_settings);
    defer _ = sys.tcsetattr(stdin.handle, @intFromEnum(std.posix.TCSA.NOW), &term_settings);

    var fds = [_]std.posix.pollfd{
        .{
            .fd = stream.handle,
            .events = std.posix.POLL.IN
            // | std.posix.POLL.RDHUP
            ,
            .revents = 0,
        },
        .{ .fd = stdin.handle, .events = std.posix.POLL.IN, .revents = 0 },
    };

    while (true) {
        _ = std.posix.poll(&fds, -1) catch break;

        var buf: [1024]u8 = undefined;
        if (fds[0].revents == std.posix.POLL.IN) {
            const n = stream.read(&buf) catch break;
            if (n == 0) break;
            _ = stdout.writer().writeAll(buf[0..n]) catch break;
        }
        if (fds[1].revents == std.posix.POLL.IN) {
            const n = std.io.getStdIn().read(&buf) catch break;
            if (n == 0) break;
            _ = stream.writer().writeAll(buf[0..n]) catch break;
        }
    }
}
const BUFFERING = true;

fn bg(alloc: std.mem.Allocator, argv: []const []const u8) !void {
    // std.posix.send()
    var stream = try std.net.connectUnixSocket(rpc.SOCKET);
    defer stream.close();

    var args = std.ArrayList(u8).init(alloc);
    defer args.deinit();
    for (argv) |arg| {
        try args.appendSlice(arg);
        try args.append(' ');
    }

    if (BUFFERING) {
        // == Bufffering
        //
        const cmd = try args.toOwnedSlice();
        defer alloc.free(cmd);
        try std.json.stringify(rpc.ServerMsg{ .bg = cmd }, .{}, args.writer());
        return stream.writeAll(args.items) catch |err| sendError(err);
    } else {
        // == No Bufffering
        //
        return std.json.stringify(rpc.ServerMsg{ .bg = args.items }, .{}, stream.writer()) catch |err| sendError(err);
    }
}

fn sendError(err: anyerror) !void {
    switch (err) {
        error.BrokenPipe => {
            std.log.warn("server disconnected before sending msg", .{});
            return;
        },
        else => |e| return e,
    }
}

fn kill(alloc: std.mem.Allocator, id: usize) !void {
    _ = alloc;

    var stream = try std.net.connectUnixSocket(rpc.SOCKET);
    defer stream.close();

    try std.json.stringify(.{ .kill = id }, .{}, stream.writer());
}

const Args = union(enum) {
    server,
    fg: usize,
    bg: []const []const u8,
    kill: usize,
    help,

    pub fn init(alloc: std.mem.Allocator) !Args {
        const argv = try std.process.argsAlloc(alloc);
        defer std.process.argsFree(alloc, argv);

        if (argv.len < 2) return .help;

        if (std.mem.eql(u8, argv[1], "server")) {
            return .server;
        }
        if (argv.len < 3) return .help;

        if (std.mem.eql(u8, argv[1], "fg")) {
            const id = std.fmt.parseInt(usize, argv[2], 10) catch return .help;
            return .{ .fg = id };
        }

        if (std.mem.eql(u8, argv[1], "bg")) {
            var args = std.ArrayList([]const u8).init(alloc);
            defer args.deinit();

            for (argv[2..]) |arg| {
                const a = try alloc.dupe(u8, arg);
                try args.append(a);
            }

            return .{ .bg = try args.toOwnedSlice() };
        }

        if (std.mem.eql(u8, argv[1], "kill")) {
            const id = std.fmt.parseInt(usize, argv[2], 10) catch return .help;
            return .{ .kill = id };
        }

        return .help;
    }

    pub fn deinit(self: Args, alloc: std.mem.Allocator) void {
        switch (self) {
            .bg => |argv| {
                for (argv) |arg| alloc.free(arg);
                alloc.free(argv);
            },
            else => {},
        }
    }
};
