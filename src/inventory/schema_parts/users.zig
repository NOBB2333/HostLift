// 用户账户记录（/etc/passwd）。
pub const UserAccount = struct {
    name: []const u8,
    uid: u32,
    gid: u32,
    home: []const u8,
    shell: []const u8,
    system: bool,
};

// 用户组记录（/etc/group）。
pub const GroupAccount = struct {
    name: []const u8,
    gid: u32,
    system: bool,
};

// 用户和组清单。
pub const UserInventory = struct {
    users: []UserAccount,
    groups: []GroupAccount,
};

// SSH authorized_keys 摘要（不存密钥内容）。
pub const AuthorizedKeys = struct {
    user: []const u8,
    path: []const u8,
    key_count: u32,
};

// sshd_config 关键指令事实。
pub const SshdConfigFact = struct {
    key: []const u8,
    value: []const u8,
};

// SSH 清单。
pub const SshInventory = struct {
    authorized_keys: []AuthorizedKeys,
    sshd_config_present: bool,
    client_config_present: bool,
    sshd_config: []SshdConfigFact = &.{},
};
