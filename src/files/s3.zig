//! S3-compatible object storage client + spool-cached Storage backend (§D). Compiled ONLY
//! under -Ds3 (conditional @import in framework.zig/root.zig). Pure Zig: the shared
//! http_client + the aws/sigv4 signer. Key layout mirrors local disk:
//! `<prefix><col>/<rid>/<filename>` (col/rid are validated ids, filename is a
//! naming-sanitized stored name; keys are additionally UriEncoded per SigV4).
//!
//! `S3Storage` (the vtable impl on top of `Client`) lands in Task 12; this file currently
//! carries only the SigV4-signed request ops (put/get/delete/head/list).
const std = @import("std");
const config = @import("../config.zig");
const files_storage = @import("storage.zig");
const sigv4 = @import("../aws/sigv4.zig");
const http_client = @import("../http_client.zig");
const clock = @import("../clock.zig");
const testcapture = @import("../testcapture.zig");
const mime = @import("mime.zig");

pub const Client = struct {
    bucket: []const u8,
    region: []const u8,
    /// Host (no scheme) + scheme split out of cfg.s3_endpoint; defaults to
    /// s3.<region>.amazonaws.com over https.
    host: []const u8,
    scheme: []const u8, // "https" | "http" (http = loud startup warning, MinIO dev/CI)
    access_key: []const u8,
    secret_key: []const u8,
    key_prefix: []const u8,
    path_style: bool,

    /// Resolve endpoint defaults: "" endpoint => https://s3.<region>.amazonaws.com
    /// (virtual-hosted addressing unless forced); an explicit endpoint (MinIO/R2) =>
    /// its scheme + host, PATH-STYLE by default. `host_storage` receives the derived
    /// default host string when no endpoint is set (the Client borrows it; all other
    /// fields borrow cfg, which outlives the server).
    pub fn init(cfg: config.Config, host_storage: []u8) Client {
        var scheme: []const u8 = "https";
        var host: []const u8 = undefined;
        if (cfg.s3_endpoint.len > 0) {
            var ep = cfg.s3_endpoint;
            if (std.mem.startsWith(u8, ep, "http://")) {
                scheme = "http"; // loud dev-only warning happens in S3Storage.create
                ep = ep["http://".len..];
            } else if (std.mem.startsWith(u8, ep, "https://")) {
                ep = ep["https://".len..];
            }
            host = std.mem.trimEnd(u8, ep, "/");
        } else {
            host = std.fmt.bufPrint(host_storage, "s3.{s}.amazonaws.com", .{cfg.s3_region}) catch
                unreachable; // region is a short AWS identifier; 256 bytes cannot overflow
        }
        return .{
            .bucket = cfg.s3_bucket,
            .region = cfg.s3_region,
            .host = host,
            .scheme = scheme,
            .access_key = cfg.s3_access_key_id,
            .secret_key = cfg.s3_secret_access_key,
            .key_prefix = cfg.s3_key_prefix,
            .path_style = cfg.s3_force_path_style orelse (cfg.s3_endpoint.len > 0),
        };
    }

    /// "<prefix><col>/<rid>/<name>" — the object key (unencoded; the signer encodes).
    /// `self` first (like every other `Client` method) so `client.objectKey(alloc, …)`
    /// works via method-call syntax.
    pub fn objectKey(self: Client, alloc: std.mem.Allocator, col: []const u8, rid: []const u8, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(alloc, "{s}{s}/{s}/{s}", .{ self.key_prefix, col, rid, name });
    }

    /// Request path for `key`: path-style => "/<bucket>/<key>"; virtual-hosted =>
    /// "/<key>" (the bucket rides the host instead — see effectiveHost).
    fn requestPath(alloc: std.mem.Allocator, self: Client, key: []const u8) ![]const u8 {
        return if (self.path_style)
            std.fmt.allocPrint(alloc, "/{s}/{s}", .{ self.bucket, key })
        else
            std.fmt.allocPrint(alloc, "/{s}", .{key});
    }

    /// Request path for the bucket itself (no key) — used by `listKeys`.
    fn bucketPath(alloc: std.mem.Allocator, self: Client) ![]const u8 {
        return if (self.path_style)
            std.fmt.allocPrint(alloc, "/{s}", .{self.bucket})
        else
            alloc.dupe(u8, "/");
    }

    /// Host to sign + dial: path-style => the endpoint host; virtual-hosted =>
    /// "<bucket>.<host>".
    fn effectiveHost(alloc: std.mem.Allocator, self: Client) ![]const u8 {
        return if (self.path_style)
            alloc.dupe(u8, self.host)
        else
            std.fmt.allocPrint(alloc, "{s}.{s}", .{ self.bucket, self.host });
    }

    /// `{scheme}://{effective_host}{UriEncoded path}` (+ `?query` when non-empty). The
    /// `path` handed to the signer stays RAW — `signRequest` UriEncodes it internally.
    fn buildUrl(alloc: std.mem.Allocator, self: Client, host: []const u8, path: []const u8, query: []const u8) ![]const u8 {
        const encoded_path = try sigv4.uriEncodePath(alloc, path);
        defer alloc.free(encoded_path);
        return if (query.len == 0)
            std.fmt.allocPrint(alloc, "{s}://{s}{s}", .{ self.scheme, host, encoded_path })
        else
            std.fmt.allocPrint(alloc, "{s}://{s}{s}?{s}", .{ self.scheme, host, encoded_path, query });
    }

    /// Sign one request: `x-amz-content-sha256` is always signed (S3 requires it);
    /// `content_type`, when given, is also signed (put only). Returns the formatted
    /// `X-Amz-Date` value + the `Authorization` header value (caller frees the latter).
    fn sign(
        self: Client,
        alloc: std.mem.Allocator,
        io: std.Io,
        method: []const u8,
        host: []const u8,
        path: []const u8,
        query: []const u8,
        payload_sha256: []const u8,
        content_type: ?[]const u8,
    ) !struct { amz_date: AmzDateBuf, authorization: []const u8 } {
        const amz_date = amzDate(clock.nowUnix(io));
        var headers_buf: [2]sigv4.Header = undefined;
        var n: usize = 0;
        if (content_type) |ct| {
            headers_buf[n] = .{ .name = "content-type", .value = ct };
            n += 1;
        }
        headers_buf[n] = .{ .name = "x-amz-content-sha256", .value = payload_sha256 };
        n += 1;
        const authorization = try sigv4.signRequest(alloc, .{
            .access_key = self.access_key,
            .secret_key = self.secret_key,
            .region = self.region,
            .service = "s3",
            .method = method,
            .host = host,
            .path = path,
            .query = query,
            .headers = headers_buf[0..n],
            .payload_sha256 = payload_sha256,
            .amz_date = &amz_date,
        });
        return .{ .amz_date = amz_date, .authorization = authorization };
    }

    /// PUT the object at `key`. Retries ONCE on a transport error or a 5xx response
    /// (idempotent); any other non-200 status is a terminal `error.S3RequestFailed`.
    pub fn put(self: Client, io: std.Io, alloc: std.mem.Allocator, key: []const u8, bytes: []const u8, content_type: []const u8) !void {
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            const status = self.putOnce(io, alloc, key, bytes, content_type) catch |err| {
                if (attempt == 0) continue;
                return err;
            };
            if (status == 200) return;
            if (status >= 500 and attempt == 0) continue;
            return error.S3RequestFailed;
        }
    }

    fn putOnce(self: Client, io: std.Io, alloc: std.mem.Allocator, key: []const u8, bytes: []const u8, content_type: []const u8) !u16 {
        const path = try requestPath(alloc, self, key);
        defer alloc.free(path);
        const host = try effectiveHost(alloc, self);
        defer alloc.free(host);
        const url = try buildUrl(alloc, self, host, path, "");
        defer alloc.free(url);

        const payload_hash = try sigv4.sha256Hex(alloc, bytes);
        defer alloc.free(payload_hash);
        const signed = try self.sign(alloc, io, "PUT", host, path, "", payload_hash, content_type);
        defer alloc.free(signed.authorization);

        var client = http_client.HttpClient{ .alloc = alloc, .io = io };
        const res = try client.request(.{
            .method = .PUT,
            .url = url,
            .headers = &.{
                .{ .name = "Content-Type", .value = content_type },
                .{ .name = "X-Amz-Date", .value = &signed.amz_date },
                .{ .name = "X-Amz-Content-Sha256", .value = payload_hash },
                .{ .name = "Authorization", .value = signed.authorization },
            },
            .body = bytes,
        });
        return res.status;
    }

    /// GET the object at `key`, streaming the body through `w`. Returns the raw HTTP
    /// status for anything below 500 (the caller — S3Storage's fetch — interprets 404
    /// etc.); retries ONCE on a transport error or a 5xx response, then
    /// `error.S3RequestFailed`.
    ///
    /// `w` receives bytes ONLY for the response that is ultimately accepted (status <
    /// 500): a 5xx attempt's error body is discarded by `getOnce` before any byte
    /// reaches `w`, so a retry never appends to or duplicates data in `w`. Once `w` has
    /// started receiving the real body, a failure is no longer retried — `getOnce` can
    /// return `error.StreamInterrupted` (transport broke mid-body, `w` may hold a
    /// partial body) or `error.WriteFailed` (the destination `w` itself failed, e.g.
    /// disk full) — both are propagated immediately since retrying would write into an
    /// already-compromised sink.
    pub fn getToWriter(self: Client, io: std.Io, alloc: std.mem.Allocator, key: []const u8, w: *std.Io.Writer) !u16 {
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            const status = self.getOnce(io, alloc, key, w) catch |err| {
                if (err == error.StreamInterrupted or err == error.WriteFailed) return err;
                if (attempt == 0) continue;
                return err;
            };
            if (status < 500) return status;
            if (attempt == 0) continue;
            return error.S3RequestFailed;
        }
    }

    fn getOnce(self: Client, io: std.Io, alloc: std.mem.Allocator, key: []const u8, w: *std.Io.Writer) !u16 {
        const path = try requestPath(alloc, self, key);
        defer alloc.free(path);
        const host = try effectiveHost(alloc, self);
        defer alloc.free(host);
        const url = try buildUrl(alloc, self, host, path, "");
        defer alloc.free(url);

        const payload_hash = try sigv4.sha256Hex(alloc, "");
        defer alloc.free(payload_hash);
        const signed = try self.sign(alloc, io, "GET", host, path, "", payload_hash, null);
        defer alloc.free(signed.authorization);

        var client = http_client.HttpClient{ .alloc = alloc, .io = io };
        const res = try client.download(.{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "X-Amz-Date", .value = &signed.amz_date },
                .{ .name = "X-Amz-Content-Sha256", .value = payload_hash },
                .{ .name = "Authorization", .value = signed.authorization },
            },
            // A 5xx body is discarded before it reaches `w` — see getToWriter's docs.
            .discard_body_status = 500,
        }, w);
        return res.status;
    }

    /// DELETE the object at `key`. Best-effort: 204/200/404 (already gone) all count as
    /// success. No retry (delete is not on the retry list).
    pub fn delete(self: Client, io: std.Io, alloc: std.mem.Allocator, key: []const u8) !void {
        const path = try requestPath(alloc, self, key);
        defer alloc.free(path);
        const host = try effectiveHost(alloc, self);
        defer alloc.free(host);
        const url = try buildUrl(alloc, self, host, path, "");
        defer alloc.free(url);

        const payload_hash = try sigv4.sha256Hex(alloc, "");
        defer alloc.free(payload_hash);
        const signed = try self.sign(alloc, io, "DELETE", host, path, "", payload_hash, null);
        defer alloc.free(signed.authorization);

        var client = http_client.HttpClient{ .alloc = alloc, .io = io };
        const res = try client.request(.{
            .method = .DELETE,
            .url = url,
            .headers = &.{
                .{ .name = "X-Amz-Date", .value = &signed.amz_date },
                .{ .name = "X-Amz-Content-Sha256", .value = payload_hash },
                .{ .name = "Authorization", .value = signed.authorization },
            },
        });
        if (res.status == 204 or res.status == 200 or res.status == 404) return;
        return error.S3RequestFailed;
    }

    /// HEAD the object at `key`. Returns the raw HTTP status (200/404/403/...) — the
    /// caller interprets it (existence probe). No retry.
    pub fn head(self: Client, io: std.Io, alloc: std.mem.Allocator, key: []const u8) !u16 {
        const path = try requestPath(alloc, self, key);
        defer alloc.free(path);
        const host = try effectiveHost(alloc, self);
        defer alloc.free(host);
        const url = try buildUrl(alloc, self, host, path, "");
        defer alloc.free(url);

        const payload_hash = try sigv4.sha256Hex(alloc, "");
        defer alloc.free(payload_hash);
        const signed = try self.sign(alloc, io, "HEAD", host, path, "", payload_hash, null);
        defer alloc.free(signed.authorization);

        var client = http_client.HttpClient{ .alloc = alloc, .io = io };
        const res = try client.request(.{
            .method = .HEAD,
            .url = url,
            .headers = &.{
                .{ .name = "X-Amz-Date", .value = &signed.amz_date },
                .{ .name = "X-Amz-Content-Sha256", .value = payload_hash },
                .{ .name = "Authorization", .value = signed.authorization },
            },
        });
        return res.status;
    }

    /// List every key under `prefix`, following ListObjectsV2 continuation tokens.
    /// Caller owns the slice and every key. A reusable page arena bounds response
    /// scratch by its high-water mark even when the caller uses an outer arena.
    pub fn listKeys(self: Client, io: std.Io, alloc: std.mem.Allocator, prefix: []const u8) ![][]const u8 {
        var keys: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (keys.items) |key| alloc.free(key);
            keys.deinit(alloc);
        }
        var tokens: std.StringHashMapUnmanaged(void) = .empty;
        defer {
            var it = tokens.keyIterator();
            while (it.next()) |token| alloc.free(token.*);
            tokens.deinit(alloc);
        }
        var continuation: ?[]const u8 = null;
        var page = std.heap.ArenaAllocator.init(alloc);
        defer page.deinit();
        while (true) {
            _ = page.reset(.retain_capacity);
            const xml = try self.listPage(io, page.allocator(), prefix, continuation, null);
            const page_keys = try scanKeys(page.allocator(), xml);
            for (page_keys) |key| {
                // Never let an unexpected listing response widen record cleanup.
                if (!std.mem.startsWith(u8, key, prefix)) return error.S3InvalidListResponse;
                const owned = try alloc.dupe(u8, key);
                errdefer alloc.free(owned);
                try keys.append(alloc, owned);
            }
            const truncated = (try xmlText(xml, "IsTruncated")) orelse return error.S3InvalidListResponse;
            if (std.mem.eql(u8, truncated, "false")) return keys.toOwnedSlice(alloc);
            if (!std.mem.eql(u8, truncated, "true")) return error.S3InvalidListResponse;
            const raw_token = (try xmlText(xml, "NextContinuationToken")) orelse return error.S3InvalidListResponse;
            const token = try decodeXmlText(alloc, raw_token);
            errdefer alloc.free(token);
            if (token.len == 0 or tokens.contains(token)) return error.S3InvalidListResponse;
            try tokens.put(alloc, token, {});
            continuation = token;
        }
    }

    /// Response body borrows the supplied page arena (HttpClient's response contract).
    fn listPage(self: Client, io: std.Io, alloc: std.mem.Allocator, prefix: []const u8, continuation: ?[]const u8, limit: ?u16) ![]const u8 {
        const path = try bucketPath(alloc, self);
        defer alloc.free(path);
        const host = try effectiveHost(alloc, self);
        defer alloc.free(host);

        const encoded_prefix = try uriEncodeQueryValue(alloc, prefix);
        defer alloc.free(encoded_prefix);
        const encoded_token = if (continuation) |token| try uriEncodeQueryValue(alloc, token) else "";
        defer if (continuation != null) alloc.free(encoded_token);
        const max_keys = if (limit) |n| try std.fmt.allocPrint(alloc, "&max-keys={d}", .{n}) else "";
        defer if (limit != null) alloc.free(max_keys);
        const query = if (continuation != null)
            try std.fmt.allocPrint(alloc, "continuation-token={s}&list-type=2{s}&prefix={s}", .{ encoded_token, max_keys, encoded_prefix })
        else
            try std.fmt.allocPrint(alloc, "list-type=2{s}&prefix={s}", .{ max_keys, encoded_prefix });
        defer alloc.free(query);

        const url = try buildUrl(alloc, self, host, path, query);
        defer alloc.free(url);

        const payload_hash = try sigv4.sha256Hex(alloc, "");
        defer alloc.free(payload_hash);
        const signed = try self.sign(alloc, io, "GET", host, path, query, payload_hash, null);
        defer alloc.free(signed.authorization);

        var client = http_client.HttpClient{ .alloc = alloc, .io = io };
        const res = try client.request(.{
            .method = .GET,
            .url = url,
            .headers = &.{
                .{ .name = "X-Amz-Date", .value = &signed.amz_date },
                .{ .name = "X-Amz-Content-Sha256", .value = payload_hash },
                .{ .name = "Authorization", .value = signed.authorization },
            },
        });
        if (res.status != 200) return error.S3RequestFailed;
        if (std.mem.indexOf(u8, res.body, "</ListBucketResult>") == null) return error.S3InvalidListResponse;
        return res.body;
    }

    /// Presign a GET URL for `key` (SigV4 query-string signing). Builds the effective host +
    /// request path exactly like every other op (path-style vs virtual-hosted addressing) and
    /// delegates to `sigv4.presignGetUrl` with an `X-Amz-Date` of "now". Caller owns the returned
    /// URL. NOT best-effort: a signing failure propagates (the serve path decides what to do).
    pub fn presignGet(self: Client, io: std.Io, alloc: std.mem.Allocator, key: []const u8, expires_seconds: u32) ![]const u8 {
        const path = try requestPath(alloc, self, key);
        defer alloc.free(path);
        const host = try effectiveHost(alloc, self);
        defer alloc.free(host);
        const amz = amzDate(clock.nowUnix(io));
        return sigv4.presignGetUrl(alloc, .{
            .access_key = self.access_key,
            .secret_key = self.secret_key,
            .region = self.region,
            .service = "s3",
            .host = host,
            .path = path,
            .amz_date = &amz,
            .expires_seconds = expires_seconds,
            .scheme = self.scheme, // http for a MinIO/dev endpoint; https otherwise
        });
    }
};

