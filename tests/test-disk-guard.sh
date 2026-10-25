#!/bin/bash
# disk-guard.sh の試験。偽の sysfs を作り、通る場合と、通らない場合(USB・取り外し可能・容量・型番・存在・数字でない指定)を確かめる。
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
GUARD="${GUARD:-$HERE/config/includes.binary/disk-guard.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; failn=0
mk() { # name path sectors removable model
  mkdir -p "$T/devices/$2/block/$1/device"
  echo "$3" > "$T/devices/$2/block/$1/size"; echo "$4" > "$T/devices/$2/block/$1/removable"; echo "$5" > "$T/devices/$2/block/$1/device/model"
  mkdir -p "$T/block"; ln -s "../devices/$2/block/$1" "$T/block/$1"
}
mk sda pci0/ata1 468862128 0 "SanDisk SDSSDHII240G"      # 240GB の SSD(SATA)
mk sdb pci0/ata2 1953525168 0 "ST1000LM014-1EJ164"       # 1TB の HDD
mk sdc pci0/usb2/1-1 1953525168 0 "SHARGE DISK"           # 1TB の USB(取り外せない扱い)
mk sdd pci0/ata3 1953525168 1 "REMOVABLE HDD"             # 取り外し可能の印つき
run() { sh "$GUARD" --sysfs "$T" --expect "$1" >/dev/null 2>&1; }
expect() { # label want(0|1) expect
  run "$3"; got=$?
  if [ "$got" = "$2" ]; then
    pass=$((pass+1)); echo "ok   $1"
  else
    failn=$((failn+1)); echo "FAIL $1 (exit $got, want $2)"
  fi
}
expect "SATA の 2 台が範囲内で通る" 0 "sda:230:250:sandisk,sdb:900:1100"
expect "USB 接続のディスクは通らない" 1 "sda:230:250,sdc:900:1100"
expect "取り外し可能の印があれば通らない" 1 "sdd:900:1100"
expect "容量が下限未満なら通らない" 1 "sda:300:400"
expect "容量が上限を超えれば通らない" 1 "sdb:100:500"
expect "型番に含まれなければ通らない" 1 "sda:230:250:Hitachi"
expect "存在しないディスクは通らない" 1 "sda:230:250,sdz:100:200"
expect "例の MIN・MAX のままでは通らない" 1 "sda:MIN:MAX"
expect "1 台でも悪ければ、全体が通らない" 1 "sda:230:250,sdb:900:1100,sdc:900:1100"
if [ "$failn" = 0 ]; then
  echo "ALL PASS ($pass)"; exit 0
else
  echo "FAILED ($failn)"; exit 1
fi
