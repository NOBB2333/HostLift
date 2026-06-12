#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

zig build >/dev/null

tmpdir="$(mktemp -d)"
cleanup() {
  if [[ "${HOSTLIFT_KEEP_FAKE_REMOTE_TMP:-}" == "1" ]]; then
    echo "keeping fake remote tmpdir: $tmpdir" >&2
    return
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

fakebin="$tmpdir/bin"
mkdir -p "$fakebin"
log="$tmpdir/fake-remote.log"

cat > "$fakebin/ssh" <<'FAKE_SSH'
#!/usr/bin/env bash
set -euo pipefail

: "${HOSTLIFT_FAKE_REMOTE_LOG:?HOSTLIFT_FAKE_REMOTE_LOG is required}"
printf 'ssh' >> "$HOSTLIFT_FAKE_REMOTE_LOG"
for arg in "$@"; do
  printf ' [%s]' "$arg" >> "$HOSTLIFT_FAKE_REMOTE_LOG"
done
printf '\n' >> "$HOSTLIFT_FAKE_REMOTE_LOG"

args=("$@")
idx=0
host=""
while [[ $idx -lt ${#args[@]} ]]; do
  case "${args[$idx]}" in
    -o)
      idx=$((idx + 2))
      ;;
    -i)
      idx=$((idx + 2))
      ;;
    --)
      idx=$((idx + 1))
      break
      ;;
    *)
      host="${args[$idx]}"
      idx=$((idx + 1))
      if [[ $idx -lt ${#args[@]} && "${args[$idx]}" == "--" ]]; then
        idx=$((idx + 1))
      fi
      break
      ;;
  esac
done

cmd=("${args[@]:$idx}")
if [[ ${#cmd[@]} -eq 0 ]]; then
  exit 0
fi

case "${cmd[0]}" in
  command)
    if [[ ${#cmd[@]} -ge 3 && "${cmd[1]}" == "-v" ]]; then
      if [[ -n "${HOSTLIFT_FAKE_PACKAGE_MANAGER:-}" ]]; then
        case "${cmd[2]}" in
          apt-get|dnf|yum|zypper|pacman)
            [[ "${cmd[2]}" == "$HOSTLIFT_FAKE_PACKAGE_MANAGER" ]] && { echo "${cmd[2]}"; exit 0; }
            exit 1
            ;;
          rpm)
            case "$HOSTLIFT_FAKE_PACKAGE_MANAGER" in
              dnf|yum|zypper) echo rpm; exit 0 ;;
            esac
            exit 1
            ;;
          dpkg-query)
            [[ "$HOSTLIFT_FAKE_PACKAGE_MANAGER" == "apt-get" ]] && { echo dpkg-query; exit 0; }
            exit 1
            ;;
        esac
      fi
      case "${cmd[2]}" in
        uname|sha256sum|find|stat|ls|apt-get|dnf|yum|zypper|pacman|rpm|dpkg-query|systemctl|runuser|chkconfig|update-rc.d|rc-update|useradd|id|groupadd|getent|docker|mkdir|rsync|cp|chmod|chown|grep|true|nft|iptables-restore|ufw|firewall-offline-cmd|firewall-cmd|systemd-run|/bin/sh|rm)
          echo "${cmd[2]}"
          exit 0
          ;;
        *)
          exit 1
          ;;
      esac
    fi
    ;;
  uname)
    echo "Linux fake-host 6.6.0 #1 SMP x86_64 GNU/Linux"
    ;;
  test)
    if [[ ${#cmd[@]} -ge 3 && "${cmd[1]}" == "-x" ]]; then
      case "${cmd[2]}" in
        /usr/bin/apt-get|/bin/apt-get)
          exit 0
          ;;
        *)
          exit 1
          ;;
      esac
    fi
    if [[ ${#cmd[@]} -ge 3 && ( "${cmd[1]}" == "-e" || "${cmd[1]}" == "-d" ) ]]; then
      exit 0
    fi
    exit 1
    ;;
  apt-get)
    echo "fake apt-get ${cmd[*]:1}"
    ;;
  dnf|yum|zypper|pacman)
    echo "fake ${cmd[*]}"
    ;;
  dpkg-query)
    if [[ "${HOSTLIFT_FAKE_DPKG_QUERY_FAIL:-}" == "1" ]]; then
      exit 1
    fi
    echo "nginx install ok installed"
    ;;
  rpm)
    if [[ "${HOSTLIFT_FAKE_RPM_QUERY_FAIL:-}" == "1" ]]; then
      exit 1
    fi
    echo "nginx-1.0-1"
    ;;
  getent)
    if [[ ${#cmd[@]} -ge 3 && "${cmd[1]}" == "passwd" && "${cmd[2]}" == "deploy" ]]; then
      echo "deploy:x:1001:1001:Deploy User:/home/deploy:/bin/bash"
      exit 0
    fi
    if [[ ${#cmd[@]} -ge 3 && "${cmd[1]}" == "group" && "${cmd[2]}" == "deploy" ]]; then
      echo "deploy:x:1001:"
      exit 0
    fi
    echo "fake ${cmd[*]}"
    ;;
  cp|mkdir|rsync|systemctl|runuser|update-rc.d|rc-update|docker|id|userdel|groupdel|chmod|chown|grep|true|nft|iptables-restore|ufw|firewall-offline-cmd|firewall-cmd|systemd-run|rm|/bin/sh)
    echo "fake ${cmd[*]}"
    ;;
  chkconfig)
    if [[ ${#cmd[@]} -ge 3 && "${cmd[1]}" == "--list" ]]; then
      echo "${cmd[2]} 0:off 1:off 2:on 3:on 4:off 5:on 6:off"
    else
      echo "fake ${cmd[*]}"
    fi
    ;;
  ls)
    case "${cmd[1]:-}" in
      /etc/rc2.d|/etc/rc3.d|/etc/rc5.d)
        echo "S20legacy"
        ;;
      *)
        echo "fake ${cmd[*]}"
        ;;
    esac
    ;;
  sha256sum)
    if [[ -n "${HOSTLIFT_FAKE_REMOTE_SHA256:-}" ]]; then
      echo "$HOSTLIFT_FAKE_REMOTE_SHA256  ${cmd[1]:-/dev/null}"
    else
      echo "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  ${cmd[1]:-/dev/null}"
    fi
    ;;
  find)
    ;;
  stat)
    echo "0 regular file"
    ;;
  *)
    echo "fake remote command on ${host}: ${cmd[*]}"
    ;;
