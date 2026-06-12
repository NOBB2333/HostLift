// 数据路径类型枚举。
pub const DataPathKind = enum {
    app_data,
    web_root,
    database_data,
    docker_data,
    home_data,
    unknown,
};

// 数据路径记录。
pub const DataPath = struct {
    path: []const u8,
    present: bool,
    kind: DataPathKind,
    size: u64,
};

// 应用数据清单汇总。
pub const AppDataInventory = struct {
    paths: []DataPath,
};

// 项目类型枚举。
pub const ProjectKind = enum {
    docker_compose,
    node,
    python,
    go,
    rust,
    zig,
    static_site,
    unknown,
};

// 项目引用记录。
pub const ProjectRef = struct {
    root: []const u8,
    kind: ProjectKind,
    manifest_path: []const u8,
};

// 项目清单汇总。
pub const ProjectInventory = struct {
    projects: []ProjectRef,
    truncated: bool,
};

// 进程摘要记录。
pub const ProcessSummary = struct {
    pid: u32,
    user: []const u8,
    command: []const u8,
};

// 进程清单汇总。
pub const ProcessInventory = struct {
    processes: []ProcessSummary,
    truncated: bool,
};

// 监听端口记录。
pub const ListeningSocket = struct {
    protocol: []const u8,
    address: []const u8,
    port: u16,
    process: ?[]const u8,
};

// 网络清单汇总。
pub const NetworkInventory = struct {
    listeners: []ListeningSocket,
    truncated: bool,
};

// 运行中容器记录。
pub const DockerContainer = struct {
    runtime: ContainerRuntimeKind = .docker,
    name: []const u8,
    image: []const u8,
    status: []const u8,
    ports: []const u8,
    compose_project: ?[]const u8 = null,
    compose_service: ?[]const u8 = null,
    compose_workdir: ?[]const u8 = null,
};

// 容器运行时类型枚举。
pub const ContainerRuntimeKind = enum {
    docker,
    podman,
};

// 容器运行时可用性记录。
pub const ContainerRuntime = struct {
    kind: ContainerRuntimeKind,
    available: bool,
};

// 容器卷记录。
pub const ContainerVolume = struct {
    runtime: ContainerRuntimeKind = .docker,
    name: []const u8,
    driver: []const u8,
    scope: ?[]const u8 = null,
    mountpoint: ?[]const u8 = null,
};

// 容器网络记录。
pub const ContainerNetwork = struct {
    runtime: ContainerRuntimeKind = .docker,
    name: []const u8,
    driver: []const u8,
    scope: ?[]const u8 = null,
};

// 容器镜像记录。
pub const DockerImage = struct {
    runtime: ContainerRuntimeKind = .docker,
    repository: []const u8,
    tag: []const u8,
    image_id: []const u8,
};

// Docker Compose 文件记录。
pub const ComposeFile = struct {
    project_root: []const u8,
    path: []const u8,
};

// Docker 清单汇总。
pub const DockerInventory = struct {
    runtimes: []ContainerRuntime = &.{},
    containers: []DockerContainer,
    volumes: []ContainerVolume = &.{},
    networks: []ContainerNetwork = &.{},
    images: []DockerImage = &.{},
    compose_files: []ComposeFile = &.{},
    truncated: bool,
};

// 防火墙后端类型枚举。
pub const FirewallBackend = enum {
    ufw,
    firewalld,
    nftables,
    iptables,
    unknown,
};

// 防火墙配置文件记录。
pub const FirewallConfig = struct {
    path: []const u8,
    present: bool,
    size: u64,
};

// 防火墙清单汇总。
pub const FirewallInventory = struct {
    backend: FirewallBackend,
    configs: []FirewallConfig,
};
