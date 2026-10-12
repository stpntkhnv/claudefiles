#!/usr/bin/env python3
"""Install an idempotent PATH block without depending on a separate dotfiles repository."""
import os
from pathlib import Path
import tempfile

START = '# >>> claudefiles launchers >>>'
END = '# <<< claudefiles launchers <<<'
BLOCK = '''# >>> claudefiles launchers >>>
if [ -x "$HOME/.local/share/claudefiles-runtime/bin/claude" ]; then
    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) PATH="$HOME/.local/bin:$PATH" ;;
    esac
    case "$PATH" in
        "$HOME/.local/share/claudefiles-runtime/bin"|"$HOME/.local/share/claudefiles-runtime/bin:"*) ;;
        *) PATH="$HOME/.local/share/claudefiles-runtime/bin:$PATH" ;;
    esac
    export PATH
fi
# <<< claudefiles launchers <<<
'''


def install(home):
    home = Path(home)
    files = [home / '.bashrc', home / '.profile']
    files += [home / name for name in ('.bash_profile', '.bash_login', '.zshrc', '.zprofile')
              if (home / name).exists()]
    if Path(os.environ.get('SHELL', '')).name == 'zsh' and home / '.zshrc' not in files:
        files.append(home / '.zshrc')
    plans = {}
    for file in files:
        # Follow an existing shell-rc symlink rather than replacing the link itself.
        file = file.resolve()
        original = file.read_text() if file.exists() else ''
        if original.count(START) != original.count(END) or original.count(START) > 1:
            raise ValueError(f'incomplete claudefiles PATH block in {file}')
        if START in original:
            start = original.index(START)
            end = original.index(END) + len(END)
            if end < start:
                raise ValueError(f'invalid claudefiles PATH block in {file}')
            if original[end:end + 1] == '\n':
                end += 1
            updated = original[:start] + BLOCK + original[end:]
        else:
            updated = original + ('\n' if original and not original.endswith('\n\n') else '') + BLOCK
        if original != updated:
            plans[file] = updated
    for file, content in plans.items():
        file.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix='.claudefiles-path-', dir=file.parent)
        try:
            if file.exists():
                os.fchmod(fd, file.stat().st_mode & 0o777)
            with os.fdopen(fd, 'w') as stream:
                stream.write(content)
            os.replace(tmp, file)
        finally:
            if os.path.exists(tmp):
                os.unlink(tmp)


if __name__ == '__main__':
    install(Path.home())