esac
FAKE_SSH
chmod +x "$fakebin/ssh"

cat > "$fakebin/scp" <<'FAKE_SCP'
#!/usr/bin/env bash
set -euo pipefail
: "${HOSTLIFT_FAKE_REMOTE_LOG:?HOSTLIFT_FAKE_REMOTE_LOG is required}"
printf 'scp' >> "$HOSTLIFT_FAKE_REMOTE_LOG"
for arg in "$@"; do
  printf ' [%s]' "$arg" >> "$HOSTLIFT_FAKE_REMOTE_LOG"
done
printf '\n' >> "$HOSTLIFT_FAKE_REMOTE_LOG"
echo "fake scp $*"
FAKE_SCP
chmod +x "$fakebin/scp"

cat > "$fakebin/rsync" <<'FAKE_RSYNC'
#!/usr/bin/env bash
set -euo pipefail
: "${HOSTLIFT_FAKE_REMOTE_LOG:?HOSTLIFT_FAKE_REMOTE_LOG is required}"
printf 'rsync' >> "$HOSTLIFT_FAKE_REMOTE_LOG"
for arg in "$@"; do
  printf ' [%s]' "$arg" >> "$HOSTLIFT_FAKE_REMOTE_LOG"
done
printf '\n' >> "$HOSTLIFT_FAKE_REMOTE_LOG"
echo "fake rsync $*"
FAKE_RSYNC
chmod +x "$fakebin/rsync"

cat > "$fakebin/logger" <<'FAKE_LOGGER'
#!/usr/bin/env bash
set -euo pipefail
: "${HOSTLIFT_FAKE_REMOTE_LOG:?HOSTLIFT_FAKE_REMOTE_LOG is required}"
printf 'logger' >> "$HOSTLIFT_FAKE_REMOTE_LOG"
for arg in "$@"; do
  printf ' [%s]' "$arg" >> "$HOSTLIFT_FAKE_REMOTE_LOG"
done
printf '\n' >> "$HOSTLIFT_FAKE_REMOTE_LOG"
FAKE_LOGGER
chmod +x "$fakebin/logger"

export PATH="$fakebin:$PATH"
export HOSTLIFT_FAKE_REMOTE_LOG="$log"

