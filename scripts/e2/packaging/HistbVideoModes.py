# DRM/KMS video-mode enumeration and control for boxes without the vendor
# /proc/stb/video interface. Python port of the reference OpenATV histb
# avcontrol backend (manhere/enigma2-hi3798cv200, packaging/avcontrol_histb_impl.h
# + histb_drm.h) using ctypes against libdrm: EDID-backed mode enumeration,
# the same histb-style mode naming as the reference (bare base name at its
# default refresh, explicit refresh suffix otherwise; matches the names in
# VideoHardware.rates) and mode application via drmModeSetCrtc.

import ctypes
import glob
import os

DRM_MODE_CONNECTED = 1
DRM_MODE_FLAG_INTERLACE = 1 << 2
DRM_MODE_FLAG_DBLSCAN = 1 << 3
DRM_MODE_CONNECTOR_HDMIA = 11
DRM_MODE_CONNECTOR_HDMIB = 12


class _ModeInfo(ctypes.Structure):
	_fields_ = [
		("clock", ctypes.c_uint32),
		("hdisplay", ctypes.c_uint16), ("hsync_start", ctypes.c_uint16),
		("hsync_end", ctypes.c_uint16), ("htotal", ctypes.c_uint16),
		("hskew", ctypes.c_uint16),
		("vdisplay", ctypes.c_uint16), ("vsync_start", ctypes.c_uint16),
		("vsync_end", ctypes.c_uint16), ("vtotal", ctypes.c_uint16),
		("vscan", ctypes.c_uint16),
		("flags", ctypes.c_uint32), ("type", ctypes.c_uint32),
		("name", ctypes.c_char * 32),
	]


class _Res(ctypes.Structure):
	_fields_ = [
		("count_fbs", ctypes.c_int), ("fbs", ctypes.POINTER(ctypes.c_uint32)),
		("count_crtcs", ctypes.c_int), ("crtcs", ctypes.POINTER(ctypes.c_uint32)),
		("count_connectors", ctypes.c_int), ("connectors", ctypes.POINTER(ctypes.c_uint32)),
		("count_encoders", ctypes.c_int), ("encoders", ctypes.POINTER(ctypes.c_uint32)),
		("min_width", ctypes.c_int), ("max_width", ctypes.c_int),
		("min_height", ctypes.c_int), ("max_height", ctypes.c_int),
	]


class _Connector(ctypes.Structure):
	_fields_ = [
		("encoder_id", ctypes.c_uint32), ("connector_id", ctypes.c_uint32),
		("connector_type", ctypes.c_uint32), ("connector_type_id", ctypes.c_uint32),
		("connection", ctypes.c_uint32), ("mm_width", ctypes.c_uint32),
		("mm_height", ctypes.c_uint32), ("subpixel", ctypes.c_uint32),
		("count_modes", ctypes.c_int), ("modes", ctypes.POINTER(_ModeInfo)),
		("count_props", ctypes.c_int), ("props", ctypes.POINTER(ctypes.c_uint32)),
		("prop_values", ctypes.POINTER(ctypes.c_uint64)),
		("count_encoders", ctypes.c_int), ("encoders", ctypes.POINTER(ctypes.c_uint32)),
	]


class _Crtc(ctypes.Structure):
	_fields_ = [
		("crtc_id", ctypes.c_uint32), ("fb_id", ctypes.c_uint32),
		("x", ctypes.c_uint32), ("y", ctypes.c_uint32),
		("gamma_size", ctypes.c_uint32), ("mode_valid", ctypes.c_int),
		("mode", _ModeInfo),
	]


class _Encoder(ctypes.Structure):
	_fields_ = [
		("encoder_id", ctypes.c_uint32), ("encoder_type", ctypes.c_uint32),
		("crtcs", ctypes.c_uint32), ("clones", ctypes.c_uint32),
		("crtc_id", ctypes.c_uint32),
	]