const AmzDateBuf = [16]u8; // "YYYYMMDDTHHMMSSZ" — 16 ASCII bytes

/// Format a unix timestamp as the SigV4 `X-Amz-Date` value `YYYYMMDDTHHMMSSZ` (UTC).
/// Copied from `mail/ses.zig`'s `amzDate` — small enough not to be worth sharing a module.
fn amzDate(ts: i64) AmzDateBuf {
    const epoch_secs = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(ts, 0)) };
    const day_secs = epoch_secs.getDaySeconds();
    const epoch_day = epoch_secs.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    var buf: AmzDateBuf = undefined;
    _ = std.fmt.bufPrint(&buf, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        @as(u32, month_day.day_index) + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    }) catch unreachable;
    return buf;
}

/// UriEncode a query VALUE: same as `sigv4.uriEncodePath`'s table but additionally
/// percent-encodes '/' (S3's canonical-query-string rules do not exempt it the way the
/// path rules do).
fn uriEncodeQueryValue(alloc: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (value) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '-' or c == '.' or c == '_' or c == '~';
        if (unreserved) {
            try out.append(alloc, c);
        } else {
            try out.print(alloc, "%{X:0>2}", .{c});
        }
    }
    return out.toOwnedSlice(alloc);
}

/// One bounded ListObjectsV2 page; keys are relative to the configured prefix.
/// Owned result; malformed/oversized pages fail instead of reporting partial usage.
fn inventoryFromXml(alloc: std.mem.Allocator, xml: []const u8, prefix: []const u8, cursor: ?[]const u8, limit: u16) !files_storage.Storage.InventoryPage {
    var items: std.ArrayList(files_storage.Storage.InventoryItem) = .empty;
    errdefer {
        for (items.items) |item| alloc.free(item.key);
        items.deinit(alloc);
    }
    var rest = xml;
    while (std.mem.indexOf(u8, rest, "<Contents>")) |start| {
        rest = rest[start + "<Contents>".len ..];
        const end = std.mem.indexOf(u8, rest, "</Contents>") orelse return error.S3InvalidListResponse;
        if (items.items.len >= limit) return error.S3InvalidListResponse;
        const raw_key = (try xmlText(rest[0..end], "Key")) orelse return error.S3InvalidListResponse;
        const full_key = try decodeXmlText(alloc, raw_key);
        defer alloc.free(full_key);
        if (!std.mem.startsWith(u8, full_key, prefix)) return error.S3InvalidListResponse;
        const raw_size = (try xmlText(rest[0..end], "Size")) orelse return error.S3InvalidListResponse;
        const size = std.fmt.parseInt(u64, raw_size, 10) catch return error.S3InvalidListResponse;
        const key = try alloc.dupe(u8, full_key[prefix.len..]);
        errdefer alloc.free(key);
        try items.append(alloc, .{ .key = key, .bytes = size });
        rest = rest[end + "</Contents>".len ..];
    }
    const truncated = (try xmlText(xml, "IsTruncated")) orelse return error.S3InvalidListResponse;
    var next: ?[]const u8 = null;
    errdefer if (next) |value| alloc.free(value);
    if (std.mem.eql(u8, truncated, "true")) {
        next = try decodeXmlText(alloc, (try xmlText(xml, "NextContinuationToken")) orelse return error.S3InvalidListResponse);
        if (next.?.len == 0 or next.?.len > 4096 or (cursor != null and std.mem.eql(u8, cursor.?, next.?))) return error.S3InvalidListResponse;
    } else if (!std.mem.eql(u8, truncated, "false")) return error.S3InvalidListResponse;
    return .{ .items = try items.toOwnedSlice(alloc), .nextCursor = next };
}

