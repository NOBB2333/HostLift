const std = @import("std");
const inventory = @import("../inventory/schema.zig");
const plan = @import("schema.zig");
const schema = @import("workload_schema.zig");
const action_compatibility = @import("action_compatibility.zig");

pub const Report = schema.Report;

// 从源/目标 inventory 和完整迁移计划构建机器可读工作负载完成度报告。
pub fn build(
    allocator: std.mem.Allocator,
    source: inventory.Inventory,
    target: inventory.Inventory,
    migration_plan: plan.MigrationPlan,
) !schema.Report {
    var workloads: std.ArrayList(schema.Workload) = .empty;
    errdefer {
        for (workloads.items) |workload| schema.deinitWorkload(allocator, workload);
        workloads.deinit(allocator);
    }

    try appendServiceWorkloads(allocator, &workloads, source, target, migration_plan);
    try appendProjectWorkloads(allocator, &workloads, source, target, migration_plan);
    try appendAppDataWorkloads(allocator, &workloads, source, target, migration_plan);
    try appendContainerWorkloads(allocator, &workloads, source, target, migration_plan);
    try appendResourceWorkloads(allocator, &workloads, source, target, migration_plan);

    const workload_slice = try workloads.toOwnedSlice(allocator);
    errdefer {
        for (workload_slice) |workload| schema.deinitWorkload(allocator, workload);
        allocator.free(workload_slice);
    }

    const unassigned = try collectUnassignedActionIds(allocator, migration_plan.actions, workload_slice);
    errdefer freeStrings(allocator, unassigned);
    const global_blockers = try buildGlobalBlockers(allocator, source, target, migration_plan, unassigned);
    errdefer freeBlockers(allocator, global_blockers);
    const summary = summarize(workload_slice, migration_plan.actions.len, unassigned.len);
    const host_status = determineHostStatus(source, target, migration_plan, workload_slice);

    const owned_schema_version = try allocator.dupe(u8, schema.schema_version);
    errdefer allocator.free(owned_schema_version);
    const source_host = try allocator.dupe(u8, source.host.hostname);
    errdefer allocator.free(source_host);
    const target_host = try allocator.dupe(u8, target.host.hostname);
    errdefer allocator.free(target_host);

    return .{
        .schema_version = owned_schema_version,
        .source_host = source_host,
        .target_host = target_host,
        .compatible = migration_plan.compatibility.compatible,
        .host_status = host_status,
        .all_workloads_complete = host_status == .complete and summary.total == summary.complete,
        .summary = summary,
        .workloads = workload_slice,
        .global_blockers = global_blockers,
        .unassigned_action_ids = unassigned,
    };
}

fn appendServiceWorkloads(
    allocator: std.mem.Allocator,
    workloads: *std.ArrayList(schema.Workload),
    source: inventory.Inventory,
    target: inventory.Inventory,
    migration_plan: plan.MigrationPlan,
) !void {
    const incomplete = moduleScanIncomplete(source, target, "services", false, false);
    for (source.modules.services.units) |unit| {
        var refs: std.ArrayList([]const u8) = .empty;
        defer refs.deinit(allocator);
        try refs.append(allocator, unit.name);
        if (unit.path) |path| try refs.append(allocator, path);
        for (source.modules.services.drop_ins) |drop_in| {
            if (std.mem.eql(u8, drop_in.unit, unit.name)) try refs.append(allocator, drop_in.path);
        }
        for (source.modules.services.env_files) |env_file| {
            if (std.mem.eql(u8, env_file.unit, unit.name)) try refs.append(allocator, env_file.path);
        }

        const action_ids = try collectActionIds(
            allocator,
            migration_plan.actions,
            &.{.services},
            refs.items,
            &.{},
        );
        const target_present = servicePresent(target.modules.services.units, unit.name);
        var components: std.ArrayList(schema.Component) = .empty;
        errdefer freeComponentList(allocator, &components);
        try appendComponent(allocator, &components, .service, unit.name, target_present, action_ids);

        for (source.modules.services.drop_ins) |drop_in| {
            if (!std.mem.eql(u8, drop_in.unit, unit.name)) continue;
            try appendComponent(
                allocator,
                &components,
                .config,
                drop_in.path,
                dropInPresent(target.modules.services.drop_ins, drop_in),
                try emptyStrings(allocator),
            );
        }
        for (source.modules.services.env_files) |env_file| {
            if (!std.mem.eql(u8, env_file.unit, unit.name)) continue;
            try appendComponent(
                allocator,
                &components,
                .config,
                env_file.path,
                envFilePresent(target.modules.services.env_files, env_file),
                try emptyStrings(allocator),
            );
        }

        const id = try std.fmt.allocPrint(allocator, "systemd/{s}", .{unit.name});
        defer allocator.free(id);
        try appendFinalWorkload(
            allocator,
            workloads,
            id,
            unit.name,
            .systemd_service,
            &components,
            incomplete,
            .medium,
            migration_plan,
        );
    }
}

