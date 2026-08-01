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
if [[ -n "${HOSTLIFT_FAKE_FAIL_COMMAND:-}" && "${cmd[0]}" == "$HOSTLIFT_FAKE_FAIL_COMMAND" ]]; then
  exit 1
fi

if [[ ${#cmd[@]} -eq 1 && "${cmd[0]}" == *"'psql'"* ]]; then
  case "${cmd[0]}" in
    *"SHOW server_version_num"*) printf '%s\n' "${HOSTLIFT_FAKE_PG_VERSION_NUM:-160003}" ;;
    *"pg_stat_activity"*) printf '%s\n' "${HOSTLIFT_FAKE_PG_CLIENTS:-0}" ;;
    *"NOT datistemplate AND datname <>"*) printf '%s\n' "${HOSTLIFT_FAKE_PG_TARGET_DATABASES:-0}" ;;
    *"rolname <>"*) printf '%s\n' "${HOSTLIFT_FAKE_PG_TARGET_ROLES:-0}" ;;
    *"pg_database_size"*) printf '%s\n' "${HOSTLIFT_FAKE_PG_DATABASE_BYTES:-4096}" ;;
    *"SHOW data_directory"*) printf '%s\n' "/var/lib/postgresql/16/main" ;;
    *"rolname ="*"rolsuper"*) printf '1\n' ;;
    *"json_agg(datname"*) printf '["app","postgres"]\n' ;;
    *"json_agg(rolname"*) printf '["app","postgres"]\n' ;;
    *) echo "unknown fixed PostgreSQL query" >&2; exit 1 ;;
  esac
  exit 0
fi