identity="$tmpdir/id_ed25519"
touch "$identity"
chmod 600 "$identity"

./zig-out/bin/hostlift remote exec \
  --host root@192.0.2.10 \
  --identity-file "$identity" \
  --timeout 3 \
  --retries 1 \
  --operation-id OPS-FAKE/remote \
  --operation-state "$tmpdir/operation-state.jsonl" \
  --approve \
  -- uname -a > "$tmpdir/remote.out"

grep -q "Linux fake-host" "$tmpdir/remote.out"
grep -q '"operation_id":"OPS-FAKE/remote"' "$tmpdir/operation-state.jsonl"
grep -q '"kind":"command"' "$tmpdir/operation-state.jsonl"
grep -q '"status":"started"' "$tmpdir/operation-state.jsonl"
grep -q '"status":"succeeded"' "$tmpdir/operation-state.jsonl"
if grep -q "$identity" "$tmpdir/operation-state.jsonl"; then
  echo "identity file path leaked into operation state" >&2
  exit 1
fi
grep -q "ssh .*\\[command\\].*\\[-v\\].*\\[uname\\]" "$log"
grep -q "ssh .*\\[-i\\] \\[$identity\\].*\\[root@192.0.2.10\\].*\\[--\\].*\\[uname\\].*\\[-a\\]" "$log"

mkdir -p "$tmpdir/src"
printf 'hello\n' > "$tmpdir/src/app.txt"
export HOSTLIFT_FAKE_REMOTE_SHA256
if command -v sha256sum >/dev/null 2>&1; then
  HOSTLIFT_FAKE_REMOTE_SHA256="$(sha256sum "$tmpdir/src/app.txt" | awk '{print $1}')"
else
  HOSTLIFT_FAKE_REMOTE_SHA256="$(shasum -a 256 "$tmpdir/src/app.txt" | awk '{print $1}')"
fi

./zig-out/bin/hostlift transfer \
  --host root@192.0.2.10 \
  --source "$tmpdir/src/app.txt" \
  --target /tmp/app.txt \
  --preserve \
  --identity-file "$identity" \
  --timeout 3 \
  --retries 1 \
  --operation-id OPS-FAKE/transfer \
  --operation-state "$tmpdir/operation-state.jsonl" \
  --approve > "$tmpdir/scp-transfer.out"

grep -q "sha256 verified: $HOSTLIFT_FAKE_REMOTE_SHA256" "$tmpdir/scp-transfer.out"
grep -q '"operation_id":"OPS-FAKE/transfer"' "$tmpdir/operation-state.jsonl"
grep -q '"kind":"transfer"' "$tmpdir/operation-state.jsonl"
grep -q "scp .*\\[-i\\] \\[$identity\\].*\\[-p\\].*\\[$tmpdir/src/app.txt\\].*\\[root@192.0.2.10:/tmp/app.txt\\]" "$log"
grep -q "ssh .*\\[command\\].*\\[-v\\].*\\[sha256sum\\]" "$log"
grep -q "ssh .*\\[sha256sum\\].*\\[/tmp/app.txt\\]" "$log"

./zig-out/bin/hostlift transfer \
  --host root@192.0.2.10 \
  --source "$tmpdir/src" \
  --target /srv/app \
  --recursive \
  --transport rsync \
  --partial \
  --identity-file "$identity" \
  --timeout 3 \
  --retries 1 \
  --approve > "$tmpdir/transfer.out"

grep -q "rsync .*\\[--partial\\].*\\[$tmpdir/src\\].*\\[root@192.0.2.10:/srv/app\\]" "$log"
grep -q -- "-i $identity" "$log"

chunk_log_lines_before="$(wc -l < "$log" | tr -d ' ')"
./zig-out/bin/hostlift transfer \
  --host root@192.0.2.10 \
  --source "$tmpdir/src" \
  --target /srv/app \
  --recursive \
  --transport chunk > "$tmpdir/chunk-transfer-plan.json"

grep -q '"transport": "chunk"' "$tmpdir/chunk-transfer-plan.json"
grep -q '"chunk_size_bytes": 8388608' "$tmpdir/chunk-transfer-plan.json"
chunk_log_lines_after_dry_run="$(wc -l < "$log" | tr -d ' ')"
if [[ "$chunk_log_lines_after_dry_run" != "$chunk_log_lines_before" ]]; then
  echo "chunk dry-run performed remote calls" >&2
  exit 1
