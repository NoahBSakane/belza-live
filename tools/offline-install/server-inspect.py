#!/usr/bin/env python3
"""統合 ISO の Server live を起動し、ファイル経由で操作・調査する。

手順: 第1起動と同じ QEMU 構成で起動し、GRUB で autoinstall を渡す。
起動後は `<prefix>.hmp` に書いた行を HMP へ、`<prefix>.cmd` に書いた行を
serial の live shell へ送る。画面は 120 秒ごとに撮影する。
`<prefix>.stop` ができたら QEMU を終了する。標準ライブラリのみ。
"""
import argparse
import json
import re
import shlex
import signal
import socket
import subprocess
import sys
import time
import threading
from pathlib import Path


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--iso', type=Path, required=True)
    parser.add_argument('--seed', type=Path, required=True)
    parser.add_argument('--disk', type=Path, required=True)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--mem', type=int, default=2048)
    parser.add_argument('--smp', type=int, default=2)
    parser.add_argument('--entry', type=int, default=6)
    parser.add_argument('--timeout', type=float, default=5400)
    parser.add_argument('--extra', default='autoinstall ds=nocloud console=tty0 console=ttyS0,115200')
    parser.add_argument('--user', default='ubuntu')
    parser.add_argument('--password', default='')
    args = parser.parse_args()
    for name in ('iso', 'seed', 'disk'):
        if not getattr(args, name).is_file():
            parser.error(f'{name} がありません: {getattr(args, name)}')
    args.iso = args.iso.resolve()
    args.seed = args.seed.resolve()
    args.disk = args.disk.resolve()
    args.prefix = args.prefix.absolute()
    return args


