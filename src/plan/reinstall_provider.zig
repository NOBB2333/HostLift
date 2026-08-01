const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const schema = @import("schema.zig");
const recipe_schema = @import("../reinstall/schema.zig");
const artifacts = @import("../reinstall/artifacts.zig");
const common = @import("modules/common.zig");

// 将显式 recipe 精确匹配的 reinstall 人工项替换为 download、execute、verify 三步 DAG。
pub fn enable(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(schema.Action),
    recipes: recipe_schema.RecipeSet,
    source_inventory_hash: [32]u8,
    target: inventory.Inventory,
) !void {
    try recipe_schema.validateSet(recipes);
    for (recipes.recipes) |recipe| {
        try validateTargetBinding(recipe, target);
        const manual_index = findAction(actions.items, recipe.manual_action_id) orelse return error.ReinstallManualActionNotFound;
        const manual = actions.items[manual_index];
        try validateManualBinding(manual, recipe);

        const root = try artifacts.rootForRecipe(allocator, source_inventory_hash, recipe.id);
        defer allocator.free(root);
        const download_id = try std.fmt.allocPrint(allocator, "resources/reinstall-download/{s}", .{recipe.id});
        defer allocator.free(download_id);
        const execute_id = try std.fmt.allocPrint(allocator, "resources/reinstall-execute/{s}", .{recipe.id});
        defer allocator.free(execute_id);

        var generated: std.ArrayList(schema.Action) = .empty;
        defer generated.deinit(allocator);
        errdefer for (generated.items) |action| schema.deinitAction(allocator, action);

        try appendAction(allocator, &generated, recipe, root, .{
            .id_prefix = "resources/reinstall-download",
            .action_type = .reinstall_download,
            .risk = .high,
            .phase = .transfer,
            .description = "Download the explicitly trusted artifact over HTTPS and verify its pinned SHA-256",
        });
        try appendAction(allocator, &generated, recipe, root, .{
            .id_prefix = "resources/reinstall-execute",
            .action_type = .reinstall_execute,
            .risk = .critical,
            .phase = .restore,
            .depends_on = &.{download_id},
            .description = "Execute the validated installer argv against the already verified local artifact",
        });
        try appendAction(allocator, &generated, recipe, root, .{
            .id_prefix = "resources/reinstall-verify",
            .action_type = .reinstall_verify,
            .risk = .high,
            .phase = .verify,
            .depends_on = &.{execute_id},
            .description = "Verify all declared managed paths and compare the fixed command output SHA-256",
        });

        const old = actions.orderedRemove(manual_index);
        schema.deinitAction(allocator, old);
        try actions.appendSlice(allocator, generated.items);
        generated.clearRetainingCapacity();
    }
}

const ActionInput = struct {
    id_prefix: []const u8,
    action_type: schema.ActionType,
    risk: schema.RiskLevel,
    phase: schema.ActionPhase,
    depends_on: []const []const u8 = &.{},
    description: []const u8,
};

fn appendAction(
    allocator: std.mem.Allocator,
    actions: *std.ArrayList(schema.Action),
    recipe: recipe_schema.Recipe,
    root: []const u8,
    input: ActionInput,
) !void {
    const id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ input.id_prefix, recipe.id });
    errdefer allocator.free(id);
    const subject = try allocator.dupe(u8, root);
    errdefer allocator.free(subject);
    const description = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ input.description, recipe.id });
    errdefer allocator.free(description);
    const dependencies = try duplicateStringsOrNull(allocator, input.depends_on);
    errdefer if (dependencies) |items| freeStrings(allocator, items);
    const spec = try duplicateSpec(allocator, recipe);
    errdefer schema.deinitReinstallSpec(allocator, spec);
    try actions.append(allocator, .{
        .id = id,
        .module = .resources,
        .action_type = input.action_type,
        .subject = subject,
        .description = description,
        .risk = input.risk,
        .requires_confirmation = true,
        .phase = input.phase,
        .depends_on = dependencies,
        .reinstall = spec,
    });
}