fi

./zig-out/bin/hostlift transfer \
  --host root@192.0.2.10 \
  --source "$tmpdir/src" \
  --target /srv/app \
  --recursive \
  --transport chunk \
  --identity-file "$identity" \
  --timeout 3 \
  --retries 1 \
  --operation-id OPS-FAKE/chunk-transfer \
  --operation-state "$tmpdir/operation-state.jsonl" \
  --approve > "$tmpdir/chunk-transfer-approved.out"

grep -q "chunk transfer staged: /tmp/hostlift-chunk-.*missing_or_changed=1" "$tmpdir/chunk-transfer-approved.out"
grep -q '"operation_id":"OPS-FAKE/chunk-transfer"' "$tmpdir/operation-state.jsonl"
grep -q "ssh .*\\[-i\\] \\[$identity\\].*\\[root@192.0.2.10\\].*\\[--\\].*\\[mkdir\\].*\\[-p\\].*\\[/tmp/hostlift-chunk-" "$log"
grep -q "ssh .*\\[find\\].*\\[/srv/app\\].*\\[-type\\].*\\[f\\].*\\[-print\\]" "$log"
grep -q "scp .*\\[-i\\] \\[$identity\\].*\\[$tmpdir/src/app.txt\\].*\\[root@192.0.2.10:/tmp/hostlift-chunk-.*/app.txt\\]" "$log"
grep -q "ssh .*\\[-i\\] \\[$identity\\].*\\[root@192.0.2.10\\].*\\[--\\].*\\[rsync\\].*\\[-a\\].*\\[/tmp/hostlift-chunk-.*\\/\\].*\\[/srv/app\\]" "$log"
if grep -q "ssh .*\\[rsync\\].*\\[--delete\\].*\\[/tmp/hostlift-chunk-" "$log"; then
  echo "chunk incremental transfer unexpectedly used --delete" >&2
  exit 1
fi

manifest="$tmpdir/rollback.jsonl"
cat > "$manifest" <<'EOF'
{"schema_version":"hostlift.rollback.v1","created_at":123,"host":"root@192.0.2.10","action_id":"packages/install/nginx","action_type":"install_package","original_path":"","backup_path":"","subject":"nginx"}
EOF

policy="$tmpdir/policy.json"
cat > "$policy" <<'EOF'
{"schema_version":"hostlift.policy.v1","allow_hosts":["root@192.0.2.10"],"require_approval_ticket":true}
EOF

host_authz="$tmpdir/host-authz.json"
cat > "$host_authz" <<'EOF'
{
  "schema_version": "hostlift.host_authz.v1",
  "rules": [
    {
      "operator": "ops/fake",
      "hosts": ["root@192.0.2.10"]
    }
  ]
}
EOF

deny_host_authz="$tmpdir/deny-host-authz.json"
cat > "$deny_host_authz" <<'EOF'
{
  "schema_version": "hostlift.host_authz.v1",
  "rules": [
    {
      "operator": "ops/other",
      "hosts": ["root@192.0.2.10"]
    }
  ]
}
EOF

audit="$tmpdir/audit.jsonl"
rollback_receipt="$tmpdir/rollback-approval-receipt.json"
cat > "$rollback_receipt" <<'EOF'
{
  "schema_version": "hostlift.approval_receipt.v1",
  "ticket": "OPS-FAKE-1",
  "operator": "ops/fake",
  "host": "root@192.0.2.10",
  "purpose": "rollback",
  "expires_at": 4102444800,
  "issuer": "fake/change-platform"
}
EOF
export HOSTLIFT_FAKE_DPKG_QUERY_FAIL=1
./zig-out/bin/hostlift rollback \
  --manifest "$manifest" \
  --host root@192.0.2.10 \
  --operator ops/fake \
  --approval-ticket OPS-FAKE-1 \
  --approval-receipt "$rollback_receipt" \
  --policy "$policy" \
  --host-authz "$host_authz" \
  --audit-log "$audit" \
  --identity-file "$identity" \
  --remote-timeout 3 \
  --remote-retries 1 \
  --operation-id OPS-FAKE/rollback \
  --operation-state "$tmpdir/operation-state.jsonl" \
  --approve > "$tmpdir/rollback.out"
unset HOSTLIFT_FAKE_DPKG_QUERY_FAIL

