const codec = @import("codec.zig");
const schema = @import("schema.zig");

pub const schema_version = schema.schema_version;
pub const Entry = schema.Entry;
pub const validateEntry = schema.validateEntry;
pub const writeEntry = codec.writeEntry;
