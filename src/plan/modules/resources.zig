const std = @import("std");
const inventory = @import("../../inventory/schema.zig");
const plan = @import("../schema.zig");
const common = @import("common.zig");
const manual_common = @import("manual_common.zig");

// 规划整机资源地图中的可迁移资源；缓存和包管理器托管资源默认不生成动作。
pub fn appendActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.ResourceInventory,
    target: inventory.ResourceInventory,
) !void {
    for (source.resources) |resource| {
        if (!resource.present) continue;
        if (resourceAlreadyPresent(target.resources, resource.path)) continue;
        if (resource.default_action == .exclude or resource.kind == .package_managed or resource.kind == .cache or resource.kind == .ephemeral) continue;

        if (shouldEmitSecurityReview(resource)) {
            try appendSecurityReviewStep(allocator, actions, resource);
        }
        if (shouldEmitManifestVerifyStep(resource)) {
            try appendManifestVerifyStep(allocator, actions, resource);
        }

        if (resource.default_action == .copy) {
            try common.appendAction(allocator, actions, .{
                .id_prefix = "resources/copy",
                .name = resource.path,
                .subject = resource.path,
                .module = .resources,
                .action_type = .copy_data_path,
                .risk = riskForResource(resource),
                .requires_confirmation = true,
                .description = descriptionForCopy(resource),
                .recursive = resource.directory,
                .file_count = resource.file_count,
            });
            if (shouldEmitReinstallStep(resource)) {
                try appendReinstallStep(allocator, actions, resource);
            }
            continue;
        }

        if (shouldEmitReinstallStep(resource)) {
            try appendReinstallStep(allocator, actions, resource);
            continue;
        }

        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "resources/review",
            .name = resource.path,
            .subject = resource.path,
            .module = .resources,
            .risk = .high,
            .description = descriptionForReview(resource),
        });
    }

    for (target.resources) |resource| {
        if (!resource.present) continue;
        if (resource.default_action == .exclude or resource.kind == .cache or resource.kind == .ephemeral) continue;
        if (resourceAlreadyPresent(source.resources, resource.path)) continue;
        const description = try cleanupDescription(allocator, resource);
        defer allocator.free(description);
        try manual_common.appendManualStep(allocator, actions, .{
            .id_prefix = "resources/cleanup-review",
            .name = resource.path,
            .subject = resource.path,
            .module = .resources,
            .risk = .high,
            .description = description,
        });
    }
}

// 根据默认复制资源的估算占用和目标挂载点可用容量生成容量风险提醒。
pub fn appendCapacityReviewActions(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(plan.Action),
    source: inventory.ResourceInventory,
    target: inventory.ResourceInventory,
    source_storage: inventory.StorageInventory,
    target_storage: inventory.StorageInventory,
) !void {
    var required_total: u64 = 0;
    var capacity_seen = false;

    for (source.resources) |resource| {
        if (!resourceCountsForCapacity(resource)) continue;
        if (resourceAlreadyPresent(target.resources, resource.path)) continue;
        const required = sizeForCapacity(resource);
        if (required == 0) continue;
        required_total += required;
        const mount = bestMountForPath(target_storage.mounts, resource.path) orelse continue;
        if (mount.available_bytes == 0) continue;
        capacity_seen = true;
        if (capacityRisky(required, mount.available_bytes) or inodeRisky(resource.file_count, mount.available_inodes)) {
            try appendCapacityStep(allocator, actions, mount.mount_point, "Review target capacity before migration; selected default-copy resources may consume most available bytes or inodes on this mount");
        }
    }

    if (required_total > 0 and !capacity_seen) {
        try appendCapacityStep(allocator, actions, "unknown", "Target capacity facts unavailable; rescan target storage or verify free disk and inode capacity before copying resources");
    }

    if (source_storage.memory_total_bytes > 0 and target_storage.memory_total_bytes > 0 and target_storage.memory_total_bytes < source_storage.memory_total_bytes) {
        try appendCapacityStep(allocator, actions, "memory", "Review target memory before migration; target total memory is lower than source and migrated services may need smaller batches or tuning");
    }
    if (source_storage.swap_total_bytes > 0 and target_storage.swap_total_bytes < source_storage.swap_total_bytes) {
        try appendCapacityStep(allocator, actions, "swap", "Review target swap before migration; target swap is lower than source and memory pressure may change after service startup");
    }
}