grep -q "Rollback entries applied: 1" "$tmpdir/rollback.out"
grep -q "verify rollback packages/install/nginx: package absent nginx" "$tmpdir/rollback.out"
grep -q '"operation_id":"OPS-FAKE/rollback"' "$tmpdir/operation-state.jsonl"
grep -Eq '"policy_hash":"[0-9a-f]{64}"' "$audit"
grep -q '"credential_source":"identity_file"' "$audit"
if grep -q "$identity" "$audit"; then
  echo "identity file path leaked into audit log" >&2
  exit 1
fi

./zig-out/bin/hostlift audit verify --log "$audit" --summary > "$tmpdir/audit-verify.out"
grep -q "Valid: true" "$tmpdir/audit-verify.out"
grep -q "\\[apt-get\\].*\\[remove\\].*\\[nginx\\]" "$log"

dnf_audit="$tmpdir/dnf-rollback-audit.jsonl"
export HOSTLIFT_FAKE_PACKAGE_MANAGER=dnf
export HOSTLIFT_FAKE_RPM_QUERY_FAIL=1
./zig-out/bin/hostlift rollback \
  --manifest "$manifest" \
  --host root@192.0.2.10 \
  --operator ops/fake \
  --approval-ticket OPS-FAKE-2 \
  --policy "$policy" \
  --host-authz "$host_authz" \
  --audit-log "$dnf_audit" \
  --identity-file "$identity" \
  --remote-timeout 3 \
  --remote-retries 1 \
  --approve > "$tmpdir/dnf-rollback.out"
unset HOSTLIFT_FAKE_PACKAGE_MANAGER
unset HOSTLIFT_FAKE_RPM_QUERY_FAIL

grep -q "Rollback entries applied: 1" "$tmpdir/dnf-rollback.out"
grep -q "verify rollback packages/install/nginx: package absent nginx" "$tmpdir/dnf-rollback.out"
grep -q "ssh .*\\[command\\].*\\[-v\\].*\\[dnf\\]" "$log"
grep -q "ssh .*\\[dnf\\].*\\[remove\\].*\\[-y\\].*\\[nginx\\]" "$log"
grep -q "ssh .*\\[rpm\\].*\\[-q\\].*\\[nginx\\]" "$log"
./zig-out/bin/hostlift audit verify --log "$dnf_audit" --summary > "$tmpdir/dnf-audit-verify.out"
grep -q "Valid: true" "$tmpdir/dnf-audit-verify.out"

replayed_audit="$tmpdir/audit-replayed.jsonl"
./zig-out/bin/hostlift audit replay \
  --log "$audit" \
  --audit-sink file:"$replayed_audit" \
  --summary > "$tmpdir/audit-replay.out"
grep -q "Valid: true" "$tmpdir/audit-replay.out"
grep -q "Replayed: 2" "$tmpdir/audit-replay.out"
./zig-out/bin/hostlift audit verify --log "$replayed_audit" --summary > "$tmpdir/audit-replayed-verify.out"
grep -q "Valid: true" "$tmpdir/audit-replayed-verify.out"

deny_policy="$tmpdir/deny-policy.json"
cat > "$deny_policy" <<'EOF'
{"schema_version":"hostlift.policy.v1","allow_hosts":["root@192.0.2.99"],"require_approval_ticket":true}
EOF

deny_plan="$tmpdir/deny-plan.json"
cat > "$deny_plan" <<'EOF'
{
  "schema_version": "hostlift.plan.v1",
  "source_inventory_hash": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  "target_inventory_hash": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
  "package_manager": "apt",
  "compatibility": {
    "compatible": true,
    "same_distro": true,
    "same_version": true,
    "same_package_manager": true,
    "same_arch": true,
    "reason": "compatible"
  },
  "actions": [
    {
      "id": "packages/install/nginx",
      "module": "packages",
      "action_type": "install_package",
      "subject": "nginx",
      "description": "Install explicit package on target: nginx",
      "risk": "low",
      "requires_confirmation": false
    }
  ],
  "created_at": 123
}
EOF

log_lines_before_apply_deny="$(wc -l < "$log" | tr -d ' ')"
if ./zig-out/bin/hostlift apply \
  --plan "$deny_plan" \
  --host root@192.0.2.10 \
  --operator ops/fake \
  --approval-ticket OPS-FAKE-APPLY \
  --policy "$deny_policy" \
  --audit-log "$tmpdir/deny-apply-audit.jsonl" \
  --identity-file "$identity" \
  --approve > "$tmpdir/deny-apply.out" 2> "$tmpdir/deny-apply.err"; then
  echo "policy deny apply unexpectedly succeeded" >&2
  exit 1
