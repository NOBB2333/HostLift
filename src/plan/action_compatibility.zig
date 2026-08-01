const std = @import("std");
const schema = @import("schema.zig");
const common = @import("modules/common.zig");

// action 的最低目标兼容要求；planner、validator 和 apply 必须共用这一分类。
pub const Requirement = enum {
    portable,
    same_arch,
    same_distro_version,
    same_package_manager,
    full_host,
};

// 根据 action 类型和模块返回最低兼容要求，不信任 plan 中的自由文本描述。
pub fn requirementForAction(action: schema.Action) Requirement {
    return switch (action.action_type) {
        .manual_step,
        .create_directory,
        .create_user,
        .create_group,
        .add_authorized_key,
        .copy_project_path,
        .postgresql_dump,
        .postgresql_target_baseline,
        .postgresql_transfer,
        .postgresql_restore,
        .postgresql_verify,
        .reinstall_download,
        .reinstall_execute,
        .reinstall_verify,
        => .portable,

        .copy_data_path => switch (action.module) {
            .appdata => .portable,
            .docker, .resources => .same_arch,
            else => .same_arch,
        },
        .copy_home_config => if (action.module == .home_configs) .portable else .same_distro_version,
        .start_compose_project, .verify_compose_project => .same_arch,

        .install_package => .same_package_manager,
        .add_repository => .full_host,

        .write_file,
        .merge_file,
        .install_systemd_unit,
        .enable_systemd_unit,
        .enable_user_systemd_unit,
        .enable_openrc_service,
        .disable_openrc_service,
        .enable_sysv_init,
        .disable_sysv_init,
        .install_cron_entry,
        .apply_firewall_config,
        => .same_distro_version,

        .run_command => .full_host,
    };
}

// 判断 compatibility 的各项事实是否构成完整主机兼容；架构必须一致。
pub fn isFullyCompatible(compatibility: schema.CompatibilityResult) bool {
    return compatibility.same_distro and
        compatibility.same_version and
        compatibility.same_package_manager and
        compatibility.same_arch;
}

// 按 action 最低要求判断该动作能否在目标主机自动执行。
pub fn isAllowed(action: schema.Action, compatibility: schema.CompatibilityResult) bool {
    return switch (requirementForAction(action)) {
        .portable => true,
        .same_arch => compatibility.same_arch,
        .same_distro_version => compatibility.same_distro and compatibility.same_version,
        .same_package_manager => compatibility.same_package_manager,
        .full_host => isFullyCompatible(compatibility),
    };
}

// 对单个 action 执行失败关闭兼容门禁，供 approved apply 防御性复核。
pub fn ensureAllowed(action: schema.Action, compatibility: schema.CompatibilityResult) !void {
    if (!isAllowed(action, compatibility)) return error.ActionCompatibilityMismatch;
}

// 返回结构化人工审查使用的兼容性不满足原因，不包含可执行命令或 secret。
pub fn mismatchReason(action: schema.Action, compatibility: schema.CompatibilityResult) []const u8 {
    return switch (requirementForAction(action)) {
        .portable => "portable action has no host compatibility mismatch",
        .same_arch => if (!compatibility.same_arch)
            "source and target CPU architectures differ or are unknown"
        else
            "CPU architecture requirement is satisfied",
        .same_distro_version => if (!compatibility.same_distro and !compatibility.same_version)
            "source and target Linux distributions and versions differ or are unknown"
        else if (!compatibility.same_distro)
            "source and target Linux distributions differ or are unknown"
        else if (!compatibility.same_version)
            "source and target Linux distribution versions differ or are unknown"
        else
            "distribution and version requirements are satisfied",
        .same_package_manager => if (!compatibility.same_package_manager)
            "source and target package managers differ or are unknown"
        else
            "package manager requirement is satisfied",
        .full_host => if (!isFullyCompatible(compatibility))
            "source and target do not match on distribution, version, package manager, and CPU architecture"
        else
            "full host compatibility requirement is satisfied",
    };
}