fn appendCapacityStep(allocator: std.mem.Allocator, actions: *std.ArrayList(plan.Action), name: []const u8, description: []const u8) !void {
    if (hasAction(actions.items, "resources/capacity", name)) return;
    try manual_common.appendManualStep(allocator, actions, .{
        .id_prefix = "resources/capacity",
        .name = name,
        .subject = name,
        .module = .resources,
        .risk = .high,
        .description = description,
    });
}

fn resourceCountsForCapacity(resource: inventory.ResourceRef) bool {
    if (!resource.present) return false;
    if (resource.default_action != .copy) return false;
    return resource.kind != .package_managed and resource.kind != .cache and resource.kind != .ephemeral;
}

fn sizeForCapacity(resource: inventory.ResourceRef) u64 {
    return if (resource.disk_usage > 0) resource.disk_usage else resource.logical_size;
}

fn capacityRisky(required: u64, available: u64) bool {
    if (available == 0) return false;
    if (required > available) return true;
    return required >= (available / 10) * 8;
}

fn inodeRisky(required: u64, available: u64) bool {
    if (required == 0 or available == 0) return false;
    if (required > available) return true;
    return required >= (available / 10) * 8;
}

fn bestMountForPath(mounts: []const inventory.MountEntry, path: []const u8) ?inventory.MountEntry {
    var best: ?inventory.MountEntry = null;
    for (mounts) |mount| {
        if (!pathBelongsToMount(path, mount.mount_point)) continue;
        if (best == null or mount.mount_point.len > best.?.mount_point.len) best = mount;
    }
    return best;
}

fn pathBelongsToMount(path: []const u8, mount_point: []const u8) bool {
    if (std.mem.eql(u8, mount_point, "/")) return std.mem.startsWith(u8, path, "/");
    if (std.mem.eql(u8, path, mount_point)) return true;
    return std.mem.startsWith(u8, path, mount_point) and path.len > mount_point.len and path[mount_point.len] == '/';
}

fn hasAction(actions: []const plan.Action, id_prefix: []const u8, name: []const u8) bool {
    for (actions) |action| {
        if (std.mem.startsWith(u8, action.id, id_prefix) and std.mem.endsWith(u8, action.id, name)) return true;
    }
    return false;
}

fn appendReinstallStep(allocator: std.mem.Allocator, actions: *std.ArrayList(plan.Action), resource: inventory.ResourceRef) !void {
    const description = try reinstallDescription(allocator, resource);
    defer allocator.free(description);
    var task_inputs: [9]common.ManualInputSpec = undefined;
    var input_count: usize = 0;
    task_inputs[input_count] = .{ .name = "artifact_path", .value = resource.path };
    input_count += 1;
    task_inputs[input_count] = .{ .name = "resource_kind", .value = @tagName(resource.kind) };
    input_count += 1;
    appendOptionalTaskInput(&task_inputs, &input_count, "sha256", resource.sha256);
    appendOptionalTaskInput(&task_inputs, &input_count, "file_type", resource.file_type);
    appendOptionalTaskInput(&task_inputs, &input_count, "dynamic_link_summary", resource.dynamic_link_summary);
    appendOptionalTaskInput(&task_inputs, &input_count, "owner", resource.owner_group orelse resource.owner);
    appendOptionalTaskInput(&task_inputs, &input_count, "mode", resource.mode);
    appendOptionalTaskInput(&task_inputs, &input_count, "mtime", resource.mtime_unix);
    appendOptionalTaskInput(&task_inputs, &input_count, "security_summary", resource.security_summary);
    try manual_common.appendManualStep(allocator, actions, .{
        .id_prefix = "resources/reinstall",
        .name = resource.path,
        .subject = resource.path,
        .module = .resources,
        .risk = .high,
        .description = description,
        .task_provider = "resource_reinstall",
        .task_inputs = task_inputs[0..input_count],
    });
}

fn appendOptionalTaskInput(
    inputs: *[9]common.ManualInputSpec,
    count: *usize,
    name: []const u8,
    value: ?[]const u8,
) void {
    const present = value orelse return;
    inputs[count.*] = .{ .name = name, .value = present, .required = false };
    count.* += 1;
}

fn appendSecurityReviewStep(allocator: std.mem.Allocator, actions: *std.ArrayList(plan.Action), resource: inventory.ResourceRef) !void {
    const description = try securityReviewDescription(allocator, resource);
    defer allocator.free(description);
    try manual_common.appendManualStep(allocator, actions, .{
        .id_prefix = "resources/security-review",
        .name = resource.path,
        .subject = resource.path,
        .module = .resources,
        .risk = if (resource.security_summary != null) .high else .medium,
        .description = description,
    });
}