case "${cmd[0]}" in
  command)
    if [[ ${#cmd[@]} -ge 3 && "${cmd[1]}" == "-v" ]]; then
      if [[ -n "${HOSTLIFT_FAKE_MISSING_COMMAND:-}" && "${cmd[2]}" == "$HOSTLIFT_FAKE_MISSING_COMMAND" ]]; then
        exit 1
      fi
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
        uname|cat|curl|sh|bash|sha256sum|find|stat|readlink|du|df|ls|apt-get|dnf|yum|zypper|pacman|rpm|dpkg-query|systemctl|runuser|chkconfig|update-rc.d|rc-update|useradd|id|groupadd|getent|docker|mkdir|rsync|cp|chmod|chown|grep|true|test|nft|iptables-restore|ufw|firewall-offline-cmd|firewall-cmd|systemd-run|/bin/sh|rm|sudo|env|psql|pg_dumpall|install)
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
    if [[ "${cmd[1]:-}" == "-m" ]]; then
      echo "x86_64"
    else
      echo "Linux fake-host 6.6.0 #1 SMP x86_64 GNU/Linux"
    fi
    ;;
  cat)
    if [[ "${cmd[1]:-}" == "/etc/os-release" ]]; then
      printf 'NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="24.04"\n'
    else
      echo "fake ${cmd[*]}"
    fi
    ;;
  id)
    if [[ "${cmd[1]:-}" == "-u" ]]; then
      echo "0"
    else
      echo "fake ${cmd[*]}"
    fi
    ;;
  test)
    if [[ -n "${HOSTLIFT_FAKE_REINSTALL_ROOT:-}" ]]; then
      if [[ "${cmd[1]:-}" == "-e" ]]; then
        case "${cmd[2]:-}" in
          "$HOSTLIFT_FAKE_REINSTALL_ROOT") [[ -e "${HOSTLIFT_FAKE_REINSTALL_ROOT_STATE:-/nonexistent}" ]] && exit 0 || exit 1 ;;
          "$HOSTLIFT_FAKE_REINSTALL_ROOT/verified-artifact") [[ -e "${HOSTLIFT_FAKE_REINSTALL_ARTIFACT_STATE:-/nonexistent}" ]] && exit 0 || exit 1 ;;
          "${HOSTLIFT_FAKE_REINSTALL_MANAGED_PATH:-/nonexistent}") [[ -e "${HOSTLIFT_FAKE_REINSTALL_MANAGED_STATE:-/nonexistent}" ]] && exit 0 || exit 1 ;;
        esac
      fi
      if [[ "${cmd[1]:-}" == "-x" && "${cmd[2]:-}" == "${HOSTLIFT_FAKE_REINSTALL_MANAGED_PATH:-/nonexistent}" ]]; then
        [[ -e "${HOSTLIFT_FAKE_REINSTALL_MANAGED_STATE:-/nonexistent}" ]] && exit 0 || exit 1
      fi
    fi
    if [[ -n "${HOSTLIFT_FAKE_PG_ROOT:-}" && "${cmd[1]:-}" == "-e" ]]; then
      case "${cmd[2]:-}" in
        "$HOSTLIFT_FAKE_PG_ROOT/source-cluster.sql")
          if [[ "$host" == "${HOSTLIFT_FAKE_PG_SOURCE_HOST:-}" ]]; then
            [[ -e "${HOSTLIFT_FAKE_PG_SOURCE_DUMP_STATE:-/nonexistent}" ]] && exit 0
          else
            [[ -e "${HOSTLIFT_FAKE_PG_TARGET_DUMP_STATE:-/nonexistent}" ]] && exit 0
          fi
          exit 1
          ;;
        "$HOSTLIFT_FAKE_PG_ROOT/target-baseline.sql")
          [[ -e "${HOSTLIFT_FAKE_PG_BASELINE_STATE:-/nonexistent}" ]] && exit 0
          exit 1
          ;;
      esac
    fi
    if [[ -n "${HOSTLIFT_FAKE_MANIFEST_ROOT:-}" && "${cmd[2]:-}" == "$HOSTLIFT_FAKE_MANIFEST_ROOT" ]]; then
      case "${cmd[1]:-}" in
        -e)
          if [[ "$host" == "${HOSTLIFT_FAKE_MANIFEST_SOURCE_HOST:-}" ]]; then
            exit 0
          fi
          [[ -n "${HOSTLIFT_FAKE_TRANSFER_STATE:-}" && -e "$HOSTLIFT_FAKE_TRANSFER_STATE" ]] && exit 0
          exit 1
          ;;
        -d)
          exit 0
          ;;
        -L|-f)
          exit 1
          ;;
      esac
    fi
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
  docker|podman)
    if [[ "${cmd[1]:-}" == "inspect" ]]; then
      echo '[{"State":{"Running":true}}]'
    else
      echo "fake ${cmd[*]}"
    fi
    ;;
  install)
    install_target="${cmd[$((${#cmd[@]} - 1))]}"
    case "$install_target" in
      "${HOSTLIFT_FAKE_REINSTALL_ROOT:-/nonexistent}")
        : > "${HOSTLIFT_FAKE_REINSTALL_ROOT_STATE:?}"
        ;;
      "${HOSTLIFT_FAKE_REINSTALL_ROOT:-/nonexistent}/verified-artifact")
        : > "${HOSTLIFT_FAKE_REINSTALL_ARTIFACT_STATE:?}"
        ;;
      "${HOSTLIFT_FAKE_PG_ROOT:-/nonexistent}/source-cluster.sql")
        if [[ "$host" == "${HOSTLIFT_FAKE_PG_SOURCE_HOST:-}" ]]; then
          : > "${HOSTLIFT_FAKE_PG_SOURCE_DUMP_STATE:?}"
        else
          : > "${HOSTLIFT_FAKE_PG_TARGET_DUMP_STATE:?}"
        fi
        ;;
      "${HOSTLIFT_FAKE_PG_ROOT:-/nonexistent}/target-baseline.sql")
        : > "${HOSTLIFT_FAKE_PG_BASELINE_STATE:?}"
        ;;
    esac
    echo "fake ${cmd[*]}"
    ;;
  curl)
    if [[ " ${cmd[*]} " == *" --output ${HOSTLIFT_FAKE_REINSTALL_ROOT:-/nonexistent}/verified-artifact "* ]]; then
      if [[ "${cmd[1]:-}" != "--disable" ]]; then
        echo "verified reinstall curl did not disable curlrc" >&2
        exit 1
      fi
      if [[ " ${cmd[*]} " != *" --max-filesize ${HOSTLIFT_FAKE_REINSTALL_ARTIFACT_SIZE:-1} "* ]]; then
        echo "verified reinstall curl omitted the pinned size limit" >&2
        exit 1
      fi
      : > "${HOSTLIFT_FAKE_REINSTALL_ARTIFACT_STATE:?}"
    fi
    echo "fake curl"
    ;;
  sh|bash)
    if [[ "${cmd[1]:-}" == "${HOSTLIFT_FAKE_REINSTALL_ROOT:-/nonexistent}/verified-artifact" ]]; then
      if [[ "${HOSTLIFT_FAKE_REINSTALL_INSTALL_FAIL:-}" == "1" ]]; then
        : > "${HOSTLIFT_FAKE_REINSTALL_MANAGED_STATE:?}"
        exit 1
      fi
      : > "${HOSTLIFT_FAKE_REINSTALL_MANAGED_STATE:?}"
      echo "fake verified installer"
      exit 0
    fi
    echo "fake ${cmd[*]}"
    ;;
  sudo)
    if [[ " ${cmd[*]} " == *" pg_dumpall "* ]]; then
      pg_dump_path="${cmd[$((${#cmd[@]} - 1))]}"
      if [[ "${cmd[$((${#cmd[@]} - 2))]:-}" == "--file" ]]; then
        case "$pg_dump_path" in
          "${HOSTLIFT_FAKE_PG_ROOT:-/nonexistent}/source-cluster.sql") : > "${HOSTLIFT_FAKE_PG_SOURCE_DUMP_STATE:?}" ;;
          "${HOSTLIFT_FAKE_PG_ROOT:-/nonexistent}/target-baseline.sql") : > "${HOSTLIFT_FAKE_PG_BASELINE_STATE:?}" ;;
        esac
      fi
      echo "fake pg_dumpall"
      exit 0
    fi
    if [[ " ${cmd[*]} " == *" psql "* && " ${cmd[*]} " == *" --file "* ]]; then
      echo 'psql: ERROR: role "postgres" already exists' >&2
      echo 'psql: ERROR: database "postgres" already exists' >&2
      exit 0
    fi
    echo "fake ${cmd[*]}"
    ;;
  rm)
    case "${cmd[$((${#cmd[@]} - 1))]}" in
      "${HOSTLIFT_FAKE_REINSTALL_MANAGED_PATH:-/nonexistent}") rm -f "${HOSTLIFT_FAKE_REINSTALL_MANAGED_STATE:-/nonexistent}" ;;
      "${HOSTLIFT_FAKE_REINSTALL_ROOT:-/nonexistent}")
        rm -f "${HOSTLIFT_FAKE_REINSTALL_ROOT_STATE:-/nonexistent}" "${HOSTLIFT_FAKE_REINSTALL_ARTIFACT_STATE:-/nonexistent}"
        ;;
    esac
    echo "fake ${cmd[*]}"
    ;;
  cp|mkdir|rsync|systemctl|runuser|update-rc.d|rc-update|userdel|groupdel|chmod|chown|grep|true|nft|iptables-restore|ufw|firewall-offline-cmd|firewall-cmd|systemd-run|/bin/sh)
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
    if [[ -n "${HOSTLIFT_FAKE_MANIFEST_ROOT:-}" ]]; then
      manifest_hash="${HOSTLIFT_FAKE_MANIFEST_TARGET_HASH:-e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855}"
      if [[ "$host" == "${HOSTLIFT_FAKE_MANIFEST_SOURCE_HOST:-}" ]]; then
        manifest_hash="${HOSTLIFT_FAKE_MANIFEST_SOURCE_HASH:-$manifest_hash}"
      fi
      for manifest_path in "${cmd[@]:1}"; do
        [[ "$manifest_path" == "--" ]] && continue
        printf '%s  %s\n' "$manifest_hash" "$manifest_path"
      done
      exit 0
    fi
    if [[ -n "${HOSTLIFT_FAKE_REMOTE_SHA256:-}" ]]; then
      echo "$HOSTLIFT_FAKE_REMOTE_SHA256  ${cmd[1]:-/dev/null}"
    else
      echo "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  ${cmd[1]:-/dev/null}"
    fi
    ;;
  find)
    if [[ -n "${HOSTLIFT_FAKE_REINSTALL_ROOT:-}" && " ${cmd[*]} " == *" -printf . "* ]]; then
      case "${cmd[1]:-}" in
        "$HOSTLIFT_FAKE_REINSTALL_ROOT") [[ -e "${HOSTLIFT_FAKE_REINSTALL_ROOT_STATE:-/nonexistent}" ]] && printf '.' ;;
        "${HOSTLIFT_FAKE_REINSTALL_MANAGED_PATH:-/nonexistent}") [[ -e "${HOSTLIFT_FAKE_REINSTALL_MANAGED_STATE:-/nonexistent}" ]] && printf '.' ;;
      esac
      exit 0
    fi
    if [[ -n "${HOSTLIFT_FAKE_MANIFEST_ROOT:-}" && "${cmd[1]:-}" == "$HOSTLIFT_FAKE_MANIFEST_ROOT" ]]; then
      if [[ " ${cmd[*]} " == *" -printf . "* ]]; then
        printf '..'
        exit 0
      fi
      find_kind=""
      for ((find_idx = 0; find_idx + 1 < ${#cmd[@]}; find_idx++)); do
        if [[ "${cmd[$find_idx]}" == "-type" ]]; then
          find_kind="${cmd[$((find_idx + 1))]}"
          break
        fi
      done
      case "$find_kind" in
        d) printf '%s\n' "$HOSTLIFT_FAKE_MANIFEST_ROOT" ;;
        f)
          printf '%s/app.txt\n' "$HOSTLIFT_FAKE_MANIFEST_ROOT"
          if [[ "${HOSTLIFT_FAKE_MANIFEST_TWO_FILES:-}" == "1" ]]; then
            printf '%s/extra.txt\n' "$HOSTLIFT_FAKE_MANIFEST_ROOT"
          fi
          ;;
        l)
          if [[ -n "${HOSTLIFT_FAKE_MANIFEST_LINK_TARGET:-}" ]]; then
            printf '%s/current\n' "$HOSTLIFT_FAKE_MANIFEST_ROOT"
          fi
          ;;
        p|s|b|c)
          if [[ "${HOSTLIFT_FAKE_MANIFEST_SPECIAL_KIND:-}" == "$find_kind" ]]; then
            printf '%s/special\n' "$HOSTLIFT_FAKE_MANIFEST_ROOT"
          fi
          ;;
      esac
    fi
    ;;
  stat)
    if [[ -n "${HOSTLIFT_FAKE_REINSTALL_ROOT:-}" && "${cmd[2]:-}" == "%s" && "${cmd[4]:-}" == "$HOSTLIFT_FAKE_REINSTALL_ROOT/verified-artifact" ]]; then
      printf '%s\n' "${HOSTLIFT_FAKE_REINSTALL_ARTIFACT_SIZE:-1}"
      exit 0
    fi
    if [[ -n "${HOSTLIFT_FAKE_REINSTALL_ROOT:-}" && "${cmd[2]:-}" == "%Y" ]]; then
      printf '1710000000\n'
      exit 0
    fi
    if [[ -n "${HOSTLIFT_FAKE_PG_ROOT:-}" && "${cmd[2]:-}" == "%s" && "${cmd[3]:-}" == "$HOSTLIFT_FAKE_PG_ROOT/"*.sql ]]; then
      printf '4096\n'
      exit 0
    fi
    if [[ -n "${HOSTLIFT_FAKE_MANIFEST_ROOT:-}" ]]; then
      if [[ "${cmd[2]:-}" == "%s" ]]; then
        for manifest_path in "${cmd[@]:4}"; do
          printf '5\n'
        done
        exit 0
      fi
      if [[ "${cmd[2]:-}" == "%Y" ]]; then
        printf '1710000000\n'
        exit 0
      fi
    fi
    echo "0 regular file"
    ;;
  readlink)
    if [[ -n "${HOSTLIFT_FAKE_MANIFEST_LINK_TARGET:-}" ]]; then
      printf '%s\n' "$HOSTLIFT_FAKE_MANIFEST_LINK_TARGET"
      exit 0
    fi
    exit 1
    ;;
  du)
    printf '5\t%s\n' "${cmd[2]:-${cmd[1]:-/tmp}}"
    ;;
  df)
    if [[ -n "${HOSTLIFT_FAKE_DF_AVAILABLE:-}" ]]; then
      printf 'Filesystem 1B-blocks Used Available Capacity Mounted on\n/dev/fake 1000000 1 %s 1%% /\n' "$HOSTLIFT_FAKE_DF_AVAILABLE"
    elif [[ -n "${HOSTLIFT_FAKE_PG_ROOT:-}" ]]; then
      printf 'Filesystem 1B-blocks Used Available Capacity Mounted on\n/dev/fake 1000000000000 1 999999999999 1%% /\n'
    else
      printf 'Filesystem 1B-blocks Used Available Capacity Mounted on\n/dev/fake 1000000 1 999999 1%% /\n'
    fi
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
if [[ -n "${HOSTLIFT_FAKE_TRANSFER_STATE:-}" ]]; then
  : > "$HOSTLIFT_FAKE_TRANSFER_STATE"
