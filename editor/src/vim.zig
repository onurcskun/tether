const std = @import("std");
const BitSet = std.bit_set.DynamicBitSetUnmanaged;
const Allocator = std.mem.Allocator;
const print = std.debug.print;
const ArrayList = std.ArrayListUnmanaged;

const metal = @import("./metal.zig");
const strutil = @import("./strutil.zig");
const Key = @import("./event.zig").Key;

const Self = @This();
pub const DEFAULT_PARSERS = [_]CommandParser{
    // move
    CommandParser.comptime_new(.Move, "<mv>", .{ .normal = true, .visual = true }),

    // delete
    CommandParser.comptime_new(.Delete, "<#> d <mv>", .{ .normal = true }),
    CommandParser.comptime_new(.Delete, "<#> d d", .{ .normal = true }),
    CommandParser.comptime_new(.Delete, "<#> d", .{ .visual = true }),

    // change
    CommandParser.comptime_new(.Change, "<#> c <mv>", .{ .normal = true }),
    CommandParser.comptime_new(.Change, "<#> c c", .{ .normal = true }),
    CommandParser.comptime_new(.Change, "<#> c", .{ .visual = true }),

    // yank
    CommandParser.comptime_new(.Yank, "<#> y <mv>", .{ .normal = true }),
    CommandParser.comptime_new(.Yank, "<#> y y", .{ .normal = true }),
    CommandParser.comptime_new(.Yank, "<#> y", .{ .visual = true }),

    // switch moves
    CommandParser.comptime_new(.SwitchMove, "<#> I", .{ .normal = true, .visual = true }),
    CommandParser.comptime_new(.SwitchMove, "<#> A", .{ .normal = true, .visual = true }),
    CommandParser.comptime_new(.SwitchMove, "<#> a", .{ .normal = true, .visual = true }),

    // newline
    CommandParser.comptime_new(.NewLine, "<#> O", .{ .normal = true, .visual = true }),
    CommandParser.comptime_new(.NewLine, "<#> o", .{ .normal = true, .visual = true }),

    // switch mode
    CommandParser.comptime_new(.SwitchMode, "<#> i", .{ .normal = true, .visual = false }),
    CommandParser.comptime_new(.SwitchMode, "<#> v", .{
        .normal = true,
    }),

    // paste
    CommandParser.comptime_new(.Paste, "<#> p", .{ .normal = true, .visual = true }),
    CommandParser.comptime_new(.PasteBefore, "<#> P", .{ .normal = true, .visual = true }),
};

mode: Mode = .Normal,

parsers: []CommandParser = &[_]CommandParser{},
failed_parsers: BitSet = .{},

pub fn init(self: *Self, alloc: Allocator, parsers: []const CommandParser) !void {
    self.parsers = try std.heap.c_allocator.alloc(CommandParser, parsers.len);
    var index: usize = 0;
    var i: usize = 0;
    while (i < parsers.len) {
        self.parsers[index] = try parsers[i].copy(std.heap.c_allocator);
        index += 1;
        i += 1;
    }
    self.failed_parsers = try BitSet.initEmpty(alloc, self.parsers.len);
}

pub fn parse(self: *Self, key: Key) ?Cmd {
    if (key == .Esc) {
        self.reset_parser();
        return .{ .repeat = 1, .kind = .{ .SwitchMode = .Normal } };
    }

    var i: usize = 0;
    while (i < self.parsers.len) : (i += 1) {
        if (self.failed_parsers.isSet(i)) continue;
        var p = &self.parsers[i];
        const res = p.parse(self.mode, key);
        if (res == .Accept) {
            const result = p.result(self.mode);
            self.reset_parser();
            return result;
        }
        if (res == .Fail) {
            self.failed_parsers.set(i);
        }
    }

    if (self.failed_parsers.count() == self.parsers.len) {
        self.reset_parser();
    }

    return null;
}

fn reset_parser(self: *Self) void {
    for (self.parsers) |*p| {
        p.reset();
    }
    self.failed_parsers.setRangeValue(.{ .start = 0, .end = self.parsers.len }, false);
}

pub const Mode = enum(u8) {
    Insert = 1,
    Normal = 2,
    Visual = 4,
};

pub const ValidMode = struct {
    insert: bool = false,
    normal: bool = false,
    visual: bool = false,
};

const FailError = error{ Continue, Reset };

pub const Cmd = struct {
    repeat: u16 = 1,
    kind: CmdKind,
};