fn appendManifestVerifyStep(allocator: std.mem.Allocator, actions: *std.ArrayList(plan.Action), resource: inventory.ResourceRef) !void {
    const description = try std.fmt.allocPrint(
        allocator,
        "Review manifest or checksum sampling for large directory before and after copy; disk={d} files={d}",
        .{ resource.disk_usage, resource.file_count },
    );
    defer allocator.free(description);
    try manual_common.appendManualStep(allocator, actions, .{
        .id_prefix = "resources/verify-manifest",
        .name = resource.path,
        .subject = resource.path,
        .module = .resources,
        .risk = .high,
        .description = description,
    });
}

fn resourceAlreadyPresent(resources: []const inventory.ResourceRef, path: []const u8) bool {
    for (resources) |resource| {
        if (resource.present and std.mem.eql(u8, resource.path, path)) return true;
    }
    return false;
}

fn shouldEmitReinstallStep(resource: inventory.ResourceRef) bool {
    if (resource.package_owner != null) return false;
    return switch (resource.kind) {
        .unmanaged_executable => true,
        .install_root => hasExecutableEvidence(resource),
        else => false,
    };
}

fn shouldEmitSecurityReview(resource: inventory.ResourceRef) bool {
    if (resource.package_owner != null) return false;
    if (resource.security_summary != null) return true;
    return resource.kind == .unmanaged_executable and (resource.sha256 != null or resource.mode != null or resource.mtime_unix != null);
}

fn shouldEmitManifestVerifyStep(resource: inventory.ResourceRef) bool {
    if (!resource.directory or resource.default_action != .copy) return false;
    if (resource.file_count >= 20_000) return true;
    return resource.disk_usage >= 1024 * 1024 * 1024;
}

fn hasExecutableEvidence(resource: inventory.ResourceRef) bool {
    for (resource.evidence) |evidence| {
        if (std.mem.indexOf(u8, evidence, "executable") != null) return true;
        if (std.mem.indexOf(u8, evidence, "Exec path") != null) return true;
        if (std.mem.indexOf(u8, evidence, "command path") != null) return true;
        if (std.mem.indexOf(u8, evidence, "profile or tool config") != null) return true;
    }
    return false;
}

fn riskForResource(resource: inventory.ResourceRef) plan.RiskLevel {
    return switch (resource.sensitivity) {
        .secret => .critical,
        .sensitive => .high,
        .ephemeral => .high,
        .normal => if (resource.directory) .high else .medium,
    };
}

fn descriptionForCopy(resource: inventory.ResourceRef) []const u8 {
    return switch (resource.kind) {
        .login_state => "Copy selected login/application state path after sensitive data review",
        .install_root => "Copy selected unmanaged install root after dependency review",
        .app_data => "Copy selected app data resource after size and service review",
        .home_state => "Copy selected home state resource after owner and sensitive data review",
        else => "Copy selected resource after review",
    };
}

fn descriptionForReview(resource: inventory.ResourceRef) []const u8 {
    return switch (resource.kind) {
        .install_root => "Review unmanaged install root before migration",
        .home_state => "Review user home state before migration",
        .app_data => if (isStatefulDataPath(resource.path))
            "Review stateful service data before migration; prefer dump, snapshot, or stop-write backup instead of hot-copying data files"
        else
            "Review app data resource before migration",
        else => "Review discovered resource before migration",
    };
}

fn isStatefulDataPath(path: []const u8) bool {
    const stateful_paths = [_][]const u8{
        "/var/lib/mysql",
        "/var/lib/postgresql",
        "/var/lib/redis",
        "/var/lib/mongodb",
        "/var/lib/elasticsearch",
        "/var/lib/rabbitmq",
        "/var/lib/kafka",
    };
    for (stateful_paths) |candidate| {
        if (std.mem.eql(u8, path, candidate)) return true;
    }
    return false;
}

fn reinstallDescription(allocator: std.mem.Allocator, resource: inventory.ResourceRef) ![]const u8 {
    const base = switch (resource.kind) {
        .unmanaged_executable => "Review reinstall path for unmanaged executable",
        .install_root => "Review reinstall path for unmanaged install root",
        else => "Review reinstall path for discovered unmanaged resource",
    };
    return std.fmt.allocPrint(
        allocator,
        "{s}; confirm source URL, version, checksum, config directory and dependencies; sha256={s} mode={s} mtime={s}",
        .{
            base,
            resource.sha256 orelse "unknown",
            resource.mode orelse "unknown",
            resource.mtime_unix orelse "unknown",
        },
    );
}

