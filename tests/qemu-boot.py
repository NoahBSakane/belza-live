#!/usr/bin/env python3
"""ISO を QEMU で起動し、追記された ctl コマンドを実行する。標準ライブラリのみ。"""

import argparse
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time


US_KEYS = {
    ' ': 'spc', '-': 'minus', '=': 'equal', '[': 'bracket_left',
    ']': 'bracket_right', '\\': 'backslash', ';': 'semicolon', "'": 'apostrophe',
    ',': 'comma', '.': 'dot', '/': 'slash', '`': 'grave_accent',
    '!': 'shift-1', '@': 'shift-2', '#': 'shift-3', '$': 'shift-4',
    '%': 'shift-5', '^': 'shift-6', '&': 'shift-7', '*': 'shift-8',
    '(': 'shift-9', ')': 'shift-0', '_': 'shift-minus', '+': 'shift-equal',
    '{': 'shift-bracket_left', '}': 'shift-bracket_right', '|': 'shift-backslash',
    ':': 'shift-semicolon', '"': 'shift-apostrophe', '<': 'shift-comma',
    '>': 'shift-dot', '?': 'shift-slash', '~': 'shift-grave_accent',
}
JP_KEYS = dict(US_KEYS, **{
    '"': 'shift-2', '&': 'shift-6', "'": 'shift-7', '(': 'shift-8',
    ')': 'shift-9', '=': 'shift-minus', '^': 'equal', '~': 'shift-equal',
    '@': 'bracket_left', '`': 'shift-bracket_left', '[': 'bracket_right',
    '{': 'shift-bracket_right', ';': 'semicolon', '+': 'shift-semicolon',
    ':': 'apostrophe', '*': 'shift-apostrophe', ']': 'backslash',
    '}': 'shift-backslash', '\\': 'yen', '|': 'shift-yen', '_': 'shift-ro',
})


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError('正の整数を指定してください')
    return number


def seconds(value):
    number = float(value)
    if not math.isfinite(number) or number < 0:
        raise argparse.ArgumentTypeError('有限の非負の秒数を指定してください')
    return number


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iso', required=True, type=Path, help='起動する ISO')
    parser.add_argument('--arch', choices=('amd64', 'arm64'), default='amd64')
    parser.add_argument('--firmware', choices=('bios', 'uefi'), default='bios')
    parser.add_argument('--mem', type=positive_int, default=2048, help='メモリー (MiB)')
    parser.add_argument('--smp', type=positive_int, default=2, help='仮想 CPU 数')
    parser.add_argument('--prefix', required=True, type=Path, help='出力と ctl の接頭辞')
    parser.add_argument('--timeout', type=seconds, default=3600, help='実行期限 (秒)')
    parser.add_argument('--kbd', choices=('us', 'jp'), default='us', help='ゲストの配列')
    parser.add_argument('--dry-run', action='store_true', help='起動せずコマンドだけ表示')
    args = parser.parse_args()
    if args.arch == 'arm64' and args.firmware != 'uefi':
        parser.error('arm64 では --firmware uefi を指定してください')
    if not args.iso.is_file():
        parser.error(f'ISO がありません: {args.iso}')
    args.iso = args.iso.resolve()
    args.prefix = args.prefix.absolute()
    return args


def firmware_files(args):
    if args.firmware == 'bios':
        return None, None
    # Homebrew の独自 prefix にも対応する。dry-run でも QEMU は起動しない。
    prefix = subprocess.check_output(['brew', '--prefix'], text=True).strip()
    directory = Path(prefix) / 'share/qemu'
    code = directory / ('edk2-x86_64-code.fd' if args.arch == 'amd64'
                        else 'edk2-aarch64-code.fd')
    variables = directory / ('edk2-i386-vars.fd' if args.arch == 'amd64'
                             else 'edk2-arm-vars.fd')
    if not code.is_file():
        raise FileNotFoundError(f'ファームウェアがありません: {code}')
    return code, variables if variables.is_file() else None


def drive_path(path):
    # QEMU の key=value 引数ではカンマを二重にする。
    return str(path).replace(',', ',,')


