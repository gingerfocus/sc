const std = @import("std");
const rpc = @import("rpc.zig");
const Job = @import("Job.zig");

const Server = @This();

/// Handle to a task. There are two modes of operation:
///
/// 1. The task is a client connection. In which case, the client will send
///    `ClientMsg` to the server.
///
/// 2. The task is a job connection. In this case, the server will send send
///    updates from the job to the client. In which case the clie
///
/// TODO: rename this
pub const Tasks = struct {
    /// If an event is longer than this, we will cross that bridge later.
    buffer: [256]u8 = undefined,
    /// The amount of data filled in the buffer.
    bindex: usize = 0,

    /// The handle to the client socket. Used for sending data back. This
    /// should be closed.
    client: std.posix.fd_t,

    /// The unique underlying job. This should not be closed as it is in the
    /// jobs list.
    job: ?*Job,

    /// The pollfd for the job. Both input and output. This should never be
    /// closed see the state field.
    pollfd: std.posix.pollfd,
};

/// List of jobs that someone is attached to
tasks: std.MultiArrayList(Tasks),

/// All the jobs that are running, regardless of whether they are active or not.
/// TODO: dont head allocate this
jobs: std.ArrayListUnmanaged(*Job),

alloc: std.mem.Allocator,

pub fn init(alloc: std.mem.Allocator) !Server {
    // std.net.Server
    const server_fd = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0); // | p.SOCK.CLOEXEC

    // Remove previous socket file if it exists
    std.posix.unlink(rpc.SOCKET) catch {};

    var server_addr: std.posix.sockaddr.un = .{
        .path = undefined,
        .family = std.posix.AF.UNIX,
    };
    @memcpy(server_addr.path[0..rpc.SOCKET.len], rpc.SOCKET);
    try std.posix.bind(server_fd, @ptrCast(&server_addr), @sizeOf(std.posix.sockaddr.un));

    // Listen for connections
    try std.posix.listen(server_fd, 5);

    const jobs = std.ArrayListUnmanaged(*Job){};

    var tasks = std.MultiArrayList(Tasks){};
    try tasks.append(alloc, Tasks{
        .client = server_fd,
        .job = null,
        .pollfd = .{
            .fd = server_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    });

    return Server{
        .tasks = tasks,
        .jobs = jobs,
        .alloc = alloc,
    };
}

pub fn deinit(server: *Server) void {
    var slice = server.tasks.slice();
    for (slice.items(.client), slice.items(.job)) |client, job| {
        // only close the client if there is no job
        if (job) |_| {} else std.posix.close(client);
    }
    for (server.jobs.items) |job| {
        job.deinit();
        server.alloc.destroy(job);
    }
    server.jobs.deinit(server.alloc);

    std.posix.unlink(rpc.SOCKET) catch {}; // Clean up socket file

    server.tasks.deinit(server.alloc);
    server.* = undefined;
}

