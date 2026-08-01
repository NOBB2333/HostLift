const std = @import("std");
const security = @import("../security/validation.zig");

pub const schema_version = "hostlift.reinstall_recipes.v1";
pub const artifact_placeholder = "{artifact}";
pub const max_recipes: usize = 128;
pub const max_argv: usize = 64;
pub const max_managed_paths: usize = 32;
pub const max_artifact_size_bytes: u64 = 16 * 1024 * 1024 * 1024;

pub const Kind = enum {
    verified_script,
    verified_binary,
};

// 单条可信重装 recipe；所有字符串都会进入 plan，因此不得包含 secret。
pub const Recipe = struct {
    id: []const u8,
    manual_action_id: []const u8,
    kind: Kind,
    source_url: []const u8,
    sha256: []const u8,
    artifact_size_bytes: u64,
    target_distro_id: []const u8,
    target_distro_version: []const u8,
    target_arch: []const u8,
    install_argv: []const []const u8,
    verify_argv: []const []const u8,
    verify_stdout_sha256: []const u8,
    managed_paths: []const []const u8,
};

// 可信重装 recipe 文件顶层合同。
pub const RecipeSet = struct {
    schema_version: []const u8,
    recipes: []const Recipe,
};

// 严格校验 recipe 文件；拒绝重复 ID/action、非 HTTPS、缺 checksum 和可解释为 shell 的 argv。
pub fn validateSet(set: RecipeSet) !void {
    if (!std.mem.eql(u8, set.schema_version, schema_version)) return error.InvalidReinstallRecipeSchema;
    if (set.recipes.len == 0 or set.recipes.len > max_recipes) return error.InvalidReinstallRecipeCount;
    for (set.recipes, 0..) |recipe, index| {
        try validateRecipe(recipe);
        for (set.recipes[0..index]) |previous| {
            if (std.mem.eql(u8, previous.id, recipe.id)) return error.DuplicateReinstallRecipeId;
            if (std.mem.eql(u8, previous.manual_action_id, recipe.manual_action_id)) return error.DuplicateReinstallManualAction;
            for (previous.managed_paths) |previous_path| {
                for (recipe.managed_paths) |path| if (pathsOverlap(previous_path, path)) return error.OverlappingReinstallManagedPaths;
            }
        }
    }
}

// 校验一条 recipe 的来源、目标绑定、argv 和声明路径边界。
pub fn validateRecipe(recipe: Recipe) !void {
    try validateId(recipe.id);
    try validateManualActionId(recipe.manual_action_id);
    try security.validateHttpsArtifactUrl(recipe.source_url);
    try validateSha256(recipe.sha256);
    if (recipe.artifact_size_bytes == 0 or recipe.artifact_size_bytes > max_artifact_size_bytes) return error.InvalidReinstallArtifactSize;
    try validateTargetToken(recipe.target_distro_id);
    try validateTargetToken(recipe.target_distro_version);
    try validateTargetToken(recipe.target_arch);
    try validateManagedPaths(recipe.managed_paths);
    const install_path = manualActionInstallPath(recipe.manual_action_id) orelse return error.InvalidReinstallManualActionId;
    if (!containsString(recipe.managed_paths, install_path)) return error.ReinstallRecipeManagedPathMismatch;
    try validateInstallArgv(recipe.kind, recipe.install_argv, recipe.managed_paths);
    try validateVerifyArgv(recipe.verify_argv);
    try validateSha256(recipe.verify_stdout_sha256);
}

// 校验 recipe ID 可安全进入 action ID 和 artifact 路径。
pub fn validateId(value: []const u8) !void {
    if (value.len == 0 or value.len > 96 or value[0] == '-') return error.InvalidReinstallRecipeId;
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte)) continue;
        switch (byte) {
            '.', '_', '-' => {},
            else => return error.InvalidReinstallRecipeId,
        }
    }
}

// 校验小写 SHA-256 文本。
pub fn validateSha256(value: []const u8) !void {
    if (value.len != 64) return error.InvalidReinstallSha256;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.InvalidReinstallSha256;
    }
}