fn appendProjectWorkloads(
    allocator: std.mem.Allocator,
    workloads: *std.ArrayList(schema.Workload),
    source: inventory.Inventory,
    target: inventory.Inventory,
    migration_plan: plan.MigrationPlan,
) !void {
    const incomplete = moduleScanIncomplete(
        source,
        target,
        "projects",
        source.modules.projects.truncated,
        target.modules.projects.truncated,
    );
    for (source.modules.projects.projects) |project| {
        const refs = [_][]const u8{ project.root, project.manifest_path };
        const modules: []const plan.ModuleName = if (project.kind == .docker_compose)
            &[_]plan.ModuleName{ .projects, .docker }
        else
            &[_]plan.ModuleName{.projects};
        const action_ids = try collectActionIds(allocator, migration_plan.actions, modules, &refs, &.{});
        const target_present = projectPresent(target.modules.projects.projects, project.root);
        var components: std.ArrayList(schema.Component) = .empty;
        errdefer freeComponentList(allocator, &components);
        try appendComponent(allocator, &components, .code, project.root, target_present, action_ids);
        try appendComponent(
            allocator,
            &components,
            .config,
            project.manifest_path,
            projectManifestPresent(target.modules.projects.projects, project),
            try emptyStrings(allocator),
        );

        const id = try std.fmt.allocPrint(allocator, "project/{s}", .{project.root});
        defer allocator.free(id);
        try appendFinalWorkload(
            allocator,
            workloads,
            id,
            project.root,
            .project,
            &components,
            incomplete,
            .medium,
            migration_plan,
        );
    }
}

fn appendAppDataWorkloads(
    allocator: std.mem.Allocator,
    workloads: *std.ArrayList(schema.Workload),
    source: inventory.Inventory,
    target: inventory.Inventory,
    migration_plan: plan.MigrationPlan,
) !void {
    const incomplete = moduleScanIncomplete(source, target, "appdata", false, false);
    for (source.modules.appdata.paths) |data_path| {
        if (!data_path.present) continue;
        const refs = [_][]const u8{data_path.path};
        const action_ids = try collectActionIds(allocator, migration_plan.actions, &.{.appdata}, &refs, &.{});
        const target_present = dataPathPresent(target.modules.appdata.paths, data_path.path);
        var components: std.ArrayList(schema.Component) = .empty;
        errdefer freeComponentList(allocator, &components);
        try appendComponent(allocator, &components, .data, data_path.path, target_present, action_ids);

        const id = try std.fmt.allocPrint(allocator, "appdata/{s}", .{data_path.path});
        defer allocator.free(id);
        try appendFinalWorkload(
            allocator,
            workloads,
            id,
            data_path.path,
            .app_data,
            &components,
            incomplete,
            .low,
            migration_plan,
        );
    }
}

