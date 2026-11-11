#ifndef E2_HISTB_DRM_H
#define E2_HISTB_DRM_H

#include <algorithm>
#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <linux/fb.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>
#include <lib/base/eerror.h>

/* The CPU canvas owns a separate, non-master DRM file. Its framebuffer ID is
 * device-global; the connected KMS master can scan out the very same GEM. */
struct HistbDrmCanvas
{
	int fd = -1;
	uint32_t handle = 0, fb = 0;
	uint32_t width = 0, height = 0, pitch = 0;
	uint64_t size = 0;
	unsigned char *map = nullptr;
	dev_t device = 0;
};

/* One KMS file/master per process, shared by AVControl, UI and decoder.
 * dup() preserves DRM-file identity; separately open()ing card0 does not.
 * All KMS commits hold mutex through completion, including page-flip events. */
struct HistbDrmSession
{
	std::mutex mutex;
	int fd = -1;
	uint32_t connector = 0, crtc = 0, primary = 0;
	/* Backing allocation/stride remain native; sourceW/H are skin pixels. */
	uint32_t sourceW = 0, sourceH = 0;
	uint32_t framebufferW = 0, framebufferH = 0, sourcePitch = 0;
	uint32_t osdFb = 0;
	HistbDrmCanvas canvas;
	double refreshPeriodUs = 0.0;
};

inline double histbDrmModePeriodUs(const drmModeModeInfo &mode)
{
	if (!mode.clock || !mode.htotal || !mode.vtotal) return 0.0;
	double period = 1000.0 * mode.htotal * mode.vtotal / mode.clock;
	if (mode.flags & DRM_MODE_FLAG_INTERLACE) period /= 2;
	if (mode.flags & DRM_MODE_FLAG_DBLSCAN) period *= 2;
	if (mode.vscan > 1) period *= mode.vscan;
	return period;
}


/* External inline linkage is intentional: the function-local session must be
 * shared across decoder.cpp, avcontrol.cpp and fb.cpp, not one per TU. */
inline HistbDrmSession &histbDrmSession()
{
	static HistbDrmSession session;
	return session;
}

/* Caller holds session.mutex. Allocate UI memory, not a mode or a sink.
 * Drop the automatic master before keeping an allocation file open so that
 * kernel fbdev hotplug can still initialize the first physical output. */
