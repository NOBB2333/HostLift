const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const systemd = @import("services_systemd.zig");
const user_systemd = @import("services_user_systemd.zig");
const xdg = @import("services_xdg.zig");
const sysv = @import("services_sysv.zig");
const openrc = @import("services_openrc.zig");

// 聚合 services 模块的各类启动项规划 provider。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.ServiceInventory,
    target: inventory.ServiceInventory,
) !void {
    try systemd.appendActions(allocator, actions, source, target);
    try user_systemd.appendActions(allocator, actions, source.user_units, target.user_units);
    try xdg.appendActions(allocator, actions, source.xdg_autostart, target.xdg_autostart);
    try sysv.appendActions(allocator, actions, source.sysv_init, target.sysv_init);
    try openrc.appendActions(allocator, actions, source.openrc, target.openrc);
}
