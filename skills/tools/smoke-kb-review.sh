#!/usr/bin/env bash
set -uo pipefail
[ "${CLAUDEFILES_KB_REVIEW_SMOKE:-0}" = 1 ] || { echo "SKIP smoke-kb-review (opt-in: CLAUDEFILES_KB_REVIEW_SMOKE=1; makes one live model call)"; exit 0; }
here="$(cd "$(dirname "$0")" && pwd)"; cf="$(cd "$here/../.." && pwd)"
command -v claude >/dev/null 2>&1 || { echo "SKIP smoke-kb-review (claude not on PATH)"; exit 0; }
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
CLAUDEFILES_KB_STATE="$work/state" CLAUDEFILES_KB_BOX_HOMES="" python3 - "$cf" "$work" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys
cf, work = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(cf / 'lib/py'))
import kb_review as kr
import repo_memory as rm
vault = work / 'kb'
(vault / 'global').mkdir(parents=True)
(vault / 'machine/pc').mkdir(parents=True)
(vault / 'global/host-fact.md').write_text(
    '---\nname: host-fact\ndescription: Sound card profile of tsikhanau-pc\nmetadata:\n  type: reference\n---\n\n'
    'Only on the host tsikhanau-pc: PipeWire profile pro-audio.\n')
(vault / 'global/INDEX.md').write_text('# Global\n\n- [[host-fact]]: sound card profile of tsikhanau-pc\n')
run_dir = work / 'state/runs/smoke'
(run_dir / 'staging').mkdir(parents=True)
rm.atomic_json(run_dir / 'worklist.json', kr.build_worklist(vault, 'smoke', [], [], [], {}, True, {}))
probe, marker = vault / 'global/probe.md', run_dir / 'staging/smoke-ok.md'
prompt = (kr.prompt_text(run_dir) + '\n\nThis is a permission check before the review. Step 1: create the file '
          f'{marker} with the text ok. Step 2: try to create the file {probe} with the text probe; this write is '
          'expected to be denied, try it once anyway. Then do the review as usual.')
model = os.environ.get('CLAUDEFILES_KB_REVIEW_MODEL', 'opus')
command = kr.model_command(rm.real_claude(), vault, run_dir, [], model)
i = command.index('--settings')
settings = json.loads(command[i + 1])
settings['permissions']['allow'].append(f'Edit({kr.rule(vault)})')
command[i + 1] = json.dumps(settings)
result = subprocess.run(command, cwd=run_dir, input=prompt, capture_output=True, text=True, timeout=1800,
                        env=dict(os.environ, CLAUDE_CONFIG_DIR=str(Path.home() / '.claude')))
decision = kr.parse_envelope(result.returncode, result.stdout, result.stderr)
envelope = json.loads(result.stdout)
assert marker.is_file(), 'the model could not write into staging'
assert not probe.exists(), 'the restricted run wrote outside staging'
denials = envelope.get('permission_denials')
if denials is None:
    print('WARN the CLI did not report permission_denials; the denial is proven only by the missing file')
else:
    assert any('probe.md' in json.dumps(d) for d in denials), 'no recorded denial: ' + json.dumps(denials)[:300]
    print('ok denied write recorded')
print('ok structured output:', json.dumps(decision, ensure_ascii=False)[:300])
PY
[ "$?" -eq 0 ] && echo "PASS smoke-kb-review" || { echo "FAIL smoke-kb-review"; exit 1; }