fn securityReviewDescription(allocator: std.mem.Allocator, resource: inventory.ResourceRef) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Review lightweight resource security facts before migration; sha256={s} owner={s} mode={s} mtime={s} findings={s}",
        .{
            resource.sha256 orelse "directory-or-unavailable",
            resource.owner_group orelse resource.owner orelse "unknown",
            resource.mode orelse "unknown",
            resource.mtime_unix orelse "unknown",
            resource.security_summary orelse "none",
        },
    );
}

fn cleanupDescription(allocator: std.mem.Allocator, resource: inventory.ResourceRef) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "Review target-only resource before cleanup; HostLift never deletes extra files automatically; disk={d} files={d} owner={s} mode={s}",
        .{
            resource.disk_usage,
            resource.file_count,
            resource.owner_group orelse resource.owner orelse "unknown",
            resource.mode orelse "unknown",
        },
    );
}

test "resources plan copies login state and reviews unmanaged executable" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer freeTestActions(&actions);

    var source_resources = [_]inventory.ResourceRef{
        .{
            .path = "/home/alice/.config",
            .directory = true,
            .kind = .login_state,
            .sensitivity = .sensitive,
            .default_action = .copy,
            .file_count = 42,
        },
        .{
            .path = "/home/alice/.local/bin/tool",
            .kind = .unmanaged_executable,
            .default_action = .review,
        },
    };

    try appendActions(std.testing.allocator, &actions, .{ .resources = source_resources[0..] }, .{});

    try std.testing.expectEqual(@as(usize, 2), actions.items.len);
    try std.testing.expectEqual(plan.ActionType.copy_data_path, actions.items[0].action_type);
    try std.testing.expectEqual(@as(u64, 42), actions.items[0].file_count);
    try std.testing.expectEqual(plan.ActionType.manual_step, actions.items[1].action_type);
    try std.testing.expectEqualStrings("resources/reinstall//home/alice/.local/bin/tool", actions.items[1].id);
    try std.testing.expectEqual(plan.ModuleName.resources, actions.items[0].module);
}

test "resources plan keeps install root copy but adds reinstall review" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer freeTestActions(&actions);

    var evidence = [_][]const u8{"systemd unit Exec path"};
    var source_resources = [_]inventory.ResourceRef{.{
        .path = "/opt/myapp",
        .directory = true,
        .kind = .install_root,
        .default_action = .copy,
        .evidence = evidence[0..],
    }};

    try appendActions(std.testing.allocator, &actions, .{ .resources = source_resources[0..] }, .{});

    try std.testing.expectEqual(@as(usize, 2), actions.items.len);
    try std.testing.expectEqual(plan.ActionType.copy_data_path, actions.items[0].action_type);
    try std.testing.expectEqual(plan.ActionType.manual_step, actions.items[1].action_type);
    try std.testing.expectEqualStrings("resources/reinstall//opt/myapp", actions.items[1].id);
}

test "resources reinstall task preserves artifact verification facts" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer freeTestActions(&actions);
    var source_resources = [_]inventory.ResourceRef{.{
        .path = "/usr/local/bin/tool",
        .kind = .unmanaged_executable,
        .default_action = .review,
        .sha256 = "abcdef",
        .file_type = "ELF 64-bit",
        .dynamic_link_summary = "libc.so.6",
        .owner_group = "root:root",
        .mode = "0755",
        .mtime_unix = "123",
    }};

    try appendActions(std.testing.allocator, &actions, .{ .resources = &source_resources }, .{});
    const action = findTestAction(actions.items, "resources/reinstall//usr/local/bin/tool").?;
    const task = action.manual_task.?;
    try std.testing.expectEqualStrings("resource_reinstall", task.provider);
    try std.testing.expectEqualStrings("abcdef", testManualInputValue(task, "sha256").?);
    try std.testing.expectEqualStrings("libc.so.6", testManualInputValue(task, "dynamic_link_summary").?);
    try std.testing.expectEqualStrings("root:root", testManualInputValue(task, "owner").?);
}

test "resources plan describes stateful data as backup review" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer freeTestActions(&actions);

    var source_resources = [_]inventory.ResourceRef{.{
        .path = "/var/lib/postgresql",
        .directory = true,
        .kind = .app_data,
        .sensitivity = .sensitive,
        .default_action = .review,
    }};

    try appendActions(std.testing.allocator, &actions, .{ .resources = source_resources[0..] }, .{});

    try std.testing.expectEqual(@as(usize, 1), actions.items.len);
    try std.testing.expectEqual(plan.ActionType.manual_step, actions.items[0].action_type);
    try std.testing.expect(std.mem.indexOf(u8, actions.items[0].description, "dump") != null);
    try std.testing.expect(std.mem.indexOf(u8, actions.items[0].description, "snapshot") != null);
}

