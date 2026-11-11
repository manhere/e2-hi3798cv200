#!/usr/bin/env python3
"""Clone enigma2's skin_default into a 1920x1080 skin.

The fbdev device on this box is the generic DRM fbdev emulation at the HDMI
native 1920x1080; skin_default declares 720x576, so its widgets occupy only
the top-left ~37%x53% of the screen. OpenPLi ships no FHD skin in-tree, and
third-party FHD skins depend on converters/renderers that are not available.

This script clones the in-tree skin (all pixmaps and fonts) and scales every
geometry attribute in skin.xml from the declared resolution to 1920x1080:

  - position / size / offset / title offset  : x by 1920/720, y by 1080/576
  - font="Name;NN", alias size, height      : NN by 1080/576
  - borderWidth, single-number size         : by 1080/576
  - pointer/seek_pointer "file.png:x,y"     : coordinates by the same factors
  - <resolution xres/yres>                 : 1920 / 1080

Symbolic geometry is preserved: center/left/right/top/bottom/fill, `*`,
`10%`, `2h`, and `c+5` / `e-45` expressions keep their symbolic part while
only the numeric offset is scaled. Element text (e.g. <convert
type="ValueRange">720,1000</convert>), colors, zPosition, scale, ids and all
business values are left untouched because the transform is attribute-name
based rather than a blanket number substitution.

Usage:
  python3 make-fhd-skin.py <enigma2-data-dir> [dst-skin-name]

<enigma2-data-dir> is the directory containing skin_default/, e.g.
  $WORK/stage/usr/share/enigma2   (build)  or
  /opt/openpli-e2/usr/share/enigma2 (isolated trial).
"""
import os
import re
import shutil
import sys

XRES, YRES = 1920, 1080
GEOM_ATTRS = ('position', 'size', 'offset', 'borderWidth', 'height',
              'font', 'pointer', 'seek_pointer')
ATTR_RE = re.compile(r'(?<![-\w])(' + '|'.join(GEOM_ATTRS) + r')="([^"]*)"')
RES_RE = re.compile(r'(<resolution\s+xres=")(\d+)("\s+yres=")(\d+)(")')


def scale_int(value, factor):
    return str(max(0, round(int(value) * factor)))


def scale_token(token, factor):
    """Scale one coordinate/size token, preserving symbolic expressions."""
    if token in ('center', 'left', 'right', 'top', 'bottom', 'fill', '*'):
        return token
    if re.fullmatch(r'\d+%', token) or re.fullmatch(r'\d+h', token):
        return token  # percentage or N x line-height: follows the scaled font
    if re.fullmatch(r'-?\d+', token):
        return scale_int(token, factor)
    m = re.fullmatch(r'([ce])([+-])(\d+)', token)  # c+5 / e-45
    if m:
        return '%s%s%s' % (m.group(1), m.group(2), scale_int(m.group(3), factor))
    return token


def scale_value(attr, value, sx, sy):
    if attr in ('pointer', 'seek_pointer') and ':' in value:
        name, coords = value.rsplit(':', 1)
        parts = coords.split(',')
        if len(parts) == 2:
            coords = '%s,%s' % (scale_token(parts[0], sx),
                                scale_token(parts[1], sy))
        return '%s:%s' % (name, coords)
    if attr == 'font':
        return re.sub(r';(\d+)$',
                      lambda m: ';' + scale_int(m.group(1), sy), value)
    if attr in ('borderWidth', 'height'):
        return scale_int(value, sy) if re.fullmatch(r'\d+', value) else value
    parts = value.split(',')
    if len(parts) == 2:
        return '%s,%s' % (scale_token(parts[0], sx),
                          scale_token(parts[1], sy))
    if len(parts) == 1:
        # single-number size = font size / alias size, scale by height
        return scale_token(parts[0], sy)
    return value


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    data_dir = sys.argv[1]
    dst_name = sys.argv[2] if len(sys.argv) > 2 else 'skin_fhd'
    src = os.path.join(data_dir, 'skin_default')
    dst = os.path.join(data_dir, dst_name)
    src_xml = os.path.join(src, 'skin.xml')
    if not os.path.isfile(src_xml):
        print('ERROR: %s not found' % src_xml)
        return 1

    xml = open(src_xml, encoding='utf-8', errors='replace').read()
    m = RES_RE.search(xml)
    if not m:
        print('ERROR: <resolution xres=... yres=...> not found in skin.xml')
        return 1
    old_x, old_y = int(m.group(2)), int(m.group(4))
    sx, sy = XRES / old_x, YRES / old_y
    print('scaling %dx%d -> %dx%d (sx=%.4f, sy=%.4f)' %
          (old_x, old_y, XRES, YRES, sx, sy))

    out = ATTR_RE.sub(lambda mm: '%s="%s"' %
                      (mm.group(1), scale_value(mm.group(1), mm.group(2), sx, sy)),
                      xml)
    out = RES_RE.sub(lambda mm: '%s%d%s%d%s' %
                     (mm.group(1), XRES, mm.group(3), YRES, mm.group(5)),
                     out, count=1)

    # Full clone: pixmaps and fonts are referenced relative to the skin dir.
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    shutil.copytree(src, dst)
    open(os.path.join(dst, 'skin.xml'), 'w', encoding='utf-8',
         newline='\n').write(out)
    print('wrote %s/skin.xml (%d bytes)' % (dst, len(out.encode())))
    return 0


if __name__ == '__main__':
    sys.exit(main())