/// Extract an S3 scalar element without accepting nested markup or a truncated tag.
fn xmlText(xml: []const u8, comptime tag: []const u8) !?[]const u8 {
    const open = "<" ++ tag ++ ">";
    const close = "</" ++ tag ++ ">";
    const start = std.mem.indexOf(u8, xml, open) orelse return null;
    const rest = xml[start + open.len ..];
    const end = std.mem.indexOf(u8, rest, close) orelse return error.S3InvalidListResponse;
    if (std.mem.indexOfScalar(u8, rest[0..end], '<') != null) return error.S3InvalidListResponse;
    return rest[0..end];
}

/// XML character data, not a general XML parser: no DTDs or external entities.
/// Self-freeing scratch; caller owns the decoded string.
fn decodeXmlText(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            if (raw[i] == '<') return error.S3InvalidListResponse;
            try out.append(alloc, raw[i]);
            i += 1;
            continue;
        }
        const end = std.mem.indexOfScalarPos(u8, raw, i, ';') orelse return error.S3InvalidListResponse;
        const entity = raw[i + 1 .. end];
        const cp: u21 = if (std.mem.eql(u8, entity, "amp")) '&' else if (std.mem.eql(u8, entity, "lt")) '<' else if (std.mem.eql(u8, entity, "gt")) '>' else if (std.mem.eql(u8, entity, "quot")) '"' else if (std.mem.eql(u8, entity, "apos")) '\'' else if (std.mem.startsWith(u8, entity, "#x"))
            std.fmt.parseInt(u21, entity[2..], 16) catch return error.S3InvalidListResponse
        else if (std.mem.startsWith(u8, entity, "#"))
            std.fmt.parseInt(u21, entity[1..], 10) catch return error.S3InvalidListResponse
        else
            return error.S3InvalidListResponse;
        if (cp == 0) return error.S3InvalidListResponse;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return error.S3InvalidListResponse;
        try out.appendSlice(alloc, buf[0..n]);
        i = end + 1;
    }
    return out.toOwnedSlice(alloc);
}

/// Bounded scalar extraction for ListObjectsV2. Reject malformed key elements
/// instead of treating a partial listing as successful cleanup.
fn scanKeys(alloc: std.mem.Allocator, xml: []const u8) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |k| alloc.free(k);
        out.deinit(alloc);
    }
    var rest = xml;
    while (std.mem.indexOf(u8, rest, "<Key>")) |start| {
        rest = rest[start + "<Key>".len ..];
        const end = std.mem.indexOf(u8, rest, "</Key>") orelse return error.S3InvalidListResponse;
        const key = try decodeXmlText(alloc, rest[0..end]);
        errdefer alloc.free(key);
        try out.append(alloc, key);
        rest = rest[end + "</Key>".len ..];
    }
    return out.toOwnedSlice(alloc);
}

