# OpenClaw Agent / Skill 平迁教程

本文给出一套针对 `OpenClaw` 的定向迁移方案：把 Ubuntu 上指定的 `agent` 或 `skill` 完整导出，再在另一台机器例如 macOS / MacBook 上导入，并执行校验。

方案遵循 OpenClaw 官方 CLI 约定：

- `openclaw agents` 用于管理隔离 agent，包括 `add`、`bind`、`set-identity`、`list`
- `openclaw skills` 用于发现和检查技能
- `openclaw config get/set` 用于非交互配置读写
- `openclaw backup verify` 体现了官方“归档 + manifest 校验”的思路，本方案沿用同类校验模型做定向迁移

官方文档入口：

- CLI 总览: https://docs.openclaw.ai/cli
- Agents: https://docs.openclaw.ai/cli/agents
- Skills: https://docs.openclaw.ai/cli/skills
- Config: https://docs.openclaw.ai/cli/config
- Backup: https://docs.openclaw.ai/cli/backup

## 1. 迁移边界

### Skill 迁移会带走

- skill 目录本体
- `skills.entries.<skillKey>` 下的配置覆盖
- 归档内的文件级 SHA-256 校验清单

### Agent 迁移会带走

- `~/.openclaw/agents/<agentId>` 整个 agent 状态目录
- 该 agent 对应 workspace
- `memory/<agentId>.sqlite`，如果存在
- `agents.list` 中该 agent 的完整配置项
- `openclaw agents bindings` 返回的路由绑定
- 归档内的文件级 SHA-256 校验清单

导入时脚本会把 `agentDir` 和 `workspace` 从源机器的绝对路径重写到目标机器当前的 OpenClaw state 目录下，例如重写到目标机的 `~/.openclaw/agents/<agentId>/...`。这一步是“平迁”成立的关键。

### 不建议混进这次“定向平迁”的内容

- 全局 channels 登录态
- 全局 credentials
- 和目标 agent 无关的其它插件、cron、设备配对信息

这些内容属于整机迁移，更适合配合官方 `openclaw backup create/verify` 做全量备份。

## 2. 脚本

权威版本以 [scripts/openclaw_migrate.sh](/data/Documents/Obsidian/Personal/scripts/openclaw_migrate.sh) 为准。下面代码块用于文档内联展示；如果你后续又调整了脚本，请以文件里的最新版本为准。

把脚本保存为 [scripts/openclaw_migrate.sh](/data/Documents/Obsidian/Personal/scripts/openclaw_migrate.sh) 并赋执行权限：

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
OPENCLAW_BIN="${OPENCLAW_BIN:-openclaw}"
PROFILE=""
STATE_DIR=""
OUTPUT_DIR="."
FORCE="0"
ARCHIVE=""
TARGET=""
MODE=""
ITEM_TYPE=""
INSTALL_MODE="auto"

usage() {
  cat <<'EOF'
Usage:
  openclaw_migrate.sh export skill <skill-name> [--output-dir DIR] [--profile NAME]
  openclaw_migrate.sh export agent <agent-id> [--output-dir DIR] [--profile NAME]
  openclaw_migrate.sh import <archive.tgz> [--profile NAME] [--state-dir DIR] [--force] [--install-mode auto|managed|workspace]
  openclaw_migrate.sh verify-archive <archive.tgz>

Notes:
  - Default state dir: ~/.openclaw
  - Profile state dir: ~/.openclaw-<profile>
  - `import` auto-detects whether the archive contains a skill or an agent.
EOF
}

err() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Missing required command: $1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

state_dir_for_profile() {
  if [[ -n "$STATE_DIR" ]]; then
    printf '%s\n' "$STATE_DIR"
  elif [[ -n "$PROFILE" ]]; then
    printf '%s\n' "$HOME/.openclaw-$PROFILE"
  else
    printf '%s\n' "$HOME/.openclaw"
  fi
}

openclaw_cmd() {
  if [[ -n "$PROFILE" ]]; then
    "$OPENCLAW_BIN" --profile "$PROFILE" "$@"
  else
    "$OPENCLAW_BIN" "$@"
  fi
}

