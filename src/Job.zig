const std = @import("std");
const Job = @This();

const sys = @import("sys.zig");
const rpc = @import("rpc.zig");

ptyfd: std.posix.fd_t,
fdopen: bool,

pid: c_int,
name: []const u8,
alloc: std.mem.Allocator,
isrunning: bool,

tid: rpc.Id,

const id = struct {
    var static: usize = 1;
    pub fn next() usize {
        const nextid = id.static;
        id.static += 1;
        return nextid;
    }
};

pub fn start(alloc: std.mem.Allocator, argv: []const []const u8) !Job {
    var master: c_int = undefined;
    var slave: c_int = undefined;
    var name_buf: [64]u8 = undefined;
    if (sys.openpty(&master, &slave, &name_buf, null, null) != 0) return error.OpenPTYFailed;

    const nameslice = std.mem.span(@as([*:0]const u8, @ptrCast(&name_buf)));
    const name = alloc.dupe(u8, nameslice) catch |err| {
        std.posix.close(master);
        std.posix.close(slave);
        return err;
    };

    const pid = try std.posix.fork();
    if (pid == 0) {
        _ = std.os.linux.setsid();
        _ = std.os.linux.ioctl(slave, std.os.linux.T.IOCSCTTY, 0);

        try std.posix.dup2(slave, 0);
        try std.posix.dup2(slave, 1);
        try std.posix.dup2(slave, 2);
        std.posix.close(master);
        std.posix.close(slave);

        const err = std.process.execv(alloc, argv);
        std.debug.print("exec failed: {s}\n", .{@errorName(err)});
        std.posix.exit(1);
    }
    if (pid < 0) return error.ForkFailed;
    std.posix.close(slave);

    return Job{
        .ptyfd = master,
        .fdopen = true,
        .pid = pid,
        .name = name,
        .alloc = alloc,
        .isrunning = true,
        .tid = id.next(),
    };
}

pub fn read(self: *Job, buf: []u8) !usize {
    if (!self.isrunning) return error.JobNotRunning;
    if (!self.fdopen) return error.JobNotRunning;

    // cant use std.posix.read() as it doesnt handle pipe errors correctly i think
    const e = std.os.linux.read(self.ptyfd, buf.ptr, buf.len);
    const n: isize = @bitCast(e);

    if (n == -1) return 0;
    if (n < 0) return error.ReadFailed;
    return @intCast(n);
}

pub fn write(self: *Job, buf: []const u8) !usize {
    const n = std.c.write(self.fd, buf.ptr, buf.len);
    if (n < 0) return error.WriteFailed;
    return @intCast(n);
}

fn close(self: *Job) void {
    if (self.fdopen) std.posix.close(self.ptyfd);
}

pub fn kill(self: *Job, sig: u8) !void {
    self.close();

    try std.posix.kill(self.pid, sig);
    self.isrunning = false;
}

pub fn wait(self: *Job, time: usize) !u32 {
    self.close();

    _ = time;
    const res = std.posix.waitpid(self.pid, 0);
    self.isrunning = false;
    return res.status;
}

pub fn deinit(self: *Job) void {
    self.alloc.free(self.name);
    if (self.isrunning) _ = std.posix.waitpid(self.pid, 0);
}