inline bool histbOsdCreateCanvas()
{
	auto &s = histbDrmSession();
	if (s.canvas.fd >= 0) return false;
	for (int card = 0; card < 8; ++card)
	{
		char path[32];
		snprintf(path, sizeof(path), "/dev/dri/card%d", card);
		HistbDrmCanvas canvas;
		canvas.fd = open(path, O_RDWR | O_CLOEXEC);
		if (canvas.fd < 0) continue;
		drmVersionPtr version = drmGetVersion(canvas.fd);
		bool vdp = version && version->name && !strcmp(version->name, "histb-vdp");
		if (version) drmFreeVersion(version);
		struct stat device = {}, connected = {};
		uint64_t dumb = 0;
		bool usable = vdp && fstat(canvas.fd, &device) == 0 &&
			(s.fd < 0 || (fstat(s.fd, &connected) == 0 && connected.st_rdev == device.st_rdev)) &&
			(!drmIsMaster(canvas.fd) || drmDropMaster(canvas.fd) == 0) &&
			drmGetCap(canvas.fd, DRM_CAP_DUMB_BUFFER, &dumb) == 0 && dumb;
		if (!usable) { close(canvas.fd); continue; }
		struct drm_mode_create_dumb create = {};
		create.width = 1920; create.height = 1080; create.bpp = 32;
		if (drmIoctl(canvas.fd, DRM_IOCTL_MODE_CREATE_DUMB, &create) != 0)
		{
			eWarning("[histb-drm] cannot allocate offscreen OSD on %s: %s", path, strerror(errno));
			close(canvas.fd);
			continue;
		}
		canvas.handle = create.handle;
		canvas.width = create.width; canvas.height = create.height;
		canvas.pitch = create.pitch; canvas.size = create.size;
		canvas.device = device.st_rdev;
		struct drm_mode_map_dumb mapping = {};
		mapping.handle = canvas.handle;
		bool ok = canvas.pitch >= uint64_t(canvas.width) * 4 &&
			canvas.size >= uint64_t(canvas.pitch) * canvas.height && canvas.size <= INT_MAX &&
			drmIoctl(canvas.fd, DRM_IOCTL_MODE_MAP_DUMB, &mapping) == 0;
		if (ok)
		{
			canvas.map = static_cast<unsigned char *>(mmap(nullptr, canvas.size,
				PROT_READ | PROT_WRITE, MAP_SHARED, canvas.fd, mapping.offset));
			if (canvas.map == MAP_FAILED) { canvas.map = nullptr; ok = false; }
		}
		if (ok)
		{
			uint32_t handles[4] = {canvas.handle, 0, 0, 0};
			uint32_t pitches[4] = {canvas.pitch, 0, 0, 0}, offsets[4] = {};
			ok = drmModeAddFB2(canvas.fd, canvas.width, canvas.height, DRM_FORMAT_ARGB8888,
				handles, pitches, offsets, &canvas.fb, 0) == 0;
		}
		if (!ok)
		{
			eWarning("[histb-drm] cannot map/register offscreen OSD on %s: %s", path, strerror(errno));
			if (canvas.map) munmap(canvas.map, canvas.size);
			struct drm_mode_destroy_dumb destroy = {};
			destroy.handle = canvas.handle;
			drmIoctl(canvas.fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
			close(canvas.fd);
			continue;
		}
		memset(canvas.map, 0, canvas.size);
		s.canvas = canvas;
		s.framebufferW = canvas.width; s.framebufferH = canvas.height; s.sourcePitch = canvas.pitch;
		s.sourceW = canvas.width; s.sourceH = canvas.height;
		eDebug("[histb-drm] offscreen ARGB8888 OSD %ux%u stride %u size %llu FB %u on %s (non-master)",
			canvas.width, canvas.height, canvas.pitch, (unsigned long long)canvas.size, canvas.fb, path);
		return true;
	}
	return false;
}

inline bool histbOsdReleaseCanvas()
{
	auto &s = histbDrmSession();
	std::lock_guard<std::mutex> lock(s.mutex);
	auto &canvas = s.canvas;
	if (canvas.fd < 0) return true;
	/* RMFB must use the creating file. It synchronously removes scanout
	 * references; the kernel retains GEM references for any driver-held FB.
	 * Never unmap/close our ownership if the removal ioctl itself fails. */
	if (drmModeRmFB(canvas.fd, canvas.fb) != 0)
	{
		eWarning("[histb-drm] retaining OSD FB %u and GEM ownership after RMFB failure: %s", canvas.fb, strerror(errno));
		return false;
	}
	if (s.osdFb == canvas.fb) { s.osdFb = 0; s.primary = 0; }
	munmap(canvas.map, canvas.size);
	struct drm_mode_destroy_dumb destroy = {};
	destroy.handle = canvas.handle;
	if (drmIoctl(canvas.fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy) != 0)
		eWarning("[histb-drm] OSD handle release failed: %s", strerror(errno));
	close(canvas.fd);
	canvas = HistbDrmCanvas();
	s.framebufferW = s.framebufferH = s.sourcePitch = s.sourceW = s.sourceH = 0;
	return true;
}

inline uint32_t histbDrmProperty(int fd, uint32_t object, uint32_t type,
	const char *name, uint64_t *value = nullptr)
{
	uint32_t id = 0;
	drmModeObjectPropertiesPtr props = drmModeObjectGetProperties(fd, object, type);
	if (!props)
		return 0;
	for (uint32_t i = 0; i < props->count_props; ++i)
	{
		drmModePropertyPtr p = drmModeGetProperty(fd, props->props[i]);
		if (p && !strcmp(p->name, name))
		{
			id = p->prop_id;
			if (value) *value = props->prop_values[i];
		}
		if (p) drmModeFreeProperty(p);
		if (id) break;
	}
	drmModeFreeObjectProperties(props);
	return id;
}

/* Caller holds session.mutex. Only connected HDMI acquires a persistent
 * master; a disconnected probe must leave kernel hotplug ownership alone. */
inline int histbDrmOpen(drmModeConnection *connection = nullptr)
{
	auto &s = histbDrmSession();
	if (connection) *connection = DRM_MODE_UNKNOWNCONNECTION;
	if (s.fd >= 0)
	{
		drmModeConnectorPtr connector = drmModeGetConnector(s.fd, s.connector);
		bool usable = connector && connector->connection == DRM_MODE_CONNECTED && connector->count_modes;
		if (connection && connector) *connection = connector->connection;
		if (connector) drmModeFreeConnector(connector);
		/* Keep the connected session's object ownership, but never report
		 * an old active CRTC as a physical output after unplugging HDMI. */
		return usable ? s.fd : -1;
	}
	bool disconnected = false, otherConnection = false;
	for (int card = 0; card < 8; ++card)
	{
		char path[32];
		snprintf(path, sizeof(path), "/dev/dri/card%d", card);
		int fd = open(path, O_RDWR | O_CLOEXEC);
		if (fd < 0) continue;
		if (s.canvas.fd >= 0)
		{
			struct stat device = {};
			if (fstat(fd, &device) != 0 || device.st_rdev != s.canvas.device) { close(fd); continue; }
		}
		drmModeResPtr res = drmModeGetResources(fd);
		if (!res) { close(fd); continue; }
		for (int i = 0; i < res->count_connectors; ++i)
		{
			drmModeConnectorPtr c = drmModeGetConnector(fd, res->connectors[i]);
			if (!c) { otherConnection = true; continue; }
			bool hdmi = c->connector_type == DRM_MODE_CONNECTOR_HDMIA || c->connector_type == DRM_MODE_CONNECTOR_HDMIB;
			if (hdmi)
			{
				disconnected |= c->connection == DRM_MODE_DISCONNECTED;
				otherConnection |= c->connection != DRM_MODE_DISCONNECTED;
			}
			if (hdmi && c->connection == DRM_MODE_CONNECTED && c->count_modes && res->count_crtcs)
			{
				uint32_t crtc = 0;
				drmModeEncoderPtr enc = c->encoder_id ? drmModeGetEncoder(fd, c->encoder_id) : nullptr;
				if (enc) { crtc = enc->crtc_id; drmModeFreeEncoder(enc); }
				/* CV200 has one display pipeline. */
				if (!crtc && res->count_crtcs == 1) crtc = res->crtcs[0];
				if (crtc && drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) == 0 &&
					drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1) == 0 &&
					(drmIsMaster(fd) || drmSetMaster(fd) == 0))
				{
					s.fd = fd; s.connector = c->connector_id; s.crtc = crtc;
					if (connection) *connection = DRM_MODE_CONNECTED;
					drmModeFreeConnector(c); drmModeFreeResources(res);
					return fd;
				}
			}
			drmModeFreeConnector(c);
		}
		drmModeFreeResources(res);
		close(fd);
	}
	if (connection && disconnected && !otherConnection) *connection = DRM_MODE_DISCONNECTED;
	return -1;
}


