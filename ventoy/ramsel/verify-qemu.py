#!/usr/bin/env python3
"""試作 ISO / 公式 ISO を QEMU で起動し、RAM 選択複写を検証する。標準ライブラリのみ。

uefi-grub: OVMF で ISO を起動し、grub 項目を番号で選ぶ (試作 ISO 用)。
bios-direct: SeaBIOS + -kernel/-initrd/-append で起動する (公式 ISO の比較・対照用)。
どちらも serial (unix socket) でログイン・操作し、HMP で取り外し・撮影する。

使い方の例:
  python3 -I ventoy/ramsel/verify-qemu.py --mode uefi-grub --iso build/trial.iso \\
      --mem 4096 --entry 2 --prefix build/evidence/T1/run --timeout 3600 --detach
"""
import argparse
import json
import os
import re
import select
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
import threading
from pathlib import Path


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError('正の整数を指定してください')
    return number


def seconds(value):
    number = float(value)
    if number <= 0:
        raise argparse.ArgumentTypeError('正の秒数を指定してください')
    return number


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--transport', choices=('unix', 'pipe'), default='unix')
    parser.add_argument('--extra-args', default='console=tty0 console=ttyS0,115200')
    parser.add_argument('--server-shell', action='store_true')
    parser.add_argument('--desktop', choices=('gnome', 'lxqt'))
    parser.add_argument('--gui-wait', type=seconds, default=30, help='GUI プロセス検出後の描画待ち秒数')
    parser.add_argument('--root-shell', action='store_true')
    parser.add_argument('--mode', choices=('uefi-grub', 'bios-direct'), required=True)
    parser.add_argument('--iso', type=Path, required=True)
    parser.add_argument('--mem', type=positive_int, required=True, help='MiB')
    parser.add_argument('--smp', type=positive_int, default=4)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--timeout', type=seconds, default=3600)
    parser.add_argument('--entry', type=int, default=0, help='grub 項目 (0 始まり)')
    parser.add_argument('--kernel', type=Path, default=None)
    parser.add_argument('--initrd', type=Path, default=None)
    parser.add_argument('--append', default='')
    parser.add_argument('--expect-os', default=None)
    parser.add_argument('--user', default='ubuntu')
    parser.add_argument('--password', default='')
    parser.add_argument('--expect-detach-failure', action='store_true')
    parser.add_argument('--machine', choices=('pc', 'q35'), default='q35')
    parser.add_argument('--detach', action='store_true', help='ISO を取り外して操作する')
    parser.add_argument('--expect-panic', action='store_true')
    parser.add_argument('--vars-template', type=Path, default=None)
    args = parser.parse_args()
    if not args.iso.is_file():
        parser.error(f'ISO がありません: {args.iso}')
    if args.mode == 'bios-direct' and (args.kernel is None or args.initrd is None):
        parser.error('bios-direct には --kernel と --initrd が要ります')
    if args.entry < 0:
        parser.error('--entry は 0 以上を指定してください')
    args.iso = args.iso.resolve()
    args.prefix = args.prefix.absolute()
    return args


def firmware_code():
    prefix = subprocess.check_output(['brew', '--prefix'], text=True).strip()
    code = Path(prefix) / 'share/qemu/edk2-x86_64-code.fd'
    if not code.is_file():
        raise FileNotFoundError(f'ファームウェアがありません: {code}')
    return code


def vars_template(args):
    if args.vars_template is not None:
        return args.vars_template
    prefix = subprocess.check_output(['brew', '--prefix'], text=True).strip()
    path = Path(prefix) / 'share/qemu/edk2-i386-vars.fd'
    if not path.is_file():
        raise FileNotFoundError(f'vars がありません: {path}')
    return path


def drive_path(path):
    return str(path).replace(',', ',,')