fi
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
if [[ -n "${HOSTLIFT_FAKE_TRANSFER_STATE:-}" ]]; then
  : > "$HOSTLIFT_FAKE_TRANSFER_STATE"
fi
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

postgresql_plan="$tmpdir/postgresql-plan.json"
postgresql_root="/var/lib/hostlift/artifacts/postgresql/0000000000000000000000000000000000000000000000000000000000000000"
cat > "$postgresql_plan" <<'EOF'
{
  "schema_version": "hostlift.plan.v2",
  "source_inventory_hash": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  "target_inventory_hash": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
  "package_manager": "apt",
  "compatibility": {"compatible":true,"same_distro":true,"same_version":true,"same_package_manager":true,"same_arch":true,"reason":"compatible"},
  "actions": [
    {"id":"appdata/postgresql-dump/cluster","module":"appdata","action_type":"postgresql_dump","subject":"/var/lib/hostlift/artifacts/postgresql/0000000000000000000000000000000000000000000000000000000000000000","description":"dump","risk":"critical","requires_confirmation":true,"phase":"quiesce"},
    {"id":"appdata/postgresql-target-baseline/cluster","module":"appdata","action_type":"postgresql_target_baseline","subject":"/var/lib/hostlift/artifacts/postgresql/0000000000000000000000000000000000000000000000000000000000000000","description":"baseline","risk":"critical","requires_confirmation":true,"phase":"quiesce","depends_on":["appdata/postgresql-dump/cluster"]},
    {"id":"appdata/postgresql-transfer/cluster","module":"appdata","action_type":"postgresql_transfer","subject":"/var/lib/hostlift/artifacts/postgresql/0000000000000000000000000000000000000000000000000000000000000000","description":"transfer","risk":"critical","requires_confirmation":true,"phase":"transfer","depends_on":["appdata/postgresql-target-baseline/cluster"]},
    {"id":"appdata/postgresql-restore/cluster","module":"appdata","action_type":"postgresql_restore","subject":"/var/lib/hostlift/artifacts/postgresql/0000000000000000000000000000000000000000000000000000000000000000","description":"restore","risk":"critical","requires_confirmation":true,"phase":"restore","depends_on":["appdata/postgresql-transfer/cluster"]},
    {"id":"appdata/postgresql-verify/cluster","module":"appdata","action_type":"postgresql_verify","subject":"/var/lib/hostlift/artifacts/postgresql/0000000000000000000000000000000000000000000000000000000000000000","description":"verify","risk":"high","requires_confirmation":true,"phase":"verify","depends_on":["appdata/postgresql-restore/cluster"]}
  ],
  "created_at": 124
}
EOF

export HOSTLIFT_FAKE_PG_ROOT="$postgresql_root"
export HOSTLIFT_FAKE_PG_SOURCE_HOST="root@192.0.2.11"
export HOSTLIFT_FAKE_PG_SOURCE_DUMP_STATE="$tmpdir/postgresql-source-dump.state"
export HOSTLIFT_FAKE_PG_TARGET_DUMP_STATE="$tmpdir/postgresql-target-dump.state"
export HOSTLIFT_FAKE_PG_BASELINE_STATE="$tmpdir/postgresql-target-baseline.state"
export HOSTLIFT_FAKE_TRANSFER_STATE="$HOSTLIFT_FAKE_PG_TARGET_DUMP_STATE"
export HOSTLIFT_FAKE_PG_TARGET_DATABASES=1

postgresql_reject_log_line="$(wc -l < "$log" | tr -d ' ')"
if ./zig-out/bin/hostlift apply \
  --plan "$postgresql_plan" \
  --source-host root@192.0.2.11 \
  --host root@192.0.2.10 \
  --identity-file "$identity" \
  --run-state "$tmpdir/postgresql-reject-run.jsonl" \
  --rollback-manifest "$tmpdir/postgresql-reject-rollback.jsonl" \
  --audit-log "$tmpdir/postgresql-reject-audit.jsonl" \
  --approve > "$tmpdir/postgresql-reject.out" 2> "$tmpdir/postgresql-reject.err"; then
  echo "PostgreSQL non-empty target unexpectedly passed preflight" >&2
  exit 1
fi
grep -q "PostgresqlTargetNotEmpty" "$tmpdir/postgresql-reject.err"
tail -n "+$((postgresql_reject_log_line + 1))" "$log" > "$tmpdir/postgresql-reject.log"
if grep -Eq '^scp|\[--\] \[install\]|\[--\] \[sudo\].*\[pg_dumpall\].*\[--file\]' "$tmpdir/postgresql-reject.log"; then
  echo "PostgreSQL rejected preflight performed mutation" >&2
  exit 1
fi
if [[ -e "$HOSTLIFT_FAKE_PG_SOURCE_DUMP_STATE" || -e "$HOSTLIFT_FAKE_PG_TARGET_DUMP_STATE" || -e "$HOSTLIFT_FAKE_PG_BASELINE_STATE" ]]; then
  echo "PostgreSQL rejected preflight created artifacts" >&2
  exit 1
fi
unset HOSTLIFT_FAKE_PG_TARGET_DATABASES

./zig-out/bin/hostlift apply \
  --plan "$postgresql_plan" \
  --source-host root@192.0.2.11 \
  --host root@192.0.2.10 \
  --identity-file "$identity" \
  --run-state "$tmpdir/postgresql-run.jsonl" \
  --rollback-manifest "$tmpdir/postgresql-rollback.jsonl" \
  --audit-log "$tmpdir/postgresql-audit.jsonl" \
  --approve > "$tmpdir/postgresql.out"

grep -q "PostgreSQL dump SHA-256 matched" "$tmpdir/postgresql.out"
grep -q "PostgreSQL database catalog matched" "$tmpdir/postgresql.out"
grep -q "PostgreSQL role catalog matched" "$tmpdir/postgresql.out"
grep -q '"action_id":"appdata/postgresql-verify/cluster","status":"succeeded"' "$tmpdir/postgresql-run.jsonl"
grep -q '"action_type":"postgresql_manual_recovery"' "$tmpdir/postgresql-rollback.jsonl"
grep -q 'target-baseline.sql' "$tmpdir/postgresql-rollback.jsonl"
grep -Eq '"subject":"sha256:[0-9a-f]{64}"' "$tmpdir/postgresql-rollback.jsonl"
./zig-out/bin/hostlift audit verify --log "$tmpdir/postgresql-audit.jsonl" --summary > "$tmpdir/postgresql-audit-verify.out"
grep -q "Valid: true" "$tmpdir/postgresql-audit-verify.out"

if ./zig-out/bin/hostlift rollback \
  --manifest "$tmpdir/postgresql-rollback.jsonl" \
  --host root@192.0.2.10 \
  --audit-log "$tmpdir/postgresql-manual-recovery-audit.jsonl" \
  --identity-file "$identity" \
  --approve > "$tmpdir/postgresql-manual-recovery.out" 2> "$tmpdir/postgresql-manual-recovery.err"; then
  echo "PostgreSQL manual recovery evidence unexpectedly reported automatic rollback" >&2
  exit 1
fi
grep -q "manual PostgreSQL recovery required" "$tmpdir/postgresql-manual-recovery.err"
grep -q "ManualRollbackRequired" "$tmpdir/postgresql-manual-recovery.err"

unset HOSTLIFT_FAKE_PG_ROOT HOSTLIFT_FAKE_PG_SOURCE_HOST HOSTLIFT_FAKE_PG_SOURCE_DUMP_STATE
unset HOSTLIFT_FAKE_PG_TARGET_DUMP_STATE HOSTLIFT_FAKE_PG_BASELINE_STATE HOSTLIFT_FAKE_TRANSFER_STATE