fn validateManualActionId(value: []const u8) !void {
    if (value.len == 0 or value.len > 4096) return error.InvalidReinstallManualActionId;
    if (!std.mem.startsWith(u8, value, "resources/reinstall/") and
        !std.mem.startsWith(u8, value, "system-baseline/reinstall-script-app/"))
    {
        return error.InvalidReinstallManualActionId;
    }
    for (value) |byte| if (byte <= 0x20 or byte == 0x7f) return error.InvalidReinstallManualActionId;
}

fn manualActionInstallPath(value: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "resources/reinstall/", "system-baseline/reinstall-script-app/" };
    for (prefixes) |prefix| {
        if (!std.mem.startsWith(u8, value, prefix)) continue;
        const path = value[prefix.len..];
        if (path.len > 1 and path[0] == '/') return path;
    }
    return null;
}

fn validateTargetToken(value: []const u8) !void {
    if (value.len == 0 or value.len > 128 or value[0] == '-') return error.InvalidReinstallTarget;
    security.validateCommandToken(value) catch return error.InvalidReinstallTarget;
}

fn validateInstallArgv(kind: Kind, argv: []const []const u8, managed_paths: []const []const u8) !void {
    if (argv.len < 2 or argv.len > max_argv) return error.InvalidReinstallInstallArgv;
    switch (kind) {
        .verified_script => {
            if (!std.mem.eql(u8, argv[0], "sh") and !std.mem.eql(u8, argv[0], "bash")) return error.InvalidReinstallInstallArgv;
            if (!std.mem.eql(u8, argv[1], artifact_placeholder)) return error.InvalidReinstallInstallArgv;
        },
        .verified_binary => {
            if (!std.mem.eql(u8, argv[0], "install") or argv.len < 3) return error.InvalidReinstallInstallArgv;
            if (!std.mem.eql(u8, argv[argv.len - 2], artifact_placeholder)) return error.InvalidReinstallInstallArgv;
            if (!containsString(managed_paths, argv[argv.len - 1])) return error.InvalidReinstallInstallTarget;
            var option_index: usize = 1;
            while (option_index < argv.len - 2) {
                const option = argv[option_index];
                if (std.mem.eql(u8, option, "-m")) {
                    option_index += 1;
                    if (option_index >= argv.len - 2 or !validInstallMode(argv[option_index])) return error.InvalidReinstallInstallArgv;
                } else if (std.mem.startsWith(u8, option, "--mode=")) {
                    if (!validInstallMode(option["--mode=".len..])) return error.InvalidReinstallInstallArgv;
                } else {
                    return error.InvalidReinstallInstallArgv;
                }
                option_index += 1;
            }
        },
    }
    var placeholders: usize = 0;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, artifact_placeholder)) {
            placeholders += 1;
        } else {
            security.validateCommandToken(arg) catch return error.InvalidReinstallInstallArgv;
            if (looksLikeSecretArgument(arg)) return error.ReinstallSecretArgumentForbidden;
        }
    }
    if (placeholders != 1) return error.InvalidReinstallInstallArgv;
}

fn looksLikeSecretArgument(value: []const u8) bool {
    const name_end = std.mem.indexOfScalar(u8, value, '=') orelse value.len;
    var name = value[0..name_end];
    while (name.len > 0 and name[0] == '-') name = name[1..];
    var tokens = std.mem.tokenizeAny(u8, name, "-_.");
    while (tokens.next()) |token| {
        const sensitive = [_][]const u8{ "password", "passwd", "secret", "token", "key", "apikey", "accesskey", "privatekey", "credential" };
        for (sensitive) |word| if (std.ascii.eqlIgnoreCase(token, word)) return true;
    }
    return false;
}

fn validInstallMode(value: []const u8) bool {
    if (value.len != 3 and value.len != 4) return false;
    for (value) |byte| if (byte < '0' or byte > '7') return false;
    return true;
}

