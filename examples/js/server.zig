const std = @import("std");

var root: std.fs.Dir = undefined;

pub fn main() !void {
    const stdOut_file = std.fs.File.stdout();
    var buf: [1024]u8 = undefined;
    var stdOut = stdOut_file.writer(&buf).interface;

    root = try std.fs.cwd().openDir("./zig-out/", .{ .access_sub_paths = true });
    defer root.close();

    const address = try std.net.Address.parseIp4("127.0.0.1", 8080);
    try stdOut.print("Server available at http://{f}\n", .{address});

    var server = try address.listen(std.net.Address.ListenOptions{ .reuse_address = true });
    defer server.deinit();

    try stdOut.flush();
    accept: while (true) {
        const conn = try server.accept();
        defer conn.stream.close();

        var buffer_rcv: [1024]u8 = undefined;
        var buffer_snd: [1024]u8 = undefined;

        var conn_br = conn.stream.reader(&buffer_rcv);
        var conn_bw = conn.stream.writer(&buffer_snd);
        var http_server = std.http.Server.init(conn_br.interface(), &conn_bw.interface);

        while (http_server.reader.state == .ready) {
            var request = http_server.receiveHead() catch |err| switch (err) {
                error.HttpConnectionClosing => continue :accept,
                else => |e| return e,
            };
            handleRequest(&request) catch continue :accept;
        }
    }
}

fn handleRequest(req: *std.http.Server.Request) !void {
    var path = req.head.target[1..];
    if (path.len == 0) path = "index.html";

    std.debug.print("Requesting ({t}): {s}\n", .{ req.head.method, path });

    const file = root.openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return req.respond("File not found\n", .{ .status = .not_found }),
        error.IsDir => return req.respond("Can't open dir", .{ .status = .bad_request }),
        else => {
            try req.respond("err", .{ .status = .internal_server_error });
            return err;
        },
    };

    const stat = file.stat() catch |err| {
        try req.respond("err", .{ .status = .internal_server_error });
        return err;
    };

    const extension = path[std.mem.lastIndexOf(u8, path, ".") orelse 0 ..];
    const contentType = mimeTypes.get(extension) orelse "text/plain";

    var buf: [4096]u8 = undefined;
    var file_buf: [4096]u8 = undefined;
    var file_reader = file.reader(&file_buf);

    var bodyW = try req.respondStreaming(&buf, .{ .content_length = stat.size, .respond_options = .{ .extra_headers = &.{.{ .name = "Content-Type", .value = contentType }} } });

    _ = try bodyW.writer.sendFileAll(&file_reader, .unlimited);
    try bodyW.flush();

    try bodyW.end();
}

const mimeTypes = std.StaticStringMap([]const u8).initComptime(.{
    .{ ".wasm", "application/wasm" },
    .{ ".js", "text/javascript" },
    .{ ".html", "text/html" },
});