fi
grep -q "PolicyDeniedMigrationPlan" "$tmpdir/deny-apply.err"
log_lines_after_apply_deny="$(wc -l < "$log" | tr -d ' ')"
if [[ "$log_lines_after_apply_deny" != "$log_lines_before_apply_deny" ]]; then
  echo "policy deny apply performed remote calls" >&2
  exit 1
fi
if [[ -e "$tmpdir/deny-apply-audit.jsonl" ]]; then
  echo "policy deny apply created an audit log before approval gate passed" >&2
  exit 1
fi

allow_apply_audit="$tmpdir/allow-apply-audit.jsonl"
if command -v sha256sum >/dev/null 2>&1; then
  deny_plan_hash="$(sha256sum "$deny_plan" | awk '{print $1}')"
else
  deny_plan_hash="$(shasum -a 256 "$deny_plan" | awk '{print $1}')"
fi
approval_receipt="$tmpdir/approval-receipt.json"
cat > "$approval_receipt" <<EOF
{
  "schema_version": "hostlift.approval_receipt.v1",
  "ticket": "OPS-FAKE-APPLY",
  "operator": "ops/fake",
  "host": "root@192.0.2.10",
  "plan_hash": "$deny_plan_hash",
  "purpose": "apply",
  "expires_at": 4102444800,
  "issuer": "fake/change-platform"
}
EOF

bad_receipt="$tmpdir/bad-approval-receipt.json"
cat > "$bad_receipt" <<EOF
{
  "schema_version": "hostlift.approval_receipt.v1",
  "ticket": "OPS-FAKE-APPLY",
  "operator": "ops/fake",
  "host": "root@192.0.2.99",
  "plan_hash": "$deny_plan_hash",
  "purpose": "apply",
  "expires_at": 4102444800
}
EOF

log_lines_before_receipt_deny="$(wc -l < "$log" | tr -d ' ')"
if ./zig-out/bin/hostlift apply \
  --plan "$deny_plan" \
  --host root@192.0.2.10 \
  --operator ops/fake \
  --approval-ticket OPS-FAKE-APPLY \
  --approval-receipt "$bad_receipt" \
  --policy "$policy" \
  --audit-log "$tmpdir/bad-receipt-audit.jsonl" \
  --identity-file "$identity" \
  --approve > "$tmpdir/bad-receipt.out" 2> "$tmpdir/bad-receipt.err"; then
  echo "approval receipt mismatch unexpectedly succeeded" >&2
  exit 1
fi
grep -q "ApprovalReceiptMismatch" "$tmpdir/bad-receipt.err"
log_lines_after_receipt_deny="$(wc -l < "$log" | tr -d ' ')"
if [[ "$log_lines_after_receipt_deny" != "$log_lines_before_receipt_deny" ]]; then
  echo "approval receipt deny performed remote calls" >&2
  exit 1
fi

log_lines_before_host_authz_deny="$(wc -l < "$log" | tr -d ' ')"
if ./zig-out/bin/hostlift apply \
  --plan "$deny_plan" \
  --host root@192.0.2.10 \
  --operator ops/fake \
  --approval-ticket OPS-FAKE-APPLY \
  --approval-receipt "$approval_receipt" \
  --policy "$policy" \
  --host-authz "$deny_host_authz" \
  --audit-log "$tmpdir/deny-host-authz-audit.jsonl" \
  --identity-file "$identity" \
  --approve > "$tmpdir/deny-host-authz.out" 2> "$tmpdir/deny-host-authz.err"; then
  echo "host authorization deny unexpectedly succeeded" >&2
  exit 1
fi
grep -q "HostAuthorizationDenied" "$tmpdir/deny-host-authz.err"
log_lines_after_host_authz_deny="$(wc -l < "$log" | tr -d ' ')"
if [[ "$log_lines_after_host_authz_deny" != "$log_lines_before_host_authz_deny" ]]; then
  echo "host authorization deny performed remote calls" >&2
  exit 1
fi
if [[ -e "$tmpdir/deny-host-authz-audit.jsonl" ]]; then
  echo "host authorization deny created an audit log before authorization gate passed" >&2
  exit 1
