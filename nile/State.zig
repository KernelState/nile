// SPDX-FileCopyrightText: © 2026 The Nile Developers
// SPDX-License-Identifier: GPL-3.0-only

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const WindowId = u64;
pub const OutputId = u64;

pub const Border = struct {
    width: u32 = 0,
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    a: u8 = 255,
};

pub const WindowState = struct {
    id: WindowId,
    x: i32 = 0,
    y: i32 = 0,
    width: u31 = 0,
    height: u31 = 0,
    hidden: bool = false,
    border: ?Border = null,
};

pub const OutputState = struct {
    id: OutputId,
    x: i32 = 0,
    y: i32 = 0,
    width: u31 = 0,
    height: u31 = 0,
    scale: f32 = 1.0,
};

pub const Message = union(enum) {
    window_upsert: WindowState,
    window_remove: WindowId,
    output_upsert: OutputState,
    output_remove: OutputId,
};

pub const Snapshot = struct {
    windows: []WindowState,
    outputs: []OutputState,
    generation: u64,

    pub fn deinit(self: *Snapshot, gpa: Allocator) void {
        gpa.free(self.windows);
        gpa.free(self.outputs);
    }
};

pub const Model = struct {
    gpa: Allocator,
    windows: std.AutoHashMapUnmanaged(WindowId, WindowState) = .empty,
    window_order: std.ArrayListUnmanaged(WindowId) = .empty,
    outputs: std.AutoHashMapUnmanaged(OutputId, OutputState) = .empty,
    output_order: std.ArrayListUnmanaged(OutputId) = .empty,

    pub fn init(gpa: Allocator) Model {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Model) void {
        self.windows.deinit(self.gpa);
        self.window_order.deinit(self.gpa);
        self.outputs.deinit(self.gpa);
        self.output_order.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn apply(self: *Model, msg: Message) !void {
        switch (msg) {
            .window_upsert => |w| {
                if (!self.windows.contains(w.id)) try self.window_order.append(self.gpa, w.id);
                try self.windows.put(self.gpa, w.id, w);
            },
            .window_remove => |id| {
                if (self.windows.remove(id)) {
                    for (self.window_order.items, 0..) |wid, i| {
                        if (wid == id) {
                            _ = self.window_order.orderedRemove(i);
                            break;
                        }
                    }
                }
            },
            .output_upsert => |o| {
                if (!self.outputs.contains(o.id)) try self.output_order.append(self.gpa, o.id);
                try self.outputs.put(self.gpa, o.id, o);
            },
            .output_remove => |id| {
                if (self.outputs.remove(id)) {
                    for (self.output_order.items, 0..) |oid, i| {
                        if (oid == id) {
                            _ = self.output_order.orderedRemove(i);
                            break;
                        }
                    }
                }
            },
        }
    }

    pub fn snapshot(self: *const Model, gpa: Allocator, generation: u64) !Snapshot {
        const windows = try gpa.alloc(WindowState, self.window_order.items.len);
        errdefer gpa.free(windows);
        for (self.window_order.items, 0..) |id, i| {
            windows[i] = self.windows.get(id).?;
        }
        const outputs = try gpa.alloc(OutputState, self.output_order.items.len);
        for (self.output_order.items, 0..) |id, i| {
            outputs[i] = self.outputs.get(id).?;
        }
        return .{ .windows = windows, .outputs = outputs, .generation = generation };
    }
};

const State = @This();

mutex: Io.Mutex = .init,
cond: Io.Condition = .init,
queue: std.ArrayListUnmanaged(Message) = .empty,
generation: u64 = 0,
shutting_down: bool = false,
gpa: Allocator,

pub fn init(gpa: Allocator) State {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *State) void {
    self.queue.deinit(self.gpa);
    self.* = undefined;
}

pub fn post(self: *State, io: Io, msg: Message) !void {
    try self.mutex.lock(io);
    defer self.mutex.unlock(io);
    if (self.shutting_down) return error.ShuttingDown;
    try self.queue.append(self.gpa, msg);
    self.generation += 1;
    self.cond.signal(io);
}

pub fn windowUpsert(self: *State, io: Io, w: WindowState) !void {
    try self.post(io, .{ .window_upsert = w });
}

pub fn windowRemove(self: *State, io: Io, id: WindowId) !void {
    try self.post(io, .{ .window_remove = id });
}

pub fn outputUpsert(self: *State, io: Io, o: OutputState) !void {
    try self.post(io, .{ .output_upsert = o });
}

pub fn outputRemove(self: *State, io: Io, id: OutputId) !void {
    try self.post(io, .{ .output_remove = id });
}

pub fn requestShutdown(self: *State, io: Io) void {
    self.mutex.lock(io) catch return;
    self.shutting_down = true;
    self.mutex.unlock(io);
    self.cond.broadcast(io);
}

pub fn drainBatch(self: *State, io: Io, out: *std.ArrayListUnmanaged(Message)) !bool {
    try self.mutex.lock(io);
    while (self.queue.items.len == 0) {
        if (self.shutting_down) {
            self.mutex.unlock(io);
            return true;
        }
        self.cond.wait(io, &self.mutex) catch |err| {
            self.mutex.unlock(io);
            return err;
        };
    }
    if (self.shutting_down) {
        self.mutex.unlock(io);
        return true;
    }
    try out.appendSlice(self.gpa, self.queue.items);
    self.queue.clearRetainingCapacity();
    self.mutex.unlock(io);
    return false;
}

pub fn currentGeneration(self: *State, io: Io) u64 {
    self.mutex.lock(io) catch return 0;
    defer self.mutex.unlock(io);
    return self.generation;
}

test "post and drain" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    const io = Io.Threaded.global_single_threaded.io();

    try state.windowUpsert(io, .{ .id = 1, .x = 10, .y = 20, .width = 100, .height = 50 });
    try state.windowUpsert(io, .{ .id = 2, .x = 0, .y = 0, .width = 40, .height = 40, .hidden = true });
    try state.outputUpsert(io, .{ .id = 7, .x = 0, .y = 0, .width = 1920, .height = 1080, .scale = 1.5 });

    var buf: std.ArrayListUnmanaged(Message) = .empty;
    defer buf.deinit(state.gpa);
    const shutdown = try state.drainBatch(io, &buf);
    try testing.expect(!shutdown);
    try testing.expectEqual(@as(usize, 3), buf.items.len);
}