class _Prop(ctypes.Structure):
	_fields_ = [
		("prop_id", ctypes.c_uint32), ("name", ctypes.c_char * 32),
		("flags", ctypes.c_uint32), ("count_values", ctypes.c_uint32),
		("values", ctypes.POINTER(ctypes.c_uint64)),
		("count_enums", ctypes.c_uint32), ("enums", ctypes.c_void_p),
		("count_ranges", ctypes.c_uint32), ("ranges", ctypes.c_void_p),
	]


_lib = None
_load_failed = False


def _drm():
	global _lib, _load_failed
	if _lib is None and not _load_failed:
		for soname in ("libdrm.so.2", "libdrm.so.1", "libdrm.so"):
			try:
				lib = ctypes.CDLL(soname)
			except OSError:
				continue
			for fn, res, args in (
				("drmModeGetResources", ctypes.POINTER(_Res), [ctypes.c_int]),
				("drmModeGetConnector", ctypes.POINTER(_Connector), [ctypes.c_int, ctypes.c_uint32]),
				("drmModeGetProperty", ctypes.POINTER(_Prop), [ctypes.c_int, ctypes.c_uint32]),
				("drmModeGetCrtc", ctypes.POINTER(_Crtc), [ctypes.c_int, ctypes.c_uint32]),
				("drmModeGetEncoder", ctypes.POINTER(_Encoder), [ctypes.c_int, ctypes.c_uint32]),
				("drmModeSetCrtc", ctypes.c_int, [ctypes.c_int, ctypes.c_uint32, ctypes.c_uint32,
					ctypes.c_uint32, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32),
					ctypes.c_int, ctypes.POINTER(_ModeInfo)]),
				("drmSetMaster", ctypes.c_int, [ctypes.c_int]),
				("drmDropMaster", ctypes.c_int, [ctypes.c_int]),
			):
				f = getattr(lib, fn)
				f.restype = res
				f.argtypes = args
			_lib = lib
			break
		if _lib is None:
			_load_failed = True
	return _lib


def _cards():
	return sorted(glob.glob("/dev/dri/card*"))


def _hasEdid(lib, fd, conn):
	for i in range(conn.count_props):
		if not conn.prop_values[i]:
			continue
		prop = lib.drmModeGetProperty(fd, conn.props[i])
		if prop:
			name = prop.name.decode("utf-8", "replace") if prop.name else ""
			lib.drmModeFreeProperty(prop)
			if name == "EDID":
				return True
	return False


def _refresh(m):
	if not m.clock or not m.htotal or not m.vtotal:
		return 0
	period = 1000.0 * m.htotal * m.vtotal / m.clock
	if m.flags & DRM_MODE_FLAG_INTERLACE:
		period /= 2
	if m.flags & DRM_MODE_FLAG_DBLSCAN:
		period *= 2
	if m.vscan > 1:
		period *= m.vscan
	return int(1000000.0 / period + 0.5)


def _modeName(m):
	# identical naming to the reference histbModeName(): 60 Hz uses the bare
	# name, 576i/576p default to 50 Hz, everything else gets an explicit suffix
	if not m.clock:
		return None
	interlaced = bool(m.flags & DRM_MODE_FLAG_INTERLACE)
	geom = (m.hdisplay, m.vdisplay, interlaced)
	base, expect = None, 60
	if geom == (1280, 720, False):
		base = "720p"
	elif geom == (1920, 1080, True):
		base = "1080i"
	elif geom == (1920, 1080, False):
		base = "1080p"
	elif geom == (3840, 2160, False):
		base = "2160p"
	elif geom == (4096, 2160, False):
		base = "smpte"
	elif geom == (720, 576, True):
		base, expect = "576i", 50
	elif geom == (720, 576, False):
		base, expect = "576p", 50
	elif geom == (720, 480, True):
		base = "480i"
	elif geom == (720, 480, False):
		base = "480p"
	if not base:
		return None
	refresh = _refresh(m)
	if refresh != expect or m.hdisplay == 4096:
		return base + str(refresh)
	return base


