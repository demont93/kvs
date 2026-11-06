const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;
const SmpAllocator = std.heap.SmpAllocator;
const Io = std.Io;
const assert = std.debug.assert;

const CountAllocator = struct {
    smp_alloc: SmpAllocator = .{},
    alloc_count: usize = 0,
    remap_count: usize = 0,
    resize_count: usize = 0,

    const VTable = Allocator.VTable{
        .alloc = alloc,
        .free = SmpAllocator.vtable.free,
        .remap = remap,
        .resize = resize,
    };

    fn allocator(self: *CountAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &VTable,
        };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        var self: *CountAllocator = @ptrCast(@alignCast(context));
        const res = SmpAllocator.vtable.alloc(&self.smp_alloc, len, alignment, ret_addr);
        if (res != null) {
            self.alloc_count += 1;
        }
        return res;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        var self: *CountAllocator = @ptrCast(@alignCast(context));
        const res = SmpAllocator.vtable.remap(
            &self.smp_alloc,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
        if (res != null) {
            self.remap_count += 1;
        }
        return res;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        var self: *CountAllocator = @ptrCast(@alignCast(context));
        const res = SmpAllocator.vtable.resize(
            &self.smp_alloc,
            memory,
            alignment,
            new_len,
            ret_addr,
        );
        if (res) {
            self.resize_count += 1;
        }
        return res;
    }
};