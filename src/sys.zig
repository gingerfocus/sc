const std = @import("std");
const c = @cImport({
    @cInclude("pty.h");
    // @cInclude("unistd.h");
    // @cInclude("fcntl.h");
    // @cInclude("sys/ioctl.h");
    // @cInclude("sys/wait.h");
    @cInclude("termios.h");
});


// std.posix.termios
pub const termios = c.struct_termios;

pub extern fn tcgetattr(fd: std.posix.fd_t, termios_p: *termios) c_int;
// pub const tcgetattr = c.tcgetattr;
pub const cfmakeraw = c.cfmakeraw;
pub const tcsetattr = c.tcsetattr;

pub const openpty = c.openpty;

pub extern fn setsid() std.posix.pid_t;
// pub const setsid = c.setsid;
