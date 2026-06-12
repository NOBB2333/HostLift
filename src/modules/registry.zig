const plan = @import("../plan/schema.zig");
const apply_support = @import("apply_support.zig");
const handler = @import("handler.zig");
const plan_registry = @import("plan_registry.zig");
const scan_registry = @import("scan_registry.zig");

pub const ModuleHandler = handler.ModuleHandler;
pub const ScanContext = handler.ScanContext;
pub const PlanContext = handler.PlanContext;
pub const ApplyContext = handler.ApplyContext;
pub const ApplyOptions = handler.ApplyOptions;
pub const ApplyRequirementsContext = handler.ApplyRequirementsContext;
pub const ApplySupport = apply_support.ApplySupport;
pub const all = plan_registry.all;
pub const allScan = scan_registry.allScan;
pub const appendPlanActions = plan_registry.appendPlanActions;
pub const applySupportForAction = apply_support.applySupportForAction;
pub const ensureApplySupported = apply_support.ensureApplySupported;
pub const findForAction = apply_support.findForAction;

// 按模块名查找处理器，供选择性规划和执行分发复用。
pub fn find(name: plan.ModuleName) ?ModuleHandler {
    return plan_registry.find(name);
}
