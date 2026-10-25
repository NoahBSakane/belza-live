#!/usr/bin/env python3
"""公開 Packages 索引から、限定した候補の Depends / Pre-Depends を再帰検査する。"""
import lzma
from pathlib import Path
import re
import sys

ROOTS = {'partclone', 'clonezilla', 'drbl'}
BASE = {'libc6', 'libc-bin', 'libsystemd0', 'libudev1'}
# Debian Policy 5.6.12 の epoch / upstream / revision と非数字・数字の比較。
def revision_compare(left, right):
    def order(char):
        if char == '~':
            return -1
        if not char:
            return 0
        return ord(char) if char.isalpha() else ord(char) + 256

    while left or right:
        while (left and not left[0].isdigit()) or (right and not right[0].isdigit()):
            a = left[0] if left and not left[0].isdigit() else ''
            b = right[0] if right and not right[0].isdigit() else ''
            if order(a) != order(b):
                return (order(a) > order(b)) - (order(a) < order(b))
            left, right = left[len(a):], right[len(b):]
        a = re.match(r'\d*', left)[0]
        b = re.match(r'\d*', right)[0]
        left, right = left[len(a):], right[len(b):]
        a, b = a.lstrip('0'), b.lstrip('0')
        if (len(a), a) != (len(b), b):
            return ((len(a), a) > (len(b), b)) - ((len(a), a) < (len(b), b))
    return 0


def version_compare(left, right):
    def split(value):
        epoch, sep, rest = value.partition(':')
        epoch, value = (int(epoch), rest) if sep else (0, value)
        upstream, sep, revision = value.rpartition('-')
        return epoch, upstream if sep else value, revision if sep else '0'

    a, b = split(left), split(right)
    return ((a[0] > b[0]) - (a[0] < b[0]) or
            revision_compare(a[1], b[1]) or revision_compare(a[2], b[2]))


def satisfies(version, operator, required):
    if not operator:
        return True
    if version is None:
        return False  # 無版の Provides は版付き依存を満たさない。
    result = version_compare(version, required)
    return {'=': result == 0, '>=': result >= 0, '<=': result <= 0,
            '>>': result > 0, '<<': result < 0}[operator]


ATOM = re.compile(r'([a-z0-9][a-z0-9+.-]*)(?::(?:any|native|amd64|arm64))?'
                  r'(?:\s*\((<<|<=|=|>=|>>)\s*([^()\s]+)\))?')


def atom(value):
    match = ATOM.fullmatch(value.strip())
    if not match:
        raise ValueError(f'未対応の依存式: {value}')
    return match.groups()


def read_index(path):
    packages = {}
    with lzma.open(path, 'rt') as stream:
        fields = {}
        key = None
        for line in stream:
            if line == '\n':
                if fields:
                    name = fields['Package']
                    if name not in packages or version_compare(fields['Version'], packages[name]['Version']) > 0:
                        packages[name] = fields
                fields, key = {}, None
            elif line.startswith(' '):
                if key:
                    fields[key] += ' ' + line.strip()
            else:
                key, value = line.rstrip('\n').split(': ', 1)
                fields[key] = value
        if fields:
            packages[fields['Package']] = fields
    return packages


def register_provider(providers, name, fields, remove=False):
    for value in filter(None, fields.get('Provides', '').split(',')):
        virtual, op, version = atom(value)
        if op not in (None, '='):
            raise ValueError(f'未対応の Provides: {value}')
        entries = providers.setdefault(virtual, {})
        if remove:
            entries.pop(name, None)
        else:
            entries[name] = version


def provider_index(candidates):
    providers = {}
    for name, (_, fields) in candidates.items():
        register_provider(providers, name, fields)
    return providers


def find_dependency(candidates, providers, group):
    for alternative in group.split('|'):
        dep, op, version = atom(alternative)
        if dep in candidates and satisfies(candidates[dep][1]['Version'], op, version):
            return dep
        for name, provided_version in providers.get(dep, {}).items():
            if satisfies(provided_version, op, version):
                return name
    return None