reinstall_plan="$tmpdir/reinstall-plan.json"
reinstall_root="/var/lib/hostlift/artifacts/reinstall/0000000000000000000000000000000000000000000000000000000000000000/tool-v1"
cat > "$reinstall_plan" <<'EOF'
{
  "schema_version": "hostlift.plan.v2",
  "source_inventory_hash": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  "target_inventory_hash": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
  "package_manager": "apt",
  "compatibility": {"compatible":true,"same_distro":true,"same_version":true,"same_package_manager":true,"same_arch":true,"reason":"compatible"},
  "actions": [
    {
      "id":"resources/reinstall-download/tool-v1","module":"resources","action_type":"reinstall_download","subject":"/var/lib/hostlift/artifacts/reinstall/0000000000000000000000000000000000000000000000000000000000000000/tool-v1","description":"download","risk":"high","requires_confirmation":true,"phase":"transfer",
      "reinstall":{"schema_version":"hostlift.reinstall_recipes.v1","recipe_id":"tool-v1","source_manual_action_id":"resources/reinstall//usr/local/bin/tool","kind":"verified_script","source_url":"https://downloads.example.test/tool/install.sh","sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","artifact_size_bytes":1,"target_distro_id":"ubuntu","target_distro_version":"24.04","target_arch":"x86_64","install_argv":["sh","{artifact}","--prefix=/usr/local"],"verify_argv":["test","-x","/usr/local/bin/tool"],"verify_stdout_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","managed_paths":["/usr/local/bin/tool"]}
    },
    {
      "id":"resources/reinstall-execute/tool-v1","module":"resources","action_type":"reinstall_execute","subject":"/var/lib/hostlift/artifacts/reinstall/0000000000000000000000000000000000000000000000000000000000000000/tool-v1","description":"execute","risk":"critical","requires_confirmation":true,"phase":"restore","depends_on":["resources/reinstall-download/tool-v1"],
      "reinstall":{"schema_version":"hostlift.reinstall_recipes.v1","recipe_id":"tool-v1","source_manual_action_id":"resources/reinstall//usr/local/bin/tool","kind":"verified_script","source_url":"https://downloads.example.test/tool/install.sh","sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","artifact_size_bytes":1,"target_distro_id":"ubuntu","target_distro_version":"24.04","target_arch":"x86_64","install_argv":["sh","{artifact}","--prefix=/usr/local"],"verify_argv":["test","-x","/usr/local/bin/tool"],"verify_stdout_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","managed_paths":["/usr/local/bin/tool"]}
    },
    {
      "id":"resources/reinstall-verify/tool-v1","module":"resources","action_type":"reinstall_verify","subject":"/var/lib/hostlift/artifacts/reinstall/0000000000000000000000000000000000000000000000000000000000000000/tool-v1","description":"verify","risk":"high","requires_confirmation":true,"phase":"verify","depends_on":["resources/reinstall-execute/tool-v1"],
      "reinstall":{"schema_version":"hostlift.reinstall_recipes.v1","recipe_id":"tool-v1","source_manual_action_id":"resources/reinstall//usr/local/bin/tool","kind":"verified_script","source_url":"https://downloads.example.test/tool/install.sh","sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","artifact_size_bytes":1,"target_distro_id":"ubuntu","target_distro_version":"24.04","target_arch":"x86_64","install_argv":["sh","{artifact}","--prefix=/usr/local"],"verify_argv":["test","-x","/usr/local/bin/tool"],"verify_stdout_sha256":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","managed_paths":["/usr/local/bin/tool"]}
    }
  ],
  "created_at": 125
}
EOF

export HOSTLIFT_FAKE_REINSTALL_ROOT="$reinstall_root"
export HOSTLIFT_FAKE_REINSTALL_ROOT_STATE="$tmpdir/reinstall-root.state"
export HOSTLIFT_FAKE_REINSTALL_ARTIFACT_STATE="$tmpdir/reinstall-artifact.state"
export HOSTLIFT_FAKE_REINSTALL_MANAGED_PATH="/usr/local/bin/tool"
export HOSTLIFT_FAKE_REINSTALL_MANAGED_STATE="$tmpdir/reinstall-managed.state"
export HOSTLIFT_FAKE_REMOTE_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
export HOSTLIFT_FAKE_REINSTALL_ARTIFACT_SIZE=1
export HOSTLIFT_FAKE_MISSING_COMMAND=sh

reinstall_reject_log_line="$(wc -l < "$log" | tr -d ' ')"
if ./zig-out/bin/hostlift apply \
  --plan "$reinstall_plan" \
  --host root@192.0.2.10 \
  --identity-file "$identity" \
  --run-state "$tmpdir/reinstall-reject-run.jsonl" \
  --rollback-manifest "$tmpdir/reinstall-reject-rollback.jsonl" \
  --audit-log "$tmpdir/reinstall-reject-audit.jsonl" \
  --approve > "$tmpdir/reinstall-reject.out" 2> "$tmpdir/reinstall-reject.err"; then
  echo "verified reinstall missing dependency unexpectedly passed" >&2
  exit 1
fi
tail -n "+$((reinstall_reject_log_line + 1))" "$log" > "$tmpdir/reinstall-reject.log"
if grep -Eq '\[--\] \[(curl|install|sh)\]' "$tmpdir/reinstall-reject.log"; then
  echo "verified reinstall rejected preflight performed mutation" >&2
  exit 1
fi
if [[ -e "$HOSTLIFT_FAKE_REINSTALL_ROOT_STATE" || -e "$HOSTLIFT_FAKE_REINSTALL_ARTIFACT_STATE" || -e "$HOSTLIFT_FAKE_REINSTALL_MANAGED_STATE" ]]; then
  echo "verified reinstall rejected preflight created state" >&2
  exit 1
fi
unset HOSTLIFT_FAKE_MISSING_COMMAND

export HOSTLIFT_FAKE_DF_AVAILABLE=1
if ./zig-out/bin/hostlift apply \
  --plan "$reinstall_plan" \
  --host root@192.0.2.10 \
  --identity-file "$identity" \
  --run-state "$tmpdir/reinstall-capacity-run.jsonl" \
  --rollback-manifest "$tmpdir/reinstall-capacity-rollback.jsonl" \
  --audit-log "$tmpdir/reinstall-capacity-audit.jsonl" \
  --approve > "$tmpdir/reinstall-capacity.out" 2> "$tmpdir/reinstall-capacity.err"; then
  echo "verified reinstall insufficient capacity unexpectedly passed" >&2
  exit 1
fi
grep -q 'ReinstallCapacityInsufficient' "$tmpdir/reinstall-capacity.err"
if [[ -e "$HOSTLIFT_FAKE_REINSTALL_ROOT_STATE" || -e "$HOSTLIFT_FAKE_REINSTALL_ARTIFACT_STATE" || -e "$HOSTLIFT_FAKE_REINSTALL_MANAGED_STATE" ]]; then
  echo "verified reinstall capacity preflight created state" >&2
  exit 1
fi
unset HOSTLIFT_FAKE_DF_AVAILABLE

export HOSTLIFT_FAKE_REINSTALL_INSTALL_FAIL=1
if ./zig-out/bin/hostlift apply \
  --plan "$reinstall_plan" \
  --host root@192.0.2.10 \
  --identity-file "$identity" \
  --run-state "$tmpdir/reinstall-failed-run.jsonl" \
  --rollback-manifest "$tmpdir/reinstall-failed-rollback.jsonl" \
  --audit-log "$tmpdir/reinstall-failed-audit.jsonl" \
  --approve > "$tmpdir/reinstall-failed.out" 2> "$tmpdir/reinstall-failed.err"; then
  echo "verified reinstall failing installer unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'RemoteCommandFailed' "$tmpdir/reinstall-failed.err"
grep -q '"original_path":"/usr/local/bin/tool"' "$tmpdir/reinstall-failed-rollback.jsonl"
grep -q '"original_path":"/var/lib/hostlift/artifacts/reinstall/' "$tmpdir/reinstall-failed-rollback.jsonl"
./zig-out/bin/hostlift rollback \
  --manifest "$tmpdir/reinstall-failed-rollback.jsonl" \
  --host root@192.0.2.10 \
  --audit-log "$tmpdir/reinstall-failed-rollback-audit.jsonl" \
  --identity-file "$identity" \
  --approve > "$tmpdir/reinstall-failed-rollback.out"
if [[ -e "$HOSTLIFT_FAKE_REINSTALL_ROOT_STATE" || -e "$HOSTLIFT_FAKE_REINSTALL_ARTIFACT_STATE" || -e "$HOSTLIFT_FAKE_REINSTALL_MANAGED_STATE" ]]; then
  echo "verified reinstall failed-install rollback left declared paths" >&2
  exit 1
fi
unset HOSTLIFT_FAKE_REINSTALL_INSTALL_FAIL

export HOSTLIFT_FAKE_REMOTE_SHA256="0101010101010101010101010101010101010101010101010101010101010101"
if ./zig-out/bin/hostlift apply \
  --plan "$reinstall_plan" \
  --host root@192.0.2.10 \
  --identity-file "$identity" \
  --run-state "$tmpdir/reinstall-hash-failed-run.jsonl" \
  --rollback-manifest "$tmpdir/reinstall-hash-failed-rollback.jsonl" \
  --audit-log "$tmpdir/reinstall-hash-failed-audit.jsonl" \
  --approve > "$tmpdir/reinstall-hash-failed.out" 2> "$tmpdir/reinstall-hash-failed.err"; then
  echo "verified reinstall mismatched artifact hash unexpectedly succeeded" >&2
  exit 1
fi
grep -q 'ReinstallArtifactChecksumMismatch' "$tmpdir/reinstall-hash-failed.err"
grep -q '"original_path":"/var/lib/hostlift/artifacts/reinstall/' "$tmpdir/reinstall-hash-failed-rollback.jsonl"
./zig-out/bin/hostlift rollback \
  --manifest "$tmpdir/reinstall-hash-failed-rollback.jsonl" \
  --host root@192.0.2.10 \
  --audit-log "$tmpdir/reinstall-hash-failed-rollback-audit.jsonl" \
  --identity-file "$identity" \
  --approve > "$tmpdir/reinstall-hash-failed-rollback.out"
if [[ -e "$HOSTLIFT_FAKE_REINSTALL_ROOT_STATE" || -e "$HOSTLIFT_FAKE_REINSTALL_ARTIFACT_STATE" || -e "$HOSTLIFT_FAKE_REINSTALL_MANAGED_STATE" ]]; then
  echo "verified reinstall hash-failure rollback left declared paths" >&2
  exit 1
fi
export HOSTLIFT_FAKE_REMOTE_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

./zig-out/bin/hostlift apply \
  --plan "$reinstall_plan" \
  --host root@192.0.2.10 \
  --identity-file "$identity" \
  --run-state "$tmpdir/reinstall-run.jsonl" \
  --rollback-manifest "$tmpdir/reinstall-rollback.jsonl" \
  --audit-log "$tmpdir/reinstall-audit.jsonl" \
  --approve > "$tmpdir/reinstall.out"

grep -q "pinned artifact size and SHA-256 matched" "$tmpdir/reinstall.out"
grep -q "all declared managed paths exist" "$tmpdir/reinstall.out"
grep -q "command output SHA-256 matched" "$tmpdir/reinstall.out"
grep -q '"action_id":"resources/reinstall-verify/tool-v1","status":"succeeded"' "$tmpdir/reinstall-run.jsonl"
[[ "$(grep -c '"action_type":"delete_created_path"' "$tmpdir/reinstall-rollback.jsonl")" == "2" ]]
grep -q '"original_path":"/usr/local/bin/tool"' "$tmpdir/reinstall-rollback.jsonl"
grep -q 'verified-artifact' "$log"
grep -q '\[--\] \[sh\] \[/var/lib/hostlift/artifacts/reinstall/.*/verified-artifact\] \[--prefix=/usr/local\]' "$log"
./zig-out/bin/hostlift audit verify --log "$tmpdir/reinstall-audit.jsonl" --summary > "$tmpdir/reinstall-audit-verify.out"
grep -q "Valid: true" "$tmpdir/reinstall-audit-verify.out"

./zig-out/bin/hostlift rollback \
  --manifest "$tmpdir/reinstall-rollback.jsonl" \
  --host root@192.0.2.10 \
  --audit-log "$tmpdir/reinstall-rollback-audit.jsonl" \
  --identity-file "$identity" \
  --approve > "$tmpdir/reinstall-rollback.out"
if [[ -e "$HOSTLIFT_FAKE_REINSTALL_ROOT_STATE" || -e "$HOSTLIFT_FAKE_REINSTALL_ARTIFACT_STATE" || -e "$HOSTLIFT_FAKE_REINSTALL_MANAGED_STATE" ]]; then
  echo "verified reinstall rollback left declared paths" >&2
  exit 1
fi

unset HOSTLIFT_FAKE_REINSTALL_ROOT HOSTLIFT_FAKE_REINSTALL_ROOT_STATE HOSTLIFT_FAKE_REINSTALL_ARTIFACT_STATE
unset HOSTLIFT_FAKE_REINSTALL_ARTIFACT_SIZE
unset HOSTLIFT_FAKE_REINSTALL_MANAGED_PATH HOSTLIFT_FAKE_REINSTALL_MANAGED_STATE HOSTLIFT_FAKE_REMOTE_SHA256

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
  "schema_version": "hostlift.plan.v2",
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
      "requires_confirmation": false,
      "phase": "prepare"
    }
  ],
  "created_at": 123
}
EOF