fn duplicateSpec(allocator: std.mem.Allocator, recipe: recipe_schema.Recipe) !schema.ReinstallSpec {
    const schema_version = try allocator.dupe(u8, recipe_schema.schema_version);
    errdefer allocator.free(schema_version);
    const recipe_id = try allocator.dupe(u8, recipe.id);
    errdefer allocator.free(recipe_id);
    const source_manual_action_id = try allocator.dupe(u8, recipe.manual_action_id);
    errdefer allocator.free(source_manual_action_id);
    const source_url = try allocator.dupe(u8, recipe.source_url);
    errdefer allocator.free(source_url);
    const sha256 = try allocator.dupe(u8, recipe.sha256);
    errdefer allocator.free(sha256);
    const target_distro_id = try allocator.dupe(u8, recipe.target_distro_id);
    errdefer allocator.free(target_distro_id);
    const target_distro_version = try allocator.dupe(u8, recipe.target_distro_version);
    errdefer allocator.free(target_distro_version);
    const target_arch = try allocator.dupe(u8, recipe.target_arch);
    errdefer allocator.free(target_arch);
    const install_argv = try duplicateStrings(allocator, recipe.install_argv);
    errdefer freeStrings(allocator, install_argv);
    const verify_argv = try duplicateStrings(allocator, recipe.verify_argv);
    errdefer freeStrings(allocator, verify_argv);
    const verify_stdout_sha256 = try allocator.dupe(u8, recipe.verify_stdout_sha256);
    errdefer allocator.free(verify_stdout_sha256);
    const managed_paths = try duplicateStrings(allocator, recipe.managed_paths);
    errdefer freeStrings(allocator, managed_paths);
    return .{
        .schema_version = schema_version,
        .recipe_id = recipe_id,
        .source_manual_action_id = source_manual_action_id,
        .kind = @enumFromInt(@intFromEnum(recipe.kind)),
        .source_url = source_url,
        .sha256 = sha256,
        .artifact_size_bytes = recipe.artifact_size_bytes,
        .target_distro_id = target_distro_id,
        .target_distro_version = target_distro_version,
        .target_arch = target_arch,
        .install_argv = install_argv,
        .verify_argv = verify_argv,
        .verify_stdout_sha256 = verify_stdout_sha256,
        .managed_paths = managed_paths,
    };
}

fn duplicateStrings(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |value| allocator.free(value);
        allocator.free(result);
    }
    for (values, 0..) |value, index| {
        result[index] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return result;
}

fn duplicateStringsOrNull(allocator: std.mem.Allocator, values: []const []const u8) !?[]const []const u8 {
    if (values.len == 0) return null;
    return try duplicateStrings(allocator, values);
}

fn freeStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn findAction(actions: []const schema.Action, id: []const u8) ?usize {
    for (actions, 0..) |action, index| if (std.mem.eql(u8, action.id, id)) return index;
    return null;
}

fn validateTargetBinding(recipe: recipe_schema.Recipe, target: inventory.Inventory) !void {
    if (!std.mem.eql(u8, recipe.target_distro_id, target.distro.id) or
        !std.mem.eql(u8, recipe.target_distro_version, target.distro.version_id) or
        !std.mem.eql(u8, recipe.target_arch, @tagName(target.host.arch)))
    {
        return error.ReinstallRecipeTargetMismatch;
    }
}

fn validateManualBinding(action: schema.Action, recipe: recipe_schema.Recipe) !void {
    if (action.action_type != .manual_step or action.manual_task == null or action.manual_task.?.kind != .reinstall) {
        return error.ReinstallRecipeNotManualReinstall;
    }
    const provider = action.manual_task.?.provider;
    if (!std.mem.eql(u8, provider, "script_reinstall") and !std.mem.eql(u8, provider, "resource_reinstall")) {
        return error.ReinstallRecipeUnsupportedProvider;
    }
    const install_path = manualInput(action.manual_task.?, "install_path") orelse manualInput(action.manual_task.?, "artifact_path") orelse
        return error.ReinstallRecipeInstallPathMissing;
    for (recipe.managed_paths) |path| if (std.mem.eql(u8, path, install_path)) return;
    return error.ReinstallRecipeManagedPathMismatch;
}