config_file_path() {
  local out
  out="$(openclaw_cmd config file 2>/dev/null | tail -n 1 || true)"
  if [[ -n "$out" && "$out" = /* ]]; then
    printf '%s\n' "$out"
    return
  fi
  printf '%s/openclaw.json\n' "$(state_dir_for_profile)"
}

ensure_config_file() {
  local config_path
  config_path="$(config_file_path)"
  mkdir -p "$(dirname "$config_path")"
  if [[ ! -f "$config_path" ]]; then
    printf '{}\n' >"$config_path"
  fi
}

copy_path() {
  local src="$1"
  local dst="$2"
  mkdir -p "$(dirname "$dst")"
  tar -C "$(dirname "$src")" -cf - "$(basename "$src")" | tar -C "$(dirname "$dst")" -xf -
}

remove_if_force() {
  local path="$1"
  if [[ -e "$path" ]]; then
    if [[ "$FORCE" != "1" ]]; then
      err "Target already exists: $path (use --force to replace)"
    fi
    rm -rf "$path"
  fi
}

write_checksums() {
  local base_dir="$1"
  local output_file="$2"
  python3 - "$base_dir" "$output_file" <<'PY'
import hashlib
import os
import pathlib
import sys

base = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(sys.argv[2])
rows = []

for path in sorted(base.rglob("*")):
    rel = path.relative_to(base).as_posix()
    if path.is_symlink():
        target = os.readlink(path)
        digest = hashlib.sha256(("SYMLINK:" + target).encode()).hexdigest()
        rows.append((digest, rel, "symlink"))
    elif path.is_file():
        h = hashlib.sha256()
        with path.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                h.update(chunk)
        rows.append((h.hexdigest(), rel, "file"))

with out.open("w", encoding="utf-8") as fh:
    for digest, rel, kind in rows:
        fh.write(f"{digest}  {kind}  {rel}\n")
PY
}

verify_checksums() {
  local base_dir="$1"
  local checksum_file="$2"
  python3 - "$base_dir" "$checksum_file" <<'PY'
import hashlib
import os
import pathlib
import sys

base = pathlib.Path(sys.argv[1]).resolve()
checksum_file = pathlib.Path(sys.argv[2])

def digest_file(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

for raw_line in checksum_file.read_text(encoding="utf-8").splitlines():
    if not raw_line.strip():
        continue
    digest, kind, rel = raw_line.split("  ", 2)
    path = base / rel
    if kind == "file":
        if not path.is_file():
            raise SystemExit(f"missing file: {rel}")
        actual = digest_file(path)
    elif kind == "symlink":
        if not path.is_symlink():
            raise SystemExit(f"missing symlink: {rel}")
        actual = hashlib.sha256(("SYMLINK:" + os.readlink(path)).encode()).hexdigest()
    else:
        raise SystemExit(f"unknown kind: {kind}")
    if actual != digest:
        raise SystemExit(f"checksum mismatch: {rel}")

print("checksum verification passed")
PY
}

extract_config_entry() {
  local config_path="$1"
  local mode="$2"
  local key="$3"
  node - "$config_path" "$mode" "$key" <<'NODE'
const fs = require('fs');
const vm = require('vm');

const [configPath, mode, key] = process.argv.slice(2);
const src = fs.readFileSync(configPath, 'utf8');
const cfg = vm.runInNewContext('(' + src + ')', {}, { timeout: 1000 });

let value = null;
if (mode === 'skill') {
  value = (((cfg || {}).skills || {}).entries || {})[key] ?? null;
} else if (mode === 'agent') {
  const entries = (((cfg || {}).agents || {}).list || []);
  value = entries.find((item) => item && item.id === key) ?? null;
} else {
  throw new Error(`unsupported mode: ${mode}`);
}

process.stdout.write(JSON.stringify(value, null, 2));
NODE
}

json_get() {
  local file="$1"
  local expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding='utf-8'))
expr = sys.argv[2]
value = data
for part in expr.split('.'):
    if not part:
        continue
    value = value[part]
if isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
elif value is None:
    print("")
else:
    print(value)
PY
}

export_skill() {
  local skill_name="$1"
  local state_dir config_path tmp_dir skill_info_json skill_dir skill_key source archive_name archive_path
  state_dir="$(state_dir_for_profile)"
  config_path="$(config_file_path)"
  [[ -f "$config_path" ]] || err "OpenClaw config not found: $config_path"

  skill_info_json="$(mktemp)"
  openclaw_cmd skills info "$skill_name" --json >"$skill_info_json"
  skill_dir="$(json_get "$skill_info_json" "baseDir")"
  skill_key="$(json_get "$skill_info_json" "skillKey")"
  source="$(json_get "$skill_info_json" "source")"
  [[ -d "$skill_dir" ]] || err "Skill directory not found: $skill_dir"

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/payload/skill" "$tmp_dir/meta"
  copy_path "$skill_dir" "$tmp_dir/payload/skill/$skill_name"
  extract_config_entry "$config_path" skill "$skill_key" >"$tmp_dir/meta/skill-entry.json"

  cat >"$tmp_dir/meta/metadata.json" <<EOF
{
  "archiveType": "openclaw-migration",
  "itemType": "skill",
  "name": $(json_escape "$skill_name"),
  "skillKey": $(json_escape "$skill_key"),
  "source": $(json_escape "$source"),
  "exportedAt": $(json_escape "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"),
  "openclawVersion": $(json_escape "$($OPENCLAW_BIN --version | tail -n 1)")
}
EOF

  write_checksums "$tmp_dir/payload" "$tmp_dir/meta/checksums.txt"
  archive_name="openclaw-skill-${skill_name}-$(date -u +%Y%m%dT%H%M%SZ).tgz"
  archive_path="$OUTPUT_DIR/$archive_name"
  mkdir -p "$OUTPUT_DIR"
  tar -C "$tmp_dir" -czf "$archive_path" payload meta
  verify_archive "$archive_path" >/dev/null
  rm -rf "$tmp_dir" "$skill_info_json"
  echo "$archive_path"
}

export_agent() {
  local agent_id="$1"
  local state_dir config_path tmp_dir bindings_json agent_root workspace_path memory_db archive_name archive_path
  state_dir="$(state_dir_for_profile)"
  config_path="$(config_file_path)"
  [[ -f "$config_path" ]] || err "OpenClaw config not found: $config_path"

  tmp_dir="$(mktemp -d)"
  mkdir -p "$tmp_dir/payload" "$tmp_dir/meta"

  extract_config_entry "$config_path" agent "$agent_id" >"$tmp_dir/meta/agent-entry.json"
  if [[ "$(tr -d '[:space:]' <"$tmp_dir/meta/agent-entry.json")" == "null" ]]; then
    err "Agent not found in config: $agent_id"
  fi

  bindings_json="$tmp_dir/meta/bindings.json"
  openclaw_cmd agents bindings --agent "$agent_id" --json >"$bindings_json"

  agent_root="$state_dir/agents/$agent_id"
  [[ -d "$agent_root" ]] || err "Agent state directory not found: $agent_root"
  copy_path "$agent_root" "$tmp_dir/payload/agent-root/$agent_id"

  workspace_path="$(json_get "$tmp_dir/meta/agent-entry.json" "workspace")"
  if [[ -n "$workspace_path" && -d "$workspace_path" ]]; then
    copy_path "$workspace_path" "$tmp_dir/payload/workspace/$agent_id"
  fi

  memory_db="$state_dir/memory/$agent_id.sqlite"
  if [[ -f "$memory_db" ]]; then
    mkdir -p "$tmp_dir/payload/memory"
    cp "$memory_db" "$tmp_dir/payload/memory/$agent_id.sqlite"
  fi

  cat >"$tmp_dir/meta/metadata.json" <<EOF
{
  "archiveType": "openclaw-migration",
  "itemType": "agent",
  "name": $(json_escape "$agent_id"),
  "exportedAt": $(json_escape "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"),
  "openclawVersion": $(json_escape "$($OPENCLAW_BIN --version | tail -n 1)")
}
EOF

  write_checksums "$tmp_dir/payload" "$tmp_dir/meta/checksums.txt"
  archive_name="openclaw-agent-${agent_id}-$(date -u +%Y%m%dT%H%M%SZ).tgz"
  archive_path="$OUTPUT_DIR/$archive_name"
  mkdir -p "$OUTPUT_DIR"
  tar -C "$tmp_dir" -czf "$archive_path" payload meta
  verify_archive "$archive_path" >/dev/null
  rm -rf "$tmp_dir"
  echo "$archive_path"
}

verify_archive() {
  local archive_path="$1"
  local tmp_dir
  [[ -f "$archive_path" ]] || err "Archive not found: $archive_path"
  tmp_dir="$(mktemp -d)"
  tar -C "$tmp_dir" -xzf "$archive_path"
  [[ -f "$tmp_dir/meta/metadata.json" ]] || err "Archive missing meta/metadata.json"
  [[ -f "$tmp_dir/meta/checksums.txt" ]] || err "Archive missing meta/checksums.txt"
  verify_checksums "$tmp_dir/payload" "$tmp_dir/meta/checksums.txt"
  rm -rf "$tmp_dir"
}

merge_agent_entry() {
  local imported_entry_file="$1"
  local merged_file="$2"
  local current_json
  current_json="$(mktemp)"
  if ! openclaw_cmd config get agents.list --json >"$current_json" 2>/dev/null; then
    printf '[]\n' >"$current_json"
  fi
  python3 - "$current_json" "$imported_entry_file" "$merged_file" <<'PY'
import json
import sys

current_path, imported_path, merged_path = sys.argv[1:]
try:
    current = json.load(open(current_path, encoding='utf-8'))
except Exception:
    current = []
imported = json.load(open(imported_path, encoding='utf-8'))

result = []
replaced = False
for item in current:
    if item.get("id") == imported.get("id"):
        result.append(imported)
        replaced = True
    else:
        result.append(item)
if not replaced:
    result.append(imported)

with open(merged_path, "w", encoding="utf-8") as fh:
    json.dump(result, fh, ensure_ascii=False, indent=2)
PY
  rm -f "$current_json"
}

verify_skill_import() {
  local install_dir="$1"
  local archive_dir="$2"
  local skill_name skill_key expected_entry
  skill_name="$(json_get "$archive_dir/meta/metadata.json" "name")"
  skill_key="$(json_get "$archive_dir/meta/metadata.json" "skillKey")"

  verify_checksums "$archive_dir/payload" "$archive_dir/meta/checksums.txt" >/dev/null
  verify_checksums "$(dirname "$install_dir")" <(python3 - "$archive_dir/meta/checksums.txt" "$skill_name" <<'PY'
import sys
src = sys.argv[1]
skill_name = sys.argv[2]
for line in open(src, encoding='utf-8'):
    if line.strip():
        digest, kind, rel = line.rstrip('\n').split('  ', 2)
        if rel.startswith('skill/'):
            rel = rel.replace('skill/' + skill_name + '/', skill_name + '/', 1)
        print(f"{digest}  {kind}  {rel}")
PY
) >/dev/null

  openclaw_cmd skills info "$skill_name" --json >/dev/null
  if [[ "$(tr -d '[:space:]' <"$archive_dir/meta/skill-entry.json")" != "null" ]]; then
    expected_entry="$(cat "$archive_dir/meta/skill-entry.json")"
    openclaw_cmd config get "skills.entries[$(json_escape "$skill_key")]" --json >"$archive_dir/meta/actual-skill-entry.json" || true
    if [[ -s "$archive_dir/meta/actual-skill-entry.json" ]]; then
      python3 - "$archive_dir/meta/skill-entry.json" "$archive_dir/meta/actual-skill-entry.json" <<'PY'
import json
import sys
expected = json.load(open(sys.argv[1], encoding='utf-8'))
actual = json.load(open(sys.argv[2], encoding='utf-8'))
if expected != actual:
    raise SystemExit("skill config mismatch after import")
PY
    fi
  fi
}

verify_agent_import() {
  local state_dir="$1"
  local archive_dir="$2"
  local agent_id target_agent_root target_workspace target_memory
  agent_id="$(json_get "$archive_dir/meta/metadata.json" "name")"
  target_agent_root="$state_dir/agents/$agent_id"
  [[ -d "$target_agent_root" ]] || err "Imported agent directory missing: $target_agent_root"

  verify_checksums "$target_agent_root/.." <(python3 - "$archive_dir/meta/checksums.txt" "$agent_id" <<'PY'
import sys
src = sys.argv[1]
agent_id = sys.argv[2]
for line in open(src, encoding='utf-8'):
    if line.strip():
        digest, kind, rel = line.rstrip('\n').split('  ', 2)
        if rel.startswith('agent-root/'):
            rel = rel.replace('agent-root/' + agent_id + '/', agent_id + '/', 1)
            print(f"{digest}  {kind}  {rel}")
PY
) >/dev/null

  if [[ -d "$archive_dir/payload/workspace/$agent_id" ]]; then
    target_workspace="$(json_get "$archive_dir/meta/agent-entry.json" "workspace")"
    [[ -d "$target_workspace" ]] || err "Imported workspace missing: $target_workspace"
    verify_checksums "$(dirname "$target_workspace")" <(python3 - "$archive_dir/meta/checksums.txt" "$agent_id" <<'PY'
import sys
src = sys.argv[1]
agent_id = sys.argv[2]
for line in open(src, encoding='utf-8'):
    if line.strip():
        digest, kind, rel = line.rstrip('\n').split('  ', 2)
        if rel.startswith('workspace/'):
            rel = rel.replace('workspace/' + agent_id + '/', agent_id + '/', 1)
            print(f"{digest}  {kind}  {rel}")
PY
) >/dev/null
  fi

  if [[ -f "$archive_dir/payload/memory/$agent_id.sqlite" ]]; then
    target_memory="$state_dir/memory/$agent_id.sqlite"
    [[ -f "$target_memory" ]] || err "Imported memory db missing: $target_memory"
    [[ "$(sha256_file "$target_memory")" == "$(sha256_file "$archive_dir/payload/memory/$agent_id.sqlite")" ]] || err "Imported memory db hash mismatch"
  fi

  openclaw_cmd agents list --json >"$archive_dir/meta/agents-after.json"
  python3 - "$archive_dir/meta/agents-after.json" "$agent_id" <<'PY'
import json
import sys
agents = json.load(open(sys.argv[1], encoding='utf-8'))
agent_id = sys.argv[2]
if not any(item.get("id") == agent_id for item in agents):
    raise SystemExit("agent not visible in openclaw agents list")
PY

  openclaw_cmd agents bindings --agent "$agent_id" --json >"$archive_dir/meta/bindings-after.json"
  python3 - "$archive_dir/meta/bindings.json" "$archive_dir/meta/bindings-after.json" <<'PY'
import json
import sys
before = json.load(open(sys.argv[1], encoding='utf-8'))
after = json.load(open(sys.argv[2], encoding='utf-8'))
norm = lambda xs: sorted((x.get("match", {}).get("channel"), x.get("match", {}).get("accountId")) for x in xs)
if norm(before) != norm(after):
    raise SystemExit("agent bindings mismatch after import")
PY
}

import_archive() {
  local archive_path="$1"
  local state_dir tmp_dir item_type name skill_key source install_dir target_workspace merged_agents_json
  [[ -f "$archive_path" ]] || err "Archive not found: $archive_path"
  state_dir="$(state_dir_for_profile)"
  ensure_config_file
  mkdir -p "$state_dir"

  tmp_dir="$(mktemp -d)"
  tar -C "$tmp_dir" -xzf "$archive_path"
  verify_checksums "$tmp_dir/payload" "$tmp_dir/meta/checksums.txt" >/dev/null

  item_type="$(json_get "$tmp_dir/meta/metadata.json" "itemType")"
  name="$(json_get "$tmp_dir/meta/metadata.json" "name")"

  if [[ "$item_type" == "skill" ]]; then
    skill_key="$(json_get "$tmp_dir/meta/metadata.json" "skillKey")"
    source="$(json_get "$tmp_dir/meta/metadata.json" "source")"

    case "$INSTALL_MODE" in
      managed)
        install_dir="$state_dir/skills/$name"
        ;;
      workspace)
        install_dir="$state_dir/workspace/skills/$name"
        ;;
      auto)
        if [[ "$source" == "openclaw-workspace" ]]; then
          install_dir="$state_dir/workspace/skills/$name"
        else
          install_dir="$state_dir/skills/$name"
        fi
        ;;
      *)
        err "Unsupported install mode: $INSTALL_MODE"
        ;;
    esac

    remove_if_force "$install_dir"
    mkdir -p "$(dirname "$install_dir")"
    copy_path "$tmp_dir/payload/skill/$name" "$install_dir"

    if [[ "$(tr -d '[:space:]' <"$tmp_dir/meta/skill-entry.json")" != "null" ]]; then
      openclaw_cmd config set "skills.entries[$(json_escape "$skill_key")]" "$(cat "$tmp_dir/meta/skill-entry.json")" --strict-json >/dev/null
    fi

    verify_skill_import "$install_dir" "$tmp_dir"
  elif [[ "$item_type" == "agent" ]]; then
    local target_agent_root agent_model
    target_agent_root="$state_dir/agents/$name"
    target_workspace="$(json_get "$tmp_dir/meta/agent-entry.json" "workspace")"
    agent_model="$(python3 - "$tmp_dir/meta/agent-entry.json" <<'PY'
import json, sys
entry = json.load(open(sys.argv[1], encoding='utf-8'))
model = entry.get("model")
if isinstance(model, str):
    print(model)
elif isinstance(model, dict) and model.get("primary"):
    print(model["primary"])
else:
    print("")
PY
)"

    remove_if_force "$target_agent_root"
    mkdir -p "$(dirname "$target_agent_root")"
    copy_path "$tmp_dir/payload/agent-root/$name" "$target_agent_root"

    if [[ -d "$tmp_dir/payload/workspace/$name" && -n "$target_workspace" ]]; then
      remove_if_force "$target_workspace"
      mkdir -p "$(dirname "$target_workspace")"
      copy_path "$tmp_dir/payload/workspace/$name" "$target_workspace"
    fi

    if [[ -f "$tmp_dir/payload/memory/$name.sqlite" ]]; then
      mkdir -p "$state_dir/memory"
      cp "$tmp_dir/payload/memory/$name.sqlite" "$state_dir/memory/$name.sqlite"
    fi

    if ! openclaw_cmd agents list --json | python3 - "$name" <<'PY'
import json, sys
agent_id = sys.argv[1]
data = json.load(sys.stdin)
raise SystemExit(0 if any(x.get("id") == agent_id for x in data) else 1)
PY
    then
      if [[ -n "$agent_model" ]]; then
        openclaw_cmd agents add "$name" --non-interactive --workspace "$target_workspace" --agent-dir "$target_agent_root/agent" --model "$agent_model" >/dev/null
      else
        openclaw_cmd agents add "$name" --non-interactive --workspace "$target_workspace" --agent-dir "$target_agent_root/agent" >/dev/null
      fi
    fi

    merged_agents_json="$(mktemp)"
    merge_agent_entry "$tmp_dir/meta/agent-entry.json" "$merged_agents_json"
    openclaw_cmd config set "agents.list" "$(cat "$merged_agents_json")" --strict-json >/dev/null
    rm -f "$merged_agents_json"

    python3 - "$tmp_dir/meta/bindings.json" <<'PY' | while IFS= read -r binding; do
import json
import sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
for item in data:
    match = item.get("match", {})
    channel = match.get("channel")
    account = match.get("accountId")
    if channel:
        print(f"{channel}:{account}" if account else channel)
PY
      [[ -n "$binding" ]] || continue
      openclaw_cmd agents bind --agent "$name" --bind "$binding" >/dev/null || true
    done

    if [[ -f "$target_workspace/IDENTITY.md" ]]; then
      openclaw_cmd agents set-identity --agent "$name" --from-identity "$target_workspace/IDENTITY.md" >/dev/null || true
    fi

    verify_agent_import "$state_dir" "$tmp_dir"
  else
    err "Unsupported archive itemType: $item_type"
  fi

  rm -rf "$tmp_dir"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    export)
      MODE="export"
      shift
      ITEM_TYPE="${1:-}"
      TARGET="${2:-}"
      shift 2 || true
      ;;
    import)
      MODE="import"
      ARCHIVE="${2:-}"
      shift 2 || true
      ;;
    verify-archive)
      MODE="verify-archive"
      ARCHIVE="${2:-}"
      shift 2 || true
      ;;
    --profile)
      PROFILE="${2:-}"
      shift 2
      ;;
    --state-dir)
      STATE_DIR="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --force)
      FORCE="1"
      shift
      ;;
    --install-mode)
      INSTALL_MODE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: $1"
      ;;
  esac
done

need_cmd "$OPENCLAW_BIN"
need_cmd tar
need_cmd node
need_cmd python3

case "$MODE" in
  export)
    [[ -n "$ITEM_TYPE" && -n "$TARGET" ]] || err "export requires: export <skill|agent> <name>"
    case "$ITEM_TYPE" in
      skill) export_skill "$TARGET" ;;
      agent) export_agent "$TARGET" ;;
      *) err "Unsupported export type: $ITEM_TYPE" ;;
    esac
    ;;
  import)
    [[ -n "$ARCHIVE" ]] || err "import requires: import <archive.tgz>"
    import_archive "$ARCHIVE"
    echo "import verification passed"
    ;;
  verify-archive)
    [[ -n "$ARCHIVE" ]] || err "verify-archive requires: verify-archive <archive.tgz>"
    verify_archive "$ARCHIVE"
    ;;
  *)
    usage
    exit 1
    ;;
esac
```

执行权限：

```bash
chmod +x scripts/openclaw_migrate.sh
```

## 3. 使用方法

### 3.1 在 Ubuntu 源机器导出 skill

```bash
./scripts/openclaw_migrate.sh export skill send-email --output-dir ./migration_out
```

你会得到类似文件：

```text
./migration_out/openclaw-skill-send-email-20260316T120000Z.tgz
```

导出后先做一次归档校验：

```bash
./scripts/openclaw_migrate.sh verify-archive ./migration_out/openclaw-skill-send-email-20260316T120000Z.tgz
```

### 3.2 在 Ubuntu 源机器导出 agent

```bash
./scripts/openclaw_migrate.sh export agent oscar-assistant --output-dir ./migration_out
```

这个包会包含：

- `agents/oscar-assistant`
- 对应 workspace
- `memory/oscar-assistant.sqlite`，如果存在
- `agents.list` 中该 agent 的完整配置项
- 路由绑定信息

同样先校验归档：

```bash
./scripts/openclaw_migrate.sh verify-archive ./migration_out/openclaw-agent-oscar-assistant-20260316T120000Z.tgz
```

### 3.3 传到 MacBook

可以用 `scp`、AirDrop、U 盘、Syncthing 任一种：

```bash
scp ./migration_out/openclaw-agent-oscar-assistant-20260316T120000Z.tgz user@macbook:~/Downloads/
```

### 3.4 在 MacBook 导入 skill

```bash
cd /path/to/your/script
./scripts/openclaw_migrate.sh import ~/Downloads/openclaw-skill-send-email-20260316T120000Z.tgz
```

如果原 skill 是 workspace skill，并且你想强制装到受管目录：

```bash
./scripts/openclaw_migrate.sh import ~/Downloads/openclaw-skill-xxx.tgz --install-mode managed
```

### 3.5 在 MacBook 导入 agent

```bash
cd /path/to/your/script
./scripts/openclaw_migrate.sh import ~/Downloads/openclaw-agent-oscar-assistant-20260316T120000Z.tgz
```

如果目标机上已存在同名 agent，需要覆盖：

```bash
./scripts/openclaw_migrate.sh import ~/Downloads/openclaw-agent-oscar-assistant-20260316T120000Z.tgz --force
```

## 4. 验证步骤

### 4.1 skill 导入后的验证

执行导入命令后，脚本会自动做 3 层验证：

- 归档内 checksum 校验
- 导入后目录文件校验
- `openclaw skills info <skill>` 可见性校验

你也可以手工再验一次：

```bash
openclaw skills info send-email --json
openclaw skills list --json | rg '"name": "send-email"'
```

如果这个 skill 依赖配置项，再检查：

```bash
openclaw config get 'skills.entries["send-email"]' --json
```

### 4.2 agent 导入后的验证

导入命令结束前，脚本会自动做：

- agent 目录 checksum 校验
- workspace checksum 校验
- memory sqlite hash 校验
- `openclaw agents list --json` 可见性校验
- `openclaw agents bindings --agent <id> --json` 绑定一致性校验

你也可以手工复验：

```bash
openclaw agents list --json | rg '"id": "oscar-assistant"'
openclaw agents bindings --agent oscar-assistant --json
openclaw config get agents.list --json
```

如果该 agent 使用 workspace 身份文件，还可以额外检查：

```bash
ls ~/.openclaw/agents/oscar-assistant
ls ~/.openclaw/agents/oscar-assistant/agent
ls ~/.openclaw/agents/oscar-assistant/sessions
```

## 5. 推荐的演练方式

先不要直接打到正式环境，先用官方 profile 隔离能力做一次彩排：

```bash
./scripts/openclaw_migrate.sh import ./migration_out/openclaw-skill-send-email-20260316T120000Z.tgz --profile migrate-test
openclaw --profile migrate-test skills info send-email --json
```

agent 也一样：

```bash
./scripts/openclaw_migrate.sh import ./migration_out/openclaw-agent-oscar-assistant-20260316T120000Z.tgz --profile migrate-test
openclaw --profile migrate-test agents list --json
openclaw --profile migrate-test agents bindings --agent oscar-assistant --json
```

官方 `openclaw --profile <name>` 会把状态隔离到 `~/.openclaw-<name>`，很适合做迁移验收。

## 6. 注意事项

### 全局凭据和通道

即使 agent/skill 已迁过去，下面这些通常仍需你在目标机单独确认：

- 渠道登录态
- 设备配对信息
- 第三方 API token 是否在目标机有效
- 插件本体是否也已安装

原因不是脚本做不到，而是这些内容属于整机级别安全资产，不建议混在定向 agent/skill 迁移包里。

### 配置文件解析说明

脚本会读取 `openclaw.json` 中对应条目。因为 OpenClaw 配置文件通常是 JSON5/对象字面量风格，脚本用 Node 的对象字面量解析方式提取目标 `skill` 或 `agent` 配置，然后用官方 `openclaw config set` 写回目标机。这么做的目的，是尽量贴合 OpenClaw 官方的配置读写方式，而不是用 `sed` 生改配置。

## 7. 建议的迁移顺序

如果你的 agent 依赖某些 skill，顺序建议是：

1. 先迁 skill
2. 在目标机验证 skill 可见、配置到位
3. 再迁 agent
4. 最后验证 bindings、workspace、memory

## 8. 已知限制

- 如果某个 agent 依赖目标机本地独有的插件、channel、browser、sandbox、系统二进制，这些外部依赖仍需你在目标机单独准备
- 如果 workspace 路径被你手工改成了非常规目录，脚本会按配置中的原路径落地；因此导入前要确保目标机对该路径有写权限
- 如果你想迁整机，而不是迁单个 agent/skill，建议直接走官方 `openclaw backup create` / `openclaw backup verify`

## 9. 最小命令清单

```bash
# 导出 skill
./scripts/openclaw_migrate.sh export skill send-email --output-dir ./migration_out

# 导出 agent
./scripts/openclaw_migrate.sh export agent oscar-assistant --output-dir ./migration_out

# 验 archive
./scripts/openclaw_migrate.sh verify-archive ./migration_out/openclaw-agent-oscar-assistant-*.tgz

# 在目标机导入
./scripts/openclaw_migrate.sh import ./migration_out/openclaw-agent-oscar-assistant-*.tgz

# 在隔离 profile 验证
openclaw --profile migrate-test agents list --json
openclaw --profile migrate-test skills list --json
```
