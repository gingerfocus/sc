const std = @import("std");

// these are not provided by zig, perhaps I could contribute them?

pub fn cfmakeraw(termios: *std.posix.termios) void {
    termios.iflag.IGNBRK = false;
    termios.iflag.BRKINT = false;
    termios.iflag.PARMRK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.INLCR = false;
    termios.iflag.IGNCR = false;
    termios.iflag.ICRNL = false;
    termios.iflag.IXON = false;

    termios.oflag.OPOST = false;

    termios.lflag.ECHO = false;
    termios.lflag.ECHONL = false;
    termios.lflag.ICANON = false;
    termios.lflag.ISIG = false;
    termios.lflag.IEXTEN = false;

    termios.cflag.CSIZE = 8;
    termios.cflag.PARENB = false;
    termios.cflag.CSTOPB = false;

    termios.cc[std.posix.V.MIN] = 1;
    termios.cc[std.posix.V.TIME] = 0;
}

pub fn openpty(amaster: *c_int, aslave: *c_int, bname: ?[*]u8, termp: ?*const std.posix.termios, winp: ?*const std.posix.winsize) c_int {
    var buf: [20]u8 = undefined;

    const m = std.posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch unreachable;
    errdefer std.posix.close(m);

    // var cs: c_int = 0;
    // pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, &cs);
    // defer pthread_setcancelstate(cs, 0);

    var n: usize = 0;

    // check non-zero
    _ = std.os.linux.ioctl(m, std.os.linux.T.IOCSPTLCK, @intFromPtr(&n));
    _ = std.os.linux.ioctl(m, std.os.linux.T.IOCGPTN, @intFromPtr(&n));

    const nameb: [*]u8 = if (bname) |b| b else &buf;
    const name = std.fmt.bufPrint(nameb[0..20], "/dev/pts/{}", .{n}) catch unreachable;

    const s = std.posix.open(name, .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch unreachable;

    if (termp) |tio| _ = std.os.linux.tcsetattr(s, std.os.linux.TCSA.NOW, tio);
    if (winp) |ws| _ = std.os.linux.ioctl(s, std.os.linux.T.IOCSWINSZ, @intFromPtr(ws));

    amaster.* = m;
    aslave.* = s;

    return 0;
}