fn appendContainerWorkloads(
    allocator: std.mem.Allocator,
    workloads: *std.ArrayList(schema.Workload),
    source: inventory.Inventory,
    target: inventory.Inventory,
    migration_plan: plan.MigrationPlan,
) !void {
    const incomplete = moduleScanIncomplete(
        source,
        target,
        "docker",
        source.modules.docker.truncated,
        target.modules.docker.truncated,
    );
    for (source.modules.docker.containers) |container| {
        const qualified_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ @tagName(container.runtime), container.name });
        defer allocator.free(qualified_name);
        const refs = [_][]const u8{ qualified_name, container.name, container.image, @tagName(container.runtime) };
        const action_ids = try collectActionIds(
            allocator,
            migration_plan.actions,
            &.{.docker},
            &refs,
            &.{},
        );
        const target_container = findContainer(target.modules.docker.containers, container.runtime, container.name);
        const target_present = target_container != null;
        var components: std.ArrayList(schema.Component) = .empty;
        errdefer freeComponentList(allocator, &components);
        try appendComponent(allocator, &components, .runtime, qualified_name, target_present, action_ids);
        try appendComponent(
            allocator,
            &components,
            .code,
            container.image,
            if (target_container) |found| std.mem.eql(u8, found.image, container.image) else false,
            try emptyStrings(allocator),
        );
        if (container.ports.len > 0) {
            try appendComponent(
                allocator,
                &components,
                .port,
                container.ports,
                if (target_container) |found| std.mem.eql(u8, found.ports, container.ports) else false,
                try emptyStrings(allocator),
            );
        }
        if (container.mounts) |mounts| {
            try appendComponent(
                allocator,
                &components,
                .data,
                mounts,
                if (target_container) |found| if (found.mounts) |target_mounts| std.mem.eql(u8, target_mounts, mounts) else false else false,
                try emptyStrings(allocator),
            );
        }
        try appendComponent(
            allocator,
            &components,
            .health,
            container.status,
            if (target_container) |found| std.mem.eql(u8, found.status, container.status) else false,
            try emptyStrings(allocator),
        );

        const id = try std.fmt.allocPrint(allocator, "container/{s}", .{qualified_name});
        defer allocator.free(id);
        try appendFinalWorkload(
            allocator,
            workloads,
            id,
            container.name,
            .container,
            &components,
            incomplete,
            .medium,
            migration_plan,
        );
    }
}

fn appendResourceWorkloads(
    allocator: std.mem.Allocator,
    workloads: *std.ArrayList(schema.Workload),
    source: inventory.Inventory,
    target: inventory.Inventory,
    migration_plan: plan.MigrationPlan,
) !void {
    const incomplete = moduleScanIncomplete(
        source,
        target,
        "resources",
        source.modules.resources.truncated,
        target.modules.resources.truncated,
    );
    for (source.modules.resources.resources) |resource| {
        if (!isWorkloadResource(resource)) continue;
        const refs = [_][]const u8{resource.path};
        const prefixes: []const []const u8 = if (resource.default_action == .copy)
            &[_][]const u8{"resources/capacity/"}
        else
            &[_][]const u8{};
        const action_ids = try collectActionIds(allocator, migration_plan.actions, &.{.resources}, &refs, prefixes);
        const target_present = resourcePresent(target.modules.resources.resources, resource.path);
        var components: std.ArrayList(schema.Component) = .empty;
        errdefer freeComponentList(allocator, &components);
        try appendComponent(
            allocator,
            &components,
            componentKindForResource(resource),
            resource.path,
            target_present,
            action_ids,
        );

        const id = try std.fmt.allocPrint(allocator, "resource/{s}", .{resource.path});
        defer allocator.free(id);
        try appendFinalWorkload(
            allocator,
            workloads,
            id,
            resource.path,
            .unmanaged_resource,
            &components,
            incomplete,
            .low,
            migration_plan,
        );
    }
}