def clean_terminal(value):
    # Bash 5.3 の OSC 3008 は最初の出力行の前に改行なしで付く。
    value = re.sub(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', '', value)
    value = re.sub(r'\x1bP.*?\x1b\\', '', value, flags=re.DOTALL)
    value = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', value)
    return value.replace('\r\n', '\n').replace('\r', '\n')


class PipeConnection:
    """サンドボックスが UNIX ソケットを禁止する場合の名前付きパイプ。"""
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer

    def recv(self, count):
        if not select.select([self.reader], [], [], 0.5)[0]:
            raise socket.timeout()
        return os.read(self.reader, count)

    def sendall(self, data):
        while data:
            written = os.write(self.writer, data)
            data = data[written:]

    def close(self):
        os.close(self.reader)
        if self.reader != self.writer:
            os.close(self.writer)


def keyboard(monitor, line, transcript):
    keys = {' ': 'spc', '=': 'equal', '-': 'minus', '.': 'dot',
            '/': 'slash', ':': 'shift-semicolon', ',': 'comma',
            '_': 'shift-minus', '@': 'shift-2', "'": 'apostrophe'}
    for char in line:
        key = keys.get(char, char)
        if char.isupper():
            key = 'shift-' + char.lower()
        monitor.send('sendkey ' + key, 'grub 入力', transcript)
        time.sleep(0.08)
    monitor.send('sendkey ret', 'grub 入力確定', transcript)


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
            return self._send(command, note, transcript)

    def _send(self, command, note, transcript):
        self.check_time()
        self.connection.sendall((command + '\n').encode())
        if command == 'quit':
            transcript.append('[hmp] 終了: quit\n')
            return ''
        result = self.response()
        clean = re.sub(r'\x1b\[[0-9;]*[A-Za-z]', '', result).replace('\r', '')
        clean = re.sub(r'^.*(screendump|sendkey|eject|info|quit) ', r'\1 ', clean,
                       flags=re.MULTILINE)
        transcript.append(f'[hmp] {note}: {command}\n{clean}')
        if re.search(r'(?im)^(?:error:|unknown command|invalid parameter|Could not|Error )', result):
            raise RuntimeError(f'QEMU モニター: {result.strip()}')
        return result


class Serial:
    def __init__(self, connection, process, deadline, raw_path, transcript):
        self.connection = connection
        self.process = process
        self.deadline = deadline
        self.buffer = b''
        self.raw = open(raw_path, 'wb')
        self.transcript = transcript
        self.stopped = threading.Event()
        self.reader = threading.Thread(target=self.read_loop, daemon=True)
        self.reader.start()

    def read_loop(self):
        while not self.stopped.is_set():
            try:
                part = self.connection.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not part:
                break
            self.raw.write(part)
            self.raw.flush()
            self.buffer += part
            # subiquity が端末サイズを問い合わせる。端末エミュレータ相当の応答。
            if b'\x1b[6n' in part:
                self.connection.sendall(b'\x1b[24;80R' * part.count(b'\x1b[6n'))

    def close(self):
        self.stopped.set()
        self.reader.join(timeout=2)
        try:
            self.raw.close()
        except OSError:
            pass

    def check_time(self):
        if time.monotonic() >= self.deadline:
            raise TimeoutError('実行期限を超えました')
        if self.process.poll() is not None:
            raise RuntimeError(f'QEMU が終了しました (exit {self.process.returncode})')

    def expect(self, markers, timeout, label):
        """markers のいずれかが出るまで待つ。見つかった文字列を返す。"""
        if isinstance(markers, (bytes, str)):
            markers = [markers]
        needles = [m if isinstance(m, bytes) else m.encode() for m in markers]
        end = time.monotonic() + timeout
        while True:
            for needle in needles:
                if needle in self.buffer:
                    text = self.buffer.decode('utf-8', errors='replace')
                    self.transcript.append(f'[serial] {label}: 検出 {needle!r}\n')
                    return needle.decode('utf-8', errors='replace')
            self.check_time()
            if time.monotonic() >= end:
                tail = self.buffer[-2000:].decode('utf-8', errors='replace')
                raise TimeoutError(f'{label}: 待ち切れませんでした。末尾:\n{tail}')
            time.sleep(0.05)

    def sendline(self, line, label):
        self.check_time()
        data = (line + '\n').encode()
        self.connection.sendall(data)
        self.raw.write(b'[host] ' + data)
        self.raw.flush()
        self.transcript.append(f'[host] {label}: {line}\n')
        time.sleep(0.5)

    def run(self, command, marker, timeout, label):
        self.buffer = b''
        self.sendline(command, label)
        marker_text = marker.decode() if isinstance(marker, bytes) else marker
        end = time.monotonic() + timeout
        while '\n' + marker_text + '\n' not in '\n' + clean_terminal(self.buffer.decode('utf-8', errors='replace')):
            self.check_time()
            if time.monotonic() >= end:
                raise TimeoutError(label + ': 完了行を取得できない: ' + self.buffer[-2000:].decode('utf-8', errors='replace'))
            time.sleep(0.05)
        self.transcript.append(f'[serial] {label}: 完了行 {marker_text}\n')
        text = self.buffer.decode('utf-8', errors='replace')
        # 応答の取り出し: 直近の marker までを残し、それ以前を切り捨てる。
        return clean_terminal(text)


def build_command(args, monitor_path, serial_path, code, variables):
    cmd = ['qemu-system-x86_64', '-machine', args.machine,
           '-accel', 'tcg,thread=multi', '-cpu', 'Westmere,-aes',
           '-smp', str(args.smp), '-m', str(args.mem)]
    if args.mode == 'uefi-grub':
        cmd += ['-drive', f'if=pflash,format=raw,readonly=on,file={drive_path(code)}',
                '-drive', f'if=pflash,format=raw,file={drive_path(variables)}']
    else:
        cmd += ['-kernel', str(args.kernel), '-initrd', str(args.initrd),
                '-append', args.append]
    cmd += ['-drive', f'id=cd0,if=none,media=cdrom,readonly=on,file={drive_path(args.iso)}',
            '-device', 'ide-cd,drive=cd0',
            '-vga', 'std', '-usb', '-device', 'usb-kbd',
            '-boot', 'd', '-display', 'none',
            '-monitor', ('stdio' if args.transport == 'pipe' else f'unix:{monitor_path},server=on,wait=off'),
            '-serial', (f'pipe:{serial_path}' if args.transport == 'pipe' else f'unix:{serial_path},server=on,wait=off'),
            '-net', 'none']
    return cmd


MEASURE_COMMANDS = [
    ('id; cat /proc/cmdline; systemctl --no-pager list-jobs; echo ID_DONE', 'ID_DONE'),
    ('df -B1; du -sb /cdrom/casper; echo DF_DONE', 'DF_DONE'),
    ('ls -la /cdrom /cdrom/casper 2>&1 | head -40; echo LS_DONE', 'LS_DONE'),
    ('head -5 /proc/meminfo; echo MEM_DONE', 'MEM_DONE'),
    ('cat /proc/mounts; echo MOUNTS_DONE', 'MOUNTS_DONE'),
    ('findmnt -n -o SOURCE,TARGET,FSTYPE; echo FINDMNT_DONE', 'FINDMNT_DONE'),
    ('losetup -a; echo LOS_DONE', 'LOS_DONE'),
    ("find /cdrom/casper -maxdepth 1 -type f -printf '%f %s\\n'; echo FILES_DONE", 'FILES_DONE'),
]

POST_DETACH_COMMANDS = [
    ("sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches; status=0; count=0; for dev in $(losetup -ln -O NAME,BACK-FILE | awk \"/common.*[.]squashfs$/ {print \\$1}\"); do count=$((count + 1)); echo READ_DEVICE=$dev; timeout 300 dd if=$dev of=/dev/null bs=4M || status=1; done; test $count -gt 0 || status=1; echo READ_LAYER_COUNT=$count; echo MEDIA_READ_RC=$status'; echo WALK_DONE", 'WALK_DONE'),
    ('python3 -c "print(\'PY_OK\')"; echo PY_DONE', 'PY_DONE'),
    ('sudo -n apt-get check; echo APT_RC=$?; echo APT_DONE', 'APT_DONE'),
    ('dmesg | tail -35; cat /proc/mounts; losetup -a; echo AFTER_DONE', 'AFTER_DONE'),
]



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
    class Transcript(list):
        def append(self, item):
            super().append(item)
            with transcript_path.open('a', encoding='utf-8') as output:
                output.write(item)
    transcript = Transcript()
    for stale in (monitor_path, serial_path):
        if os.path.lexists(stale):
            raise FileExistsError(f'ソケットのパスが使用中です: {stale}')
    process = None
    monitor_conn = None
    monitor = None
    serial_conn = None
    serial = None
    variables = None
    shots_stop = threading.Event()
    shots_thread = None
    control_thread = None
    deadline = time.monotonic() + args.timeout
    try:
        code = firmware_code() if args.mode == 'uefi-grub' else None
        if args.mode == 'uefi-grub':
            variables = prefix.parent / (prefix.name + '.vars.fd')
            shutil.copyfile(vars_template(args), variables)
        command = build_command(args, monitor_path, serial_path, code, variables)
        print(shlex.join(command), flush=True)
        with log_path.open('wb') as log:
            if args.transport == 'pipe':
                for suffix in ('.in', '.out'):
                    os.mkfifo(str(serial_path) + suffix)
                # O_RDWR で open の相互待ちを避ける。通信は各 FIFO の片方向だけ。
                serial_reader = os.open(str(serial_path) + '.out', os.O_RDWR | os.O_NONBLOCK)
                serial_writer = os.open(str(serial_path) + '.in', os.O_RDWR)
                process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log)
                monitor_conn = PipeConnection(os.dup(process.stdout.fileno()), os.dup(process.stdin.fileno()))
                serial_conn = PipeConnection(serial_reader, serial_writer)
            else:
                process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
                monitor_conn = wait_connect(monitor_path, process, deadline, 'monitor')
            monitor = Monitor(monitor_conn, process, deadline)
            monitor.response()
            if serial_conn is None:
                serial_conn = wait_connect(serial_path, process, deadline, 'serial')
            serial = Serial(serial_conn, process, deadline, serial_raw, transcript)
            Path(str(prefix) + '.pid').write_text(str(process.pid) + '\n')
            def progress_shots():
                while not shots_stop.wait(120):
                    try:
                        monitor.send(f'screendump {json.dumps(str(prefix) + "-progress.png")} -f png', '進行の撮影', transcript)
                    except (OSError, RuntimeError, TimeoutError):
                        break
            shots_thread = threading.Thread(target=progress_shots, daemon=True)
            shots_thread.start()
            # 同じロックで HMP を直列化し、起動中の画面操作・追加撮影も可能にする。
            control_path = Path(str(prefix) + '.hmp')
            def control_commands():
                offset = 0
                while not shots_stop.wait(0.5):
                    if not control_path.exists():
                        continue
                    lines = control_path.read_text().splitlines()
                    for line in lines[offset:]:
                        if line.strip():
                            try:
                                monitor.send(line, '追加の画面操作', transcript)
                            except (OSError, RuntimeError, TimeoutError) as error:
                                transcript.append(f'[control 異常] {error}\n')
                                return
                    offset = len(lines)
            control_thread = threading.Thread(target=control_commands, daemon=True)
            control_thread.start()
            if args.mode == 'uefi-grub':
                serial.expect('Try or Install Ubuntu', 600, 'grub メニュー待ち')
                monitor.send('sendkey c', 'grub コンソール', transcript)
                time.sleep(2)
                keyboard(monitor, "set bootkit_extra='" + args.extra_args + "'", transcript)
                monitor.send('sendkey esc', 'grub メニューへ戻る', transcript)
                time.sleep(2)
                monitor.send(f'screendump {json.dumps(str(prefix) + "-grub.png")} -f png', 'grub 撮影', transcript)
                for _ in range(args.entry):
                    monitor.send('sendkey down', 'grub 移動', transcript)
                    time.sleep(3)
                monitor.send('sendkey ret', 'grub 決定', transcript)
                time.sleep(10)
                monitor.send(f'screendump {json.dumps(str(prefix) + "-boot.png")} -f png',
                             '起動開始の撮影', transcript)
            if args.expect_panic:
                remaining = max(60, deadline - time.monotonic() - 60)
                try:
                    marker = serial.expect('RAM が足りない', min(1200, remaining), 'RAM 不足の理由')
                    serial.expect('(initramfs)', 120, '停止 shell')
                    if '複写が完了'.encode() in serial.buffer:
                        raise RuntimeError('RAM 不足にもかかわらず複写が完了した')

                except TimeoutError as error:
                    transcript.append(f'[判定] panic せず: {error}\n')
                    raise RuntimeError('panic しませんでした')
                time.sleep(10)
                monitor.send(f'screendump {json.dumps(str(prefix) + "-panic.png")} -f png',
                             'panic 撮影', transcript)
                transcript.append(f'[判定] panic を確認: {marker}\n')
                return 0
            if args.expect_os is not None:
                # 誤った項目で起動したら早めに落とす (grub 選択の取違い対策)。
                serial.expect(f'os={args.expect_os})'.encode(), 900, 'OS 選択の確認')
            if args.root_shell:
                serial.expect(b'# ', 2400, '診断 root shell')
            elif args.server_shell:
                serial.expect([b'Continue in rich mode', b'Help ]'], 2400, 'subiquity 待ち')
                serial.connection.sendall(b'\x1b[12~')
                time.sleep(5)
                serial.connection.sendall(b'\x1a')
                serial.expect(b'# ', 120, 'Server shell')
            else:
                serial.expect(b'login:', min(2400, args.timeout), 'ログイン待ち')
            if not (args.server_shell or args.root_shell):
                serial.sendline(args.user, 'ユーザー名')
                try:
                    serial.expect(b'Password:', 30, 'パスワード待ち')
                    serial.sendline(args.password, 'パスワード')
                except TimeoutError:
                    transcript.append('[serial] パスワード不要で進行\n')
                prompt = serial.expect([b'$ ', b'# '], 60, 'プロンプト待ち')
                prompt = prompt.strip()
            for command, marker in MEASURE_COMMANDS:
                serial.run(command, marker.encode(), 300, command)
            if args.desktop:
                monitor.send(f'screendump {json.dumps(str(prefix) + "-gui-start.png")} -f png', 'GUI 確認前の撮影', transcript)
                name = {'gnome': 'gnome-shell', 'lxqt': 'lxqt-session'}[args.desktop]
                result = serial.run(
                    f'for i in $(seq 1 360); do pgrep -x {name} && break; sleep 5; done; echo GUI_DONE',
                    b'GUI_DONE', 1850, 'GUI のプロセス待ち')
                if not re.search(r'(?m)^\d+\r?$', result):
                    raise RuntimeError(f'{name} が起動しなかった')
                time.sleep(args.gui_wait)
            monitor.send(f'screendump {json.dumps(str(prefix) + "-desktop.png")} -f png',
                         'デスクトップ撮影', transcript)
            if args.detach:
                monitor.send('info block', '取り外し前の確認', transcript)
                monitor.send('eject -f cd0', 'ISO 取り外し', transcript)
                time.sleep(5)
                monitor.send('info block', '取り外し後の確認', transcript)
                for command, marker in POST_DETACH_COMMANDS:
                    try:
                        result = serial.run(command, marker.encode(), 900, command)
                        if marker == 'WALK_DONE':
                            match = re.search(r'(?m)^MEDIA_READ_RC=(\d+)\r?$', result)
                            if match is None:
                                if not (args.expect_detach_failure and 'Input/output error' in result):
                                    raise RuntimeError('媒体読み出しの終了値を取得できない')
                                failed = True
                            else:
                                failed = int(match.group(1)) != 0
                            if failed != args.expect_detach_failure:
                                raise RuntimeError('取り外し対照と結果が不一致: ' + result[-1000:])
                    except TimeoutError as error:
                        transcript.append(f'[判定] 取り外し後の操作で応答なし: {error}\n')
                        raise
                transcript.append('[判定] 取り外し後の操作が完了\n')
            monitor.send('quit', '終了', transcript)
            try:
                process.wait(timeout=30)
            except subprocess.TimeoutExpired:
                process.terminate()
            return 0
    except (OSError, RuntimeError, TimeoutError, ValueError, subprocess.SubprocessError) as error:
        transcript.append(f'[異常] {error}\n')
        if monitor is not None and process is not None and process.poll() is None:
            try:
                monitor.send(f'screendump {json.dumps(str(prefix) + "-error.png")} -f png', '異常時の撮影', transcript)
            except (OSError, RuntimeError, TimeoutError):
                pass
        print(f'エラー: {error}', file=sys.stderr)
        return 1
    finally:
        shots_stop.set()
        if shots_thread is not None:
            shots_thread.join(timeout=2)
        if control_thread is not None:
            control_thread.join(timeout=2)
        if serial is not None:
            serial.close()
        for conn in (monitor_conn, serial_conn):
            if conn is not None:
                try:
                    conn.close()
                except OSError:
                    pass
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        for stale in (monitor_path, serial_path, Path(str(serial_path) + '.in'), Path(str(serial_path) + '.out')):
            try:
                os.unlink(stale)
            except OSError:
                pass
        if variables is not None:
            try:
                variables.unlink()
            except OSError:
                pass
        with transcript_path.open('w', encoding='utf-8') as stream:
            stream.write(''.join(transcript))
            try:
                tail = serial_raw.read_bytes()[-8000:].decode('utf-8', errors='replace')
                stream.write('\n=== serial 末尾 ===\n' + tail)
            except OSError:
                pass


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt))
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print('中断しました', file=sys.stderr)
        sys.exit(130)
