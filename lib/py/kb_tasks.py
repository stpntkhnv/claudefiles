from datetime import datetime, timezone
from pathlib import Path
import re
import time
from urllib.parse import unquote

import kb_vault as kv
import repo_memory as rm

ADO = re.compile(r'https?://(?:[^/@]+@)?dev\.azure\.com/([^/]+)/([^/]+)/_git/([^/?#]+)/pullrequest/(\d+)', re.I)
VSO = re.compile(r'https?://([^./]+)\.visualstudio\.com/(?:DefaultCollection/)?([^/]+)/_git/([^/?#]+)'
                 r'/pullrequest/(\d+)', re.I)
GITHUB = re.compile(r'https?://github\.com/([^/]+)/([^/]+)/pull/(\d+)', re.I)
DEFAULT_REFS = ('origin/main', 'origin/master', 'origin/development', 'origin/develop')
STALE_DAYS = 30
CLOSED = ('done', 'dropped')


def parse_link(link):
    link = (link or '').strip()
    if link.startswith('branch:'):
        name = link[len('branch:'):].strip()
        return ('branch', None, name) if name else None
    for pattern in (ADO, VSO):
        match = pattern.search(link)
        if match:
            org, project, repo, number = (unquote(group) for group in match.groups())
            return ('ado', rm.canonical_remote(f'azure:{org}/{project}/{repo}'), int(number))
    match = GITHUB.search(link)
    if match:
        owner, repo, number = match.groups()
        return ('github', rm.canonical_remote(f'github.com/{owner}/{repo}'), int(number))
    return None


def identity(path):
    url = rm.git_value(path, 'config', '--get', 'remote.origin.url')
    try:
        return rm.canonical_remote(url) if url else None
    except ValueError:
        return None


def default_ref(path):
    head = rm.git_value(path, 'symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD')
    if head:
        return head
    for ref in DEFAULT_REFS:
        if rm.git_value(path, 'rev-parse', '-q', '--verify', 'refs/remotes/' + ref):
            return ref
    return None


def fetched(path):
    common = rm.git_value(path, 'rev-parse', '--path-format=absolute', '--git-common-dir')
    stamp = Path(common) / 'FETCH_HEAD' if common else None
    if stamp and stamp.is_file():
        return datetime.fromtimestamp(stamp.stat().st_mtime, timezone.utc).date().isoformat()
    return None


def merge_commit(path, ref, kind, number):
    for line in rm.git_value(path, 'log', '--format=%H%x09%s', ref).splitlines():
        sha, _, subject = line.partition('\t')
        if kind == 'ado' and subject.startswith(f'Merged PR {number}:'):
            return sha
        if kind == 'github' and (subject.endswith(f'(#{number})') or
                                 subject.startswith(f'Merge pull request #{number} ')):
            return sha
    return None


def checkouts(vault, rel):
    layer = kv.layer_of(rel)
    if not layer:
        return []
    data = rm.json_read(Path(vault) / layer / '.checkouts.json', {}) or {}
    result = []
    for path in data:
        if not Path(path).is_dir():
            continue
        try:
            project = rm.resolve(vault, path, create=False)
        except (LookupError, ValueError):
            continue
        if project and project['memory'] == layer:
            result.append(path)
    return result


def status(vault, rel, now=None):
    now = time.time() if now is None else now
    meta = kv.meta(kv.read(vault, rel))
    age = int((now - (Path(vault) / rel).stat().st_mtime) // 86400)
    result = dict(status='unconfirmed', sha=None, checkout=None, fetched=None, age_days=age,
                  declared=meta.get('status'), link=meta.get('link'))
    if meta.get('status') in CLOSED:
        result['status'] = 'declared-' + meta['status']
        return result
    try:
        parsed = parse_link(meta.get('link'))
    except ValueError:
        parsed = None
    if not parsed:
        return result
    kind, wanted, value = parsed
    for path in checkouts(vault, rel):
        if kind != 'branch' and identity(path) != wanted:
            continue
        ref = default_ref(path)
        if not ref:
            continue
        result.update(checkout=path, fetched=fetched(path))
        if kind == 'branch':
            if 'origin/' + value in rm.git_value(path, 'branch', '-r', '--merged', ref).split():
                result.update(status='branch-merged', sha=rm.git_value(path, 'rev-parse', ref))
                return result
            continue
        sha = merge_commit(path, ref, kind, value)
        if sha:
            result.update(status='merged', sha=sha)
            return result
    return result


def question(info):
    if info['status'] == 'branch-merged':
        return 'Ветка из ссылки уже влита в ветку по умолчанию. Задача закрыта?'
    if info['status'] == 'unconfirmed' and info['age_days'] > STALE_DAYS:
        return f'Забытая задача? Не менялась {info["age_days"]} дней, мерж не найден.'
    return None


def task_notes(vault, now=None):
    return {rel: status(vault, rel, now) for rel in kv.all_notes(vault)
            if kv.note_type(kv.read(vault, rel)) == 'task'}