inline bool histbDrmAdd(drmModeAtomicReqPtr req, uint32_t obj, uint32_t type,
	const char *name, uint64_t value)
{
	auto &s = histbDrmSession();
	uint32_t id = histbDrmProperty(s.fd, obj, type, name);
	return id && drmModeAtomicAddProperty(req, obj, id, value) >= 0;
}

inline bool histbDrmSameMode(const drmModeModeInfo &a, const drmModeModeInfo &b)
{
	return a.clock == b.clock && a.hdisplay == b.hdisplay &&
		a.hsync_start == b.hsync_start && a.hsync_end == b.hsync_end && a.htotal == b.htotal &&
		a.vdisplay == b.vdisplay && a.vsync_start == b.vsync_start &&
		a.vsync_end == b.vsync_end && a.vtotal == b.vtotal && a.flags == b.flags && a.vscan == b.vscan;
}

/* Caller holds mutex. GP0 scales the skin directly from its real GEM backing.
 * Never disable another graphics input to evade the shared-group constraint,
 * or copy video/OSD pixels to conceal a rejected hardware configuration. */
inline bool histbDrmSetMode(const drmModeModeInfo &mode)
{
	auto &s = histbDrmSession();
	if (histbDrmOpen() < 0) return false;
	if (s.canvas.fd >= 0 && (!s.canvas.fb || s.framebufferW != s.canvas.width ||
		s.framebufferH != s.canvas.height || s.sourcePitch != s.canvas.pitch)) return false;
	if (!s.framebufferW)
	{
		int fb = open("/dev/fb0", O_RDWR | O_CLOEXEC);
		fb_var_screeninfo v = {}; fb_fix_screeninfo f = {};
		if (fb < 0) return false;
		bool valid = ioctl(fb, FBIOGET_VSCREENINFO, &v) == 0 && ioctl(fb, FBIOGET_FSCREENINFO, &f) == 0 &&
			v.bits_per_pixel == 32 && v.xoffset == 0 && v.yoffset == 0 &&
			f.line_length >= v.xres * 4 && uint64_t(f.line_length) * v.yres <= f.smem_len;
		close(fb);
		if (!valid) return false;
		s.framebufferW = v.xres; s.framebufferH = v.yres; s.sourcePitch = f.line_length;
		if (!s.sourceW) { s.sourceW = v.xres; s.sourceH = v.yres; }
	}
	if (!s.sourceW || !s.sourceH || s.sourceW > s.framebufferW || s.sourceH > s.framebufferH)
		return false;
	drmModeCrtcPtr before = drmModeGetCrtc(s.fd, s.crtc);
	drmModePlaneResPtr planes = drmModeGetPlaneResources(s.fd);
	if (!before || (!before->mode_valid && s.canvas.fd < 0) || !planes)
	{
		if (before) drmModeFreeCrtc(before);
		if (planes) drmModeFreePlaneResources(planes);
		return false;
	}
	uint32_t crtcMask = 0;
	drmModeResPtr resources = drmModeGetResources(s.fd);
	if (resources)
	{
		for (int i = 0; i < resources->count_crtcs && i < 32; ++i)
			if (resources->crtcs[i] == s.crtc) crtcMask = uint32_t(1) << i;
		drmModeFreeResources(resources);
	}
	uint32_t primary = 0, currentFb = 0;
	for (uint32_t i = 0; i < planes->count_planes; ++i)
	{
		drmModePlanePtr p = drmModeGetPlane(s.fd, planes->planes[i]);
		uint64_t type = 0;
		if (p && ((p->crtc_id == s.crtc && p->fb_id) ||
			(s.canvas.fd >= 0 && (p->possible_crtcs & crtcMask))) &&
			histbDrmProperty(s.fd, p->plane_id, DRM_MODE_OBJECT_PLANE, "type", &type) && type == DRM_PLANE_TYPE_PRIMARY)
		{ primary = p->plane_id; currentFb = p->fb_id; }
		if (p) drmModeFreePlane(p);
	}
	uint32_t fb = s.canvas.fd >= 0 ? s.canvas.fb : s.osdFb;
	if (primary && !fb)
	{
		drmModeFBPtr old = drmModeGetFB(s.fd, currentFb);
		if (old && old->handle)
		{
			uint32_t handles[4] = {old->handle, 0, 0, 0}, pitches[4] = {old->pitch, 0, 0, 0}, offsets[4] = {};
			if (old->width == s.framebufferW && old->height >= s.framebufferH && old->pitch == s.sourcePitch)
				drmModeAddFB2(s.fd, s.framebufferW, s.framebufferH, DRM_FORMAT_ARGB8888, handles, pitches, offsets, &fb, 0);
			drmCloseBufferHandle(s.fd, old->handle);
		}
		if (old) drmModeFreeFB(old);
	}
	uint32_t blob = 0, previousBlob = 0;
	drmModeAtomicReqPtr req = drmModeAtomicAlloc(), rollback = drmModeAtomicAlloc();
	bool ok = primary && fb && req && rollback &&
		drmModeCreatePropertyBlob(s.fd, &mode, sizeof(mode), &blob) == 0 &&
		(!before->mode_valid || drmModeCreatePropertyBlob(s.fd, &before->mode, sizeof(before->mode), &previousBlob) == 0);
	auto add = [&](uint32_t obj, uint32_t type, const char *name, uint64_t value) {
		uint64_t old = 0;
		uint32_t id = histbDrmProperty(s.fd, obj, type, name, &old);
		if (obj == s.crtc && !strcmp(name, "MODE_ID")) old = previousBlob;
		return id && drmModeAtomicAddProperty(rollback, obj, id, old) >= 0 &&
			drmModeAtomicAddProperty(req, obj, id, value) >= 0;
	};
	if (ok) ok = add(s.connector, DRM_MODE_OBJECT_CONNECTOR, "CRTC_ID", s.crtc) &&
		add(s.crtc, DRM_MODE_OBJECT_CRTC, "MODE_ID", blob) && add(s.crtc, DRM_MODE_OBJECT_CRTC, "ACTIVE", 1);
	for (uint32_t i = 0; i < planes->count_planes && ok; ++i)
	{
		drmModePlanePtr p = drmModeGetPlane(s.fd, planes->planes[i]);
		if (!p) { ok = false; break; }
		if (p->plane_id == primary)
		{
			ok = add(primary, DRM_MODE_OBJECT_PLANE, "FB_ID", fb) &&
				add(primary, DRM_MODE_OBJECT_PLANE, "CRTC_ID", s.crtc) &&
				add(primary, DRM_MODE_OBJECT_PLANE, "SRC_X", 0) && add(primary, DRM_MODE_OBJECT_PLANE, "SRC_Y", 0) &&
				add(primary, DRM_MODE_OBJECT_PLANE, "SRC_W", uint64_t(s.sourceW) << 16) &&
				add(primary, DRM_MODE_OBJECT_PLANE, "SRC_H", uint64_t(s.sourceH) << 16) &&
				add(primary, DRM_MODE_OBJECT_PLANE, "CRTC_X", 0) && add(primary, DRM_MODE_OBJECT_PLANE, "CRTC_Y", 0) &&
				add(primary, DRM_MODE_OBJECT_PLANE, "CRTC_W", mode.hdisplay) &&
				add(primary, DRM_MODE_OBJECT_PLANE, "CRTC_H", mode.vdisplay);
			if (histbDrmProperty(s.fd, primary, DRM_MODE_OBJECT_PLANE, "pixel blend mode"))
				ok = ok && add(primary, DRM_MODE_OBJECT_PLANE, "pixel blend mode", 1);
		}
		else if (p->crtc_id == s.crtc && p->fb_id)
		{
			bool graphics = false;
			for (uint32_t j = 0; j < p->count_formats; ++j)
				if (p->formats[j] == DRM_FORMAT_ARGB8888 || p->formats[j] == DRM_FORMAT_XRGB8888) graphics = true;
			/* Keep every source/crop/buffer unchanged. V1 has no scaler: the
			 * kernel must reject a destination resize it cannot implement. */
			if (!graphics && before->mode_valid)
			{
				const char *names[] = {"CRTC_X", "CRTC_Y", "CRTC_W", "CRTC_H"};
				for (int j = 0; j < 4 && ok; ++j)
				{
					uint64_t value = 0;
					ok = histbDrmProperty(s.fd, p->plane_id, DRM_MODE_OBJECT_PLANE, names[j], &value);
					int64_t scaled = int64_t(value) * (j % 2 ? mode.vdisplay : mode.hdisplay) /
						(j % 2 ? before->mode.vdisplay : before->mode.hdisplay);
					ok = ok && add(p->plane_id, DRM_MODE_OBJECT_PLANE, names[j], uint64_t(scaled));
				}
			}
		}
		drmModeFreePlane(p);
	}
	if (ok) ok = drmModeAtomicCommit(s.fd, req, DRM_MODE_ATOMIC_TEST_ONLY | DRM_MODE_ATOMIC_ALLOW_MODESET, nullptr) == 0;
	if (ok) ok = drmModeAtomicCommit(s.fd, req, DRM_MODE_ATOMIC_ALLOW_MODESET, nullptr) == 0;
	if (ok)
	{
		drmModeCrtcPtr actual = drmModeGetCrtc(s.fd, s.crtc);
		ok = actual && actual->mode_valid && histbDrmSameMode(mode, actual->mode);
		if (actual && actual->mode_valid) s.refreshPeriodUs = histbDrmModePeriodUs(actual->mode);
		if (actual) drmModeFreeCrtc(actual);
		const char *names[] = {"FB_ID", "SRC_X", "SRC_Y", "SRC_W", "SRC_H", "CRTC_X", "CRTC_Y", "CRTC_W", "CRTC_H"};
		uint64_t expected[] = {fb, 0, 0, uint64_t(s.sourceW) << 16, uint64_t(s.sourceH) << 16, 0, 0, mode.hdisplay, mode.vdisplay};
		for (unsigned int i = 0; i < sizeof(expected) / sizeof(expected[0]) && ok; ++i)
		{
			uint64_t value = 0;
			ok = histbDrmProperty(s.fd, primary, DRM_MODE_OBJECT_PLANE, names[i], &value) && value == expected[i];
		}
		if (!ok)
		{
			eWarning("[histb-drm] mode readback mismatch; restoring prior KMS state");
			if (drmModeAtomicCommit(s.fd, rollback, DRM_MODE_ATOMIC_ALLOW_MODESET, nullptr) != 0)
			{
				// Retain the alias if it might still be bound: RMFB would blank it.
				s.osdFb = fb; s.primary = primary;
				eWarning("[histb-drm] KMS rollback failed: %s", strerror(errno));
			}
			else s.refreshPeriodUs = histbDrmModePeriodUs(before->mode);
		}
	}
	if (ok)
	{
		s.osdFb = fb; s.primary = primary;
		s.refreshPeriodUs = histbDrmModePeriodUs(mode);
		eDebug("[histb-drm] GP0 %ux%u stride %u -> %ux%u@%u", s.sourceW, s.sourceH, s.sourcePitch, mode.hdisplay, mode.vdisplay, mode.vrefresh);
	}
	else eWarning("[histb-drm] rejected %s@%u, GP0 %ux%u: %s", mode.name, mode.vrefresh, s.sourceW, s.sourceH, strerror(errno));
	if (req) drmModeAtomicFree(req);
	if (rollback) drmModeAtomicFree(rollback);
	if (blob) drmModeDestroyPropertyBlob(s.fd, blob);
	if (previousBlob) drmModeDestroyPropertyBlob(s.fd, previousBlob);
	if (fb && fb != s.osdFb && fb != s.canvas.fb) drmModeRmFB(s.fd, fb);
	drmModeFreePlaneResources(planes);
	drmModeFreeCrtc(before);
	return ok;
}