fi

./zig-out/bin/hostlift apply \
  --plan "$deny_plan" \
  --host root@192.0.2.10 \
  --operator ops/fake \
  --approval-ticket OPS-FAKE-APPLY \
  --approval-receipt "$approval_receipt" \
  --policy "$policy" \
  --host-authz "$host_authz" \
  --audit-log "$allow_apply_audit" \
  --identity-file "$identity" \
  --remote-timeout 3 \
  --remote-retries 1 \
  --operation-id OPS-FAKE/apply \
  --operation-state "$tmpdir/operation-state.jsonl" \
  --approve > "$tmpdir/allow-apply.out"

grep -q "Applying supported actions:" "$tmpdir/allow-apply.out"
grep -q "packages/install/nginx" "$tmpdir/allow-apply.out"
grep -q '"operation_id":"OPS-FAKE/apply"' "$tmpdir/operation-state.jsonl"
grep -q "ssh .*\\[command\\].*\\[-v\\].*\\[apt-get\\]" "$log"
grep -q "ssh .*\\[command\\].*\\[-v\\].*\\[dpkg-query\\]" "$log"
grep -q "ssh .*\\[apt-get\\].*\\[install\\].*\\[-y\\].*\\[nginx\\]" "$log"
grep -q "ssh .*\\[dpkg-query\\].*\\[-W\\].*\\[nginx\\]" "$log"
grep -q '"credential_source":"identity_file"' "$allow_apply_audit"

users_plan="$tmpdir/users-plan.json"
cat > "$users_plan" <<'EOF'
{
  "schema_version": "hostlift.plan.v1",
  "source_inventory_hash": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  "target_inventory_hash": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
  "package_manager": "apt",
  "compatibility": {
    "compatible": true,
    "same_distro": true,
    "same_version": true,
    "same_package_manager": true,
    "same_arch": true,
    "reason": "compatible"
  },
  "actions": [
    {
      "id": "users/create-user/deploy",
      "module": "users",
      "action_type": "create_user",
      "subject": "deploy",
      "uid": 1001,
      "gid": 1001,
      "home": "/home/deploy",
      "shell": "/bin/bash",
      "description": "Create user deploy",
      "risk": "medium",
      "requires_confirmation": false
    }
  ],
  "created_at": 125
}
EOF

./zig-out/bin/hostlift apply \
  --plan "$users_plan" \
  --host root@192.0.2.10 \
  --operator ops/fake \
  --approval-ticket OPS-FAKE-USERS \
  --policy "$policy" \
  --host-authz "$host_authz" \
  --audit-log "$tmpdir/users-apply-audit.jsonl" \
  --identity-file "$identity" \
  --remote-timeout 3 \
  --remote-retries 1 \
  --approve > "$tmpdir/users-apply.out"

grep -q "user metadata matched deploy" "$tmpdir/users-apply.out"
grep -q "ssh .*\\[command\\].*\\[-v\\].*\\[getent\\]" "$log"
grep -q "ssh .*\\[useradd\\].*\\[-u\\].*\\[1001\\].*\\[-g\\].*\\[1001\\].*\\[-d\\].*\\[/home/deploy\\].*\\[-s\\].*\\[/bin/bash\\]" "$log"
grep -q "ssh .*\\[getent\\].*\\[passwd\\].*\\[deploy\\]" "$log"

audit_mirror="$tmpdir/audit-mirror.jsonl"
./zig-out/bin/hostlift apply \
  --plan "$deny_plan" \
  --host root@192.0.2.10 \
  --operator ops/fake \
  --approval-ticket OPS-FAKE-APPLY \
  --approval-receipt "$approval_receipt" \
  --policy "$policy" \
  --host-authz "$host_authz" \
  --audit-sink syslog:local0 \
  --audit-mirror-log "$audit_mirror" \
  --identity-file "$identity" \
  --remote-timeout 3 \
  --remote-retries 1 \
  --approve > "$tmpdir/mirror-apply.out"

