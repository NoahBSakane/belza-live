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
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import time
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


class Monitor:
    def __init__(self, connection, process, deadline):
        self.connection = connection
        self.process = process
        self.deadline = deadline

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
        self.check_time()
        self.connection.sendall((command + '\n').encode())
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

    def close(self):
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
            try:
                part = self.connection.recv(65536)
            except socket.timeout:
                continue
            if not part:
                raise RuntimeError('serial が切断されました')
            self.raw.write(part)
            self.raw.flush()
            self.buffer += part

    def sendline(self, line, label):
        self.check_time()
        data = (line + '\n').encode()
        self.connection.sendall(data)
        self.raw.write(b'[host] ' + data)
        self.raw.flush()
        self.transcript.append(f'[host] {label}: {line}\n')
        time.sleep(0.5)

    def run(self, command, marker, timeout, label):
        self.sendline(command, label)
        self.expect(marker, timeout, label + ' の応答')
        text = self.buffer.decode('utf-8', errors='replace')
        # 応答の取り出し: 直近の marker までを残し、それ以前を切り捨てる。
        return text


def build_command(args, monitor_path, serial_path, code, variables):
    cmd = ['qemu-system-x86_64', '-machine', 'pc',
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
            '-monitor', f'unix:{monitor_path},server=on,wait=off',
            '-serial', f'unix:{serial_path},server=on,wait=off',
            '-net', 'none']
    return cmd


MEASURE_COMMANDS = [
    ('id; echo ID_DONE', 'ID_DONE'),
    ('df -k /bootkit-ram /cdrom; echo DF_DONE', 'DF_DONE'),
    ('ls -la /cdrom /cdrom/casper 2>&1 | head -40; echo LS_DONE', 'LS_DONE'),
    ('head -5 /proc/meminfo; echo MEM_DONE', 'MEM_DONE'),
    ('cat /proc/mounts; echo MOUNTS_DONE', 'MOUNTS_DONE'),
    ('findmnt -n -o SOURCE,TARGET,FSTYPE; echo FINDMNT_DONE', 'FINDMNT_DONE'),
    ('losetup -a; echo LOS_DONE', 'LOS_DONE'),
]

POST_DETACH_COMMANDS = [
    ('ls -R /usr 2>&1 | md5sum; echo WALK_DONE', 'WALK_DONE'),
    ('python3 -c "print(\'PY_OK\')"; echo PY_DONE', 'PY_DONE'),
    ('sudo -n apt-get check 2>&1 | tail -5; echo APT_DONE', 'APT_DONE'),
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
    transcript = []
    for stale in (monitor_path, serial_path):
        if os.path.lexists(stale):
            raise FileExistsError(f'ソケットのパスが使用中です: {stale}')
    process = None
    monitor_conn = None
    serial_conn = None
    serial = None
    variables = None
    deadline = time.monotonic() + args.timeout
    try:
        code = firmware_code() if args.mode == 'uefi-grub' else None
        if args.mode == 'uefi-grub':
            variables = prefix.parent / (prefix.name + '.vars.fd')
            shutil.copyfile(vars_template(args), variables)
        command = build_command(args, monitor_path, serial_path, code, variables)
        print(shlex.join(command), flush=True)
        with log_path.open('wb') as log:
            process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
            monitor_conn = wait_connect(monitor_path, process, deadline, 'monitor')
            monitor = Monitor(monitor_conn, process, deadline)
            monitor.response()
            serial_conn = wait_connect(serial_path, process, deadline, 'serial')
            serial = Serial(serial_conn, process, deadline, serial_raw, transcript)
            if args.mode == 'uefi-grub':
                # OVMF の初期化を待つ。TCG では数分かかるため、画面が
                # 真っ黒でなくなるまで撮影を繰り返す (grub 項目の選択用)。
                shot = str(prefix) + '-grub.png'
                for _ in range(40):
                    monitor.send(f'screendump {json.dumps(shot)} -f png',
                                 'grub 撮影', transcript)
                    try:
                        if Path(shot).stat().st_size > 6000:
                            break
                    except OSError:
                        pass
                    time.sleep(30)
                else:
                    raise RuntimeError('grub の画面が出ませんでした')
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
                    marker = serial.expect([b'bootkit-ramsel', b'Kernel panic', b'panic:'],
                                           min(1200, remaining), 'panic 待ち')
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
            serial.expect(b'login:', min(1800, args.timeout / 2), 'ログイン待ち')
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
            monitor.send(f'screendump {json.dumps(str(prefix) + "-desktop.png")} -f png',
                         'デスクトップ撮影', transcript)
            if args.detach:
                monitor.send('info block', '取り外し前の確認', transcript)
                monitor.send('eject -f cd0', 'ISO 取り外し', transcript)
                time.sleep(5)
                monitor.send('info block', '取り外し後の確認', transcript)
                for command, marker in POST_DETACH_COMMANDS:
                    try:
                        serial.run(command, marker.encode(), 600, command)
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
        print(f'エラー: {error}', file=sys.stderr)
        return 1
    finally:
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
        for stale in (monitor_path, serial_path):
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
