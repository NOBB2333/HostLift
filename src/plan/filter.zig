const std = @import("std");
const filter_match = @import("filter_match.zig");
const plan = @import("schema.zig");

// 过滤模式枚举，支持包含和排除两种模式。
pub const Mode = enum { include, exclude };

// 表达模块和 action 前缀过滤规则，plan/apply 共用同一套筛选语义。
pub const ActionFilter = struct {
    include_modules: std.ArrayList(plan.ModuleName) = .empty,
    exclude_modules: std.ArrayList(plan.ModuleName) = .empty,
    include_actions: std.ArrayList([]const u8) = .empty,
    exclude_actions: std.ArrayList([]const u8) = .empty,

    pub const empty: ActionFilter = .{};

    // 释放 action 过滤器中收集的 include/exclude 列表。
    pub fn deinit(self: *ActionFilter, allocator: std.mem.Allocator) void {
        self.include_modules.deinit(allocator);
        self.exclude_modules.deinit(allocator);
        self.include_actions.deinit(allocator);
        self.exclude_actions.deinit(allocator);
    }

    // 判断当前是否没有任何过滤条件。
    pub fn isEmpty(self: ActionFilter) bool {
        return self.include_modules.items.len == 0 and
            self.exclude_modules.items.len == 0 and
            self.include_actions.items.len == 0 and
            self.exclude_actions.items.len == 0;
    }

    // 解析逗号分隔的模块列表并加入过滤器。
    pub fn appendModuleList(self: *ActionFilter, allocator: std.mem.Allocator, mode: Mode, value: []const u8) !void {
        var parts = std.mem.splitScalar(u8, value, ',');
        var appended = false;
        while (parts.next()) |raw_part| {
            const part = std.mem.trim(u8, raw_part, " \t\r\n");
            if (part.len == 0) continue;
            const module = try filter_match.parseModuleName(part);
            switch (mode) {
                .include => try self.include_modules.append(allocator, module),
                .exclude => try self.exclude_modules.append(allocator, module),
            }
            appended = true;
        }
        if (!appended) return error.MissingFilterValue;
    }

    // 加入 action id 前缀或完整 id 过滤规则。
    pub fn appendActionPattern(self: *ActionFilter, allocator: std.mem.Allocator, mode: Mode, value: []const u8) !void {
        try filter_match.validateActionPattern(value);
        switch (mode) {
            .include => try self.include_actions.append(allocator, value),
            .exclude => try self.exclude_actions.append(allocator, value),
        }
    }

    // 判断单个 action 是否通过当前 include/exclude 规则。
    pub fn matches(self: ActionFilter, action: plan.Action) bool {
        return filter_match.actionMatches(
            self.include_modules.items,
            self.exclude_modules.items,
            self.include_actions.items,
            self.exclude_actions.items,
            action,
        );
    }
};

// 统计过滤后会保留的 action 数量。
pub fn countSelectedActions(actions: []const plan.Action, filter: ActionFilter) usize {
    var count: usize = 0;
    for (actions) |action| {
        if (filter.matches(action)) count += 1;
    }
    return count;
}

// 根据用户选择裁剪计划中的 action 列表。
pub fn filterPlanActions(allocator: std.mem.Allocator, migration_plan: *plan.MigrationPlan, filter: ActionFilter) !void {
    if (filter.isEmpty()) return;

    var filtered: std.ArrayList(plan.Action) = .empty;
    errdefer {
        for (filtered.items) |action| deinitAction(allocator, action);
        filtered.deinit(allocator);
    }

    const old_actions = migration_plan.actions;
    for (old_actions) |action| {
        if (filter.matches(action)) {
            try filtered.append(allocator, action);
        } else {
            deinitAction(allocator, action);
        }
    }
    allocator.free(old_actions);
    migration_plan.actions = try filtered.toOwnedSlice(allocator);
}

// 释放单个 plan action 中由 builder 分配的字段。
fn deinitAction(allocator: std.mem.Allocator, action: plan.Action) void {
    plan.deinitAction(allocator, action);
}

test "action filter selects modules and action id prefixes" {
    var filter: ActionFilter = .empty;
    defer filter.deinit(std.testing.allocator);

    try filter.appendModuleList(std.testing.allocator, .include, "packages,services");
    try filter.appendModuleList(std.testing.allocator, .exclude, "services");
    try filter.appendActionPattern(std.testing.allocator, .exclude, "packages/review-held/");

    const install = plan.Action{
        .id = "packages/install/nginx",
        .module = .packages,
        .action_type = .install_package,
        .description = "Install package",
        .risk = .low,
        .requires_confirmation = false,
    };
    const held = plan.Action{
        .id = "packages/review-held/nginx",
        .module = .packages,
        .action_type = .manual_step,
        .description = "Review held package",
        .risk = .medium,
        .requires_confirmation = true,
    };
    const service = plan.Action{
        .id = "services/enable/nginx.service",
        .module = .services,
        .action_type = .enable_systemd_unit,
        .description = "Enable service",
        .risk = .low,
        .requires_confirmation = false,
    };

    try std.testing.expect(filter.matches(install));
    try std.testing.expect(!filter.matches(held));
    try std.testing.expect(!filter.matches(service));
}

test "action filter rejects unknown modules and unsafe action patterns" {
    var filter: ActionFilter = .empty;
    defer filter.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidFilterModule, filter.appendModuleList(std.testing.allocator, .include, "packages,unknown"));
    try std.testing.expectError(error.InvalidActionFilter, filter.appendActionPattern(std.testing.allocator, .include, "packages/install/*"));
}