// 将 builder 生成但不满足目标兼容要求的自动 action 原位改写为结构化人工审查任务。
pub fn replaceBlockedWithManualReviews(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(schema.Action),
    compatibility: schema.CompatibilityResult,
) !void {
    var blocked_indexes: std.ArrayList(usize) = .empty;
    defer blocked_indexes.deinit(allocator);
    var replacements: std.ArrayList(schema.Action) = .empty;
    defer replacements.deinit(allocator);
    errdefer for (replacements.items) |action| schema.deinitAction(allocator, action);

    for (actions.items, 0..) |action, index| {
        if (isAllowed(action, compatibility)) continue;
        try blocked_indexes.append(allocator, index);
        const inputs = [_]common.ManualInputSpec{
            .{ .name = "blocked_action_id", .value = action.id },
            .{ .name = "blocked_action_type", .value = @tagName(action.action_type) },
            .{ .name = "blocked_action_module", .value = @tagName(action.module) },
            .{ .name = "required_compatibility", .value = @tagName(requirementForAction(action)) },
            .{ .name = "mismatch", .value = mismatchReason(action, compatibility) },
            .{ .name = "blocked_description", .value = action.description },
        };
        try common.appendAction(allocator, &replacements, .{
            .id_prefix = "compatibility/review",
            .name = action.id,
            .subject = action.subject,
            .module = action.module,
            .action_type = .manual_step,
            .risk = .high,
            .requires_confirmation = true,
            .description = "Review action blocked by target compatibility policy",
            .manual_task_spec = .{
                .provider = "compatibility_review",
                .inputs = &inputs,
            },
        });
    }

    std.debug.assert(blocked_indexes.items.len == replacements.items.len);
    for (blocked_indexes.items, replacements.items) |index, replacement| {
        schema.deinitAction(allocator, actions.items[index]);
        actions.items[index] = replacement;
    }
}

test "portable project and app data actions remain allowed across hosts" {
    const compatibility: schema.CompatibilityResult = .{
        .compatible = false,
        .same_distro = false,
        .same_version = false,
        .same_package_manager = false,
        .same_arch = false,
        .reason = "incompatible",
    };
    const project = schema.Action{
        .id = "projects/copy//srv/app",
        .module = .projects,
        .action_type = .copy_project_path,
        .description = "copy",
        .risk = .medium,
        .requires_confirmation = true,
    };
    const appdata = schema.Action{
        .id = "appdata/copy//srv/data",
        .module = .appdata,
        .action_type = .copy_data_path,
        .description = "copy",
        .risk = .medium,
        .requires_confirmation = true,
    };

    try std.testing.expect(isAllowed(project, compatibility));
    try std.testing.expect(isAllowed(appdata, compatibility));
}

test "resource copy is blocked across architectures and rewritten as provider task" {
    var actions: std.ArrayList(schema.Action) = .empty;
    defer {
        for (actions.items) |action| schema.deinitAction(std.testing.allocator, action);
        actions.deinit(std.testing.allocator);
    }
    try common.appendAction(std.testing.allocator, &actions, .{
        .id_prefix = "resources/copy",
        .name = "/opt/tool",
        .module = .resources,
        .action_type = .copy_data_path,
        .risk = .high,
        .requires_confirmation = true,
        .description = "copy resource",
    });
    const compatibility: schema.CompatibilityResult = .{
        .compatible = false,
        .same_distro = true,
        .same_version = true,
        .same_package_manager = true,
        .same_arch = false,
        .reason = "architecture mismatch",
    };

    try replaceBlockedWithManualReviews(std.testing.allocator, &actions, compatibility);

    try std.testing.expectEqual(@as(usize, 1), actions.items.len);
    try std.testing.expectEqual(schema.ActionType.manual_step, actions.items[0].action_type);
    try std.testing.expectEqualStrings("compatibility_review", actions.items[0].manual_task.?.provider);
    try std.testing.expectEqualStrings("same_arch", actions.items[0].manual_task.?.inputs[4].value.?);
}