def build_command(args, monitor, code, variables):
    executable = 'qemu-system-x86_64' if args.arch == 'amd64' else 'qemu-system-aarch64'
    cmd = [executable, '-machine', 'pc' if args.arch == 'amd64' else 'virt',
           '-accel', 'tcg,thread=multi', '-cpu',
           'Westmere,-aes' if args.arch == 'amd64' else 'max',
           '-smp', str(args.smp), '-m', str(args.mem)]
    if code is not None:
        cmd += ['-drive', f'if=pflash,format=raw,readonly=on,file={drive_path(code)}']
        if variables is not None:
            cmd += ['-drive', f'if=pflash,format=raw,file={drive_path(variables)}']
    if args.arch == 'amd64':
        cmd += ['-drive', f'file={drive_path(args.iso)},media=cdrom,readonly=on,if=ide',
                '-vga', 'std', '-usb', '-device', 'usb-kbd']
    else:
        cmd += ['-device', 'virtio-gpu-pci', '-device', 'qemu-xhci',
                '-device', 'usb-kbd', '-device', 'usb-mouse',
                '-device', 'virtio-scsi-pci', '-drive',
                f'if=none,id=cdrom,media=cdrom,readonly=on,file={drive_path(args.iso)}',
                '-device', 'scsi-cd,drive=cdrom']
    cmd += ['-boot', 'd', '-display', 'none', '-monitor',
            f'unix:{monitor},server=on,wait=off', '-net', 'none']
    return cmd


def text_keys(text, layout):
    mapping = JP_KEYS if layout == 'jp' else US_KEYS
    keys = []
    for char in text:
        if char in mapping:
            keys.append(mapping[char])
        elif char.isascii() and char.isalnum():
            keys.append('shift-' + char.lower() if char.isupper() else char)
        else:
            raise ValueError(f'type で送れない文字です: {char!r}')
    return keys


class Monitor:
    def __init__(self, connection, process, deadline):
        self.connection = connection
        self.process = process
        self.deadline = deadline

    def check_time(self):
        if time.monotonic() >= self.deadline:
            raise TimeoutError('実行期限を超えました')

    def pause(self, duration):
        end = time.monotonic() + duration
        while True:
            self.check_time()
            if self.process.poll() is not None:
                raise RuntimeError(f'QEMU が終了しました (exit {self.process.returncode})')
            remaining = end - time.monotonic()
            if remaining <= 0:
                return
            time.sleep(min(remaining, 0.1))

    def response(self):
        data = b''
        end = time.monotonic() + 10
        while not data.endswith(b'(qemu) '):
            self.check_time()
            if time.monotonic() >= end:
                raise TimeoutError('QEMU モニターの応答がありません')
            try:
                part = self.connection.recv(65536)
            except socket.timeout:
                continue
            if not part:
                raise RuntimeError('QEMU モニターが切断されました')
            data += part
        return data.decode('utf-8', errors='replace')

    def send(self, command):
        self.check_time()
        self.connection.sendall((command + '\n').encode())
        result = self.response()
        # HMP はエラーでもプロンプトを返すので、成功として見逃さない。
        if re.search(r'(?im)^(?:error:|unknown command|invalid parameter|Could not|Error )', result):
            raise RuntimeError(f'QEMU モニター: {result.strip()}')
        return result


def log_tail(path):
    if path.exists():
        with path.open('rb') as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - 8192))
            print(stream.read().decode('utf-8', errors='replace'), file=sys.stderr)