incompatible_action_plan="$tmpdir/incompatible-action-plan.json"
cat > "$incompatible_action_plan" <<'EOF'
{
  "schema_version": "hostlift.plan.v2",
  "source_inventory_hash": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  "target_inventory_hash": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
  "package_manager": "apt",
  "compatibility": {
    "compatible": false,
    "same_distro": true,
    "same_version": true,
    "same_package_manager": true,
    "same_arch": false,
    "reason": "architecture mismatch"
  },
  "actions": [
    {
      "id": "resources/copy//opt/myapp",
      "module": "resources",
      "action_type": "copy_data_path",
      "subject": "/opt/myapp",
      "description": "Unsafe hand-written cross-architecture install root copy",
      "risk": "high",
      "requires_confirmation": true,
      "recursive": true,
      "phase": "transfer"
    }
  ],
  "created_at": 120
}
EOF

incompatible_log_before="$(wc -l < "$log" | tr -d ' ')"
if ./zig-out/bin/hostlift apply \
  --plan "$incompatible_action_plan" \
  --host root@192.0.2.10 \
  --audit-log "$tmpdir/incompatible-action-audit.jsonl" \
  --run-state "$tmpdir/incompatible-action-run.jsonl" \
  --rollback-manifest "$tmpdir/incompatible-action-rollback.jsonl" \
  --approve > "$tmpdir/incompatible-action.out" 2> "$tmpdir/incompatible-action.err"; then
  echo "incompatible hand-written action unexpectedly passed apply validation" >&2
  exit 1
fi
grep -q "Compatibility errors: 1" "$tmpdir/incompatible-action.out"
grep -q "InvalidMigrationPlan" "$tmpdir/incompatible-action.err"
incompatible_log_after="$(wc -l < "$log" | tr -d ' ')"
if [[ "$incompatible_log_after" != "$incompatible_log_before" ]]; then
  echo "incompatible hand-written action performed remote calls" >&2
  exit 1
fi
if [[ -e "$tmpdir/incompatible-action-audit.jsonl" || \
      -e "$tmpdir/incompatible-action-run.jsonl" || \
      -e "$tmpdir/incompatible-action-rollback.jsonl" ]]; then
  echo "incompatible hand-written action created execution evidence" >&2
  exit 1
fi

preflight_plan="$tmpdir/preflight-plan.json"
cat > "$preflight_plan" <<'EOF'
{
  "schema_version": "hostlift.plan.v2",
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
      "requires_confirmation": false,
      "phase": "prepare"
    },
    {
      "id": "services/enable/nginx.service",
      "module": "services",
      "action_type": "enable_systemd_unit",
      "subject": "nginx.service",
      "description": "Enable nginx.service",
      "risk": "medium",
      "requires_confirmation": false,
      "phase": "configure",
      "depends_on": ["packages/install/nginx"]
    }
  ],
  "created_at": 121
}
EOF

preflight_audit="$tmpdir/preflight-audit.jsonl"
preflight_rollback="$tmpdir/preflight-rollback.jsonl"
preflight_log_start=$(( $(wc -l < "$log") + 1 ))
export HOSTLIFT_FAKE_MISSING_COMMAND=systemctl
if ./zig-out/bin/hostlift apply \
  --plan "$preflight_plan" \
  --host root@192.0.2.10 \
  --audit-log "$preflight_audit" \
  --rollback-manifest "$preflight_rollback" \
  --identity-file "$identity" \
  --approve > "$tmpdir/preflight-apply.out" 2> "$tmpdir/preflight-apply.err"; then
  echo "batch preflight unexpectedly succeeded with missing systemctl" >&2
  exit 1
