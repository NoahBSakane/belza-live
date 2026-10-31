#!/usr/bin/env python3
"""統合 ISO から Server を autoinstall で標的ディスクへ入れる (第1起動)。

手順: 統合 ISO + CIDATA seed + 空 qcow2 で QEMU を起動し、GRUB の Server
通常項目 (0 始まり 6) に bootkit_extra で autoinstall を渡す。設置が終わると
ゲストは poweroff し、QEMU が終了する。標準ライブラリのみ。
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
    parser.add_argument('--timeout', type=float, default=7200)
    parser.add_argument('--extra', default='autoinstall ds=nocloud console=tty0 console=ttyS0,115200')
    args = parser.parse_args()
    for name in ('iso', 'seed', 'disk'):
        if not getattr(args, name).is_file():
            parser.error(f'{name} がありません: {getattr(args, name)}')
    args.iso = args.iso.resolve()
    args.seed = args.seed.resolve()
    args.disk = args.disk.resolve()
    args.prefix = args.prefix.absolute()
    return args


class Monitor:
    def __init__(self, connection, process, deadline):
        self.connection = connection
        self.process = process
        self.deadline = deadline
        self.lock = threading.RLock()

    def check_time(self):
        if time.monotonic() >= self.deadline:
            raise TimeoutError('実行期限を超えました')
        if self.process.poll() is not None:
            raise RuntimeError(f'QEMU が終了しました (exit {self.process.returncode})')

    def response(self):
        data = b''
        end = time.monotonic() + 30
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

    def send(self, command, note, transcript):
        with self.lock:
            self.check_time()
            self.connection.sendall((command + '\n').encode())
            if command == 'quit':
                transcript.append('[hmp] 終了: quit\n')
                return ''
            result = self.response()
            clean = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', result).replace('\r', '')
            transcript.append(f'[hmp] {note}: {command}\n{clean}\n')
            if re.search(r'(?im)^(?:error:|unknown command|invalid parameter|Could not|Error )', result):
                raise RuntimeError(f'QEMU モニター: {result.strip()}')
            return result


def keyboard(monitor, line, transcript, key_delay=0.08):
    keys = {' ': 'spc', '=': 'equal', '-': 'minus', '.': 'dot',
            '/': 'slash', ':': 'shift-semicolon', ',': 'comma',
            '_': 'shift-minus', '@': 'shift-2', "'": 'apostrophe'}
    for char in line:
        key = keys.get(char, char)
        if char.isupper():
            key = 'shift-' + char.lower()
        monitor.send('sendkey ' + key, 'grub 入力', transcript)
        time.sleep(key_delay)
    monitor.send('sendkey ret', 'grub 入力確定', transcript)


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
    transcript = []

    def note(line):
        transcript.append(line + '\n')

    for stale in (monitor_path, serial_path):
        if stale.exists() or Path(str(stale)).is_symlink():
            raise FileExistsError(f'ソケットのパスが使用中です: {stale}')
    process = None
    monitor_conn = None
    monitor = None
    serial_conn = None
    serial_file = None
    variables = prefix.parent / (prefix.name + '.vars.fd')
    deadline = time.monotonic() + args.timeout
    code = Path(subprocess.check_output(['brew', '--prefix'], text=True).strip()) / 'share/qemu/edk2-x86_64-code.fd'
    vars_template = Path(subprocess.check_output(['brew', '--prefix'], text=True).strip()) / 'share/qemu/edk2-i386-vars.fd'

    def drive(path):
        return str(path).replace(',', ',,')

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
        monitor = Monitor(monitor_conn, process, deadline)
        monitor.response()
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
            nonlocal buffer
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
                    tail = buffer[-2000:].decode('utf-8', errors='replace')
                    raise TimeoutError(f'{label}: 待ち切れませんでした。末尾:\n{tail}')
                drain(0.5)

        expect('Try or Install Ubuntu', 600, 'grub メニュー待ち')
        monitor.send('sendkey c', 'grub コンソール', transcript)
        time.sleep(2)
        keyboard(monitor, "set bootkit_extra='" + args.extra + "'", transcript)
        monitor.send('sendkey esc', 'grub メニューへ戻る', transcript)
        time.sleep(2)
        monitor.send(f'screendump {json.dumps(str(prefix) + "-grub.png")} -f png', 'grub 撮影', transcript)
        for _ in range(args.entry):
            monitor.send('sendkey down', 'grub 移動', transcript)
            time.sleep(3)
        monitor.send('sendkey ret', 'grub 決定', transcript)
        time.sleep(10)
        monitor.send(f'screendump {json.dumps(str(prefix) + "-boot.png")} -f png', '起動開始の撮影', transcript)
        # 進行の撮影を 5 分ごとに別スレッドで行う。
        stop = threading.Event()

        def shots():
            index = 0
            while not stop.wait(300):
                index += 1
                try:
                    monitor.send(f'screendump {json.dumps(str(prefix) + f"-progress-{index}.png")} -f png',
                                 f'進行の撮影 {index}', transcript)
                    serial_file.flush()
                    note(f'[serial] 進行 {index}: 受信 {len(buffer)} バイト')
                except (OSError, RuntimeError, TimeoutError):
                    break

        thread = threading.Thread(target=shots, daemon=True)
        thread.start()
        # poweroff による QEMU 終了を待つ。serial の停止も検出する。
        start = time.monotonic()
        last_size = 0
        quiet_since = start
        exit_code = None
        while time.monotonic() < deadline:
            exit_code = process.poll()
            if exit_code is not None:
                note(f'[qemu] 終了 exit={exit_code} 所要 {time.monotonic() - start:.0f} 秒')
                break
            drain(5)
            if len(buffer) != last_size:
                last_size = len(buffer)
                quiet_since = time.monotonic()
            time.sleep(5)
        stop.set()
        thread.join(timeout=5)
        monitor.send(f'screendump {json.dumps(str(prefix) + "-final.png")} -f png', '最終の撮影', transcript)
        if exit_code is None:
            raise TimeoutError('期限内に設置が終わりませんでした')
        if exit_code != 0:
            raise RuntimeError(f'QEMU が異常終了しました (exit {exit_code})')
        note('[判定] 第1起動が poweroff で終了 (autoinstall 完走の候補)')
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
            with transcript_path.open('w', encoding='utf-8') as stream:
                stream.write(''.join(transcript))


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt))
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('中断しました', file=sys.stderr)
        sys.exit(130)
