/// Messages sent from the client to the server.
pub const ServerMsg = union(enum) {
    bg: []const u8,
    fg: Id,
    kill: Id,

    // Kys.
    // close: void,
};

/// Messages sent from the server to the client.
pub const ClientMsg = union(enum) {
    /// Sent by a server to deliver new data to a client
    data: []const u8,

    /// Sent by a server when a new job is started
    spawn: Id,

    /// Sent in response to an invalid client message
    err: []const u8,

    /// Sent to signal a job exited
    exit: u32,
};

/// A job ID. Different from pid.
pub const Id = usize;

/// The path to the socket file.
pub const SOCKET = "/tmp/sc.sock";