fn appendFinalWorkload(
    allocator: std.mem.Allocator,
    workloads: *std.ArrayList(schema.Workload),
    id: []const u8,
    name: []const u8,
    kind: schema.WorkloadKind,
    components: *std.ArrayList(schema.Component),
    scan_incomplete: bool,
    confidence: schema.Confidence,
    migration_plan: plan.MigrationPlan,
) !void {
    const component_slice = try components.toOwnedSlice(allocator);
    errdefer deinitComponents(allocator, component_slice);
    const action_ids = if (component_slice.len > 0) component_slice[0].action_ids else &.{};
    const target_facts_complete = allComponentsPresent(component_slice);
    const blockers = try buildWorkloadBlockers(
        allocator,
        action_ids,
        target_facts_complete,
        scan_incomplete,
        migration_plan,
    );
    errdefer freeBlockers(allocator, blockers);
    const evidence = try buildEvidence(allocator, id, target_facts_complete, action_ids);
    errdefer freeEvidence(allocator, evidence);
    const status = determineWorkloadStatus(
        action_ids,
        target_facts_complete,
        scan_incomplete,
        migration_plan,
    );

    const owned_id = try allocator.dupe(u8, id);
    errdefer allocator.free(owned_id);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    try workloads.append(allocator, .{
        .id = owned_id,
        .name = owned_name,
        .kind = kind,
        .components = component_slice,
        .status = status,
        .blockers = blockers,
        .confidence = if (scan_incomplete) .low else confidence,
        .evidence = evidence,
    });
}

fn allComponentsPresent(components: []const schema.Component) bool {
    if (components.len == 0) return false;
    for (components) |component| if (!component.target_present) return false;
    return true;
}

fn appendComponent(
    allocator: std.mem.Allocator,
    components: *std.ArrayList(schema.Component),
    kind: schema.ComponentKind,
    source_ref: []const u8,
    target_present: bool,
    action_ids: []const []const u8,
) !void {
    errdefer freeStrings(allocator, action_ids);
    const owned_ref = try allocator.dupe(u8, source_ref);
    errdefer allocator.free(owned_ref);
    try components.append(allocator, .{
        .kind = kind,
        .source_ref = owned_ref,
        .target_present = target_present,
        .action_ids = action_ids,
    });
}

fn collectActionIds(
    allocator: std.mem.Allocator,
    actions: []const plan.Action,
    modules: []const plan.ModuleName,
    refs: []const []const u8,
    global_prefixes: []const []const u8,
) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer freeStringList(allocator, &ids);
    for (actions) |action| {
        if (!moduleIncluded(modules, action.module)) continue;
        if (!actionMatches(action, refs, global_prefixes)) continue;
        try appendOwnedString(allocator, &ids, action.id);
    }
    return ids.toOwnedSlice(allocator);
}

fn actionMatches(action: plan.Action, refs: []const []const u8, global_prefixes: []const []const u8) bool {
    for (global_prefixes) |prefix| {
        if (std.mem.startsWith(u8, action.id, prefix)) return true;
    }
    for (refs) |ref| {
        if (std.mem.eql(u8, action.subject, ref)) return true;
        if (!std.mem.endsWith(u8, action.id, ref)) continue;
        const start = action.id.len - ref.len;
        if (start == 0 or action.id[start - 1] == '/') return true;
    }
    return false;
}

fn moduleIncluded(modules: []const plan.ModuleName, needle: plan.ModuleName) bool {
    for (modules) |module| {
        if (module == needle) return true;
    }
    return false;
}

fn buildWorkloadBlockers(
    allocator: std.mem.Allocator,
    action_ids: []const []const u8,
    target_present: bool,
    scan_incomplete: bool,
    migration_plan: plan.MigrationPlan,
) ![]const schema.Blocker {
    var blockers: std.ArrayList(schema.Blocker) = .empty;
    errdefer freeBlockerList(allocator, &blockers);
    if (scan_incomplete) try appendBlocker(allocator, &blockers, .scan_incomplete, "module inventory incomplete", null);
    for (action_ids) |action_id| {
        const action = findAction(migration_plan.actions, action_id) orelse continue;
        if (!action_compatibility.isAllowed(action, migration_plan.compatibility) or isCompatibilityReview(action)) {
            try appendBlocker(allocator, &blockers, .incompatible_target, action.id, action.id);
        }
        if (action.action_type == .manual_step) {
            try appendBlocker(allocator, &blockers, .manual_action, action.id, action.id);
        } else if (action.risk == .critical) {
            try appendBlocker(allocator, &blockers, .critical_action, action.id, action.id);
        }
    }
    if (!target_present and action_ids.len == 0) {
        try appendBlocker(allocator, &blockers, .target_fact_missing, "target fact missing without a planned action", null);
    }
    return blockers.toOwnedSlice(allocator);
}