test "resources capacity review warns when default copy is large for target mount" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer freeTestActions(&actions);

    var source_resources = [_]inventory.ResourceRef{.{
        .path = "/home/alice/.config",
        .directory = true,
        .kind = .login_state,
        .default_action = .copy,
        .logical_size = 900,
        .disk_usage = 900,
    }};
    var target_mounts = [_]inventory.MountEntry{.{
        .mount_point = "/home",
        .fs_type = "ext4",
        .source = "/dev/vdb1",
        .options = "rw",
        .total_bytes = 1000,
        .available_bytes = 1000,
    }};

    try appendCapacityReviewActions(
        std.testing.allocator,
        &actions,
        .{ .resources = source_resources[0..] },
        .{},
        .{ .fstab_entries = &.{}, .mounts = &.{} },
        .{ .fstab_entries = &.{}, .mounts = target_mounts[0..] },
    );

    try std.testing.expectEqual(@as(usize, 1), actions.items.len);
    try std.testing.expectEqualStrings("resources/capacity//home", actions.items[0].id);
}

test "resources capacity review warns when default copy consumes target inodes" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer freeTestActions(&actions);

    var source_resources = [_]inventory.ResourceRef{.{
        .path = "/home/alice/.cache-small-files",
        .directory = true,
        .kind = .login_state,
        .default_action = .copy,
        .logical_size = 100,
        .disk_usage = 100,
        .file_count = 900,
    }};
    var target_mounts = [_]inventory.MountEntry{.{
        .mount_point = "/home",
        .fs_type = "ext4",
        .source = "/dev/vdb1",
        .options = "rw",
        .total_bytes = 10_000,
        .available_bytes = 10_000,
        .total_inodes = 1000,
        .available_inodes = 1000,
    }};

    try appendCapacityReviewActions(
        std.testing.allocator,
        &actions,
        .{ .resources = source_resources[0..] },
        .{},
        .{ .fstab_entries = &.{}, .mounts = &.{} },
        .{ .fstab_entries = &.{}, .mounts = target_mounts[0..] },
    );

    try std.testing.expectEqual(@as(usize, 1), actions.items.len);
    try std.testing.expectEqualStrings("resources/capacity//home", actions.items[0].id);
    try std.testing.expect(std.mem.indexOf(u8, actions.items[0].description, "inodes") != null);
}

test "resources capacity review warns when target memory is smaller than source" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer freeTestActions(&actions);

    try appendCapacityReviewActions(
        std.testing.allocator,
        &actions,
        .{},
        .{},
        .{ .fstab_entries = &.{}, .mounts = &.{}, .memory_total_bytes = 8 * 1024 },
        .{ .fstab_entries = &.{}, .mounts = &.{}, .memory_total_bytes = 4 * 1024 },
    );

    try std.testing.expectEqual(@as(usize, 1), actions.items.len);
    try std.testing.expectEqualStrings("resources/capacity/memory", actions.items[0].id);
}

test "resources plan reviews target-only cleanup without deleting" {
    var actions: std.ArrayList(plan.Action) = .empty;
    defer freeTestActions(&actions);

    var target_resources = [_]inventory.ResourceRef{.{
        .path = "/opt/old-tool",
        .directory = true,
        .kind = .install_root,
        .default_action = .review,
    }};

    try appendActions(std.testing.allocator, &actions, .{}, .{ .resources = target_resources[0..] });

    try std.testing.expectEqual(@as(usize, 1), actions.items.len);
    try std.testing.expectEqualStrings("resources/cleanup-review//opt/old-tool", actions.items[0].id);
    try std.testing.expectEqual(plan.ActionType.manual_step, actions.items[0].action_type);
}

fn freeTestActions(actions: *std.ArrayList(plan.Action)) void {
    for (actions.items) |action| plan.deinitAction(std.testing.allocator, action);
    actions.deinit(std.testing.allocator);
}

fn findTestAction(actions: []const plan.Action, id: []const u8) ?plan.Action {
    for (actions) |action| {
        if (std.mem.eql(u8, action.id, id)) return action;
    }
    return null;
}

fn testManualInputValue(task: plan.ManualTask, name: []const u8) ?[]const u8 {
    for (task.inputs) |input| {
        if (std.mem.eql(u8, input.name, name)) return input.value;
    }
    return null;
}