pub const CmdKindEnum = enum {
    Delete,
    Change,
    Yank,

    Move,
    SwitchMove,
    SwitchMode,
    NewLine,
    Undo,
    Redo,
    Paste,
    PasteBefore,

    Custom,
};

pub const CmdTag = union(CmdKindEnum) {
    Delete,
    Change,
    Yank,

    Move,
    SwitchMove,
    SwitchMode,
    NewLine,
    Undo,
    Redo,
    Paste,
    PasteBefore,

    Custom: []const u8,
};

pub const CmdKind = union(CmdKindEnum) {
    Delete: ?Move,
    Change: ?Move,
    Yank: ?Move,

    Move: MoveKind,
    SwitchMove: struct { mv: MoveKind, mode: Mode },
    SwitchMode: Mode,
    NewLine: NewLine,
    Undo,
    Redo,
    Paste,
    PasteBefore,

    Custom: *CustomCmd,
};

pub const NewLine = struct { up: bool, switch_mode: bool };

pub const Move = struct {
    kind: MoveKind,
    repeat: u16,
};

pub const MoveKind = union(enum) {
    Left,
    Right,
    Up,
    Down,
    LineStart,
    LineEnd,
    // Bool is true if find in reverse
    Find: struct { char: u8, reverse: bool },
    ParagraphBegin,
    ParagraphEnd,
    Start,
    End,
    Word: bool,
    BeginningWord: bool,
    EndWord: bool,

    pub fn is_delete_end_inclusive(self: *const MoveKind) bool {
        return switch (self.*) {
            .Left, .Right, .Up, .Down, .LineStart, .LineEnd, .ParagraphBegin, .ParagraphEnd, .Start, .End, .Word, .BeginningWord, .EndWord => false,
            .Find => true,
        };
    }
};

pub const CustomCmd = struct {};