fn determineWorkloadStatus(
    action_ids: []const []const u8,
    target_present: bool,
    scan_incomplete: bool,
    migration_plan: plan.MigrationPlan,
) schema.Status {
    if (scan_incomplete) return .unknown;
    for (action_ids) |action_id| {
        const action = findAction(migration_plan.actions, action_id) orelse continue;
        if (!action_compatibility.isAllowed(action, migration_plan.compatibility)) return .blocked;
        if (action.action_type == .manual_step or action.risk == .critical) return .blocked;
    }
    if (action_ids.len > 0) return .pending;
    if (!target_present) return .unknown;
    return .complete;
}

fn determineHostStatus(
    source: inventory.Inventory,
    target: inventory.Inventory,
    migration_plan: plan.MigrationPlan,
    workloads: []const schema.Workload,
) schema.Status {
    if (!inventoryScanComplete(source) or !inventoryScanComplete(target)) return .unknown;
    for (workloads) |workload| if (workload.status == .unknown) return .unknown;
    for (migration_plan.actions) |action| {
        if (!action_compatibility.isAllowed(action, migration_plan.compatibility)) return .blocked;
        if (action.action_type == .manual_step or action.risk == .critical) return .blocked;
    }
    if (migration_plan.actions.len > 0) return .pending;
    return .complete;
}

fn buildEvidence(
    allocator: std.mem.Allocator,
    workload_id: []const u8,
    target_present: bool,
    action_ids: []const []const u8,
) ![]const schema.Evidence {
    var evidence: std.ArrayList(schema.Evidence) = .empty;
    errdefer freeEvidenceList(allocator, &evidence);
    try appendEvidence(allocator, &evidence, .source_inventory, workload_id);
    if (target_present) try appendEvidence(allocator, &evidence, .target_inventory, workload_id);
    for (action_ids) |action_id| try appendEvidence(allocator, &evidence, .migration_action, action_id);
    return evidence.toOwnedSlice(allocator);
}

fn collectUnassignedActionIds(
    allocator: std.mem.Allocator,
    actions: []const plan.Action,
    workloads: []const schema.Workload,
) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer freeStringList(allocator, &ids);
    for (actions) |action| {
        if (actionAssigned(workloads, action.id)) continue;
        try appendOwnedString(allocator, &ids, action.id);
    }
    return ids.toOwnedSlice(allocator);
}

fn actionAssigned(workloads: []const schema.Workload, action_id: []const u8) bool {
    for (workloads) |workload| {
        for (workload.components) |component| {
            for (component.action_ids) |candidate| {
                if (std.mem.eql(u8, candidate, action_id)) return true;
            }
        }
    }
    return false;
}

fn buildGlobalBlockers(
    allocator: std.mem.Allocator,
    source: inventory.Inventory,
    target: inventory.Inventory,
    migration_plan: plan.MigrationPlan,
    unassigned: []const []const u8,
) ![]const schema.Blocker {
    var blockers: std.ArrayList(schema.Blocker) = .empty;
    errdefer freeBlockerList(allocator, &blockers);
    if (source.scan.full_scan != true or target.scan.full_scan != true) {
        try appendBlocker(allocator, &blockers, .scan_incomplete, "source and target inventories must come from unfiltered full scans", null);
    }
    if (inventoryTruncated(source) or inventoryTruncated(target)) {
        try appendBlocker(allocator, &blockers, .scan_incomplete, "one or more inventory modules were truncated", null);
    }
    for (source.scan.warnings) |warning| try appendBlocker(allocator, &blockers, .scan_incomplete, warning, null);
    for (target.scan.warnings) |warning| try appendBlocker(allocator, &blockers, .scan_incomplete, warning, null);
    for (unassigned) |action_id| {
        const action = findAction(migration_plan.actions, action_id) orelse continue;
        if (!action_compatibility.isAllowed(action, migration_plan.compatibility) or isCompatibilityReview(action)) {
            try appendBlocker(allocator, &blockers, .incompatible_target, action.id, action.id);
        }
        if (action.action_type == .manual_step) {
            try appendBlocker(allocator, &blockers, .manual_action, action.id, action.id);
        } else if (action.risk == .critical) {
            try appendBlocker(allocator, &blockers, .critical_action, action.id, action.id);
        }
    }
    return blockers.toOwnedSlice(allocator);
}