pub const S3Storage = struct {
    gpa: std.mem.Allocator,
    client: Client,
    cache_dir: []const u8, // owned
    cache_max_bytes: u64,
    /// Owned heap buffer backing `Client.init`'s derived default host string.
    /// Deliberately heap (not a struct-embedded array): `create` returns `S3Storage`
    /// BY VALUE (the caller stores it into a union field — see `DefaultStoragePlugin`),
    /// and a stack-array-backed slice would dangle across that move. A heap buffer's
    /// address stays valid no matter how many times the surrounding struct is copied.
    host_buf: []u8,

    /// §D.7 startup (fail-fast): config validation, the 5 GiB single-PUT guard, then a
    /// HeadObject PROBE on `<prefix>.zigbase/probe` — 200 OR 404 proves DNS/TLS/SigV4/
    /// bucket/permissions end-to-end (404 expected; it needs exactly the permission
    /// serving needs); 403/301/5xx/connect-failure => refuse to start (the JWT-secret /
    /// FieldKeyRequired precedent). Deliberately a NEW precedent vs SMTP (no probe
    /// there): storage sits on the synchronous request path; mail is queued+retryable.
    ///
    /// The actual validation (`validateConfig`) and network probe (`probe`) are
    /// deliberately logging-free so they stay directly unit-testable — a `std.log.err`
    /// call trips the test runner's `log_err_count` gate and fails the build even when
    /// every assertion passes (the `liveEncryptedCollection` precedent in framework.zig:
    /// "Logging lives in the caller so this stays a pure, unit-testable scan"). `create`
    /// is the thin, logging integration wrapper around both.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: config.Config) !S3Storage {
        validateConfig(cfg) catch |err| {
            switch (err) {
                error.S3ConfigMissing => if (cfg.s3_access_key_id.len == 0)
                    std.log.err("refusing to start: ZIGBASE_S3_BUCKET is set but ZIGBASE_S3_ACCESS_KEY_ID is empty", .{})
                else
                    std.log.err("refusing to start: ZIGBASE_S3_BUCKET is set but ZIGBASE_S3_SECRET_ACCESS_KEY is empty", .{}),
                error.S3UploadCapTooLarge => std.log.err("refusing to start: ZIGBASE_MAX_UPLOAD_SIZE ({d}) exceeds the S3 single-PUT limit of 5 GiB", .{cfg.max_upload_size}),
                error.S3ConfigInvalid => std.log.err("refusing to start: ZIGBASE_S3_BUCKET/REGION/ENDPOINT/KEY_PREFIX/ACCESS_KEY_ID/SECRET_ACCESS_KEY must not contain CR or LF", .{}),
            }
            return err;
        };

        const cache_dir = if (cfg.s3_cache_dir.len > 0)
            try gpa.dupe(u8, cfg.s3_cache_dir)
        else
            try std.fmt.allocPrint(gpa, "{s}/storage_cache", .{cfg.data_dir});
        errdefer gpa.free(cache_dir);
        const host_buf = try gpa.alloc(u8, 256);
        errdefer gpa.free(host_buf);

        var self = S3Storage{
            .gpa = gpa,
            .client = undefined,
            .cache_dir = cache_dir,
            .cache_max_bytes = cfg.s3_cache_max_bytes,
            .host_buf = host_buf,
        };
        self.client = Client.init(cfg, self.host_buf);
        if (std.mem.eql(u8, self.client.scheme, "http")) {
            std.log.warn("S3 endpoint {s} is PLAIN HTTP — credentials and objects transit unencrypted; dev/CI only", .{cfg.s3_endpoint});
        }

        self.probe(io) catch |e| {
            std.log.err("refusing to start: S3 HeadObject probe to {s} failed ({s}) — check endpoint/DNS/TLS/credentials/bucket/region/permissions", .{ self.client.host, @errorName(e) });
            return error.S3ProbeFailed;
        };
        return self;
    }

    /// Config validation, no I/O and no logging (see `create`'s doc comment).
    fn validateConfig(cfg: config.Config) !void {
        if (cfg.s3_access_key_id.len == 0) return error.S3ConfigMissing;
        if (cfg.s3_secret_access_key.len == 0) return error.S3ConfigMissing;
        inline for (.{ cfg.s3_bucket, cfg.s3_region, cfg.s3_endpoint, cfg.s3_key_prefix, cfg.s3_access_key_id, cfg.s3_secret_access_key }) |v| {
            if (std.mem.indexOfAny(u8, v, "\r\n") != null) return error.S3ConfigInvalid;
        }
        // Request bodies are capped by the zap listener (ZIGBASE_MAX_UPLOAD_SIZE);
        // a single PutObject tops out at 5 GiB — fail fast so the gap can never
        // silently open (multipart upload is an explicit non-goal this round).
        if (cfg.max_upload_size > (5 << 30)) return error.S3UploadCapTooLarge;
    }

    /// HeadObject on `<prefix>.zigbase/probe`; 200 or 404 both prove the round trip
    /// worked end-to-end — 404 is the *expected* outcome (the probe object need not
    /// exist; it needs exactly the permission serving needs). No I/O-error handling
    /// beyond propagating it, and no logging (see `create`'s doc comment).
    fn probe(self: S3Storage, io: std.Io) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const probe_key = try std.fmt.allocPrint(arena.allocator(), "{s}.zigbase/probe", .{self.client.key_prefix});
        const status = try self.client.head(io, arena.allocator(), probe_key);
        if (status != 200 and status != 404) return error.S3ProbeFailed;
    }

    pub fn storage(self: *S3Storage) files_storage.Storage {
        return .{ .ctx = self, .vtable = &vtable };
    }

    pub fn deinit(self: *S3Storage) void {
        self.gpa.free(self.cache_dir);
        self.gpa.free(self.host_buf);
    }

    const vtable = files_storage.Storage.VTable{
        .inventory = if (@import("build_options").file_inventory) inventoryImpl else null,
        .put = putImpl,
        .fetch = fetchImpl,
        .delete = deleteImpl,
        .deleteRecord = deleteRecordImpl,
        .presignGetUrl = presignGetUrlImpl,
    };

    fn inventoryImpl(ctx: *anyopaque, io: std.Io, alloc: std.mem.Allocator, cursor: ?[]const u8, limit: u16) !files_storage.Storage.InventoryPage {
        const self: *S3Storage = @ptrCast(@alignCast(ctx));
        var scratch = std.heap.ArenaAllocator.init(alloc);
        defer scratch.deinit();
        const xml = try self.client.listPage(io, scratch.allocator(), self.client.key_prefix, cursor, limit);
        return inventoryFromXml(alloc, xml, self.client.key_prefix, cursor, limit);
    }

    /// Presign a time-limited GET URL for the object so api/files.serve can 302-redirect instead of
    /// spooling+streaming the bytes. Reuses the SigV4 query-string signer over the same object key
    /// as `fetch`. Non-null on S3; a signing failure propagates (not best-effort).
    fn presignGetUrlImpl(ctx: *anyopaque, io: std.Io, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8, expires_seconds: u32) anyerror!?[]const u8 {
        const self: *S3Storage = @ptrCast(@alignCast(ctx));
        const key = try self.client.objectKey(alloc, col, record_id, filename);
        defer alloc.free(key);
        return try self.client.presignGet(io, alloc, key, expires_seconds);
    }

    /// PutObject with Content-Type from content sniffing (stored as object metadata).
    /// HTTP record handlers upload before acquiring the writer and only commit
    /// references after successful validation; failed requests best-effort remove
    /// these immutable names. Retry-once lives in `Client.put`.
    fn putImpl(ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8, bytes: []const u8) anyerror!void {
        const self: *S3Storage = @ptrCast(@alignCast(ctx));
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const key = try self.client.objectKey(a, col, record_id, filename);
        try self.client.put(io, a, key, bytes, mime.sniff(bytes));
    }

    /// §D.6 spool: cache hit -> path; miss -> stream GetObject to a .tmp<rand> then
    /// atomically rename (a concurrently-served reader can never see a partial file;
    /// concurrent misses may download twice — both renames idempotent, no
    /// singleflight). Stored names are content-immutable -> no invalidation problem.
    /// 404 from S3 -> null (the backend has no such object); other failures error.
    fn fetchImpl(ctx: *anyopaque, io: std.Io, alloc: std.mem.Allocator, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!?[]const u8 {
        const self: *S3Storage = @ptrCast(@alignCast(ctx));
        const path = try std.fs.path.join(alloc, &.{ self.cache_dir, col, record_id, filename });
        // `path` is the caller's to free on every non-success exit (a non-arena consumer relies on
        // this — see Storage.fetch's contract). Guard the whole miss-fill window, where the dir
        // create / file create / arena allocPrints can propagate an error before `path` is either
        // returned or freed. Success exits (spool hit + fill) return `path` and DON'T fire this;
        // the 404 `return null` frees it manually (a success-typed return errdefer can't cover).
        errdefer alloc.free(path);
        if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
            if (st.kind == .file) {
                // Approximate last-access LRU: bump the entry's mtime to now on a
                // cache hit so `evictIfOver` (which drops oldest-mtime-first) treats
                // a frequently-read file as recently accessed and evicts a rarely-read
                // one instead. Best-effort — a failed touch must NEVER fail the serve,
                // so the error is swallowed and we still return the hit.
                std.Io.Dir.cwd().setTimestamps(io, path, .{
                    .access_timestamp = .now,
                    .modify_timestamp = .now,
                }) catch {};
                return path; // spool hit
            }
        } else |_| {}

        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const dir = try std.fs.path.join(a, &.{ self.cache_dir, col, record_id });
        try std.Io.Dir.cwd().createDirPath(io, dir);
        var rand_hex: [8]u8 = undefined;
        var rand_bytes: [4]u8 = undefined;
        io.random(&rand_bytes); // filename-uniqueness only, not security-critical (entropy.zig scopes to ID/token gen)
        _ = std.fmt.bufPrint(&rand_hex, "{x:0>8}", .{std.mem.readInt(u32, &rand_bytes, .big)}) catch unreachable;
        const tmp_path = try std.fmt.allocPrint(a, "{s}.tmp{s}", .{ path, rand_hex });
        const key = try self.client.objectKey(a, col, record_id, filename);

        const f = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        var write_buf: [64 * 1024]u8 = undefined;
        var fwriter = f.writer(io, &write_buf);
        const status = self.client.getToWriter(io, a, key, &fwriter.interface) catch |e| {
            f.close(io);
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            return e; // `path` freed by errdefer
        };
        fwriter.interface.flush() catch |e| {
            f.close(io);
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            return e; // `path` freed by errdefer
        };
        f.close(io);
        if (status == 404) {
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            alloc.free(path); // success-typed `return null`: errdefer won't fire, free manually
            return null;
        }
        if (status != 200) {
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            return error.S3RequestFailed; // `path` freed by errdefer
        }
        std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, io) catch |e| { // atomic fill
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            return e; // `path` freed by errdefer
        };
        self.evictIfOver(io);
        return path;
    }

    /// Best-effort remote delete + spool-entry removal (hygiene, not security —
    /// recordReferencesFile already 404s de-referenced names before storage is hit).
    fn deleteImpl(ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8, filename: []const u8) anyerror!void {
        const self: *S3Storage = @ptrCast(@alignCast(ctx));
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        try self.client.delete(io, a, try self.client.objectKey(a, col, record_id, filename));
        const spool = try std.fs.path.join(a, &.{ self.cache_dir, col, record_id, filename });
        std.Io.Dir.cwd().deleteFile(io, spool) catch {};
    }

    fn deleteRecordImpl(ctx: *anyopaque, io: std.Io, col: []const u8, record_id: []const u8) anyerror!void {
        const self: *S3Storage = @ptrCast(@alignCast(ctx));
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const prefix = try std.fmt.allocPrint(a, "{s}{s}/{s}/", .{ self.client.key_prefix, col, record_id });
        const keys = try self.client.listKeys(io, a, prefix);
        for (keys) |k| self.client.delete(io, a, k) catch |e| {
            // Best-effort (a record delete must not fail on remote-cleanup hygiene), but log the
            // orphaned key: a failed DELETE (expired creds / bucket-policy change / network blip)
            // leaves an object billed + retained after its DB record is gone. Without this line
            // the skip is undiscoverable — the key was enumerated but recorded nowhere (#34).
            std.log.warn("[s3] failed to delete object '{s}': {s}; object orphaned", .{ k, @errorName(e) });
        };
        const spool_dir = try std.fs.path.join(a, &.{ self.cache_dir, col, record_id });
        std.Io.Dir.cwd().deleteTree(io, spool_dir) catch {};
    }

    /// Size-triggered eviction on miss-fill: when the spool exceeds the cap, delete
    /// oldest-mtime entries down to a 3/4 low-water mark. Walk failures are best-effort
    /// swallowed — eviction never turns into a serve failure.
    fn evictIfOver(self: *S3Storage, io: std.Io) void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const Entry = struct { path: []const u8, mtime: i96, size: u64 };
        var entries: std.ArrayList(Entry) = .empty;
        var total: u64 = 0;
        var dir = std.Io.Dir.cwd().openDir(io, self.cache_dir, .{ .iterate = true }) catch |e| {
            // Best-effort, but log it: a cache dir that becomes unlistable at runtime (permission
            // drift) permanently disables LRU eviction, so the spool grows past cache_max_bytes
            // until the disk fills — silently, without this line (#34).
            std.log.warn("[s3] spool eviction skipped: cannot open cache dir '{s}': {s}", .{ self.cache_dir, @errorName(e) });
            return;
        };
        defer dir.close(io);
        var walker = dir.walk(a) catch |e| {
            std.log.warn("[s3] spool eviction skipped: cannot walk cache dir '{s}': {s}", .{ self.cache_dir, @errorName(e) });
            return;
        };
        defer walker.deinit();
        while (walker.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const st = dir.statFile(io, entry.path, .{}) catch continue;
            total += st.size;
            entries.append(a, .{ .path = a.dupe(u8, entry.path) catch continue, .mtime = st.mtime.nanoseconds, .size = st.size }) catch continue;
        }
        if (total <= self.cache_max_bytes) return;
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lt(_: void, x: Entry, y: Entry) bool {
                return x.mtime < y.mtime; // oldest first
            }
        }.lt);
        const low_water = self.cache_max_bytes * 3 / 4;
        for (entries.items) |e| {
            if (total <= low_water) break;
            dir.deleteFile(io, e.path) catch continue;
            total -= e.size;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Client.init: default host derived from region, https, virtual-hosted" {
    var cfg = config.Config{};
    cfg.s3_bucket = "zbtest";
    cfg.s3_region = "eu-central-1";
    var host_buf: [256]u8 = undefined;
    const client = Client.init(cfg, &host_buf);
    try testing.expectEqualStrings("s3.eu-central-1.amazonaws.com", client.host);
    try testing.expectEqualStrings("https", client.scheme);
    try testing.expectEqual(false, client.path_style);
}