pub const CommandParser = struct {
    const Self = @This();

    inputs: []Input,
    data: Metadata,
    tag: CmdTag,

    const Metadata = packed struct {
        insert_mode: u1,
        normal_mode: u1,
        visual_mode: u1,
        _pad: u1 = 0,
        idx: u4 = 0,

        fn is_valid_mode(self: Metadata, mode: Mode) bool {
            return (@bitCast(u8, self) & 0b00000111) & @bitCast(u8, @enumToInt(mode)) != 0;
        }

        pub fn from_valid_modes(modes: ValidMode) Metadata {
            var ret: Metadata = .{ .idx = 0, .insert_mode = if (modes.insert) 1 else 0, .normal_mode = if (modes.normal) 1 else 0, .visual_mode = if (modes.visual) 1 else 0 };
            return ret;
        }
    };

    const InputEnum = enum {
        Number,
        Key,
        Move,
    };
    const Input = union(InputEnum) {
        Number: NumberParser,
        Key: KeyParser,
        Move: MoveParser,

        fn parse(self: *Input, key: Key) ParseResult {
            switch (@as(InputEnum, self.*)) {
                .Number => return self.Number.parse(key),
                .Key => return self.Key.parse(key),
                .Move => return self.Move.parse(key),
            }
        }

        fn copy(self: *const Input) Input {
            switch (self.*) {
                .Number => return .{ .Number = .{} },
                .Char => return .{ .Char = .{ .desired = self.Char.desired } },
                .Move => return .{ .Move = .{} },
            }
        }

        fn reset(self: *Input) void {
            switch (@as(InputEnum, self.*)) {
                .Number => self.Number.reset(),
                .Key => {
                    self.* = .{ .Key = .{ .desired = self.Key.desired } };
                },
                .Move => self.Move.reset(),
            }
        }
    };
    const ParseResult = enum { Accept, Fail, Continue, TryTransition, Skip };

    /// TODO: Rename to AmountParser because this is technically for amounts e.g. 20j, where 0 is not allowed
    const NumberParser = struct {
        amount: u16 = 0,

        fn result(self: *NumberParser) ?u16 {
            return if (self.amount == 0) null else self.amount;
        }

        fn parse(self: *NumberParser, key: Key) ParseResult {
            switch (key) {
                .Char => |c| {
                    switch (c) {
                        '0' => {
                            if (self.amount == 0) return .Skip;
                            self.amount *= 10;
                            return .Continue;
                        },
                        '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                            self.amount *= 10;
                            self.amount += c - 48;
                            return .Continue;
                        },
                        else => {
                            if (self.amount == 0) return .Skip;
                            return .TryTransition;
                        },
                    }
                },
                else => {
                    if (self.amount == 0) return .Skip;
                    return .TryTransition;
                },
            }
        }

        fn reset(self: *NumberParser) void {
            self.amount = 0;
        }
    };
    /// TODO: Rename to KeyParser, because this should match keys and not just chars
    const KeyParser = struct {
        desired: Key,

        fn result(self: *KeyParser) Key {
            return self.desired;
        }

        fn parse(self: *KeyParser, key: Key) ParseResult {
            if (key.eq(self.desired)) return .Accept;
            return .Fail;
        }
    };
    const MoveParser = struct {
        num: NumberParser = .{},
        keys: [4]Key = [_]Key{.Up} ** 4,
        data: PackedData = .{},
        kind: ?MoveKind = null,

        /// packed struct for additional fields so
        /// the struct can be packed into 16 bytes
        const PackedData = packed struct {
            keys_len: u6 = 0,
            _num_done: u1 = 0,
            _optional: u1 = 0,

            fn optional(self: PackedData) bool {
                return self._optional != 0;
            }

            fn num_done(self: PackedData) bool {
                return self._num_done != 0;
            }
        };

        fn reset(self: *MoveParser) void {
            self.num.reset();
            self.data = .{};
            self.kind = null;
        }

        fn result(self: *MoveParser) ?Move {
            const kind = self.kind orelse return null;
            const amount = self.num.result() orelse 1;
            return .{ .kind = kind, .repeat = amount };
        }

        fn parse(self: *MoveParser, key: Key) ParseResult {
            if (!self.data.num_done()) {
                const res = self.num.parse(key);
                switch (res) {
                    .Accept => {
                        self.data._num_done = 1;
                        return .Continue;
                    },
                    .Fail => {
                        self.data._num_done = 1;
                        self.num.reset();
                    },
                    .Continue => return .Continue,
                    .TryTransition => {
                        self.data._num_done = 1;
                    },
                    .Skip => {
                        self.data._num_done = 1;
                    },
                }
            }

            if (self.data.keys_len >= self.keys.len) {
                @panic("Too long!");
            }

            self.keys[self.data.keys_len] = key;

            switch (self.keys[0]) {
                .Char => |c| {
                    switch (c) {
                        '0' => return self.set_kind(.LineStart),
                        '$' => return self.set_kind(.LineEnd),
                        'h' => return self.set_kind(.Left),
                        'j' => return self.set_kind(.Down),
                        'k' => return self.set_kind(.Up),
                        'l' => return self.set_kind(.Right),
                        else => return if (self.data.optional()) .Skip else .Fail,
                    }
                },
                .Up => return self.set_kind(.Up),
                .Down => return self.set_kind(.Down),
                .Left => return self.set_kind(.Left),
                .Right => return self.set_kind(.Right),
                else => return if (self.data.optional()) .Skip else .Fail,
            }
        }

        fn set_kind(self: *MoveParser, kind: MoveKind) ParseResult {
            self.kind = kind;
            return .Accept;
        }
    };

    pub fn new(tag: CmdTag, inputs: []Input, metadata: Metadata) CommandParser {
        return .{
            .inputs = inputs,
            .data = metadata,
            .tag = tag,
        };
    }

    pub fn reset(self: *CommandParser) void {
        var i: usize = 0;
        while (i < self.inputs.len) {
            var input = &self.inputs[i];
            input.reset();
            i += 1;
        }
        self.data.idx = 0;
    }

    pub fn copy(self: *const CommandParser, alloc: Allocator) !CommandParser {
        var cpy = CommandParser{
            .data = self.data,
            .tag = self.tag,
            .inputs = try alloc.alloc(Input, self.inputs.len),
        };

        var i: usize = 0;
        while (i < self.inputs.len) {
            // var input = &self.inputs[i];
            // cpy.inputs[i] = input.copy();
            cpy.inputs[i] = self.inputs[i];
            i += 1;
        }

        return cpy;
    }

    fn is_valid_mode(self: *CommandParser, mode: Mode) bool {
        _ = mode;
        _ = self;
        // @ptrCast(u8, self.data + s)
        return true;
    }

    pub fn parse(self: *CommandParser, mode: Mode, key: Key) ParseResult {
        if (!self.data.is_valid_mode(mode)) return .Fail;
        if (self.data.idx >= self.inputs.len) return .Fail;

        var parser = &self.inputs[self.data.idx];
        const res = parser.parse(key);

        switch (res) {
            .Accept => {
                self.data.idx += 1;
                if (self.data.idx >= self.inputs.len) return .Accept;
                return .Continue;
            },
            .Skip, .TryTransition => {
                self.data.idx += 1;
                return self.parse(mode, key);
            },
            .Fail => return .Fail,
            .Continue => return .Continue,
        }
    }

    fn result_dcy(self: *CommandParser, comptime dcy_kind: CmdTag, mode: Mode) Cmd {
        const amount = self.inputs[0].Number.result() orelse 1;
        if (mode == .Visual) {
            const kind = k: {
                switch (dcy_kind) {
                    inline else => {
                        if (dcy_kind == .Delete) {
                            break :k .{ .Delete = null };
                        } else if (dcy_kind == .Change) {
                            break :k .{ .Change = null };
                        } else if (dcy_kind == .Yank) {
                            break :k .{ .Yank = null };
                        } else {
                            @panic("Invalid input");
                        }
                    },
                }
            };
            return .{ .repeat = amount, .kind = kind };
        }

        switch (@as(InputEnum, self.inputs[2])) {
            .Move => {
                const move = self.inputs[2].Move.result();
                const kind = k: {
                    switch (dcy_kind) {
                        inline else => {
                            if (dcy_kind == .Delete) {
                                break :k .{ .Delete = move };
                            } else if (dcy_kind == .Change) {
                                break :k .{ .Change = move };
                            } else if (dcy_kind == .Yank) {
                                break :k .{ .Yank = move };
                            } else {
                                @panic("Invalid input");
                            }
                        },
                    }
                };
                return .{ .repeat = amount, .kind = kind };
            },
            .Key => {
                const kind = k: {
                    switch (dcy_kind) {
                        inline else => {
                            if (dcy_kind == .Delete) {
                                break :k .{ .Delete = null };
                            } else if (dcy_kind == .Change) {
                                break :k .{ .Change = null };
                            } else if (dcy_kind == .Yank) {
                                break :k .{ .Yank = null };
                            } else {
                                @panic("Invalid input");
                            }
                        },
                    }
                };
                return .{ .repeat = amount, .kind = kind };
            },
            else => @panic("Invalid input"),
        }
    }

    pub fn result(self: *CommandParser, mode: Mode) Cmd {
        switch (self.tag) {
            .Move => {
                const move = self.inputs[0].Move.result() orelse @panic("oopts");
                return .{ .repeat = move.repeat, .kind = .{ .Move = move.kind } };
            },

            .Delete => {
                return self.result_dcy(.Delete, mode);
            },
            .Change => {
                return self.result_dcy(.Change, mode);
            },
            .Yank => {
                return self.result_dcy(.Yank, mode);
            },

            .SwitchMove => {
                const move_char = self.inputs[1].Key.result();
                switch (move_char) {
                    .Char => |c| {
                        switch (c) {
                            'I' => {
                                return .{ .repeat = 1, .kind = .{ .SwitchMove = .{ .mv = .LineStart, .mode = .Insert } } };
                            },
                            'A' => {
                                return .{ .repeat = 1, .kind = .{ .SwitchMove = .{ .mv = .LineEnd, .mode = .Insert } } };
                            },
                            'a' => {
                                return .{ .repeat = 1, .kind = .{ .SwitchMove = .{ .mv = .Right, .mode = .Insert } } };
                            },
                            else => @panic("Unknown char: " ++ [_]u8{c}),
                        }
                    },
                    else => @panic("Unknown key"),
                }
            },
            .SwitchMode => {
                const move_char = self.inputs[1].Key.result();
                const kind: Mode = b: {
                    switch (move_char) {
                        .Char => |c| {
                            switch (c) {
                                'i' => {
                                    break :b .Insert;
                                },
                                'v' => {
                                    break :b .Visual;
                                },
                                else => @panic("Unknown char: " ++ [_]u8{c}),
                            }
                        },
                        else => @panic("Unknown key"),
                    }
                };
                return .{
                    .repeat = 1,
                    .kind = .{ .SwitchMode = kind },
                };
            },
            .NewLine => {
                const amount = self.inputs[0].Number.result() orelse 1;
                const move_char = self.inputs[1].Key.result();
                const newline: NewLine = b: {
                    switch (move_char) {
                        .Char => |c| {
                            switch (c) {
                                'O' => {
                                    break :b .{ .up = true, .switch_mode = true };
                                },
                                'o' => {
                                    break :b .{ .up = false, .switch_mode = true };
                                },
                                else => @panic("Bad char: " ++ [_]u8{c}),
                            }
                        },
                        else => @panic("Bad key"),
                    }
                };
                return .{
                    .repeat = amount,
                    .kind = .{ .NewLine = newline },
                };
            },
            .Undo => {},
            .Redo => {},
            .Paste => {
                const amount = self.inputs[0].Number.result() orelse 1;
                return .{ .repeat = amount, .kind = .Paste };
            },
            .PasteBefore => {
                const amount = self.inputs[0].Number.result() orelse 1;
                return .{ .repeat = amount, .kind = .PasteBefore };
            },

            .Custom => |name| {
                _ = name;
                unreachable;
            },
        }
        unreachable;
    }

    pub fn comptime_new(comptime tag: CmdTag, comptime str: []const u8, comptime valid_modes: ValidMode) CommandParser {
        const N = comptime CommandParser.input_len_from_str(str);
        // var inputs = comptime _: {
        //     var inputs = [_]Input{.{ .Number = .{} }} ** N;
        //     var n: usize = N;
        //     _ = n;
        //     CommandParser.populate_from_str(inputs[0..N], str);
        //     break :_ inputs;
        // };
        var inputs = comptime input_blah(N, str);

        const metadata = comptime Metadata.from_valid_modes(valid_modes);
        const parser = CommandParser.new(tag, inputs, metadata);

        return parser;
    }

    fn input_blah(comptime N: usize, comptime str: []const u8) []Input {
        var inputs = [_]Input{.{ .Number = .{} }} ** N;
        var n: usize = N;
        CommandParser.populate_from_str(inputs[0..N], str);
        return inputs[0..n];
    }

    fn input_len_from_str(str: []const u8) usize {
        var iter = std.mem.splitSequence(u8, str, " ");
        var n: u32 = 0;
        while (iter.next()) |val| {
            if (std.mem.eql(u8, "<mv>", val)) {
                // n += 1;
            }
            n += 1;
        }
        return n;
    }

    fn populate_from_str(input: []Input, str: []const u8) void {
        var iter = std.mem.splitSequence(u8, str, " ");
        var i: usize = 0;
        while (iter.next()) |token| {
            const Case = enum {
                SPC,
                // ALT, CTRL,
                @"<mv>",
                @"<#>",
            };
            const case = std.meta.stringToEnum(Case, token) orelse {
                if (token.len != 1) {
                    @panic("Invalid token");
                }
                var val: Input = .{ .Key = .{ .desired = .{ .Char = token[0] } } };
                input[i] = val;
                i += 1;
                continue;
            };
            switch (case) {
                .SPC => {
                    input[i] = .{ .Char = .{ .desired = ' ' } };
                    i += 1;
                },
                // .ALT => .{ .Special = .ALT },
                // .CTRL => .{ .Special = .CTRL },
                .@"<mv>" => {
                    // input[i] = .{ .Number = .{} };
                    // i += 1;
                    input[i] = .{ .Move = .{} };
                    i += 1;
                },
                .@"<#>" => {
                    input[i] = .{ .Number = .{} };
                    i += 1;
                },
            }
        }
    }
};

