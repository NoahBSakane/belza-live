"""Validate expanded template hierarchy without requiring a bootloader binary."""
from pathlib import Path
import re

base = Path('config/bootloaders')
expected = ['Live (icewm)', 'Other flavors', 'Safe / Survey', 'Start installer',
            'Advanced install options', 'Utilities']


def grub_tree(text):
    root = []
    stack = [root]
    for line in text.splitlines():
        match = re.match(r'\s*(menuentry|submenu) [\'"]([^\'"]+)[\'"]', line)
        if match:
            node = [match[2], []]
            stack[-1].append(node)
            stack.append(node[1])
        elif line.strip() == '}':
            assert len(stack) > 1, 'unbalanced GRUB submenu'
            stack.pop()
    assert len(stack) == 1
    return root


def syslinux_tree(text):
    root = []
    stack = [root]
    current = None
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith('menu begin '):
            current = ['', []]
            stack[-1].append(current)
            stack.append(current[1])
        elif stripped == 'menu end':
            stack.pop()
            current = None
        elif stripped.startswith('label '):
            current = ['', []]
            stack[-1].append(current)
        elif stripped.startswith('menu label '):
            assert current is not None
            current[0] = stripped[len('menu label '):].replace('^', '')
    assert len(stack) == 1
    return root


def check(tree):
    assert [node[0] for node in tree] == expected, tree
    assert [node[0] for node in tree[1][1]] == ['Live (cli)', 'Live (lxqt)']
    safe = [node[0] for node in tree[2][1]]
    assert len(safe) in (3, 6), safe
    assert set(safe[:3]) == {'Live system, safe mode', 'Live system, copy to RAM',
                             'Live system, fail-safe mode'}
    if len(safe) == 6:
        assert safe[3:] == ['Hardware survey: generic, auto',
                            'Hardware survey: Lenovo G560, auto',
                            'Hardware survey: ThinkPad Edge 14 (0578), auto']
    assert [node[0] for node in tree[3][1]] == [
        'Start installer (' + f + ')' for f in ('icewm', 'lxqt', 'cli')]
    for node in tree:
        assert node[0].isascii()


for kind in ('text', 'gui'):
    grub = (base / 'grub-pc/grub.cfg').read_text().replace(
        'source\t/boot/grub/install_start.cfg',
        (base / ('grub-pc/install_start_' + kind + '.cfg')).read_text())
    check(grub_tree(grub))
    installer = (base / ('syslinux_common/install_' + kind + '.cfg')).read_text()
    # Advanced entries are tested elsewhere; expand only root menu includes.
    syslinux = (base / 'syslinux_common/menu.cfg').read_text().replace(
        'include live.cfg', (base / 'syslinux_common/live.cfg.in').read_text()).replace(
        '@OPTIONAL_INSTALLER_INCLUDE@', installer)
    check(syslinux_tree(syslinux))
    for text in ((base / ('grub-pc/install_start_' + kind + '.cfg')).read_text(),
                 installer.split('menu begin install\n')[0]):
        flavors = re.findall(r'bootkit.flavor=(\w+)', text)
        assert flavors == ['icewm', 'lxqt', 'cli'], flavors
        assert text.count('@APPEND_INSTALL@') == 3
        assert text.count('--- quiet') == 3
print('PASS: six root items, submenu membership, three installer flavor arguments')
