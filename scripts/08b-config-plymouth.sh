#!/bin/bash
set -e

# Install the Raphael vendor boot-logo plymouth theme into the rootfs and make
# it the default. MUST run before 09-install-kernel.sh, because that script
# generates the initramfs (update-initramfs) which bakes in the active theme.
#
# The theme assets live in the repo at plymouth/themes/bgrt/ (script module +
# anim-*.png light-sweep frames) and are byte-for-byte the ones validated on
# the device.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLYMOUTH_SRC="$SCRIPT_DIR/../plymouth"
THEMES_DST="rootdir/usr/share/plymouth/themes"
THEME_NAME="bgrt"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [08b] 🎬 配置 Plymouth 开机 logo 动画"

if [ ! -d "$PLYMOUTH_SRC/themes/$THEME_NAME" ]; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [08b] ❌ 缺少主题源: $PLYMOUTH_SRC/themes/$THEME_NAME" >&2
    exit 1
fi

# 1. Copy the vendor theme (script module + animation frames).
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [08b]   └─ 安装主题 $THEME_NAME ..."
mkdir -p "$THEMES_DST"
cp -a "$PLYMOUTH_SRC/themes/$THEME_NAME" "$THEMES_DST/"
# Drop dev-only files that don't belong in the rootfs.
rm -f "$THEMES_DST/$THEME_NAME/render-anim.py" \
      "$THEMES_DST/$THEME_NAME/"*.orig 2>/dev/null || true

# Bundle CJK font in the theme (initramfs ships the whole theme directory).
WQY_FONT=$(chroot rootdir sh -c 'ls /usr/share/fonts/truetype/wqy/wqy-microhei.ttc 2>/dev/null || ls /usr/share/fonts/*/wqy/wqy-microhei.ttc 2>/dev/null' | head -1)
if [ -n "$WQY_FONT" ] && [ -f "rootdir$WQY_FONT" ]; then
	cp -a "rootdir$WQY_FONT" "$THEMES_DST/$THEME_NAME/wqy-microhei.ttc"
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [08b]   └─ 打包中文字体 wqy-microhei"
else
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [08b] ⚠️  未找到 wqy-microhei，Plymouth 中文可能乱码" >&2
fi

# 2. Static fallback image used by the two-step path on machines without an
#    ACPI BGRT table (this device). Harmless even with the script theme active.
if [ -f "$PLYMOUTH_SRC/themes/spinner/bgrt-fallback.png" ]; then
    mkdir -p "$THEMES_DST/spinner"
    cp -a "$PLYMOUTH_SRC/themes/spinner/bgrt-fallback.png" "$THEMES_DST/spinner/"
fi

# 3. plymouth's initramfs hook is skipped unless FRAMEBUFFER=y. Without this the
#    initramfs ships no plymouth at all and the splash only appears late (after
#    systemd), leaving kernel logs visible first.
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [08b]   └─ 启用 initramfs FRAMEBUFFER ..."
mkdir -p rootdir/etc/initramfs-tools/conf.d
echo "FRAMEBUFFER=y" > rootdir/etc/initramfs-tools/conf.d/plymouth.conf

# CJK font + fontconfig for Plymouth Image.Text in early boot initramfs.
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [08b]   └─ initramfs 中文字体 hook ..."
cat > rootdir/etc/initramfs-tools/hooks/plymouth-cjk-font << 'EOF'
#!/bin/sh
PREREQS=""
case $1 in
prereqs) echo "$PREREQS"; exit 0;;
esac

. /usr/share/initramfs-tools/hook-functions

for font in \
	/usr/share/fonts/truetype/wqy/wqy-microhei.ttc \
	/usr/share/plymouth/themes/bgrt/wqy-microhei.ttc
do
	[ -f "$font" ] || continue
	mkdir -p "${DESTDIR}/usr/share/fonts/truetype/wqy"
	cp "$font" "${DESTDIR}/usr/share/fonts/truetype/wqy/wqy-microhei.ttc"
	break
done

if [ -f /etc/fonts/fonts.conf ]; then
	mkdir -p "${DESTDIR}/etc/fonts/conf.d"
	cp /etc/fonts/fonts.conf "${DESTDIR}/etc/fonts/"
	for conf in /etc/fonts/conf.d/65-nonlatin.conf /etc/fonts/conf.d/44-wqy-microhei.conf; do
		[ -f "$conf" ] || continue
		cp -L "$conf" "${DESTDIR}/etc/fonts/conf.d/" 2>/dev/null || cp "$conf" "${DESTDIR}/etc/fonts/conf.d/"
	done
fi
EOF
chmod +x rootdir/etc/initramfs-tools/hooks/plymouth-cjk-font

# 4. Make our theme the default.
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [08b]   └─ 设为默认主题 ..."
if chroot rootdir plymouth-set-default-theme "$THEME_NAME" 2>/dev/null; then
    :
else
    # Fallback if plymouth-set-default-theme is unavailable: register and select
    # the alternative manually.
    chroot rootdir update-alternatives --install \
        /usr/share/plymouth/themes/default.plymouth default.plymouth \
        "/usr/share/plymouth/themes/$THEME_NAME/$THEME_NAME.plymouth" 200
    chroot rootdir update-alternatives --set default.plymouth \
        "/usr/share/plymouth/themes/$THEME_NAME/$THEME_NAME.plymouth"
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [08b] ✅ Plymouth 主题配置完成（initramfs 将在 09 重新生成）"