fi
unset HOSTLIFT_FAKE_MISSING_COMMAND
tail -n +"$preflight_log_start" "$log" > "$tmpdir/preflight-remote.log"
grep -q "RemoteDependencyMissing" "$tmpdir/preflight-apply.err"
grep -q "ssh .*\[command\].*\[-v\].*\[apt-get\]" "$tmpdir/preflight-remote.log"
grep -q "ssh .*\[command\].*\[-v\].*\[systemctl\]" "$tmpdir/preflight-remote.log"
if grep -q "ssh .*\[apt-get\].*\[install\]" "$tmpdir/preflight-remote.log"; then
  echo "batch preflight failure allowed an earlier package mutation" >&2
  exit 1
fi
if grep -Eq '^(scp|rsync)|ssh .*\[(cp|mkdir|chmod|chown|rm)\]' "$tmpdir/preflight-remote.log"; then
  echo "batch preflight failure performed backup or transfer mutation" >&2
  exit 1
fi
if [[ -e "$preflight_audit" || -e "$preflight_rollback" ]]; then
  echo "batch preflight failure created audit or rollback output" >&2
  exit 1
fi

dag_filter_log_start=$(( $(wc -l < "$log") + 1 ))
if ./zig-out/bin/hostlift apply \
  --plan "$preflight_plan" \
  --host root@192.0.2.10 \
  --include-action services/enable/ \
  --audit-log "$tmpdir/dag-filter-audit.jsonl" \
  --run-state "$tmpdir/dag-filter-run.jsonl" \
  --rollback-manifest "$tmpdir/dag-filter-rollback.jsonl" \
  --approve > "$tmpdir/dag-filter.out" 2> "$tmpdir/dag-filter.err"; then
  echo "dependency-incomplete apply filter unexpectedly succeeded" >&2
  exit 1
fi
grep -q "SelectedActionDependencyMissing" "$tmpdir/dag-filter.err"
dag_filter_log_end="$(wc -l < "$log" | tr -d ' ')"
if [[ "$dag_filter_log_end" != "$((dag_filter_log_start - 1))" ]]; then
  echo "dependency-incomplete apply filter performed remote calls" >&2
  exit 1
fi
if [[ -e "$tmpdir/dag-filter-audit.jsonl" || -e "$tmpdir/dag-filter-run.jsonl" || -e "$tmpdir/dag-filter-rollback.jsonl" ]]; then
  echo "dependency-incomplete apply filter created execution evidence" >&2
  exit 1
fi

checkpoint_state="$tmpdir/checkpoint-run.jsonl"
checkpoint_rollback="$tmpdir/checkpoint-rollback.jsonl"
checkpoint_first_audit="$tmpdir/checkpoint-first-audit.jsonl"
checkpoint_first_log_start=$(( $(wc -l < "$log") + 1 ))
export HOSTLIFT_FAKE_FAIL_COMMAND=systemctl
if ./zig-out/bin/hostlift apply \
  --plan "$preflight_plan" \
  --host root@192.0.2.10 \
  --run-state "$checkpoint_state" \
  --rollback-manifest "$checkpoint_rollback" \
  --audit-log "$checkpoint_first_audit" \
  --identity-file "$identity" \
  --approve > "$tmpdir/checkpoint-first.out" 2> "$tmpdir/checkpoint-first.err"; then
  echo "checkpoint fixture unexpectedly completed its first run" >&2
  exit 1
fi
unset HOSTLIFT_FAKE_FAIL_COMMAND
tail -n +"$checkpoint_first_log_start" "$log" > "$tmpdir/checkpoint-first-remote.log"
grep -q "RemoteCommandFailed" "$tmpdir/checkpoint-first.err"
grep -q '"action_id":"packages/install/nginx".*"status":"succeeded"' "$checkpoint_state"
grep -q '"action_id":"services/enable/nginx.service".*"status":"failed"' "$checkpoint_state"
grep -q "ssh .*\[apt-get\].*\[install\].*\[nginx\]" "$tmpdir/checkpoint-first-remote.log"
grep -q "ssh .*\[systemctl\].*\[enable\].*\[nginx.service\]" "$tmpdir/checkpoint-first-remote.log"
checkpoint_manifest_lines_before_resume="$(wc -l < "$checkpoint_rollback" | tr -d ' ')"

checkpoint_resume_log_start=$(( $(wc -l < "$log") + 1 ))
./zig-out/bin/hostlift apply \
  --plan "$preflight_plan" \
  --host root@192.0.2.10 \
  --resume-run "$checkpoint_state" \
  --rollback-manifest "$checkpoint_rollback" \
  --audit-log "$tmpdir/checkpoint-resume-audit.jsonl" \
  --identity-file "$identity" \
  --approve > "$tmpdir/checkpoint-resume.out"
tail -n +"$checkpoint_resume_log_start" "$log" > "$tmpdir/checkpoint-resume-remote.log"
grep -q "packages/install/nginx: skipped (proven succeeded in run state)" "$tmpdir/checkpoint-resume.out"
grep -q "rollback preparation services/enable/nginx.service: reused from run state" "$tmpdir/checkpoint-resume.out"
if grep -q "ssh .*\[apt-get\].*\[install\].*\[nginx\]" "$tmpdir/checkpoint-resume-remote.log"; then
  echo "resumed run repeated a proven successful package action" >&2
  exit 1
fi
grep -q "ssh .*\[systemctl\].*\[enable\].*\[nginx.service\]" "$tmpdir/checkpoint-resume-remote.log"
checkpoint_manifest_lines_after_resume="$(wc -l < "$checkpoint_rollback" | tr -d ' ')"
if [[ "$checkpoint_manifest_lines_after_resume" != "$checkpoint_manifest_lines_before_resume" ]]; then
  echo "resumed run duplicated rollback manifest entries" >&2
  exit 1
fi
grep -q '"action_id":"services/enable/nginx.service".*"status":"succeeded"' "$checkpoint_state"

if ./zig-out/bin/hostlift apply \
  --plan "$preflight_plan" \
  --host root@192.0.2.99 \
  --resume-run "$checkpoint_state" \
  --audit-log "$tmpdir/checkpoint-mismatch-audit.jsonl" \
  --approve > "$tmpdir/checkpoint-mismatch.out" 2> "$tmpdir/checkpoint-mismatch.err"; then
  echo "run state host mismatch unexpectedly succeeded" >&2
  exit 1
fi
grep -q "RunStateHostMismatch" "$tmpdir/checkpoint-mismatch.err"
if [[ -e "$tmpdir/checkpoint-mismatch-audit.jsonl" ]]; then
  echo "run state mismatch created an audit log" >&2
  exit 1
fi

mixed_plan="$tmpdir/mixed-plan.json"
cat > "$mixed_plan" <<'EOF'
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
    },
    {
      "id": "packages/review-held/nginx",
      "module": "packages",
      "action_type": "manual_step",
      "subject": "nginx",
      "description": "Review held package before migration",
      "risk": "high",
      "requires_confirmation": true
    }
  ],
  "created_at": 122
}
EOF

log_lines_before_mixed_apply="$(wc -l < "$log" | tr -d ' ')"
if ./zig-out/bin/hostlift apply \
  --plan "$mixed_plan" \
  --host root@192.0.2.10 \
  --approve > "$tmpdir/mixed-apply.out" 2> "$tmpdir/mixed-apply.err"; then
  echo "mixed manual apply unexpectedly succeeded" >&2
  exit 1
fi
grep -q "UnsupportedApplyAction" "$tmpdir/mixed-apply.err"
log_lines_after_mixed_apply="$(wc -l < "$log" | tr -d ' ')"
if [[ "$log_lines_after_mixed_apply" != "$log_lines_before_mixed_apply" ]]; then
  echo "mixed manual apply performed remote calls" >&2
  exit 1
fi

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
allow_apply_rollback="$tmpdir/allow-apply-rollback.jsonl"
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
  --rollback-manifest "$allow_apply_rollback" \
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
grep -q '"action_id":"packages/install/nginx"' "$allow_apply_rollback"

log_lines_before_manifest_collision="$(wc -l < "$log" | tr -d ' ')"
if ./zig-out/bin/hostlift apply \
  --plan "$deny_plan" \
  --host root@192.0.2.10 \
  --operator ops/fake \
  --approval-ticket OPS-FAKE-APPLY \
  --approval-receipt "$approval_receipt" \
  --policy "$policy" \
  --host-authz "$host_authz" \
  --audit-log "$tmpdir/manifest-collision-audit.jsonl" \
  --rollback-manifest "$allow_apply_rollback" \
  --identity-file "$identity" \
  --approve > "$tmpdir/manifest-collision.out" 2> "$tmpdir/manifest-collision.err"; then
  echo "existing rollback manifest apply unexpectedly succeeded" >&2
  exit 1