test "Client.init: http:// endpoint => scheme http + path_style default true" {
    var cfg = config.Config{};
    cfg.s3_bucket = "zbtest";
    cfg.s3_endpoint = "http://127.0.0.1:9000";
    var host_buf: [256]u8 = undefined;
    const client = Client.init(cfg, &host_buf);
    try testing.expectEqualStrings("127.0.0.1:9000", client.host);
    try testing.expectEqualStrings("http", client.scheme);
    try testing.expectEqual(true, client.path_style);
}

test "Client.init: explicit s3_force_path_style=false is respected with an endpoint set" {
    var cfg = config.Config{};
    cfg.s3_bucket = "zbtest";
    cfg.s3_endpoint = "https://minio.example.com";
    cfg.s3_force_path_style = false;
    var host_buf: [256]u8 = undefined;
    const client = Client.init(cfg, &host_buf);
    try testing.expectEqualStrings("minio.example.com", client.host);
    try testing.expectEqualStrings("https", client.scheme);
    try testing.expectEqual(false, client.path_style);
}

test "presignGet: virtual-hosted URL — host+path match addressing, https, has signature/expires" {
    const a = std.testing.allocator;
    var cfg = config.Config{};
    cfg.s3_bucket = "zbtest";
    cfg.s3_region = "us-east-1";
    cfg.s3_access_key_id = "AKID";
    cfg.s3_secret_access_key = "SECRET";
    var host_buf: [256]u8 = undefined;
    const client = Client.init(cfg, &host_buf); // no endpoint => virtual-hosted
    const key = try client.objectKey(a, "posts", "rec1", "a.png");
    defer a.free(key);
    const url = try client.presignGet(std.testing.io, a, key, 900);
    defer a.free(url);
    // Virtual-hosted: bucket rides the host, key is the path.
    try std.testing.expect(std.mem.startsWith(u8, url, "https://zbtest.s3.us-east-1.amazonaws.com/posts/rec1/a.png?"));
    try std.testing.expect(std.mem.indexOf(u8, url, "X-Amz-Signature=") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "X-Amz-Expires=900") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "X-Amz-Credential=AKID") != null);
}

test "presignGet: path-style URL — bucket in the path, honors the endpoint host" {
    const a = std.testing.allocator;
    var cfg = config.Config{};
    cfg.s3_bucket = "zbtest";
    cfg.s3_region = "us-east-1";
    cfg.s3_endpoint = "https://minio.example.com"; // path-style by default with an endpoint
    cfg.s3_access_key_id = "AKID";
    cfg.s3_secret_access_key = "SECRET";
    var host_buf: [256]u8 = undefined;
    const client = Client.init(cfg, &host_buf);
    const key = try client.objectKey(a, "posts", "rec1", "a.png");
    defer a.free(key);
    const url = try client.presignGet(std.testing.io, a, key, 1800);
    defer a.free(url);
    // Path-style: bucket is a path segment on the endpoint host.
    try std.testing.expect(std.mem.startsWith(u8, url, "https://minio.example.com/zbtest/posts/rec1/a.png?"));
    try std.testing.expect(std.mem.indexOf(u8, url, "X-Amz-Signature=") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "X-Amz-Expires=1800") != null);
}

test "presignGet: an http endpoint yields an http presigned URL (scheme honored)" {
    const a = std.testing.allocator;
    var cfg = config.Config{};
    cfg.s3_bucket = "zbtest";
    cfg.s3_region = "us-east-1";
    cfg.s3_endpoint = "http://minio.local:9000"; // dev MinIO over http
    cfg.s3_access_key_id = "AKID";
    cfg.s3_secret_access_key = "SECRET";
    var host_buf: [256]u8 = undefined;
    const client = Client.init(cfg, &host_buf);
    const key = try client.objectKey(a, "posts", "rec1", "a.png");
    defer a.free(key);
    const url = try client.presignGet(std.testing.io, a, key, 900);
    defer a.free(url);
    // The presigned URL must match the endpoint scheme, or it is undialable.
    try std.testing.expect(std.mem.startsWith(u8, url, "http://minio.local:9000/zbtest/posts/rec1/a.png?"));
    try std.testing.expect(std.mem.indexOf(u8, url, "X-Amz-Signature=") != null);
}

fn testClient() Client {
    return .{
        .bucket = "zbtest",
        .region = "us-east-1",
        .host = "s3.us-east-1.amazonaws.com",
        .scheme = "https",
        .access_key = "AKID",
        .secret_key = "SECRET",
        .key_prefix = "",
        .path_style = true,
    };
}

test "put: sends signed headers and the path-style, space-encoded URL" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.enable(true);
    defer testcapture.http.reset();
    testcapture.http.mock("zbtest/col/r1/a%20b.png", .{ .status = 200 });

    // BLOCKED (contract-4, root cause outside this batch): `Client.put` -> `putOnce` ->
    // `HttpClient.request` (src/http_client.zig) allocates its response scratch (the
    // fixed `max_response_bytes` body buffer, the redirect buffer, and the captured
    // header array/strings) on this allocator and never frees it — by house convention
    // `HttpResponse` has no `deinit`; every production caller (S3Storage's putImpl et
    // al.) wraps the call in its own disposable arena. A raw `std.testing.allocator`
    // here would report that http_client.zig scratch as a leak; fixing it means
    // changing http_client.zig, which is out of this batch's scope. Kept arena-wrapped.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const client = testClient();
    try client.put(std.testing.io, a, "col/r1/a b.png", "hello", "image/png");

    try testing.expectEqual(@as(usize, 1), testcapture.http.requestCount());
    const rq = testcapture.http.requestAt(0).?;
    try testing.expect(std.mem.indexOf(u8, rq.url, "/zbtest/col/r1/a%20b.png") != null);

    var found_auth = false;
    var found_sha = false;
    const expected_sha = try sigv4.sha256Hex(a, "hello");
    for (rq.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Authorization")) {
            try testing.expect(std.mem.startsWith(u8, h.value, "AWS4-HMAC-SHA256 Credential=AKID"));
            found_auth = true;
        }
        if (std.ascii.eqlIgnoreCase(h.name, "X-Amz-Content-Sha256")) {
            try testing.expectEqualStrings(expected_sha, h.value);
            found_sha = true;
        }
    }
    try testing.expect(found_auth);
    try testing.expect(found_sha);
}

