#!/bin/sh
case " $(cat /proc/cmdline) " in
    *' bootkit.session=server '*)
        printf '%s\n' \
            'GUI を使うには: sudo systemctl start gdm3 (Ubuntu with Server) または sudo systemctl start sddm (Lubuntu-modoki)。' \
            '次回から GUI で起動するには、起動メニューで Lubuntu-modoki か Ubuntu with Server を選ぶ。' \
            '初回は persistence を選び、sudo sh ubuntu-modoki-setup.sh で追加パックを導入する。'
        ;;
esac