/* Register the exact mapped backing, whether fbdev or the offscreen GEM.
 * No HDMI sink defers presentation only; connected commit errors still fail. */
inline bool histbOsdSetGeometry(uint32_t width, uint32_t height,
	uint32_t backingWidth, uint32_t backingHeight, uint32_t pitch)
{
	auto &s = histbDrmSession();
	std::lock_guard<std::mutex> lock(s.mutex);
	if (!width || !height || width > backingWidth || height > backingHeight || uint64_t(pitch) < uint64_t(backingWidth) * 4 ||
		(s.canvas.fd >= 0 && (backingWidth != s.canvas.width || backingHeight != s.canvas.height || pitch != s.canvas.pitch)))
		return false;
	uint32_t oldW = s.sourceW, oldH = s.sourceH;
	uint32_t oldBackingW = s.framebufferW, oldBackingH = s.framebufferH, oldPitch = s.sourcePitch;
	s.sourceW = width; s.sourceH = height;
	s.framebufferW = backingWidth; s.framebufferH = backingHeight; s.sourcePitch = pitch;
	drmModeConnection connection;
	int fd = histbDrmOpen(&connection);
	if (connection == DRM_MODE_DISCONNECTED)
	{
		eDebug("[histb-drm] HDMI disconnected; real OSD canvas %ux%u remains available without an active output", width, height);
		return true;
	}
	bool ok = false;
	if (fd >= 0 && connection == DRM_MODE_CONNECTED)
	{
		drmModeCrtcPtr crtc = drmModeGetCrtc(s.fd, s.crtc);
		if (crtc && crtc->mode_valid) ok = histbDrmSetMode(crtc->mode);
		else if (crtc && s.canvas.fd >= 0)
		{
			/* A first real connection need not have an fbdev CRTC yet. Use
			 * only a timing actually advertised by that connected sink. */
			drmModeConnectorPtr connector = drmModeGetConnector(s.fd, s.connector);
			uint64_t edid = 0;
			if (connector && connector->connection == DRM_MODE_CONNECTED && connector->count_modes &&
				histbDrmProperty(s.fd, connector->connector_id, DRM_MODE_OBJECT_CONNECTOR, "EDID", &edid) && edid)
			{
				int preferred = 0;
				for (int i = 0; i < connector->count_modes; ++i)
					if (connector->modes[i].type & DRM_MODE_TYPE_PREFERRED) { preferred = i; break; }
				ok = histbDrmSetMode(connector->modes[preferred]);
			}
			if (connector) drmModeFreeConnector(connector);
		}
		if (crtc) drmModeFreeCrtc(crtc);
	}
	if (!ok)
	{
		s.sourceW = oldW; s.sourceH = oldH;
		s.framebufferW = oldBackingW; s.framebufferH = oldBackingH; s.sourcePitch = oldPitch;
	}
	return ok;
}

inline bool histbEnsureOsd()
{
	auto &s = histbDrmSession();
	if (s.osdFb && s.primary)
	{
		drmModePlanePtr plane = drmModeGetPlane(s.fd, s.primary);
		bool bound = plane && plane->crtc_id == s.crtc && plane->fb_id == s.osdFb;
		if (plane) drmModeFreePlane(plane);
		if (bound) return true;
	}
	drmModeCrtcPtr crtc = drmModeGetCrtc(s.fd, s.crtc);
	if (!crtc) return false;
	bool ok = crtc->mode_valid && histbDrmSetMode(crtc->mode);
	drmModeFreeCrtc(crtc);
	return ok;
}
#endif