fi
grep -q "RollbackManifestAlreadyExists" "$tmpdir/manifest-collision.err"
log_lines_after_manifest_collision="$(wc -l < "$log" | tr -d ' ')"
if [[ "$log_lines_after_manifest_collision" != "$log_lines_before_manifest_collision" ]]; then
  echo "rollback manifest collision performed remote calls" >&2
  exit 1
fi
if [[ -e "$tmpdir/manifest-collision-audit.jsonl" ]]; then
  echo "rollback manifest collision created an audit log" >&2
  exit 1
fi

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

probe_plan="$tmpdir/manual-probe-plan.json"
cat > "$probe_plan" <<'EOF'
{
  "schema_version": "hostlift.plan.v2",
  "source_inventory_hash": [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0],
  "target_inventory_hash": [1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
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
      "id": "services/check-status/worker.service",
      "module": "services",
      "action_type": "manual_step",
      "subject": "worker.service",
      "description": "Check worker status",
      "risk": "high",
      "requires_confirmation": true,
      "phase": "verify",
      "manual_task": {
        "schema_version": "hostlift.manual_task.v2",
        "kind": "health_check",
        "provider": "systemd_status",
        "inputs": [{"name":"subject","value":"worker.service"}],
        "preconditions": [{"kind":"approval","target":"worker.service"}],
        "expected_outputs": [{"name":"health_result"}],
        "verify_probes": [{"kind":"systemd","target":"worker.service"}],
        "rollback_policy": "none",
        "evidence_schema": "hostlift.manual_evidence.v1"
      }
    },
    {
      "id": "docker/check-container/api",
      "module": "docker",
      "action_type": "manual_step",
      "subject": "api",
      "description": "Check API container",
      "risk": "high",
      "requires_confirmation": true,
      "phase": "verify",
      "manual_task": {
        "schema_version": "hostlift.manual_task.v2",
        "kind": "health_check",
        "provider": "container_status",
        "inputs": [
          {"name":"subject","value":"api"},
          {"name":"runtime","value":"docker"},
          {"name":"container","value":"api"}
        ],
        "preconditions": [{"kind":"approval","target":"api"}],
        "expected_outputs": [{"name":"health_result"}],
        "verify_probes": [{"kind":"container","target":"docker:api"}],
        "rollback_policy": "none",
        "evidence_schema": "hostlift.manual_evidence.v1"
      }
    }
  ],
  "created_at": 124
}
EOF

systemd_probe_report="$tmpdir/systemd-probe.json"
./zig-out/bin/hostlift evidence probe \
  --plan "$probe_plan" \
  --action services/check-status/worker.service \
  --host root@192.0.2.10 \
  --output "$systemd_probe_report" \
  --identity-file "$identity" \
  --remote-timeout 3 > "$tmpdir/systemd-probe.stdout"

grep -q '"schema_version": "hostlift.manual_probe_report.v1"' "$systemd_probe_report"
grep -q '"all_required_passed": true' "$systemd_probe_report"
grep -q '"executor": "systemctl_is_active"' "$systemd_probe_report"
grep -q "ssh .*\\[systemctl\\].*\\[is-active\\].*\\[--quiet\\].*\\[worker.service\\]" "$log"
if grep -q "fake systemctl" "$systemd_probe_report"; then
  echo "manual probe report persisted remote stdout" >&2
  exit 1
fi

log_lines_before_probe_collision="$(wc -l < "$log" | tr -d ' ')"
if ./zig-out/bin/hostlift evidence probe \
  --plan "$probe_plan" \
  --action services/check-status/worker.service \
  --host root@192.0.2.10 \
  --output "$systemd_probe_report" \
  --identity-file "$identity" \
  --remote-timeout 3 > "$tmpdir/systemd-probe-collision.out" 2> "$tmpdir/systemd-probe-collision.err"; then
  echo "manual probe unexpectedly overwrote an existing report" >&2
  exit 1
fi
grep -q "OutputFileExists" "$tmpdir/systemd-probe-collision.err"
log_lines_after_probe_collision="$(wc -l < "$log" | tr -d ' ')"
if [[ "$log_lines_before_probe_collision" != "$log_lines_after_probe_collision" ]]; then
  echo "manual probe output collision performed a remote call" >&2
  exit 1
fi

container_probe_report="$tmpdir/container-probe.json"
./zig-out/bin/hostlift evidence probe \
  --plan "$probe_plan" \
  --action docker/check-container/api \
  --host root@192.0.2.10 \
  --output "$container_probe_report" \
  --identity-file "$identity" \
  --remote-timeout 3 > "$tmpdir/container-probe.stdout"
grep -q '"executor": "docker_inspect_state"' "$container_probe_report"
grep -q '"observation_sha256": "' "$container_probe_report"
grep -q "ssh .*\\[docker\\].*\\[inspect\\].*\\[api\\]" "$log"
if grep -q '"State"' "$container_probe_report"; then
  echo "container probe report persisted inspect output" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  probe_plan_sha="$(sha256sum "$probe_plan" | awk '{print $1}')"
  systemd_probe_sha="$(sha256sum "$systemd_probe_report" | awk '{print $1}')"
else
  probe_plan_sha="$(shasum -a 256 "$probe_plan" | awk '{print $1}')"
  systemd_probe_sha="$(shasum -a 256 "$systemd_probe_report" | awk '{print $1}')"
fi
systemd_observed_at="$(sed -n 's/.*"observed_at": \([0-9][0-9]*\).*/\1/p' "$systemd_probe_report" | head -n 1)"
evidence_recorded_at="$(date +%s)"
systemd_evidence="$tmpdir/systemd-evidence.json"
cat > "$systemd_evidence" <<EOF
{
  "schema_version": "hostlift.manual_evidence.v1",
  "plan_sha256": "$probe_plan_sha",
  "action_id": "services/check-status/worker.service",
  "task_kind": "health_check",
  "provider": "systemd_status",
  "status": "succeeded",
  "operator": "ai-agent",
  "recorded_at": $evidence_recorded_at,
  "preconditions": [{"kind":"approval","target":"worker.service","status":"satisfied","observed_at":$systemd_observed_at}],
  "outputs": [{"name":"health_result","status":"produced"}],
  "probes": [{"kind":"systemd","target":"worker.service","status":"passed","observed_at":$systemd_observed_at,"evidence_sha256":"$systemd_probe_sha"}]
}
EOF

./zig-out/bin/hostlift evidence validate-probed \
  --plan "$probe_plan" \
  --evidence "$systemd_evidence" \
  --probe-report "$systemd_probe_report" \
  --host root@192.0.2.10 \
  --summary > "$tmpdir/validate-probed.out"
grep -q "Valid: true" "$tmpdir/validate-probed.out"
grep -q "Trust level: hostlift_remote_read_only" "$tmpdir/validate-probed.out"

if ./zig-out/bin/hostlift evidence validate-probed \
  --plan "$probe_plan" \
  --evidence "$systemd_evidence" \
  --probe-report "$systemd_probe_report" \
  --host root@192.0.2.11 \
  --summary > "$tmpdir/validate-probed-host.out" 2> "$tmpdir/validate-probed-host.err"; then
  echo "probed evidence unexpectedly accepted the wrong host" >&2
  exit 1
fi
grep -q "InvalidProbedManualEvidence" "$tmpdir/validate-probed-host.err"

forged_evidence="$tmpdir/forged-systemd-evidence.json"
sed "s/$systemd_probe_sha/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/" \
  "$systemd_evidence" > "$forged_evidence"
if ./zig-out/bin/hostlift evidence validate-probed \
  --plan "$probe_plan" \
  --evidence "$forged_evidence" \
  --probe-report "$systemd_probe_report" \
  --host root@192.0.2.10 \
  --summary > "$tmpdir/validate-probed-forged.out" 2> "$tmpdir/validate-probed-forged.err"; then
  echo "probed evidence unexpectedly accepted a self-reported probe hash" >&2
  exit 1
fi
grep -q "InvalidProbedManualEvidence" "$tmpdir/validate-probed-forged.err"

recursive_manifest_plan="$tmpdir/recursive-manifest-plan.json"
cat > "$recursive_manifest_plan" <<'EOF'
{
  "schema_version": "hostlift.plan.v2",
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
      "id": "resources/copy//opt/manifest-app",
      "module": "resources",
      "action_type": "copy_data_path",
      "subject": "/opt/manifest-app",
      "description": "Copy an unmanaged application with recursive content verification",
      "risk": "high",
      "requires_confirmation": true,
      "recursive": true,
      "phase": "transfer"
    }
  ],
  "created_at": 125
}
EOF

