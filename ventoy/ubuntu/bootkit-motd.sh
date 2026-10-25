#!/bin/sh
case " $(cat /proc/cmdline) " in
    *' bootkit.session=server '*)
        printf '%s\n' \
            'GUI を使うには: sudo systemctl start gdm3 (Ubuntu) または sudo systemctl start sddm (Lubuntu)。' \
            '次回から GUI で起動するには、起動メニューで Lubuntu か Ubuntu を選ぶ。' \
            '初回は persistence を選び、sudo sh ubuntu-pack-setup.sh で追加パックを導入する。'
        ;;
esac