def clean_terminal(value):
    value = re.sub(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', '', value)
    value = re.sub(r'\x1bP.*?\x1b\\', '', value, flags=re.DOTALL)
    value = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', value)
    return value.replace('\r\n', '\n').replace('\r', '\n')


def wait_connect(path, process, deadline, label):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(0.5)
    try:
        end = time.monotonic() + 60
        while True:
            if process.poll() is not None:
                raise RuntimeError(f'QEMU が起動直後に終了しました (exit {process.returncode})')
            if time.monotonic() >= min(end, deadline):
                raise TimeoutError(f'{label} の接続を待てませんでした')
            try:
                sock.connect(str(path))
                return sock
            except (FileNotFoundError, ConnectionRefusedError):
                time.sleep(0.2)
    except Exception:
        sock.close()
        raise


def main():
    args = parse_args()
    prefix = args.prefix
    prefix.parent.mkdir(parents=True, exist_ok=True)
    monitor_path = prefix.parent / (prefix.name + '.mon')
    serial_path = prefix.parent / (prefix.name + '.ser')
    log_path = Path(str(prefix) + '.qemu.log')
    serial_raw = Path(str(prefix) + '.serial.log')
    transcript_path = Path(str(prefix) + '.transcript.txt')
    hmp_path = Path(str(prefix) + '.hmp')
    cmd_path = Path(str(prefix) + '.cmd')
    stop_path = Path(str(prefix) + '.stop')
    for stale in (hmp_path, cmd_path, stop_path):
        try:
            stale.unlink()
        except OSError:
            pass
    transcript = []

    def note(line):
        transcript.append(line + '\n')
        with transcript_path.open('a', encoding='utf-8') as output:
            output.write(line + '\n')

    deadline = time.monotonic() + args.timeout
    code = Path(subprocess.check_output(['brew', '--prefix'], text=True).strip()) / 'share/qemu/edk2-x86_64-code.fd'
    vars_template = Path(subprocess.check_output(['brew', '--prefix'], text=True).strip()) / 'share/qemu/edk2-i386-vars.fd'
    variables = prefix.parent / (prefix.name + '.vars.fd')
    process = None
    monitor_conn = None
    serial_conn = None
    serial_file = None

    def drive(path):
        return str(path).replace(',', ',,')

    def monitor_send(command):
        monitor_conn.sendall((command + '\n').encode())
        if command == 'quit':
            return ''
        data = b''
        end = time.monotonic() + 30
        while not data.endswith(b'(qemu) '):
            if time.monotonic() >= end:
                raise TimeoutError('QEMU モニターの応答がありません')
            try:
                data += monitor_conn.recv(65536)
            except socket.timeout:
                continue
        text = data.decode('utf-8', errors='replace')
        note(f'[hmp] {command}\n{text}')
        return text

    def keyboard(line, key_delay=0.08):
        keys = {' ': 'spc', '=': 'equal', '-': 'minus', '.': 'dot',
                '/': 'slash', ':': 'shift-semicolon', ',': 'comma',
                '_': 'shift-minus', '@': 'shift-2', "'": 'apostrophe'}
        for char in line:
            key = keys.get(char, char)
            if char.isupper():
                key = 'shift-' + char.lower()
            monitor_send('sendkey ' + key)
            time.sleep(key_delay)
        monitor_send('sendkey ret')

    try:
        subprocess.run(['cp', str(vars_template), str(variables)], check=True)
        command = ['qemu-system-x86_64', '-machine', 'q35',
                   '-accel', 'tcg,thread=multi', '-cpu', 'Westmere,-aes',
                   '-smp', str(args.smp), '-m', str(args.mem),
                   '-drive', f'if=pflash,format=raw,readonly=on,file={drive(code)}',
                   '-drive', f'if=pflash,format=raw,file={drive(variables)}',
                   '-drive', f'id=cd0,if=none,media=cdrom,readonly=on,file={drive(args.iso)}',
                   '-device', 'ide-cd,drive=cd0',
                   '-device', 'ahci,id=ahci',
                   '-drive', f'id=cd1,if=none,media=cdrom,readonly=on,file={drive(args.seed)}',
                   '-device', 'ide-cd,drive=cd1,bus=ahci.0',
                   '-drive', f'file={drive(args.disk)},if=virtio,format=qcow2',
                   '-vga', 'std', '-usb', '-device', 'usb-kbd',
                   '-boot', 'd', '-display', 'none',
                   '-monitor', f'unix:{monitor_path},server=on,wait=off',
                   '-serial', f'unix:{serial_path},server=on,wait=off',
                   '-net', 'none']
        note('[qemu] ' + shlex.join(command))
        print(shlex.join(command), flush=True)
        log = open(log_path, 'wb')
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        Path(str(prefix) + '.pid').write_text(str(process.pid) + '\n')
        monitor_conn = wait_connect(monitor_path, process, deadline, 'monitor')
        monitor_conn.settimeout(0.5)
        data = b''
        end = time.monotonic() + 30
        while not data.endswith(b'(qemu) '):
            if time.monotonic() >= end:
                raise TimeoutError('QEMU モニターの応答がありません')
            try:
                data += monitor_conn.recv(65536)
            except socket.timeout:
                continue
        serial_conn = wait_connect(serial_path, process, deadline, 'serial')
        serial_conn.settimeout(0.5)
        serial_file = open(serial_raw, 'wb')
        buffer = b''

        def drain(timeout):
            nonlocal buffer
            end = time.monotonic() + timeout
            while time.monotonic() < end:
                try:
                    part = serial_conn.recv(65536)
                except socket.timeout:
                    continue
                if not part:
                    break
                serial_file.write(part)
                serial_file.flush()
                buffer += part
                if b'\x1b[6n' in part:
                    serial_conn.sendall(b'\x1b[24;80R' * part.count(b'\x1b[6n'))

        def expect(needle, timeout, label):
            mark = needle if isinstance(needle, bytes) else needle.encode()
            end = time.monotonic() + timeout
            while True:
                if mark in buffer:
                    note(f'[serial] {label}: 検出 {needle!r}')
                    return
                if process.poll() is not None:
                    raise RuntimeError(f'{label} の前に QEMU が終了しました')
                if time.monotonic() >= deadline:
                    raise TimeoutError('実行期限を超えました')
                if time.monotonic() >= end:
                    raise TimeoutError(f'{label}: 待ち切れませんでした')
                drain(0.5)

        expect('Try or Install Ubuntu', 600, 'grub メニュー待ち')
        monitor_send('sendkey c')
        time.sleep(2)
        keyboard("set bootkit_extra='" + args.extra + "'")
        monitor_send('sendkey esc')
        time.sleep(2)
        monitor_send(f'screendump {json.dumps(str(prefix) + "-grub.png")} -f png')
        for _ in range(args.entry):
            monitor_send('sendkey down')
            time.sleep(3)
        monitor_send('sendkey ret')
        note('[boot] Server 項目で起動した')
        stop = threading.Event()

        def shots():
            index = 0
            while not stop.wait(120):
                index += 1
                try:
                    monitor_send(f'screendump {json.dumps(str(prefix) + f"-watch-{index}.png")} -f png')
                except (OSError, RuntimeError, TimeoutError):
                    break

        thread = threading.Thread(target=shots, daemon=True)
        thread.start()
        # live shell へのログインを試みる (設置の成否にかかわらず調査用)。
        logged_in = False
        try:
            expect('login:', 1800, 'ログイン待ち')
            serial_conn.sendall((args.user + '\n').encode())
            time.sleep(1)
            try:
                expect('Password:', 20, 'パスワード待ち')
                serial_conn.sendall((args.password + '\n').encode())
                time.sleep(1)
            except TimeoutError:
                note('[serial] パスワード不要で進行')
            expect('$ ', 60, 'プロンプト待ち')
            logged_in = True
        except (RuntimeError, TimeoutError) as error:
            note(f'[serial] 自動ログイン失敗: {error}')
        hmp_offset = 0
        cmd_offset = 0
        serial_count = 0
        while time.monotonic() < deadline:
            if process.poll() is not None:
                note(f'[qemu] 終了 exit={process.returncode}')
                break
            if stop_path.exists():
                note('[op] stop ファイルで終了する')
                break
            if hmp_path.exists():
                lines = hmp_path.read_text(encoding='utf-8').splitlines()
                for line in lines[hmp_offset:]:
                    if line.strip():
                        try:
                            monitor_send(line)
                        except (OSError, RuntimeError, TimeoutError) as error:
                            note(f'[hmp 異常] {error}')
                hmp_offset = len(lines)
            if logged_in and cmd_path.exists():
                lines = cmd_path.read_text(encoding='utf-8').splitlines()
                for line in lines[cmd_offset:]:
                    if line.strip():
                        serial_count += 1
                        marker = f'CMD_{serial_count}_DONE'
                        serial_conn.sendall(f'echo BEGIN_{marker}; {line}; echo "RC=$?"; echo {marker}\n'.encode())
                        serial_file.write(f'[host] {line}\n'.encode())
                        serial_file.flush()
                        end = time.monotonic() + 300
                        while marker.encode() not in buffer:
                            if time.monotonic() >= end:
                                note(f'[serial] 応答待ち切れ: {line}')
                                break
                            drain(0.5)
                        text = clean_terminal(buffer.decode('utf-8', errors='replace'))
                        tail = text[-3000:]
                        note(f'[serial 出力] {line}\n{tail}')
                        buffer = b''
                cmd_offset = len(lines)
            drain(2)
        stop.set()
        thread.join(timeout=5)
        try:
            monitor_send(f'screendump {json.dumps(str(prefix) + "-final.png")} -f png')
        except (OSError, RuntimeError, TimeoutError):
            pass
        try:
            monitor_send('quit')
            process.wait(timeout=30)
        except (OSError, RuntimeError, TimeoutError, subprocess.TimeoutExpired):
            if process.poll() is None:
                process.terminate()
        return 0
    except (OSError, RuntimeError, TimeoutError, ValueError, subprocess.SubprocessError) as error:
        note(f'[異常] {error}')
        print(f'エラー: {error}', file=sys.stderr)
        return 1
    finally:
        try:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        finally:
            for conn in (monitor_conn, serial_conn):
                if conn is not None:
                    try:
                        conn.close()
                    except OSError:
                        pass
            if serial_file is not None:
                try:
                    serial_file.close()
                except OSError:
                    pass
            for stale in (monitor_path, serial_path):
                try:
                    stale.unlink()
                except OSError:
                    pass
            try:
                variables.unlink()
            except OSError:
                pass


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt))
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('中断しました', file=sys.stderr)
        sys.exit(130)