fn isCompatibilityReview(action: plan.Action) bool {
    const task = action.manual_task orelse return false;
    return std.mem.eql(u8, task.provider, "compatibility_review");
}

fn appendBlocker(
    allocator: std.mem.Allocator,
    blockers: *std.ArrayList(schema.Blocker),
    kind: schema.BlockerKind,
    ref: []const u8,
    action_id: ?[]const u8,
) !void {
    const owned_ref = try allocator.dupe(u8, ref);
    errdefer allocator.free(owned_ref);
    const owned_action_id = if (action_id) |value| try allocator.dupe(u8, value) else null;
    errdefer if (owned_action_id) |value| allocator.free(value);
    try blockers.append(allocator, .{ .kind = kind, .ref = owned_ref, .action_id = owned_action_id });
}

fn appendEvidence(
    allocator: std.mem.Allocator,
    evidence: *std.ArrayList(schema.Evidence),
    kind: schema.EvidenceKind,
    ref: []const u8,
) !void {
    const owned_ref = try allocator.dupe(u8, ref);
    errdefer allocator.free(owned_ref);
    try evidence.append(allocator, .{ .kind = kind, .ref = owned_ref });
}

fn appendOwnedString(
    allocator: std.mem.Allocator,
    values: *std.ArrayList([]const u8),
    value: []const u8,
) !void {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try values.append(allocator, owned);
}

fn summarize(workloads: []const schema.Workload, plan_actions: usize, unassigned_actions: usize) schema.Summary {
    var summary: schema.Summary = .{
        .total = workloads.len,
        .plan_actions = plan_actions,
        .unassigned_actions = unassigned_actions,
    };
    for (workloads) |workload| {
        switch (workload.status) {
            .complete => summary.complete += 1,
            .pending => summary.pending += 1,
            .blocked => summary.blocked += 1,
            .unknown => summary.unknown += 1,
        }
    }
    return summary;
}

fn moduleScanIncomplete(
    source: inventory.Inventory,
    target: inventory.Inventory,
    module_name: []const u8,
    source_truncated: bool,
    target_truncated: bool,
) bool {
    return source.scan.full_scan != true or target.scan.full_scan != true or
        source_truncated or target_truncated or
        hasModuleWarning(source.scan.warnings, module_name) or
        hasModuleWarning(target.scan.warnings, module_name);
}

fn hasModuleWarning(warnings: []const []const u8, module_name: []const u8) bool {
    const prefix = "scan module ";
    for (warnings) |warning| {
        if (!std.mem.startsWith(u8, warning, prefix)) continue;
        const rest = warning[prefix.len..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        if (std.mem.eql(u8, rest[0..end], module_name)) return true;
    }
    return false;
}

fn inventoryTruncated(value: inventory.Inventory) bool {
    return value.modules.sudoers.truncated or
        value.modules.acl.truncated or
        value.modules.home_configs.truncated or
        value.modules.projects.truncated or
        value.modules.processes.truncated or
        value.modules.network.truncated or
        value.modules.docker.truncated or
        value.modules.resources.truncated or
        value.modules.storage.truncated;
}

fn inventoryScanComplete(value: inventory.Inventory) bool {
    return value.scan.full_scan == true and value.scan.warnings.len == 0 and !inventoryTruncated(value);
}

fn servicePresent(units: []const inventory.ServiceUnit, name: []const u8) bool {
    for (units) |unit| if (std.mem.eql(u8, unit.name, name)) return true;
    return false;
}

fn dropInPresent(values: []const inventory.SystemdDropIn, needle: inventory.SystemdDropIn) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value.unit, needle.unit) and
            std.mem.eql(u8, value.path, needle.path) and
            value.size == needle.size and
            value.meaningful_lines == needle.meaningful_lines) return true;
    }
    return false;
}

