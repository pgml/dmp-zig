const options = @import("dmp_options");

pub const nullTerminated = options.nullTerminated;
pub const StrType = if (options.nullTerminated) [:0]const u8 else []const u8;