def _pickConnector(lib, fd, res):
	# first connected connector with a real EDID, HDMI preferred; returns
	# (connector_id, [mode info copies]) or (None, [])
	best = None
	for i in range(res.count_connectors):
		conn = lib.drmModeGetConnector(fd, res.connectors[i])
		if not conn:
			continue
		try:
			c = conn.contents
			if c.connection != DRM_MODE_CONNECTED or not _hasEdid(lib, fd, c):
				continue
			modes = [c.modes[j] for j in range(c.count_modes)]
			hdmi = c.connector_type in (DRM_MODE_CONNECTOR_HDMIA, DRM_MODE_CONNECTOR_HDMIB)
			if hdmi:
				return c.connector_id, modes
			if best is None:
				best = (c.connector_id, modes)
		finally:
			lib.drmModeFreeConnector(conn)
	return best if best else (None, [])


def readEdidModes():
	# space-separated EDID mode names, deduplicated in EDID order, exactly
	# what /proc/stb/video/videomode(_choices) would have provided
	lib = _drm()
	if lib is None:
		print("[HistbVideoModes] libdrm unavailable, no modes")
		return []
	names = []
	for card in _cards():
		try:
			fd = os.open(card, os.O_RDWR)
		except OSError:
			continue
		try:
			res = lib.drmModeGetResources(fd)
			if not res:
				continue
			try:
				connId, modes = _pickConnector(lib, fd, res)
			finally:
				lib.drmModeFreeResources(res)
			if connId is None:
				continue
			for m in modes:
				name = _modeName(m)
				if name and name not in names:
					names.append(name)
		finally:
			os.close(fd)
	return names


def applyMode(name):
	# apply one of the histb-style mode names via a legacy drmModeSetCrtc on
	# the current framebuffer (the decode backend owns the video planes while
	# playing; a mode change therefore only succeeds while idle, which is the
	# normal A/V-settings flow)
	lib = _drm()
	if lib is None:
		print("[HistbVideoModes] libdrm unavailable, cannot set mode")
		return False
	for card in _cards():
		try:
			fd = os.open(card, os.O_RDWR)
		except OSError:
			continue
		try:
			res = lib.drmModeGetResources(fd)
			if not res:
				continue
			try:
				connId, modes = _pickConnector(lib, fd, res)
				if connId is None:
					continue
				target = None
				for m in modes:
					if _modeName(m) == name:
						target = _ModeInfo.from_buffer_copy(m)
						break
				if target is None:
					continue
				crtcId = None
				conn = lib.drmModeGetConnector(fd, connId)
				if conn:
					enc = lib.drmModeGetEncoder(fd, conn.contents.encoder_id)
					if enc:
						if enc.contents.crtc_id:
							crtcId = enc.contents.crtc_id
						lib.drmModeFreeEncoder(enc)
					lib.drmModeFreeConnector(conn)
				if crtcId is None and res.count_crtcs:
					crtcId = res.crtcs[0]
				if crtcId is None:
					continue
				crtc = lib.drmModeGetCrtc(fd, crtcId)
				if not crtc:
					continue
				fb = crtc.contents.fb_id
				lib.drmModeFreeCrtc(crtc)
				if not fb:
					print("[HistbVideoModes] no fb bound to crtc %d" % crtcId)
					continue
				if lib.drmSetMaster(fd) != 0:
					print("[HistbVideoModes] cannot become DRM master (decoder busy?)")
					continue
				conns = (ctypes.c_uint32 * 1)(connId)
				ok = lib.drmModeSetCrtc(fd, crtcId, fb, 0, 0, conns, 1, ctypes.byref(target)) == 0
				lib.drmDropMaster(fd)
				print("[HistbVideoModes] %s -> %s" % (name, "applied" if ok else "rejected"))
				return ok
			finally:
				lib.drmModeFreeResources(res)
		finally:
			os.close(fd)
	return False
