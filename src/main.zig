const std = @import("std");
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
});

const Job = struct {
    fd: c_int,
    pid: c_int,
    name: []const u8,
    alloc: std.mem.Allocator,

    pub fn start(
        alloc: std.mem.Allocator,
        // argv: [:null]const ?[*:0]const u8,
        argv: []const []const u8,
    ) !Job {
        var master: c_int = undefined;
        var slave: c_int = undefined;
        var name_buf: [64]u8 = undefined;

        if (c.openpty(&master, &slave, &name_buf, null, null) != 0)
            return error.OpenPTYFailed;

        const nameslice = std.mem.span(@as([*:0]const u8, @ptrCast(&name_buf)));
        const name = alloc.dupe(u8, nameslice) catch |err| {
            std.posix.close(master);
            std.posix.close(slave);
            return err;
        };

        const pid = c.fork();
        if (pid == 0) {
            // Child process
            _ = c.setsid();
            _ = c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0));

            _ = c.dup2(slave, 0);
            _ = c.dup2(slave, 1);
            _ = c.dup2(slave, 2);

            _ = c.close(master);
            _ = c.close(slave);

            const err = std.process.execv(alloc, argv);
            std.debug.print("exec failed: {s}\n", .{@errorName(err)});
            std.posix.exit(1);
        }
        if (pid < 0) return error.ForkFailed;

        std.debug.assert(pid > 0);

        // Parent process
        std.posix.close(slave);

        return Job{
            .fd = master,
            .pid = pid,
            .name = name,
            .alloc = alloc,
        };
    }

    pub fn read(self: *Job, buf: []u8) !usize {
        // cant use posix.read as it doesnt handle below error correctly

        const n = std.c.read(self.fd, buf.ptr, buf.len);

        // I dont know why, but sometimes read returns -1 when child process
        // exits
        if (n == -1) return 0;

        if (n < 0) return error.ReadFailed;

        return @intCast(n);
    }

    pub fn deinit(self: *Job) void {
        self.alloc.free(self.name);
        _ = c.close(self.fd);
        _ = c.waitpid(self.pid, null, 0);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const argv = [_][]const u8{ "/bin/sh", "-c", "echo hello world 2" };
    var job = try Job.start(alloc, &argv);
    defer job.deinit();

    while (true) {
        var buf: [1024]u8 = undefined;
        const n = try job.read(&buf);
        if (n == 0) break;
        _ = try std.io.getStdOut().writeAll(buf[0..n]);
    }
}