test "put: 500 retries once then errors; 200 succeeds with a single request" {
    if (!testcapture.enabled) return error.SkipZigTest;
    // BLOCKED (contract-4, root cause outside this batch): see the identical arena note
    // on "put: sends signed headers…" above — `HttpClient.request` (http_client.zig)
    // scratch is never freed by the callee.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const client = testClient();

    testcapture.http.enable(true);
    testcapture.http.mock("zbtest", .{ .status = 500 });
    try testing.expectError(error.S3RequestFailed, client.put(std.testing.io, a, "col/r1/x.bin", "d", "application/octet-stream"));
    try testing.expectEqual(@as(usize, 2), testcapture.http.requestCount());
    testcapture.http.reset();

    testcapture.http.enable(true);
    defer testcapture.http.reset();
    testcapture.http.mock("zbtest", .{ .status = 200 });
    try client.put(std.testing.io, a, "col/r1/x.bin", "d", "application/octet-stream");
    try testing.expectEqual(@as(usize, 1), testcapture.http.requestCount());
}

test "getToWriter: 500 retries once then errors; 200 succeeds with a single request" {
    if (!testcapture.enabled) return error.SkipZigTest;
    // BLOCKED (contract-4, root cause outside this batch): `Client.getToWriter` ->
    // `HttpClient.download` (http_client.zig) allocates its own response scratch
    // (extra-headers array, redirect buffer, captured header array/strings) and never
    // frees it — same house-convention gap as `request()` (see "put: sends signed
    // headers…" above). Out of this batch's scope to fix.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const client = testClient();

    var buf: [64]u8 = undefined;

    testcapture.http.enable(true);
    testcapture.http.mock("zbtest", .{ .status = 500 });
    var fw1 = std.Io.Writer.fixed(&buf);
    try testing.expectError(error.S3RequestFailed, client.getToWriter(std.testing.io, a, "col/r1/x.bin", &fw1));
    try testing.expectEqual(@as(usize, 2), testcapture.http.requestCount());
    testcapture.http.reset();

    testcapture.http.enable(true);
    defer testcapture.http.reset();
    testcapture.http.mock("zbtest", .{ .status = 200, .body = "OBJDATA" });
    var fw2 = std.Io.Writer.fixed(&buf);
    const status = try client.getToWriter(std.testing.io, a, "col/r1/x.bin", &fw2);
    try testing.expectEqual(@as(u16, 200), status);
    try testing.expectEqualStrings("OBJDATA", fw2.buffered());
    try testing.expectEqual(@as(usize, 1), testcapture.http.requestCount());
}

test "getToWriter: a 500 WITH a body on the first attempt does not corrupt the retry's write" {
    if (!testcapture.enabled) return error.SkipZigTest;
    // BLOCKED (contract-4, root cause outside this batch): see the `download()` scratch
    // note on "getToWriter: 500 retries…" above.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const client = testClient();

    testcapture.http.enable(true);
    defer testcapture.http.reset();
    // Unlike the empty-body 500 above, this 500 carries a non-empty XML error body — the
    // exact shape that previously leaked into `w` ahead of the retried success body.
    testcapture.http.mockSequence("zbtest", &.{
        .{ .status = 500, .body = "<Error><Code>SlowDown</Code></Error>" },
        .{ .status = 200, .body = "OBJDATA" },
    });

    var buf: [64]u8 = undefined;
    var fw = std.Io.Writer.fixed(&buf);
    const status = try client.getToWriter(std.testing.io, a, "col/r1/x.bin", &fw);
    try testing.expectEqual(@as(u16, 200), status);
    // `w` holds ONLY the success body — not the 500's error bytes followed by it.
    try testing.expectEqualStrings("OBJDATA", fw.buffered());
    try testing.expectEqual(@as(usize, 2), testcapture.http.requestCount());
}

test "getToWriter: a failing destination writer is not retried" {
    if (!testcapture.enabled) return error.SkipZigTest;
    // BLOCKED (contract-4, root cause outside this batch): see the `download()` scratch
    // note on "getToWriter: 500 retries…" above.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const client = testClient();

    testcapture.http.enable(true);
    defer testcapture.http.reset();
    testcapture.http.mock("zbtest", .{ .status = 200, .body = "TOO-BIG-FOR-THE-BUFFER" });

    // A 4-byte destination can't fit the mocked body — writeAll fails partway through.
    var buf: [4]u8 = undefined;
    var fw = std.Io.Writer.fixed(&buf);
    try testing.expectError(error.WriteFailed, client.getToWriter(std.testing.io, a, "col/r1/x.bin", &fw));
    // The broken destination is not retried — only one request went out.
    try testing.expectEqual(@as(usize, 1), testcapture.http.requestCount());
}

test "head: returns the raw status for 200/404/403 without erroring" {
    if (!testcapture.enabled) return error.SkipZigTest;
    // BLOCKED (contract-4, root cause outside this batch): `Client.head` -> `request()`
    // (http_client.zig) scratch is never freed by the callee — see "put: sends signed
    // headers…" above.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const client = testClient();

    for ([_]u16{ 200, 404, 403 }) |status| {
        testcapture.http.enable(true);
        testcapture.http.mock("zbtest", .{ .status = status });
        const got = try client.head(std.testing.io, a, "col/r1/x.bin");
        try testing.expectEqual(status, got);
        testcapture.http.reset();
    }
}

test "inventory uses one bounded S3 page and keeps usage within configured prefix" {
    if (!testcapture.enabled or !@import("build_options").file_inventory) return error.SkipZigTest;
    testcapture.http.enable(true);
    defer testcapture.http.reset();
    testcapture.http.mock("list-type=2", .{ .status = 200, .body = "<ListBucketResult><IsTruncated>true</IsTruncated><Contents><Key>tenant/posts/r1/a&amp;b</Key><Size>42</Size></Contents><NextContinuationToken>next+/=</NextContinuationToken></ListBucketResult>" });
    const a = testing.allocator;
    var client = testClient();
    client.key_prefix = "tenant/";
    var instance = S3Storage{ .gpa = a, .client = client, .cache_dir = "", .cache_max_bytes = 0, .host_buf = &.{} };
    const result = try instance.storage().inventory(std.testing.io, a, "previous", 1);
    defer result.deinit(a);
    try testing.expectEqualStrings("posts/r1/a&b", result.items[0].key);
    try testing.expectEqual(@as(u64, 42), result.items[0].bytes);
    try testing.expectEqualStrings("next+/=", result.nextCursor.?);
    try testing.expectEqual(@as(usize, 1), testcapture.http.requestCount());
    try testing.expect(std.mem.indexOf(u8, testcapture.http.requestAt(0).?.url, "continuation-token=previous&list-type=2&max-keys=1&prefix=tenant%2F") != null);
    try testing.expectError(error.S3InvalidListResponse, inventoryFromXml(a, "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>outside/r1/a</Key><Size>1</Size></Contents></ListBucketResult>", "tenant/", null, 1));
    try testing.expectError(error.S3InvalidListResponse, inventoryFromXml(a, "<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>repeat</NextContinuationToken></ListBucketResult>", "tenant/", "repeat", 1));
}

test "listKeys follows encoded continuation tokens and decodes XML keys" {
    if (!testcapture.enabled) return error.SkipZigTest;
    testcapture.http.enable(true);
    defer testcapture.http.reset();
    testcapture.http.mockSequence("list-type=2", &.{
        .{ .status = 200, .body = "<ListBucketResult><IsTruncated>true</IsTruncated><Key>col/r1/a&amp;b</Key><NextContinuationToken>a+/=&amp;</NextContinuationToken></ListBucketResult>" },
        .{ .status = 200, .body = "<ListBucketResult><IsTruncated>false</IsTruncated><Key>col/r1/c&#xE9;</Key></ListBucketResult>" },
    });
    const a = testing.allocator;
    const keys = try testClient().listKeys(std.testing.io, a, "col/r1/");
    defer {
        for (keys) |key| a.free(key);
        a.free(keys);
    }
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expectEqualStrings("col/r1/a&b", keys[0]);
    try testing.expectEqualStrings("col/r1/cé", keys[1]);
    try testing.expect(std.mem.indexOf(u8, testcapture.http.requestAt(1).?.url, "continuation-token=a%2B%2F%3D%26") != null);
}

