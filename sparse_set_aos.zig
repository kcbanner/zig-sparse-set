const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
/// Creates a Sparse Set with convenience functionality for a single AOS (Array of Structures)
/// See https://research.swtch.com/sparse
/// Useful for example in an Entity Component System that can handle many entities (sparse index),
/// but only a few of those will have a number of components (dense index), and you want to be able
/// to loop over the components using a regular linear for loop.
/// In short:
/// * O(1) Lookup from sparse to dense, and vice versa
/// * O(1) Has, Add and Remove.
/// * O(1) Clear (remove all elements)
/// * O(d) iteration (dense list).
/// * Dense list is unsorted if you remove elements.
/// * Unused elements of sparse and dense lists are undefined.
/// * Supports SoA-style component layout.
/// * Set errored to true for error checking, to false for speed.

// /// Like SparseSet, but with the handy addition of storing a ValueT array internally, saving
// /// the user some bookkeeping.
pub fn SparseSetAOS(comptime SparseT: type, comptime DenseT: type, comptime ValueT: type) type {
    return struct {
        const Self = @This();

        allocator: *Allocator,
        values: []ValueT,
        dense_to_sparse: []SparseT,
        sparse_to_dense: []DenseT,
        dense_count: DenseT,
        capacity_dense: DenseT,
        capacity_sparse: SparseT,

        pub fn init(allocator: *Allocator, capacity_sparse: SparseT, capacity_dense: DenseT) !Self {
            // Could be <= but I'm not sure why'd you use a sparse_set if you don't have more sparse
            // indices than dense...
            assert(capacity_dense < capacity_sparse);
            return Self{
                .allocator = allocator,
                .values = try allocator.alloc(ValueT, capacity_dense),
                .dense_to_sparse = try allocator.alloc(SparseT, capacity_dense),
                .sparse_to_dense = try allocator.alloc(DenseT, capacity_sparse),
                .capacity_dense = capacity_dense,
                .capacity_sparse = capacity_sparse,
                .dense_count = 0,
            };
        }

        pub fn deinit(self: Self) void {
            self.allocator.free(self.values);
            self.allocator.free(self.dense_to_sparse);
            self.allocator.free(self.sparse_to_dense);
        }

        pub fn clear(self: *Self) void {
            self.dense_count = 0;
        }

        pub fn len(self: Self) void {
            return self.dense_count;
        }

        pub fn toSparseSlice(self: Self) []SparseT {
            return self.dense_to_sparse[0..self.dense_count];
        }

        pub fn toValueSlice(self: Self) []ValueT {
            return self.values[0..self.dense_count];
        }

        pub fn remainingCapacity(self: Self) DenseT {
            return self.capacity_dense - self.dense_count;
        }

        /// Registers the sparse value and matches it to a dense index
        pub fn add(self: *Self, sparse: SparseT, value: ValueT) DenseT {
            self.dense_to_sparse[self.dense_count] = sparse;
            self.sparse_to_dense[sparse] = self.dense_count;
            self.values[self.dense_count] = value;
            self.dense_count += 1;
            return self.dense_count - 1;
        }

        /// May return error.OutOfBounds or error.AlreadyRegistered, otherwise calls add.
        pub fn addOrError(self: *Self, sparse: SparseT) !DenseT {
            if (self.dense_count == self.capacity_dense) {
                return error.OutOfBounds;
            }

            if (try self.hasSparseOrError(sparse)) {
                return error.AlreadyRegistered;
            }

            return self.add(sparse);
        }

        /// Removes the sparse/dense index, and replaces it with the last ones.
        /// dense_old and dense_new is
        pub fn removeWithInfo(self: *Self, sparse: SparseT, dense_old: *DenseT, dense_new: *DenseT) void {
            assert(self.dense_count > 0);
            var last_dense = self.dense_count - 1;
            var last_sparse = self.dense_to_sparse[last_dense];
            var dense = self.sparse_to_dense[sparse];
            self.dense_to_sparse[dense] = last_sparse;
            self.sparse_to_dense[last_sparse] = dense;
            self.dense_count -= 1;

            dense_old.* = last_dense;
            dense_new.* = dense;
        }

        /// May return error.OutOfBounds, otherwise alls removeWithInfo
        pub fn removeWithInfoOrError(self: *Self, sparse: SparseT, dense_old: *DenseT, dense_new: *DenseT) !void {
            if (self.dense_count == 0) {
                return error.OutOfBounds;
            }

            if (!self.hasSparse(sparse)) {
                return error.OutOfBounds;
            }

            return self.removeWithInfo(sparse, dense_old, dense_new);
        }

        /// Like removeWithInfo info, but slightly faster, in case you don't care about the switch
        pub fn remove(self: *Self, sparse: SparseT) void {
            assert(self.dense_count > 0);
            var last_dense = self.dense_count - 1;
            var last_sparse = self.dense_to_sparse[last_dense];
            var dense = self.sparse_to_dense[sparse];
            self.dense_to_sparse[dense] = last_sparse;
            self.sparse_to_dense[last_sparse] = dense;
            self.values[dense] = self.values[last_dense];
            self.dense_count -= 1;
        }

        pub fn removeOrError(self: *Self, sparse: SparseT) !void {
            if (errored and self.dense_count == 0) {
                return error.OutOfBounds;
            }
            return self.remove(sparse);
        }

        /// Returns true if the sparse is registered to a dense index
        pub fn hasSparse(self: Self, sparse: SparseT) bool {
            var dense = self.sparse_to_dense[sparse];
            return dense < self.dense_count and self.dense_to_sparse[dense] == sparse;
        }

        /// May return error.OutOfBounds, otherwise calls hasSparse
        pub fn hasSparseOrError(self: Self, sparse: SparseT) !bool {
            if (sparse >= self.capacity_sparse) {
                return error.OutOfBounds;
            }

            return self.hasSparse(sparse);
        }

        /// Returns corresponding dense index
        pub fn getBySparse(self: Self, sparse: SparseT) DenseT {
            return self.sparse_to_dense[sparse];
        }

        /// Tries hasSparseOrError, then returns getBySparse
        pub fn getBySparseOrError(self: Self, sparse: SparseT) !DenseT {
            _ = try self.hasSparseOrError(sparse);
            return self.getBySparse(sparse);
        }

        /// Returns corresponding sparse index
        pub fn getByDense(self: Self, dense: DenseT) SparseT {
            assert(dense < self.dense_count);
            return self.dense_to_sparse[dense];
        }

        /// Returns OutOfBounds or getByDense
        pub fn getByDenseOrError(self: Self, dense: DenseT) !SparseT {
            if (dense >= self.dense_count) {
                return error.OutOfBounds;
            }
            return self.getByDense(dense);
        }

        /// Returns a pointer to the SOA value corresponding to the sparse parameter.
        pub fn getValueBySparse(self: Self, sparse: SparseT) *ValueT {
            var dense = self.sparse_to_dense[sparse];
            return &self.values[dense];
        }

        // First tries hasSparse, then returns getValueBySparse()
        pub fn getValueBySparseOrError(self: Self, sparse: SparseT) !*ValueT {
            _ = try self.hasSparse(sparse);
            return getValueBySparse();
        }

        /// Returns a pointer to the SOA value corresponding to the sparse parameter.
        pub fn getValueByDense(self: Self, dense: DenseT) *ValueT {
            assert(dense < self.dense_count);
            return &self.values[dense];
        }

        // Returns error.OutOfBounds or getValueByDense()
        pub fn getValueByDenseOrError(self: Self, dense: DenseT) !*ValueT {
            if (dense >= self.dense_count) {
                return error.OutOfBounds;
            }
            return getValueByDense();
        }
    };
}