grep -q "Audit sink: syslog:local0" "$tmpdir/mirror-apply.out"
grep -q "Audit mirror log: $audit_mirror" "$tmpdir/mirror-apply.out"
grep -q "logger .*\\[local0.info\\].*\\[hostlift\\]" "$log"
./zig-out/bin/hostlift audit verify --log "$audit_mirror" --summary > "$tmpdir/audit-mirror-verify.out"
grep -q "Valid: true" "$tmpdir/audit-mirror-verify.out"
mirror_replayed="$tmpdir/audit-mirror-replayed.jsonl"
./zig-out/bin/hostlift audit replay \
  --log "$audit_mirror" \
  --audit-sink file:"$mirror_replayed" \
  --summary > "$tmpdir/audit-mirror-replay.out"
grep -q "Replayed: 2" "$tmpdir/audit-mirror-replay.out"
./zig-out/bin/hostlift audit verify --log "$mirror_replayed" --summary > "$tmpdir/audit-mirror-replayed-verify.out"
grep -q "Valid: true" "$tmpdir/audit-mirror-replayed-verify.out"

firewall_plan="$tmpdir/firewall-plan.json"
cat > "$firewall_plan" <<'EOF'
{
  "schema_version": "hostlift.plan.v1",
  "source_inventory_hash": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  "target_inventory_hash": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
  "package_manager": "apt",
  "compatibility": {
    "compatible": true,
    "same_distro": true,
    "same_version": true,
    "same_package_manager": true,
    "same_arch": true,
    "reason": "compatible"
  },
  "actions": [
    {
      "id": "firewall/apply-config//etc/nftables.conf",
      "module": "firewall",
      "action_type": "apply_firewall_config",
      "subject": "/etc/nftables.conf",
      "description": "Apply nftables config",
      "risk": "high",
      "requires_confirmation": true,
      "recursive": true
    }
  ],
  "created_at": 124
}
EOF

./zig-out/bin/hostlift apply \
  --plan "$firewall_plan" \
  --source-host root@192.0.2.11 \
  --host root@192.0.2.10 \
  --operator ops/fake \
  --approval-ticket OPS-FAKE-FIREWALL \
  --policy "$policy" \
  --host-authz "$host_authz" \
  --audit-log "$tmpdir/firewall-apply-audit.jsonl" \
  --identity-file "$identity" \
  --remote-timeout 3 \
  --remote-retries 1 \
  --firewall-reload \
  --ssh-port 22 \
  --firewall-recovery-window 120 \
  --approve > "$tmpdir/firewall-apply.out"

grep -q "firewall reload preflight \\[nftables\\]" "$tmpdir/firewall-apply.out"
grep -q "ssh .*\\[command\\].*\\[-v\\].*\\[nft\\]" "$log"
grep -q "ssh .*\\[command\\].*\\[-v\\].*\\[systemd-run\\]" "$log"
grep -q "ssh .*\\[grep\\].*\\[22\\].*\\[/etc/nftables.conf\\]" "$log"
grep -q "ssh .*\\[nft\\].*\\[-c\\].*\\[-f\\].*\\[/etc/nftables.conf\\]" "$log"
grep -q "ssh .*\\[systemd-run\\].*\\[--on-active=120\\]" "$log"
grep -q "ssh .*\\[nft\\].*\\[-f\\].*\\[/etc/nftables.conf\\]" "$log"
grep -q "ssh .*\\[systemctl\\].*\\[stop\\].*\\[hostlift-firewall-recovery-" "$log"

log_lines_before_deny="$(wc -l < "$log" | tr -d ' ')"
if ./zig-out/bin/hostlift rollback \
  --manifest "$manifest" \
  --host root@192.0.2.10 \
  --operator ops/fake \
  --approval-ticket OPS-FAKE-2 \
  --policy "$deny_policy" \
  --audit-log "$tmpdir/deny-audit.jsonl" \
  --identity-file "$identity" \
  --remote-timeout 3 \
  --remote-retries 1 \
  --approve > "$tmpdir/deny-rollback.out" 2> "$tmpdir/deny-rollback.err"; then
  echo "policy deny rollback unexpectedly succeeded" >&2
  exit 1
fi
grep -q "PolicyDeniedRollback" "$tmpdir/deny-rollback.err"
log_lines_after_deny="$(wc -l < "$log" | tr -d ' ')"
if [[ "$log_lines_after_deny" != "$log_lines_before_deny" ]]; then
  echo "policy deny rollback performed remote calls" >&2
  exit 1
fi
if [[ -e "$tmpdir/deny-audit.jsonl" ]]; then
  echo "policy deny rollback created an audit log before approval gate passed" >&2
  exit 1
fi

echo "fake remote smoke passed"