test "listKeys reuses response scratch under an outer arena" {
    if (!testcapture.enabled) return error.SkipZigTest;
    var fixture = std.heap.ArenaAllocator.init(testing.allocator);
    defer fixture.deinit();
    const a = fixture.allocator();
    const padding = try a.alloc(u8, 128 * 1024);
    @memset(padding, ' ');
    var responses: [32]testcapture.MockResponse = undefined;
    for (&responses, 0..) |*response, i| response.* = .{
        .body = try std.fmt.allocPrint(a, "{s}<ListBucketResult><IsTruncated>{s}</IsTruncated><Key>col/r1/{d}</Key><NextContinuationToken>{d}</NextContinuationToken></ListBucketResult>", .{ padding, if (i + 1 == responses.len) "false" else "true", i, i }),
    };
    testcapture.http.enable(true);
    defer testcapture.http.reset();
    testcapture.http.mockSequence("list-type=2", &responses);
    var output = std.heap.ArenaAllocator.init(testing.allocator);
    defer output.deinit();
    const keys = try testClient().listKeys(std.testing.io, output.allocator(), "col/r1/");
    try testing.expectEqual(responses.len, keys.len);
    try testing.expectEqualStrings("col/r1/0", keys[0]);
    try testing.expectEqualStrings("col/r1/31", keys[31]);
    // The returned keys/tokens are small. Retaining 32 response bodies alone
    // would exceed 4 MiB; scratch must plateau instead of accumulating pages.
    try testing.expect(output.queryCapacity() < 2 * 1024 * 1024);
}

test "listKeys refuses partial, out-of-prefix, and non-progressing listings" {
    if (!testcapture.enabled) return error.SkipZigTest;
    const invalid = [_][]const u8{
        "<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>",
        "<ListBucketResult><IsTruncated>false</IsTruncated><Key>other/r1/a</Key></ListBucketResult>",
        "<ListBucketResult><IsTruncated>false</IsTruncated><Key>col/r1/a</Key>",
        "<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>repeat</NextContinuationToken></ListBucketResult>",
    };
    for (invalid) |body| {
        testcapture.http.enable(true);
        defer testcapture.http.reset();
        testcapture.http.mock("list-type=2", .{ .status = 200, .body = body });
        try testing.expectError(error.S3InvalidListResponse, testClient().listKeys(std.testing.io, testing.allocator, "col/r1/"));
        try testing.expect(testcapture.http.requestCount() <= 2);
    }
}

test "scanKeys: well-formed, truncated, and hostile input" {
    const a = testing.allocator;

    {
        const keys = try scanKeys(a, "<Key>a</Key><Key>b/c</Key>");
        defer {
            for (keys) |k| a.free(k);
            a.free(keys);
        }
        try testing.expectEqual(@as(usize, 2), keys.len);
        try testing.expectEqualStrings("a", keys[0]);
        try testing.expectEqualStrings("b/c", keys[1]);
    }

    try testing.expectError(error.S3InvalidListResponse, scanKeys(a, "<Key>a</Key><Key>trunc"));
    try testing.expectError(error.S3InvalidListResponse, scanKeys(a, "<Key><Key>inner</Key>"));

    // 10k keys bound: never crashes, extracts all of them.
    {
        var xml: std.ArrayList(u8) = .empty;
        defer xml.deinit(a);
        var i: usize = 0;
        while (i < 10_000) : (i += 1) {
            try xml.print(a, "<Key>k{d}</Key>", .{i});
        }
        const keys = try scanKeys(a, xml.items);
        defer {
            for (keys) |k| a.free(k);
            a.free(keys);
        }
        try testing.expectEqual(@as(usize, 10_000), keys.len);
        try testing.expectEqualStrings("k0", keys[0]);
        try testing.expectEqualStrings("k9999", keys[9999]);
    }
}

// ---------------------------------------------------------------------------
// S3Storage tests
// ---------------------------------------------------------------------------

/// A config that passes `create`'s validation, rooted at `cache_dir` (a real tmpDir
/// so the spool logic exercises real filesystem behavior).
fn testCfg(cache_dir: []const u8) config.Config {
    var cfg = config.Config{};
    cfg.s3_bucket = "zbtest";
    cfg.s3_region = "us-east-1";
    cfg.s3_access_key_id = "AKID";
    cfg.s3_secret_access_key = "SECRET";
    cfg.s3_cache_dir = cache_dir;
    return cfg;
}

// The next two tests target `validateConfig` directly rather than `create` — `create`'s
// failure branches call `std.log.err`, which the test runner counts against the build
// (`log_err_count`) even when every assertion passes (see `create`'s doc comment).
// `validateConfig` is the exact, logging-free decision logic `create` delegates to.

test "S3Storage.validateConfig: missing access key id / secret key -> S3ConfigMissing" {
    var cfg = config.Config{};
    cfg.s3_bucket = "zbtest";
    // neither key set
    try testing.expectError(error.S3ConfigMissing, S3Storage.validateConfig(cfg));

    cfg.s3_access_key_id = "AKID";
    // access key set, secret still missing
    try testing.expectError(error.S3ConfigMissing, S3Storage.validateConfig(cfg));

    cfg.s3_secret_access_key = "SECRET";
    try S3Storage.validateConfig(cfg); // both set, defaults otherwise valid
}

test "S3Storage.validateConfig: max_upload_size over the 5 GiB single-PUT limit -> S3UploadCapTooLarge" {
    var cfg = config.Config{};
    cfg.s3_bucket = "zbtest";
    cfg.s3_access_key_id = "AKID";
    cfg.s3_secret_access_key = "SECRET";
    cfg.max_upload_size = 6 << 30;
    try testing.expectError(error.S3UploadCapTooLarge, S3Storage.validateConfig(cfg));
}

test "S3Storage.validateConfig: CR/LF in bucket/region/endpoint/key_prefix -> S3ConfigInvalid" {
    var cfg = config.Config{};
    cfg.s3_access_key_id = "AKID";
    cfg.s3_secret_access_key = "SECRET";
    cfg.s3_bucket = "zbtest\r\nX-Injected: yes";
    try testing.expectError(error.S3ConfigInvalid, S3Storage.validateConfig(cfg));
}

