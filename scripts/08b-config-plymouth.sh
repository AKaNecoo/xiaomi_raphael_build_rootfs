#!/bin/bash
set -e

# Install the Raphael vendor boot-logo plymouth theme into the rootfs and make
# it the default. MUST run before 09-install-kernel.sh, because that script
# generates the initramfs (update-initramfs) which bakes in the active theme.

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
rm -f "$THEMES_DST/$THEME_NAME/render-anim.py" \
      "$THEMES_DST/$THEME_NAME/"*.orig 2>/dev/null || true

# 2. Bundle CJK font + patch theme to match installed font (Noto on Ubuntu, wqy on Debian).
FONT_FAMILY=""
FONT_SRC=""
FONT_BUNDLE=""
if chroot rootdir test -f /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc; then
	FONT_FAMILY="Noto Sans CJK SC 16"
	FONT_SRC=/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc
	FONT_BUNDLE=noto-cjk.ttc
elif chroot rootdir sh -c 'ls /usr/share/fonts/truetype/wqy/wqy-microhei.ttc 2>/dev/null' | grep -q .; then
	FONT_FAMILY="WenQuanYi Micro Hei 16"
	FONT_SRC=/usr/share/fonts/truetype/wqy/wqy-microhei.ttc
	FONT_BUNDLE=wqy-microhei.ttc
fi

if [ -n "$FONT_FAMILY" ] && [ -f "rootdir$FONT_SRC" ]; then
	cp -a "rootdir$FONT_SRC" "$THEMES_DST/$THEME_NAME/$FONT_BUNDLE"
	sed -i "s/^FONT_NAME = .*/FONT_NAME = \"$FONT_FAMILY\";/" "$THEMES_DST/$THEME_NAME/bgrt.script"
	sed -i "s/^MonospaceFont=.*/MonospaceFont=$FONT_FAMILY/" "$THEMES_DST/$THEME_NAME/bgrt.plymouth"
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [08b]   └─ Plymouth 字体: $FONT_FAMILY"
else
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] [08b] ⚠️  未找到 CJK 字体，Plymouth 中文可能乱码" >&2
fi

# 3. Static fallback image used by the two-step path on machines without an
#    ACPI BGRT table (this device). Harmless even with the script theme active.
if [ -f "$PLYMOUTH_SRC/themes/spinner/bgrt-fallback.png" ]; then
    mkdir -p "$THEMES_DST/spinner"
    cp -a "$PLYMOUTH_SRC/themes/spinner/bgrt-fallback.png" "$THEMES_DST/spinner/"
fi

# 4. plymouth's initramfs hook is skipped unless FRAMEBUFFER=y.
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
	/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc \
	/usr/share/plymouth/themes/bgrt/noto-cjk.ttc \
	/usr/share/fonts/truetype/wqy/wqy-microhei.ttc \
	/usr/share/plymouth/themes/bgrt/wqy-microhei.ttc
do
	[ -f "$font" ] || continue
	case "$font" in
	*noto*)
		mkdir -p "${DESTDIR}/usr/share/fonts/opentype/noto"
		cp "$font" "${DESTDIR}/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
		;;
	*)
		mkdir -p "${DESTDIR}/usr/share/fonts/truetype/wqy"
		cp "$font" "${DESTDIR}/usr/share/fonts/truetype/wqy/wqy-microhei.ttc"
		;;
	esac
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

# 5. Make our theme the default.
echo "[$(date +'%Y-%m-%d %H:%M:%S')] [08b]   └─ 设为默认主题 ..."
if chroot rootdir plymouth-set-default-theme "$THEME_NAME" 2>/dev/null; then
    :
else
    chroot rootdir update-alternatives --install \
        /usr/share/plymouth/themes/default.plymouth default.plymouth \
        "/usr/share/plymouth/themes/$THEME_NAME/$THEME_NAME.plymouth" 200
    chroot rootdir update-alternatives --set default.plymouth \
        "/usr/share/plymouth/themes/$THEME_NAME/$THEME_NAME.plymouth"
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] [08b] ✅ Plymouth 主题配置完成（initramfs 将在 09 重新生成）"