pub fn run(self: *Server) !void {
    std.log.info("starting server", .{});
    while (true) {
        var count = try std.posix.poll(self.tasks.items(.pollfd), -1);
        // std.log.info("polled {d} events", .{count});

        // we will at most append one new task per event
        try self.tasks.ensureUnusedCapacity(self.alloc, count);

        // from this point on this is a stable slice
        const slice = self.tasks.slice();
        defer {
            for (slice.items(.pollfd)) |*fd| fd.revents = 0;
        }

        // Send response to client
        var i: usize = 1;

        while (i < count) : (i += 1) {
            const fd = slice.items(.pollfd)[i];

            std.log.info("revent {d}", .{fd.revents});

            if (fd.revents & std.posix.POLL.HUP != 0) {
                std.log.info("got HUP, removing task", .{});
                self.tasks.swapRemove(i);
                i -= 1;
                continue;
            }

            if (fd.revents & std.posix.POLL.IN == 0) {
                continue;
            }

            std.log.info("checking event {d}", .{i});

            count -= 1;

            if (self.tasks.items(.job)[i]) |job| {
                std.log.info("reading from job", .{});

                const f = std.fs.File{ .handle = self.tasks.items(.client)[i] };
                const writer = f.writer();

                var bufn: [1024]u8 = undefined;
                const n = job.read(&bufn) catch continue;

                if (n == 0) {
                    const code = job.wait(0) catch |err| switch (err) {
                        error.WouldBlock => {
                            job.kill(std.posix.SIG.TERM) catch {};
                            break 0;
                        },
                        else => |e| return e,
                    };

                    std.json.stringify(rpc.ClientMsg{ .exit = code }, .{}, writer) catch {};
                }

                std.json.stringify(rpc.ClientMsg{ .data = bufn[0..n] }, .{}, writer) catch {};

                // read from job and return to client
                continue;
            }

            const client = fd.fd;
            // _ = try std.posix.send(client_fd, "Hello from server!", 0);

            const buffer: *[256]u8 = &slice.items(.buffer)[i];
            const index: *usize = &slice.items(.bindex)[i];

            while (true) {
                const bytes = try std.posix.recv(client, buffer[index.*..], 0);
                if (bytes == 0) break;
                index.* += bytes;

                if (endIndexOfFirstJsonObject(buffer[0..index.*])) |_| break else continue;
            }

            const data = buffer[0..index.*];
            std.log.info("received msg: {s} ", .{data});

            const parsed = std.json.parseFromSlice(rpc.ServerMsg, self.alloc, data, .{}) catch |err| {
                std.log.info("error parsing msg: {s}", .{@errorName(err)});
                return;
            };
            defer parsed.deinit();

            const msg = parsed.value;
            try self.dispatch(client, msg);
        }

        const srv = slice.items(.pollfd)[0];
        // check at end
        if (srv.revents == std.posix.POLL.IN) {
            std.log.info("checking event {d}", .{0});

            count -= 1;
            // var client_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.un);
            // var client_addr: std.posix.sockaddr.un = undefined;

            // Accept client connection
            const client = try std.posix.accept(srv.fd, null, null, 0);

            std.log.info("accepted client: {d}", .{client});
            self.tasks.appendAssumeCapacity(Tasks{
                .client = client,
                .job = null,
                .pollfd = .{
                    .fd = client,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            });
        }
        if (count == 0) {
            std.log.warn("poll said there were more events than we have", .{});
        }
    }
}

pub fn dispatch(self: *Server, client: std.posix.fd_t, msg: rpc.ServerMsg) !void {
    switch (msg) {
        .bg => |cmd| {
            std.log.info("starting job: {s}", .{cmd});

            const job = try self.alloc.create(Job);
            errdefer self.alloc.destroy(job);
            job.* = try Job.start(self.alloc, &.{ "sh", "-c", cmd });

            try self.jobs.append(self.alloc, job);

            std.log.info("new job: {d}", .{job.tid});
            // std.posix.write(client, "{\"bg\":\"ok\"}\n", .{}) catch {};
        },
        .kill => |tid| {
            _ = tid;

            // const job: *Job = self.tasks.items(.job)[i];
            // try job.kill(std.posix.SIG.TERM);
            //
            // defer job.deinit();

            // std.log.debug("job not found: {d}", .{tid});

            // TODO: remove from tasks could be done with swapRemove
            // and a custome index that is not incremented for that
            // loop or keep track of the indexes to remove and then
            // remove them all at once at the en
            // _ = self.jobs.swapRemove(i);
        },
        .fg => |tid| {
            std.log.info("fg: {d}", .{tid});

            var job: *Job = undefined;
            for (self.jobs.items) |ijob| {
                if (ijob.tid == tid) {
                    job = ijob;
                    break;
                }
            } else {
                std.log.info("job not found: {d}", .{tid});
                return;
            }

            std.log.info("adding listening for job: {d}", .{job.tid});
            try self.tasks.append(self.alloc, Tasks{
                .client = client,
                .job = job,
                .pollfd = .{
                    .fd = job.ptyfd,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            });
        },
    }
}

// ----------------------------------------------------------------------------

fn endIndexOfFirstJsonObject(data: []const u8) ?usize {
    // minimum is `{}`
    if (data.len < 2) return null;

    var parens: usize = 0;
    var inquote: bool = false;

    for (data, 0..) |byte, i| {
        if (inquote) {
            if (byte == '"') inquote = false;
            continue;
        } else if (byte == '"') {
            inquote = true;
            continue;
        } else if (byte == '{') {
            parens += 1;
        } else if (byte == '}') {
            if (parens == 0) return null;
            parens -= 1;
            if (parens == 0) return i + 1;
        }
    }
    if (parens == 0)
        return data.len;

    return null;
}

fn testFindSingleCompleteJsonObject(expected: ?[]const u8, data: []const u8) !void {
    const actual = endIndexOfFirstJsonObject(data);
    if (actual) |i| {
        if (expected == null) return error.ExpectedNull;
        try std.testing.expectEqualStrings(expected.?, data[0..i]);
    } else {
        try std.testing.expectEqual(expected, null);
    }
}

test "isCompleteObject" {
    try testFindSingleCompleteJsonObject(
        "{}",
        "{}",
    );
    try testFindSingleCompleteJsonObject(
        "{\"a}\": 1 }",
        "{\"a}\": 1 }",
    );
    try testFindSingleCompleteJsonObject(
        \\{"a":"afaf"}
    ,
        \\{"a":"afaf"}{"b":"bbbb"}{}
    );

    try testFindSingleCompleteJsonObject(null, "{");
    try testFindSingleCompleteJsonObject(null, "{\"a\":1");
    try testFindSingleCompleteJsonObject(null, "{\"a}:");
}