test "S3Storage.create: startup probe — 404 and 200 succeed (the common case)" {
    if (!testcapture.enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = testing.allocator;
    const cache_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(cache_dir);
    const cfg = testCfg(cache_dir);

    testcapture.http.enable(true);
    defer testcapture.http.reset();

    testcapture.http.mock("zbtest", .{ .status = 404 }); // no such probe object: expected
    var s1 = try S3Storage.create(testing.allocator, std.testing.io, cfg);
    s1.deinit();
    testcapture.http.reset();

    testcapture.http.enable(true);
    testcapture.http.mock("zbtest", .{ .status = 200 }); // probe object happens to exist: also fine
    var s2 = try S3Storage.create(testing.allocator, std.testing.io, cfg);
    s2.deinit();
}

// `create`'s failure branch logs (see above) so it isn't called directly here; `probe`
// is create()'s exact, logging-free decision logic — built via a real `create()` success
// (404, no log) so it exercises the same `Client` the real startup path would use.
test "S3Storage.probe: 403 and an unmocked/blocked transport both fail closed" {
    if (!testcapture.enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = testing.allocator;
    const cache_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(cache_dir);
    const cfg = testCfg(cache_dir);

    testcapture.http.enable(true);
    defer testcapture.http.reset();
    testcapture.http.mock("zbtest", .{ .status = 404 });
    var s3 = try S3Storage.create(testing.allocator, std.testing.io, cfg);
    defer s3.deinit();

    testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("zbtest", .{ .status = 403 }); // wrong bucket/credentials
    try testing.expectError(error.S3ProbeFailed, s3.probe(std.testing.io));

    testcapture.http.reset();
    testcapture.http.enable(true); // block_unmocked=true, no mock registered -> transport error
    try testing.expectError(error.TransportFailed, s3.probe(std.testing.io));
}

test "S3Storage.fetch: cache miss downloads+spools; cache hit skips the network; 404 -> null; 5xx -> error" {
    if (!testcapture.enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = testing.allocator;
    const cache_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(cache_dir);
    const cfg = testCfg(cache_dir);

    testcapture.http.enable(true);
    defer testcapture.http.reset();
    testcapture.http.mock("zbtest", .{ .status = 404 }); // probe
    var s3 = try S3Storage.create(testing.allocator, std.testing.io, cfg);
    defer s3.deinit();
    const st = s3.storage();

    testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("col/r1/f.bin", .{ .status = 200, .body = "SPOOLME" });

    const p1 = (try st.fetch(std.testing.io, testing.allocator, "col", "r1", "f.bin")).?;
    defer testing.allocator.free(p1);
    const back = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, p1, testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("SPOOLME", back);
    try testing.expectEqual(@as(usize, 1), testcapture.http.requestCount());

    // Cache hit: same path, no second request.
    const p2 = (try st.fetch(std.testing.io, testing.allocator, "col", "r1", "f.bin")).?;
    defer testing.allocator.free(p2);
    try testing.expectEqualStrings(p1, p2);
    try testing.expectEqual(@as(usize, 1), testcapture.http.requestCount());

    // 404 from the backend -> null, not an error.
    testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("col/r1/missing.bin", .{ .status = 404 });
    const miss = try st.fetch(std.testing.io, testing.allocator, "col", "r1", "missing.bin");
    try testing.expect(miss == null);

    // A transport/5xx failure propagates as an error, never collapses to null.
    testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("col/r1/bad.bin", .{ .status = 500 }); // sticky: both the initial try and the one retry see 500
    try testing.expectError(error.S3RequestFailed, st.fetch(std.testing.io, testing.allocator, "col", "r1", "bad.bin"));
}

test "S3Storage: put/delete round-trip through the vtable" {
    if (!testcapture.enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = testing.allocator;
    const cache_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(cache_dir);
    const cfg = testCfg(cache_dir);

    testcapture.http.enable(true);
    defer testcapture.http.reset();
    testcapture.http.mock("zbtest", .{ .status = 404 }); // probe
    var s3 = try S3Storage.create(testing.allocator, std.testing.io, cfg);
    defer s3.deinit();
    const st = s3.storage();

    testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("col/r2/doc.txt", .{ .status = 200 });
    try st.put(std.testing.io, "col", "r2", "doc.txt", "hello world");
    var found_put = false;
    for (testcapture.http.requests()) |rq| {
        if (rq.method == .PUT) found_put = true;
    }
    try testing.expect(found_put);

    testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("col/r2/doc.txt", .{ .status = 204 });
    try st.delete(std.testing.io, "col", "r2", "doc.txt");
}

test "S3Storage.delete: removes the spool entry alongside the remote object" {
    if (!testcapture.enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = testing.allocator;
    const cache_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(cache_dir);
    const cfg = testCfg(cache_dir);

    testcapture.http.enable(true);
    defer testcapture.http.reset();
    testcapture.http.mock("zbtest", .{ .status = 404 }); // probe
    var s3 = try S3Storage.create(testing.allocator, std.testing.io, cfg);
    defer s3.deinit();
    const st = s3.storage();

    testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("col/r3/x.bin", .{ .status = 200, .body = "DATA" });
    const p = (try st.fetch(std.testing.io, testing.allocator, "col", "r3", "x.bin")).?;
    defer testing.allocator.free(p);
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, p, .{}); // spooled

    testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("col/r3/x.bin", .{ .status = 204 });
    try st.delete(std.testing.io, "col", "r3", "x.bin");
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, p, .{}));
}

test "S3Storage: eviction removes oldest spool entries once over cache_max_bytes" {
    if (!testcapture.enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = testing.allocator;
    const cache_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(cache_dir);
    var cfg = testCfg(cache_dir);
    cfg.s3_cache_max_bytes = 100; // low-water = 75; three 60-byte entries force eviction

    testcapture.http.enable(true);
    defer testcapture.http.reset();
    testcapture.http.mock("zbtest", .{ .status = 404 }); // probe
    var s3 = try S3Storage.create(testing.allocator, std.testing.io, cfg);
    defer s3.deinit();
    const st = s3.storage();

    const body60 = "x" ** 60;
    const names = [_][]const u8{ "a.bin", "b.bin", "c.bin" };
    for (names) |name| {
        testcapture.http.reset();
        testcapture.http.enable(true);
        testcapture.http.mock(name, .{ .status = 200, .body = body60 });
        const p = (try st.fetch(std.testing.io, testing.allocator, "col", "r4", name)).?;
        testing.allocator.free(p);
        // Nudge mtimes apart — some filesystems have coarse mtime resolution.
        std.testing.io.sleep(std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }

    // Oldest ("a.bin") was evicted once the 3rd fetch pushed the spool over 100 bytes;
    // the newest ("c.bin") survives.
    const path_a = try std.fs.path.join(testing.allocator, &.{ cache_dir, "col", "r4", "a.bin" });
    defer testing.allocator.free(path_a);
    const path_c = try std.fs.path.join(testing.allocator, &.{ cache_dir, "col", "r4", "c.bin" });
    defer testing.allocator.free(path_c);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, path_a, .{}));
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, path_c, .{});
}

test "S3Storage: a cache hit bumps mtime so eviction approximates last-access LRU" {
    if (!testcapture.enabled) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = testing.allocator;
    const cache_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(cache_dir);
    var cfg = testCfg(cache_dir);
    // cap 170 -> low-water = 127. Two 60-byte entries (120) stay under the cap;
    // the third (180) trips eviction, which frees exactly one 60-byte entry
    // (120 <= 127) — the oldest by mtime.
    cfg.s3_cache_max_bytes = 170;

    testcapture.http.enable(true);
    defer testcapture.http.reset();
    testcapture.http.mock("zbtest", .{ .status = 404 }); // probe
    var s3 = try S3Storage.create(testing.allocator, std.testing.io, cfg);
    defer s3.deinit();
    const st = s3.storage();

    const body60 = "x" ** 60;
    const nudge = std.Io.Duration.fromMilliseconds(10);

    // Miss-fill a.bin, then b.bin (spacing mtimes apart — some filesystems have
    // coarse mtime resolution). Total 120 <= 170, so no eviction yet.
    const names = [_][]const u8{ "a.bin", "b.bin" };
    for (names) |name| {
        testcapture.http.reset();
        testcapture.http.enable(true);
        testcapture.http.mock(name, .{ .status = 200, .body = body60 });
        const p = (try st.fetch(std.testing.io, testing.allocator, "col", "r5", name)).?;
        testing.allocator.free(p);
        std.testing.io.sleep(nudge, .awake) catch {};
    }

    // Cache HIT on a.bin — returns the spooled path with no HTTP request, and
    // bumps a.bin's mtime above b.bin's, making b.bin the oldest entry.
    const hit = (try st.fetch(std.testing.io, testing.allocator, "col", "r5", "a.bin")).?;
    testing.allocator.free(hit);
    std.testing.io.sleep(nudge, .awake) catch {};

    // Miss-fill c.bin -> spool 180 > 170, eviction frees the oldest entry down to
    // <= 127. With the touch, that oldest entry is b.bin; WITHOUT it a.bin (the
    // create-time oldest) would be evicted instead.
    testcapture.http.reset();
    testcapture.http.enable(true);
    testcapture.http.mock("c.bin", .{ .status = 200, .body = body60 });
    const pc = (try st.fetch(std.testing.io, testing.allocator, "col", "r5", "c.bin")).?;
    testing.allocator.free(pc);

    const path_a = try std.fs.path.join(testing.allocator, &.{ cache_dir, "col", "r5", "a.bin" });
    defer testing.allocator.free(path_a);
    const path_b = try std.fs.path.join(testing.allocator, &.{ cache_dir, "col", "r5", "b.bin" });
    defer testing.allocator.free(path_b);
    const path_c = try std.fs.path.join(testing.allocator, &.{ cache_dir, "col", "r5", "c.bin" });
    defer testing.allocator.free(path_c);

    // b.bin (never re-hit -> oldest mtime) is evicted; the hot a.bin and the newest
    // c.bin both survive.
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, path_b, .{}));
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, path_a, .{});
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, path_c, .{});
}

// ---------------------------------------------------------------------------
// LIVE tests — real network I/O against a real S3-compatible server (MinIO in
// CI's `s3` job). Gated on ZIGBASE_S3_TEST_* (the ZIGBASE_PG_TEST_URL / seam_test.zig
// precedent): SkipZigTest when unset, so the default and -Ds3=true-without-MinIO
// unit runs stay green everywhere else.
// ---------------------------------------------------------------------------

/// A `ZIGBASE_S3_TEST_*` value from the process environment, or null to skip (no
/// configured live server). Mirrors `backend/seam_test.zig`'s `testUrlZ`.
fn testEnv(name: []const u8) ?[]const u8 {
    return std.testing.environ.getPosix(name);
}

test "LIVE MinIO: put/head/get/list/delete round-trip (object verifiably GONE)" {
    // Deletion-verification lives HERE, where the signer is available (the python
    // e2e can't issue signed S3 requests without a client library).
    const endpoint = testEnv("ZIGBASE_S3_TEST_ENDPOINT") orelse return error.SkipZigTest;
    const bucket = testEnv("ZIGBASE_S3_TEST_BUCKET") orelse return error.SkipZigTest;
    const key_id = testEnv("ZIGBASE_S3_TEST_KEY") orelse return error.SkipZigTest;
    const secret = testEnv("ZIGBASE_S3_TEST_SECRET") orelse return error.SkipZigTest;
    // BLOCKED (contract-4, root cause outside this batch): this exercises the raw
    // `Client` ops directly (put/head/getToWriter/listKeys/delete), each of which routes
    // through `HttpClient.request`/`download` (http_client.zig) — see "put: sends
    // signed headers…" above for the scratch-never-freed detail.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var host_buf: [256]u8 = undefined;
    const client = Client.init(.{
        .s3_bucket = bucket,
        .s3_endpoint = endpoint,
        .s3_access_key_id = key_id,
        .s3_secret_access_key = secret,
    }, &host_buf);
    const key = "livetest/r1/a_0000000000.png";
    try client.put(std.testing.io, a, key, "LIVE-BYTES", "image/png");
    try std.testing.expectEqual(@as(u16, 200), try client.head(std.testing.io, a, key));
    var buf: [64]u8 = undefined;
    var fw = std.Io.Writer.fixed(&buf);
    try std.testing.expectEqual(@as(u16, 200), try client.getToWriter(std.testing.io, a, key, &fw));
    try std.testing.expectEqualStrings("LIVE-BYTES", fw.buffered());
    const keys = try client.listKeys(std.testing.io, a, "livetest/r1/");
    try std.testing.expectEqual(@as(usize, 1), keys.len);
    try std.testing.expectEqualStrings(key, keys[0]);
    try client.delete(std.testing.io, a, key);
    try std.testing.expectEqual(@as(u16, 404), try client.head(std.testing.io, a, key)); // GONE in MinIO
}