fn containsString(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn validateVerifyArgv(argv: []const []const u8) !void {
    if (argv.len == 0 or argv.len > max_argv) return error.InvalidReinstallVerifyArgv;
    if (!std.mem.eql(u8, argv[0], "test") and !std.mem.eql(u8, argv[0], "sha256sum") and !std.mem.eql(u8, argv[0], "stat")) {
        return error.InvalidReinstallVerifyArgv;
    }
    for (argv) |arg| security.validateCommandToken(arg) catch return error.InvalidReinstallVerifyArgv;
}

fn validateManagedPaths(paths: []const []const u8) !void {
    if (paths.len == 0 or paths.len > max_managed_paths) return error.InvalidReinstallManagedPaths;
    for (paths, 0..) |path, index| {
        security.validatePath(path) catch return error.InvalidReinstallManagedPaths;
        if (!std.mem.startsWith(u8, path, "/") or path.len <= 1) return error.InvalidReinstallManagedPaths;
        if (pathsOverlap(path, "/var/lib/hostlift/artifacts/reinstall")) return error.InvalidReinstallManagedPaths;
        for (paths[0..index]) |previous| {
            if (pathsOverlap(previous, path)) return error.InvalidReinstallManagedPaths;
        }
    }
}

fn pathsOverlap(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return true;
    if (left.len < right.len and std.mem.startsWith(u8, right, left) and right[left.len] == '/') return true;
    return right.len < left.len and std.mem.startsWith(u8, left, right) and left[right.len] == '/';
}

test "verified reinstall recipe rejects curl pipe semantics and requires exact hashes" {
    const valid = Recipe{
        .id = "tool-v1",
        .manual_action_id = "resources/reinstall//usr/local/bin/tool",
        .kind = .verified_script,
        .source_url = "https://downloads.example.test/tool/install.sh",
        .sha256 = "01" ** 32,
        .artifact_size_bytes = 1024,
        .target_distro_id = "ubuntu",
        .target_distro_version = "24.04",
        .target_arch = "x86_64",
        .install_argv = &.{ "sh", artifact_placeholder, "--prefix=/usr/local" },
        .verify_argv = &.{ "test", "-x", "/usr/local/bin/tool" },
        .verify_stdout_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        .managed_paths = &.{"/usr/local/bin/tool"},
    };
    try validateSet(.{ .schema_version = schema_version, .recipes = &.{valid} });

    var invalid = valid;
    invalid.source_url = "http://downloads.example.test/install.sh";
    try std.testing.expectError(error.InvalidHttpsArtifactUrl, validateRecipe(invalid));
    invalid = valid;
    invalid.install_argv = &.{ "sh", "-c", "curl|sh" };
    try std.testing.expectError(error.InvalidReinstallInstallArgv, validateRecipe(invalid));

    invalid = valid;
    invalid.artifact_size_bytes = 0;
    try std.testing.expectError(error.InvalidReinstallArtifactSize, validateRecipe(invalid));
    invalid = valid;
    invalid.managed_paths = &.{"/var/lib/hostlift/artifacts/reinstall/owned"};
    try std.testing.expectError(error.InvalidReinstallManagedPaths, validateRecipe(invalid));
    invalid = valid;
    invalid.install_argv = &.{ "sh", artifact_placeholder, "--api-key=secret" };
    try std.testing.expectError(error.ReinstallSecretArgumentForbidden, validateRecipe(invalid));
    invalid = valid;
    invalid.managed_paths = &.{"/opt/different-tool"};
    try std.testing.expectError(error.ReinstallRecipeManagedPathMismatch, validateRecipe(invalid));
}

test "verified binary install destination must be a declared managed path" {
    const valid = Recipe{
        .id = "tool-bin-v1",
        .manual_action_id = "resources/reinstall//usr/local/bin/tool",
        .kind = .verified_binary,
        .source_url = "https://downloads.example.test/tool/tool",
        .sha256 = "01" ** 32,
        .artifact_size_bytes = 4096,
        .target_distro_id = "ubuntu",
        .target_distro_version = "24.04",
        .target_arch = "x86_64",
        .install_argv = &.{ "install", "-m", "0755", artifact_placeholder, "/usr/local/bin/tool" },
        .verify_argv = &.{ "test", "-x", "/usr/local/bin/tool" },
        .verify_stdout_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        .managed_paths = &.{"/usr/local/bin/tool"},
    };
    try validateRecipe(valid);

    var invalid = valid;
    invalid.install_argv = &.{ "install", "-m", "0755", artifact_placeholder, "/etc/shadow" };
    try std.testing.expectError(error.InvalidReinstallInstallTarget, validateRecipe(invalid));
    invalid = valid;
    invalid.install_argv = &.{ "install", "--target-directory=/etc", artifact_placeholder, "/usr/local/bin/tool" };
    try std.testing.expectError(error.InvalidReinstallInstallArgv, validateRecipe(invalid));
}
