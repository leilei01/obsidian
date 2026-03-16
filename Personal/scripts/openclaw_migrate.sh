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

capture_openclaw_json() {
  local output_file="$1"
  shift
  local raw_file
  raw_file="$(mktemp)"
  openclaw_cmd "$@" >"$raw_file"
  python3 - "$raw_file" "$output_file" <<'PY'
import json
import pathlib
import sys

raw_path = pathlib.Path(sys.argv[1])
out_path = pathlib.Path(sys.argv[2])
text = raw_path.read_text(encoding="utf-8")
decoder = json.JSONDecoder()
best = None

for idx, ch in enumerate(text):
    if ch not in "{[":
        continue
    try:
        value, end = decoder.raw_decode(text[idx:])
    except json.JSONDecodeError:
        continue
    payload = text[idx: idx + end].strip()
    best = json.dumps(value, ensure_ascii=False, indent=2)
    break

if best is None:
    raise SystemExit("no JSON payload found in openclaw output")

out_path.write_text(best + "\n", encoding="utf-8")
PY
  rm -f "$raw_file"
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
  capture_openclaw_json "$skill_info_json" skills info "$skill_name" --json
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
  local state_dir config_path tmp_dir config_entry_json bindings_json agent_root workspace_path memory_db archive_name archive_path
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
  capture_openclaw_json "$bindings_json" agents bindings --agent "$agent_id" --json

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
  "sourceStateDir": $(json_escape "$state_dir"),
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
  if ! capture_openclaw_json "$current_json" config get agents.list --json 2>/dev/null; then
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

rewrite_agent_entry_paths() {
  local metadata_file="$1"
  local entry_file="$2"
  local target_state_dir="$3"
  local output_file="$4"
  python3 - "$metadata_file" "$entry_file" "$target_state_dir" "$output_file" <<'PY'
import json
import os
import sys

metadata_file, entry_file, target_state_dir, output_file = sys.argv[1:]
metadata = json.load(open(metadata_file, encoding='utf-8'))
entry = json.load(open(entry_file, encoding='utf-8'))

agent_id = metadata["name"]
source_state_dir = (metadata.get("sourceStateDir") or "").rstrip(os.sep)
default_agent_root = os.path.join(target_state_dir, "agents", agent_id)
default_workspace = os.path.join(default_agent_root, "workspace")

entry["agentDir"] = os.path.join(default_agent_root, "agent")

workspace = entry.get("workspace")
if isinstance(workspace, str) and workspace:
    if source_state_dir and workspace == os.path.join(source_state_dir, "workspace"):
        entry["workspace"] = os.path.join(target_state_dir, "workspace")
    elif source_state_dir and workspace.startswith(source_state_dir + os.sep):
        suffix = workspace[len(source_state_dir) + 1 :]
        entry["workspace"] = os.path.join(target_state_dir, suffix)
    elif os.path.basename(workspace) == "workspace":
        entry["workspace"] = default_workspace
else:
    entry["workspace"] = default_workspace

with open(output_file, "w", encoding="utf-8") as fh:
    json.dump(entry, fh, ensure_ascii=False, indent=2)
PY
}

verify_skill_import() {
  local install_dir="$1"
  local archive_dir="$2"
  local skill_name skill_key expected_entry actual_skill_dir
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

  capture_openclaw_json "$archive_dir/meta/skill-info-after.json" skills info "$skill_name" --json
  if [[ "$(tr -d '[:space:]' <"$archive_dir/meta/skill-entry.json")" != "null" ]]; then
    expected_entry="$(cat "$archive_dir/meta/skill-entry.json")"
    capture_openclaw_json "$archive_dir/meta/actual-skill-entry.json" config get "skills.entries[$(json_escape "$skill_key")]" --json || true
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
  local agent_id target_agent_root target_workspace target_memory current_bindings
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

  capture_openclaw_json "$archive_dir/meta/agents-after.json" agents list --json
  python3 - "$archive_dir/meta/agents-after.json" "$agent_id" <<'PY'
import json
import sys
agents = json.load(open(sys.argv[1], encoding='utf-8'))
agent_id = sys.argv[2]
if not any(item.get("id") == agent_id for item in agents):
    raise SystemExit("agent not visible in openclaw agents list")
PY

  capture_openclaw_json "$archive_dir/meta/bindings-after.json" agents bindings --agent "$agent_id" --json
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
  local state_dir tmp_dir item_type name skill_key source install_dir agent_workspace merged_agents_json model_json
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
    local agent_root target_agent_root target_workspace target_memory agent_model rewritten_entry
    target_agent_root="$state_dir/agents/$name"
    rewritten_entry="$(mktemp)"
    rewrite_agent_entry_paths "$tmp_dir/meta/metadata.json" "$tmp_dir/meta/agent-entry.json" "$state_dir" "$rewritten_entry"
    mv "$rewritten_entry" "$tmp_dir/meta/agent-entry.json"
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

    local agents_list_json
    agents_list_json="$(mktemp)"
    capture_openclaw_json "$agents_list_json" agents list --json
    if ! python3 - "$name" "$agents_list_json" <<'PY'
import json, sys
agent_id = sys.argv[1]
data = json.load(open(sys.argv[2], encoding='utf-8'))
raise SystemExit(0 if any(x.get("id") == agent_id for x in data) else 1)
PY
    then
      if [[ -n "$agent_model" ]]; then
        openclaw_cmd agents add "$name" --non-interactive --workspace "$target_workspace" --agent-dir "$target_agent_root/agent" --model "$agent_model" >/dev/null
      else
        openclaw_cmd agents add "$name" --non-interactive --workspace "$target_workspace" --agent-dir "$target_agent_root/agent" >/dev/null
      fi
    fi
    rm -f "$agents_list_json"

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
      openclaw_cmd agents set-identity --agent "$name" --identity-file "$target_workspace/IDENTITY.md" --from-identity >/dev/null || true
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