def run(args, code, source_variables):
    monitor_path = Path(f'/tmp/qb-{os.getpid()}.mon')
    log_path = Path(f'{args.prefix}.qemu.log')
    ctl_path = Path(f'{args.prefix}.ctl')
    process = None
    connection = None
    temporary = None
    deadline = time.monotonic() + args.timeout
    try:
        args.prefix.parent.mkdir(parents=True, exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix=f'qb-{os.getpid()}-', dir='/private/tmp')
        variables = None
        if source_variables is not None:
            variables = Path(temporary.name) / 'vars.fd'
            shutil.copyfile(source_variables, variables)
        command = build_command(args, monitor_path, code, variables)
        # 既存ソケットを消すと別プロセスを壊しうるので、衝突時は止める。
        if os.path.lexists(monitor_path):
            raise FileExistsError(f'モニターのパスが使用中です: {monitor_path}')
        ctl_path.write_text('', encoding='utf-8')
        with log_path.open('wb') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(0.2)
            monitor = Monitor(connection, process, deadline)
            startup_end = time.monotonic() + 20
            while True:
                monitor.check_time()
                if process.poll() is not None:
                    raise RuntimeError(f'QEMU が起動直後に終了しました (exit {process.returncode})')
                try:
                    connection.connect(str(monitor_path))
                    break
                except (FileNotFoundError, ConnectionRefusedError):
                    if time.monotonic() >= startup_end:
                        raise TimeoutError('QEMU モニターの起動を待てませんでした')
                    time.sleep(0.1)
            monitor.response()
            print(f'ready: {ctl_path}', flush=True)
            with ctl_path.open('rb') as ctl:
                while True:
                    monitor.check_time()
                    if process.poll() is not None:
                        if process.returncode != 0:
                            raise RuntimeError(f'QEMU が異常終了しました (exit {process.returncode})')
                        return 0
                    position = ctl.tell()
                    raw = ctl.readline()
                    if not raw.endswith(b'\n'):
                        ctl.seek(position)
                        monitor.pause(0.1)
                        continue
                    line = raw.decode('utf-8').rstrip('\r\n')
                    op, _, arg = line.partition(' ')
                    if not line or line.startswith('#'):
                        continue
                    if op == 'shot':
                        if not re.fullmatch(r'[A-Za-z0-9_.-]+', arg):
                            raise ValueError('shot の名前は英数字・_・.・- で指定してください')
                        output = Path(f'{args.prefix}-{arg}.png')
                        monitor.send(f'screendump {json.dumps(str(output), ensure_ascii=False)} -f png')
                        if not output.is_file() or output.read_bytes()[:8] != b'\x89PNG\r\n\x1a\n':
                            raise RuntimeError(f'PNG が生成されませんでした: {output}')
                        print(f'shot: {output}', flush=True)
                    elif op == 'type':
                        for key in text_keys(arg, args.kbd):
                            monitor.send(f'sendkey {key} 50')
                            monitor.pause(0.06)
                    elif op == 'key':
                        if not re.fullmatch(r'[A-Za-z0-9_-]+', arg):
                            raise ValueError('key のキー名が不正です')
                        monitor.send(f'sendkey {arg}')
                    elif op == 'wait':
                        monitor.pause(seconds(arg))
                    elif op == 'quit' and not arg:
                        connection.sendall(b'quit\n')
                        process.wait(timeout=max(0.01, min(20, deadline - time.monotonic())))
                        if process.returncode != 0:
                            raise RuntimeError(f'QEMU の終了に失敗しました (exit {process.returncode})')
                        return 0
                    else:
                        raise ValueError(f'未知の ctl コマンド: {line}')
    except (OSError, ValueError, RuntimeError, argparse.ArgumentTypeError,
            subprocess.SubprocessError) as error:
        print(f'エラー: {error}', file=sys.stderr)
        log_tail(log_path)
        return 1
    finally:
        if connection is not None:
            connection.close()
        if process is not None:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            monitor_path.unlink(missing_ok=True)
        if temporary is not None:
            temporary.cleanup()


def main():
    args = parse_args()
    try:
        code, variables = firmware_files(args)
        if args.dry_run:
            planned_variables = Path(f'/tmp/qb-{os.getpid()}.vars.fd') if variables else None
            print(shlex.join(build_command(args, f'/tmp/qb-{os.getpid()}.mon', code,
                                           planned_variables)))
            return 0
        return run(args, code, variables)
    except (OSError, subprocess.SubprocessError) as error:
        print(f'エラー: {error}', file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print('中断しました', file=sys.stderr)
        return 130


def interrupt(*_):
    raise KeyboardInterrupt


if __name__ == '__main__':
    # SIGTERM でも finally を通し、子プロセスと一時ファイルを片付ける。
    signal.signal(signal.SIGTERM, interrupt)
    sys.exit(main())