fn manualInput(task: schema.ManualTask, name: []const u8) ?[]const u8 {
    for (task.inputs) |input| if (std.mem.eql(u8, input.name, name)) return input.value;
    return null;
}

test "verified reinstall provider replaces one bound manual action with a validated dag" {
    var actions: std.ArrayList(schema.Action) = .empty;
    defer {
        for (actions.items) |action| schema.deinitAction(std.testing.allocator, action);
        actions.deinit(std.testing.allocator);
    }
    const inputs = [_]common.ManualInputSpec{.{ .name = "artifact_path", .value = "/usr/local/bin/tool" }};
    try common.appendAction(std.testing.allocator, &actions, .{
        .id_prefix = "resources/reinstall",
        .name = "/usr/local/bin/tool",
        .subject = "/usr/local/bin/tool",
        .module = .resources,
        .action_type = .manual_step,
        .risk = .high,
        .requires_confirmation = true,
        .description = "review reinstall",
        .manual_task_spec = .{ .provider = "resource_reinstall", .inputs = &inputs },
    });
    const recipe = recipe_schema.Recipe{
        .id = "tool-v1",
        .manual_action_id = "resources/reinstall//usr/local/bin/tool",
        .kind = .verified_script,
        .source_url = "https://downloads.example.test/tool/install.sh",
        .sha256 = "01" ** 32,
        .artifact_size_bytes = 1024,
        .target_distro_id = "ubuntu",
        .target_distro_version = "24.04",
        .target_arch = "x86_64",
        .install_argv = &.{ "sh", recipe_schema.artifact_placeholder, "--prefix=/usr/local" },
        .verify_argv = &.{ "test", "-x", "/usr/local/bin/tool" },
        .verify_stdout_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        .managed_paths = &.{"/usr/local/bin/tool"},
    };
    try enable(std.testing.allocator, &actions, .{ .schema_version = recipe_schema.schema_version, .recipes = &.{recipe} }, [_]u8{0xab} ** 32, testTarget());

    try std.testing.expectEqual(@as(usize, 3), actions.items.len);
    try std.testing.expectEqual(schema.ActionType.reinstall_download, actions.items[0].action_type);
    try std.testing.expectEqual(schema.ActionType.reinstall_execute, actions.items[1].action_type);
    try std.testing.expectEqual(schema.ActionType.reinstall_verify, actions.items[2].action_type);
    try std.testing.expectEqualStrings("resources/reinstall-download/tool-v1", actions.items[1].depends_on.?[0]);
    try artifacts.validateRoot(actions.items[0].subject, [_]u8{0xab} ** 32, "tool-v1");

    const migration_plan = schema.MigrationPlan{
        .schema_version = schema.schema_version_v2,
        .source_inventory_hash = [_]u8{0xab} ** 32,
        .target_inventory_hash = [_]u8{0xcd} ** 32,
        .compatibility = .{ .compatible = true, .same_distro = true, .same_version = true, .same_package_manager = true, .same_arch = true, .reason = "compatible" },
        .actions = actions.items,
        .created_at = 0,
    };
    try std.testing.expect(@import("validator.zig").validate(migration_plan).valid);
    const original_subject = actions.items[0].subject;
    actions.items[0].subject = "/var/lib/hostlift/artifacts/reinstall/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/tool-v1";
    try std.testing.expect(!@import("validator.zig").validate(migration_plan).valid);
    actions.items[0].subject = original_subject;
}

fn testTarget() inventory.Inventory {
    return .{
        .schema_version = inventory.schema_version,
        .host = .{ .hostname = "target", .machine_id_hash = null, .kernel_release = "test", .arch = .x86_64 },
        .distro = .{ .id = "ubuntu", .id_like = &.{}, .version_id = "24.04", .pretty_name = "Ubuntu" },
        .package_manager = .{ .kind = .apt, .version = "apt", .repos = &.{} },
        .modules = inventory.emptyModules(),
        .scan = .{ .scanned_at_unix = 0, .warnings = &.{} },
    };
}