def discover(indexes, arch):
    # まずツール 3 つだけを置換し、trixie に足りないものだけを求める。
    candidates = {name: ('trixie', fields) for name, fields in indexes['trixie'].items()}
    candidates.update({name: ('forky', indexes['forky'][name]) for name in ROOTS})
    providers = provider_index(candidates)
    required, visited, pending = set(ROOTS), set(), list(sorted(ROOTS))
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        visited.add(name)
        fields = candidates[name][1]
        for field in ('Pre-Depends', 'Depends'):
            for group in filter(None, fields.get(field, '').split(',')):
                chosen = find_dependency(candidates, providers, group)
                if not chosen:
                    for alternative in group.split('|'):
                        dep, op, version = atom(alternative)
                        extra = indexes['forky'].get(dep)
                        if extra and satisfies(extra['Version'], op, version):
                            if dep in BASE or not dep.startswith('lib'):
                                raise ValueError(f'{arch}: {name} が forky の基盤/非ライブラリ {dep} を要求します')
                            if dep in candidates:
                                register_provider(providers, dep, candidates[dep][1], remove=True)
                            candidates[dep] = ('forky', extra)
                            register_provider(providers, dep, extra)
                            required.add(dep)
                            # 置換で既存の辺が変わる場合も、依存を再走査する。
                            visited.discard(dep)
                            chosen = dep
                            break
                if not chosen:
                    raise ValueError(f'{arch}: {name}: {group.strip()} の追加候補がありません')
                pending.append(chosen)
    return required


def check(cache, whitelist, arch):
    indexes = {suite: read_index(cache / f'{suite}-main-{arch}-Packages.xz')
               for suite in ('trixie', 'forky')}
    for name in whitelist:
        if name not in indexes['forky']:
            raise ValueError(f'{arch}: forky に {name} がありません')
    required = discover(indexes, arch)
    if required != whitelist:
        raise ValueError(f'{arch}: 機械的に求めた forky 対象 {sorted(required)} と限定リストが違います')
    # APT の候補と同様、限定リストは forky、それ以外は trixie の版を使う。
    candidates = {name: ('trixie', fields) for name, fields in indexes['trixie'].items()}
    candidates.update({name: ('forky', indexes['forky'][name]) for name in whitelist})
    providers = provider_index(candidates)
    visited, edges = set(), []
    pending = list(sorted(ROOTS))
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        visited.add(name)
        suite, fields = candidates[name]
        for field in ('Pre-Depends', 'Depends'):
            for group in filter(None, fields.get(field, '').split(',')):
                chosen = find_dependency(candidates, providers, group)
                if not chosen:
                    raise ValueError(f'{arch}: {suite}/{name} の {field}: {group.strip()} を満たせません。'
                                     'forky の許可範囲は自動で広げません')
                edges.append((name, field, group.strip(), chosen))
                pending.append(chosen)
    unused = whitelist - visited
    if unused:
        raise ValueError(f'{arch}: 不要な forky 指定: {sorted(unused)}')
    print(f'PASS: {arch}: 再帰依存 {len(visited)} パッケージ / {len(edges)} 条件、forky={",".join(sorted(whitelist))}')
    for name in sorted(whitelist):
        fields = candidates[name][1]
        print(f'  {name} {fields["Version"]}: {fields.get("Depends", "")}')
    print(f'  trixie libc6={indexes["trixie"]["libc6"]["Version"]}')


def main():
    cache, source = map(Path, sys.argv[1:])
    names = [line.split('#', 1)[0].strip() for line in source.read_text().splitlines()]
    names = list(filter(None, names))
    if len(names) != len(set(names)) or not ROOTS <= set(names):
        raise ValueError('forky 一覧の重複、または必須ツールの欠落')
    if any(not re.fullmatch(r'[a-z0-9][a-z0-9+.-]*', name) for name in names):
        raise ValueError('forky 一覧の名前が不正です')
    if any(name not in ROOTS and not name.startswith('lib') for name in names):
        raise ValueError('forky の追加対象はライブラリだけです')
    if set(names) & BASE:
        raise ValueError('forky の基盤ライブラリは禁止です')
    for arch in ('amd64', 'arm64'):
        check(cache, set(names), arch)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError) as error:
        sys.exit(f'FAIL: {error}')