fn envFilePresent(values: []const inventory.ServiceEnvFile, needle: inventory.ServiceEnvFile) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value.unit, needle.unit) and
            std.mem.eql(u8, value.path, needle.path) and
            value.size == needle.size and
            value.meaningful_lines == needle.meaningful_lines) return true;
    }
    return false;
}

fn projectPresent(projects: []const inventory.ProjectRef, root: []const u8) bool {
    for (projects) |project| if (std.mem.eql(u8, project.root, root)) return true;
    return false;
}

fn projectManifestPresent(projects: []const inventory.ProjectRef, needle: inventory.ProjectRef) bool {
    for (projects) |project| {
        if (std.mem.eql(u8, project.root, needle.root) and
            std.mem.eql(u8, project.manifest_path, needle.manifest_path) and
            project.kind == needle.kind) return true;
    }
    return false;
}

fn dataPathPresent(paths: []const inventory.DataPath, needle: []const u8) bool {
    for (paths) |data_path| if (data_path.present and std.mem.eql(u8, data_path.path, needle)) return true;
    return false;
}

fn findContainer(
    containers: []const inventory.DockerContainer,
    runtime: inventory.ContainerRuntimeKind,
    name: []const u8,
) ?inventory.DockerContainer {
    for (containers) |container| {
        if (container.runtime == runtime and std.mem.eql(u8, container.name, name)) return container;
    }
    return null;
}

fn isWorkloadResource(resource: inventory.ResourceRef) bool {
    if (!resource.present or resource.default_action == .exclude) return false;
    return switch (resource.kind) {
        .package_managed, .cache, .ephemeral => false,
        else => resource.package_owner == null,
    };
}

fn componentKindForResource(resource: inventory.ResourceRef) schema.ComponentKind {
    if (resource.sensitivity == .secret) return .secret;
    return switch (resource.kind) {
        .unmanaged_executable, .install_root => .code,
        else => .data,
    };
}

fn resourcePresent(resources: []const inventory.ResourceRef, path: []const u8) bool {
    for (resources) |resource| if (resource.present and std.mem.eql(u8, resource.path, path)) return true;
    return false;
}

fn findAction(actions: []const plan.Action, id: []const u8) ?plan.Action {
    for (actions) |action| if (std.mem.eql(u8, action.id, id)) return action;
    return null;
}

fn emptyStrings(allocator: std.mem.Allocator) ![]const []const u8 {
    return allocator.alloc([]const u8, 0);
}

fn deinitComponents(allocator: std.mem.Allocator, components: []const schema.Component) void {
    for (components) |component| {
        allocator.free(component.source_ref);
        freeStrings(allocator, component.action_ids);
    }
    allocator.free(components);
}

fn freeComponentList(allocator: std.mem.Allocator, components: *std.ArrayList(schema.Component)) void {
    for (components.items) |component| {
        allocator.free(component.source_ref);
        freeStrings(allocator, component.action_ids);
    }
    components.deinit(allocator);
}

fn freeStrings(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn freeStringList(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8)) void {
    for (values.items) |value| allocator.free(value);
    values.deinit(allocator);
}

fn freeBlockers(allocator: std.mem.Allocator, blockers: []const schema.Blocker) void {
    for (blockers) |blocker| {
        allocator.free(blocker.ref);
        if (blocker.action_id) |action_id| allocator.free(action_id);
    }
    allocator.free(blockers);
}

fn freeBlockerList(allocator: std.mem.Allocator, blockers: *std.ArrayList(schema.Blocker)) void {
    for (blockers.items) |blocker| {
        allocator.free(blocker.ref);
        if (blocker.action_id) |action_id| allocator.free(action_id);
    }
    blockers.deinit(allocator);
}

fn freeEvidence(allocator: std.mem.Allocator, evidence: []const schema.Evidence) void {
    for (evidence) |item| allocator.free(item.ref);
    allocator.free(evidence);
}

fn freeEvidenceList(allocator: std.mem.Allocator, evidence: *std.ArrayList(schema.Evidence)) void {
    for (evidence.items) |item| allocator.free(item.ref);
    evidence.deinit(allocator);
}