export HOSTLIFT_FAKE_MANIFEST_ROOT=/opt/manifest-app
export HOSTLIFT_FAKE_MANIFEST_SOURCE_HOST=root@192.0.2.11
export HOSTLIFT_FAKE_MANIFEST_SOURCE_HASH=8ed3f6ad685b959ead7022518e1af76cd816f8e8ec7ccdda1ed4018e8f2223f8
export HOSTLIFT_FAKE_MANIFEST_TARGET_HASH="$HOSTLIFT_FAKE_MANIFEST_SOURCE_HASH"
export HOSTLIFT_FAKE_TRANSFER_STATE="$tmpdir/recursive-manifest-match.transferred"

./zig-out/bin/hostlift apply \
  --plan "$recursive_manifest_plan" \
  --source-host "$HOSTLIFT_FAKE_MANIFEST_SOURCE_HOST" \
  --host root@192.0.2.10 \
  --audit-log "$tmpdir/recursive-manifest-match-audit.jsonl" \
  --rollback-manifest "$tmpdir/recursive-manifest-match-rollback.jsonl" \
  --run-state "$tmpdir/recursive-manifest-match-run.jsonl" \
  --approve > "$tmpdir/recursive-manifest-match.out"
grep -q "content manifest preflight resources/copy//opt/manifest-app" "$tmpdir/recursive-manifest-match.out"
grep -q "content manifest matched entries=1" "$tmpdir/recursive-manifest-match.out"
grep -q '"action_id":"resources/copy//opt/manifest-app".*"status":"succeeded"' "$tmpdir/recursive-manifest-match-run.jsonl"
grep -q '"action_type":"delete_created_path"' "$tmpdir/recursive-manifest-match-rollback.jsonl"
grep -q "ssh .*\[root@192.0.2.11\].*\[find\].*\[/opt/manifest-app\].*\[-type\].*\[f\]" "$log"
grep -q "ssh .*\[root@192.0.2.10\].*\[sha256sum\].*\[--\].*\[/opt/manifest-app/app.txt\]" "$log"

export HOSTLIFT_FAKE_MANIFEST_TARGET_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export HOSTLIFT_FAKE_TRANSFER_STATE="$tmpdir/recursive-manifest-mismatch.transferred"
if ./zig-out/bin/hostlift apply \
  --plan "$recursive_manifest_plan" \
  --source-host "$HOSTLIFT_FAKE_MANIFEST_SOURCE_HOST" \
  --host root@192.0.2.10 \
  --audit-log "$tmpdir/recursive-manifest-mismatch-audit.jsonl" \
  --rollback-manifest "$tmpdir/recursive-manifest-mismatch-rollback.jsonl" \
  --run-state "$tmpdir/recursive-manifest-mismatch-run.jsonl" \
  --approve > "$tmpdir/recursive-manifest-mismatch.out" 2> "$tmpdir/recursive-manifest-mismatch.err"; then
  echo "recursive manifest mismatch unexpectedly succeeded" >&2
  exit 1
fi
grep -q "VerifyManifestMismatch" "$tmpdir/recursive-manifest-mismatch.err"
grep -q '"action_id":"resources/copy//opt/manifest-app".*"status":"failed"' "$tmpdir/recursive-manifest-mismatch-run.jsonl"
if grep -q '"action_id":"resources/copy//opt/manifest-app".*"status":"succeeded"' "$tmpdir/recursive-manifest-mismatch-run.jsonl"; then
  echo "recursive manifest mismatch was recorded as succeeded" >&2
  exit 1
fi
grep -q '"action_type":"delete_created_path"' "$tmpdir/recursive-manifest-mismatch-rollback.jsonl"
grep -q '"result":"failed"' "$tmpdir/recursive-manifest-mismatch-audit.jsonl"

export HOSTLIFT_FAKE_MANIFEST_SPECIAL_KIND=p
export HOSTLIFT_FAKE_TRANSFER_STATE="$tmpdir/recursive-manifest-special.transferred"
special_scp_before="$(grep -c '^scp' "$log" || true)"
if ./zig-out/bin/hostlift apply \
  --plan "$recursive_manifest_plan" \
  --source-host "$HOSTLIFT_FAKE_MANIFEST_SOURCE_HOST" \
  --host root@192.0.2.10 \
  --audit-log "$tmpdir/recursive-manifest-special-audit.jsonl" \
  --rollback-manifest "$tmpdir/recursive-manifest-special-rollback.jsonl" \
  --run-state "$tmpdir/recursive-manifest-special-run.jsonl" \
  --approve > "$tmpdir/recursive-manifest-special.out" 2> "$tmpdir/recursive-manifest-special.err"; then
  echo "recursive manifest special file unexpectedly passed preflight" >&2
  exit 1
fi
grep -q "UnsupportedManifestEntryKind" "$tmpdir/recursive-manifest-special.err"
special_scp_after="$(grep -c '^scp' "$log" || true)"
if [[ "$special_scp_before" != "$special_scp_after" ]]; then
  echo "recursive manifest special file reached transfer" >&2
  exit 1
fi
if [[ -e "$tmpdir/recursive-manifest-special-audit.jsonl" || -e "$tmpdir/recursive-manifest-special-rollback.jsonl" || -e "$tmpdir/recursive-manifest-special-run.jsonl" ]]; then
  echo "recursive manifest special-file preflight created execution evidence" >&2
  exit 1
fi

export HOSTLIFT_FAKE_TRANSFER_STATE="$tmpdir/recursive-manifest-optout.transferred"
./zig-out/bin/hostlift apply \
  --plan "$recursive_manifest_plan" \
  --source-host "$HOSTLIFT_FAKE_MANIFEST_SOURCE_HOST" \
  --host root@192.0.2.10 \
  --no-transfer-manifest-verify \
  --audit-log "$tmpdir/recursive-manifest-optout-audit.jsonl" \
  --rollback-manifest "$tmpdir/recursive-manifest-optout-rollback.jsonl" \
  --run-state "$tmpdir/recursive-manifest-optout-run.jsonl" \
  --approve > "$tmpdir/recursive-manifest-optout.out"
grep -q "verify resources/copy//opt/manifest-app: target exists" "$tmpdir/recursive-manifest-optout.out"
grep -q '"action_id":"resources/copy//opt/manifest-app".*"status":"succeeded"' "$tmpdir/recursive-manifest-optout-run.jsonl"
unset HOSTLIFT_FAKE_MANIFEST_SPECIAL_KIND

export HOSTLIFT_FAKE_MANIFEST_TWO_FILES=1
export HOSTLIFT_FAKE_TRANSFER_STATE="$tmpdir/recursive-manifest-truncated.transferred"
if ./zig-out/bin/hostlift apply \
  --plan "$recursive_manifest_plan" \
  --source-host "$HOSTLIFT_FAKE_MANIFEST_SOURCE_HOST" \
  --host root@192.0.2.10 \
  --transfer-manifest-max-entries 1 \
  --audit-log "$tmpdir/recursive-manifest-truncated-audit.jsonl" \
  --rollback-manifest "$tmpdir/recursive-manifest-truncated-rollback.jsonl" \
  --run-state "$tmpdir/recursive-manifest-truncated-run.jsonl" \
  --approve > "$tmpdir/recursive-manifest-truncated.out" 2> "$tmpdir/recursive-manifest-truncated.err"; then
  echo "truncated recursive manifest unexpectedly passed preflight" >&2
  exit 1
fi
grep -q "ManifestTruncated" "$tmpdir/recursive-manifest-truncated.err"
if [[ -e "$tmpdir/recursive-manifest-truncated-audit.jsonl" || -e "$tmpdir/recursive-manifest-truncated-rollback.jsonl" || -e "$tmpdir/recursive-manifest-truncated-run.jsonl" ]]; then
  echo "truncated recursive manifest preflight created execution evidence" >&2
  exit 1
fi

unset HOSTLIFT_FAKE_MANIFEST_TWO_FILES
unset HOSTLIFT_FAKE_MANIFEST_ROOT
unset HOSTLIFT_FAKE_MANIFEST_SOURCE_HOST
unset HOSTLIFT_FAKE_MANIFEST_SOURCE_HASH
unset HOSTLIFT_FAKE_MANIFEST_TARGET_HASH
unset HOSTLIFT_FAKE_TRANSFER_STATE

echo "fake remote smoke passed"