fn test_parse(alloc: Allocator, vim: *Self, input: []const u8, expected: ?Cmd) !?Cmd {
    if (vim.parsers.len == 0) {
        try vim.init(alloc, DEFAULT_PARSERS[0..]);
    }
    for (input) |c| {
        if (vim.parse(.{ .Char = c })) |cmd| {
            try std.testing.expectEqualDeep(expected, cmd);
            return cmd;
        }
    }
    try std.testing.expectEqualDeep(expected, null);
    return null;
}

test "valid mode" {
    var mode: Mode = .Insert;
    var metadata = CommandParser.Metadata.from_valid_modes(.{ .insert = true, .normal = true });

    try std.testing.expectEqual(true, metadata.is_valid_mode(mode));

    mode = .Normal;
    metadata = CommandParser.Metadata.from_valid_modes(.{
        .insert = true,
    });

    try std.testing.expectEqual(false, metadata.is_valid_mode(mode));
}

test "command parse normal" {
    const alloc = std.heap.c_allocator;
    var self = Self{};

    // move
    _ = try test_parse(alloc, &self, "h", .{ .repeat = 1, .kind = .{ .Move = .Left } });
    _ = try test_parse(alloc, &self, "j", .{ .repeat = 1, .kind = .{ .Move = .Down } });
    _ = try test_parse(alloc, &self, "k", .{ .repeat = 1, .kind = .{ .Move = .Up } });
    _ = try test_parse(alloc, &self, "l", .{ .repeat = 1, .kind = .{ .Move = .Right } });
    _ = try test_parse(alloc, &self, "20l", .{ .repeat = 20, .kind = .{ .Move = .Right } });

    // d/c/y
    _ = try test_parse(alloc, &self, "69d20l", .{ .repeat = 69, .kind = .{ .Delete = .{ .repeat = 20, .kind = .Right } } });
    _ = try test_parse(alloc, &self, "69dd", .{ .repeat = 69, .kind = .{ .Delete = null } });
    _ = try test_parse(alloc, &self, "420c20l", .{ .repeat = 420, .kind = .{ .Change = .{ .repeat = 20, .kind = .Right } } });
    _ = try test_parse(alloc, &self, "420cc", .{ .repeat = 420, .kind = .{ .Change = null } });
    _ = try test_parse(alloc, &self, "420y20l", .{ .repeat = 420, .kind = .{ .Yank = .{ .repeat = 20, .kind = .Right } } });
    _ = try test_parse(alloc, &self, "420yy", .{ .repeat = 420, .kind = .{ .Yank = null } });

    // switch move
    _ = try test_parse(alloc, &self, "I", .{ .repeat = 1, .kind = .{ .SwitchMove = .{ .mv = .LineStart, .mode = .Insert } } });
    _ = try test_parse(alloc, &self, "22I", .{ .repeat = 1, .kind = .{ .SwitchMove = .{ .mv = .LineStart, .mode = .Insert } } });
    _ = try test_parse(alloc, &self, "A", .{ .repeat = 1, .kind = .{ .SwitchMove = .{ .mv = .LineEnd, .mode = .Insert } } });
    _ = try test_parse(alloc, &self, "1A", .{ .repeat = 1, .kind = .{ .SwitchMove = .{ .mv = .LineEnd, .mode = .Insert } } });
    _ = try test_parse(alloc, &self, "a", .{ .repeat = 1, .kind = .{ .SwitchMove = .{ .mv = .Right, .mode = .Insert } } });
    _ = try test_parse(alloc, &self, "50a", .{ .repeat = 1, .kind = .{ .SwitchMove = .{ .mv = .Right, .mode = .Insert } } });

    // newline
    _ = try test_parse(alloc, &self, "O", .{ .repeat = 1, .kind = .{ .NewLine = .{ .up = true, .switch_mode = true } } });
    _ = try test_parse(alloc, &self, "10O", .{ .repeat = 10, .kind = .{ .NewLine = .{ .up = true, .switch_mode = true } } });
    _ = try test_parse(alloc, &self, "o", .{ .repeat = 1, .kind = .{ .NewLine = .{ .up = false, .switch_mode = true } } });
    _ = try test_parse(alloc, &self, "50o", .{ .repeat = 50, .kind = .{ .NewLine = .{ .up = false, .switch_mode = true } } });

    // switch mode
    _ = try test_parse(alloc, &self, "i", .{ .repeat = 1, .kind = .{ .SwitchMode = .Insert } });
    _ = try test_parse(alloc, &self, "20i", .{ .repeat = 1, .kind = .{ .SwitchMode = .Insert } });
    _ = try test_parse(alloc, &self, "v", .{ .repeat = 1, .kind = .{ .SwitchMode = .Visual } });
    _ = try test_parse(alloc, &self, "200v", .{ .repeat = 1, .kind = .{ .SwitchMode = .Visual } });

    _ = try test_parse(alloc, &self, "200p", .{ .repeat = 200, .kind = .Paste });
    _ = try test_parse(alloc, &self, "200P", .{ .repeat = 200, .kind = .PasteBefore });
}

test "command parse visual" {
    const alloc = std.heap.c_allocator;
    var self = Self{};

    self.mode = .Visual;

    _ = try test_parse(alloc, &self, "12d", .{ .repeat = 12, .kind = .{ .Delete = null } });
    _ = try test_parse(alloc, &self, "d", .{ .repeat = 1, .kind = .{ .Delete = null } });
    _ = try test_parse(alloc, &self, "c", .{ .repeat = 1, .kind = .{ .Change = null } });
    _ = try test_parse(alloc, &self, "y", .{ .repeat = 1, .kind = .{ .Yank = null } });
}