test "model apply and snapshot" {
    var model = Model.init(testing.allocator);
    defer model.deinit();

    try model.apply(.{ .window_upsert = .{ .id = 1, .x = 5, .y = 6, .width = 10, .height = 20 } });
    try model.apply(.{ .window_upsert = .{ .id = 2, .x = 30, .y = 40, .width = 7, .height = 8 } });
    try model.apply(.{ .output_upsert = .{ .id = 9, .width = 1920, .height = 1080 } });

    var snap = try model.snapshot(testing.allocator, 42);
    defer snap.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 42), snap.generation);
    try testing.expectEqual(@as(usize, 2), snap.windows.len);
    try testing.expectEqual(@as(WindowId, 1), snap.windows[0].id);
    try testing.expectEqual(@as(u31, 1920), snap.outputs[0].width);

    try model.apply(.{ .window_remove = 1 });
    var snap2 = try model.snapshot(testing.allocator, 43);
    defer snap2.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), snap2.windows.len);
    try testing.expectEqual(@as(WindowId, 2), snap2.windows[0].id);
}

test "wakes on message" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    const io = Io.Threaded.global_single_threaded.io();

    const Thread = std.Thread;
    const Ctx = struct {
        state: *State,
        io: Io,
    };
    var ctx: Ctx = .{ .state = &state, .io = io };

    const worker = try Thread.spawn(.{}, struct {
        fn run(c: *Ctx) void {
            c.state.windowUpsert(c.io, .{ .id = 3, .width = 1, .height = 1 }) catch {};
        }
    }.run, .{&ctx});

    var buf: std.ArrayListUnmanaged(Message) = .empty;
    defer buf.deinit(state.gpa);
    const shutdown = try state.drainBatch(io, &buf);
    try testing.expect(!shutdown);
    try testing.expectEqual(@as(usize, 1), buf.items.len);
    worker.join();
}

test "shutdown wakes waiter" {
    var state = State.init(testing.allocator);
    defer state.deinit();
    const io = Io.Threaded.global_single_threaded.io();

    const Thread = std.Thread;
    const Ctx = struct {
        state: *State,
        io: Io,
    };
    var ctx: Ctx = .{ .state = &state, .io = io };

    const worker = try Thread.spawn(.{}, struct {
        fn run(c: *Ctx) void {
            c.state.requestShutdown(c.io);
        }
    }.run, .{&ctx});

    var buf: std.ArrayListUnmanaged(Message) = .empty;
    defer buf.deinit(state.gpa);
    const shutdown = try state.drainBatch(io, &buf);
    try testing.expect(shutdown);
    try testing.expectEqual(@as(usize, 0), buf.items.len);
    worker.join();
}
