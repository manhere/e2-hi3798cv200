"""HDMI hotplug recovery fed by kernel DRM uevents.

Adapted from manhere/enigma2-hi3798cv200 packaging/patches/0009 (OpenATV) to
the OpenPLi VideoHardware + HistbVideoModes KMS backend. The box exposes no
vendor hotplug procfs, so VideoHardware.on_hotplug never fires and a
replugged HDMI sink leaves E2 without video/PCM. This listener watches
NETLINK_KOBJECT_UEVENT for DRM HOTPLUG=1 messages, refreshes the EDID mode
list, reapplies the configured mode and restarts live DVB playback so the
decoder reopens video/PCM on the (re)connected sink.
"""
from pathlib import Path
from socket import AF_NETLINK, SOCK_DGRAM, socket

from enigma import eServiceReference, eTimer
from twisted.internet import reactor

from Components.config import config
from NavigationInstance import NavigationInstance

from Plugins.SystemPlugins.Videomode.HistbVideoModes import readEdidModes, applyMode


class HistbVideoHotplug:
	def __init__(self, hw):
		self.hw = hw
		self.sock = None
		self.timer = eTimer()
		self.timer.callback.append(self.refresh)
		self.state = self.readState()
		self.lastModes = tuple(readEdidModes())
		try:
			# Linux NETLINK_KOBJECT_UEVENT is not named by Python's socket module.
			self.sock = socket(AF_NETLINK, SOCK_DGRAM, 15)
			self.sock.bind((0, 1))
			self.sock.setblocking(False)
			reactor.addReader(self)
			print("[HistbVideoHotplug] listening for kernel DRM hotplug events.")
		except OSError as error:
			self.close()
			print("[HistbVideoHotplug] cannot monitor HDMI: %s" % error)

	def start(self):
		pass  # The listener is armed in __init__.

	def stop(self):
		self.close()

	def fileno(self):
		return self.sock.fileno() if self.sock else -1

	def logPrefix(self):
		return "HistbVideoHotplug"

	def doRead(self):
		while self.sock is not None:
			try:
				data, sender = self.sock.recvfrom(65536)
			except BlockingIOError:
				break
			fields = data.split(b"\0")
			if sender[0] == 0 and b"SUBSYSTEM=drm" in fields and b"HOTPLUG=1" in fields:
				# Coalesce one kernel hotplug burst; do not poll or retry modesets.
				self.timer.start(250, True)

	def connectionLost(self, failure=None):
		self.close()
		print("[HistbVideoHotplug] HDMI event monitor stopped: %s" % failure)

	def close(self):
		self.timer.stop()
		if self.sock is not None:
			reactor.removeReader(self)
			self.sock.close()
			self.sock = None

	@staticmethod
	def readState():
		state = []
		for path in sorted(Path("/sys/class/drm").glob("card*-HDMI-A-*/status")):
			try:
				state.append((str(path), path.read_text().strip(), path.with_name("edid").read_bytes()))
			except OSError as error:
				print("[HistbVideoHotplug] cannot read connector state: %s" % error)
		return tuple(state)

	def refresh(self):
		if self.hw is None:
			return
		state = self.readState()
		if state == self.state:
			return
		connected = any(status == "connected" for path, status, edid in state)
		wasConnected = any(status == "connected" for path, status, edid in self.state)
		self.state = state
		self.lastModes = tuple(readEdidModes())
		self.refreshModeConfig()
		self.hw.on_hotplug("HDMI")
		if not connected:
			print("[HistbVideoHotplug] HDMI disconnected; E2 keeps running.")
			return
		print("[HistbVideoHotplug] HDMI connected.")
		if not wasConnected:
			self.reapplyMode()

	def refreshModeConfig(self):
		# Rebuild the mode config from the fresh EDID while preserving the
		# current selections where they are still valid choices.
		hw = self.hw
		oldPort = config.av.videoport.value
		oldModes = dict((port, entry.value) for port, entry in config.av.videomode.items())
		oldRates = dict((mode, entry.value) for mode, entry in config.av.videorate.items())
		hw.readAvailableModes()
		hw.readPreferredModes()
		hw.widescreen_modes = set(["720p", "1080i", "1080p", "2160p", "2160p30"]).intersection(*[hw.modes_available])
		hw.createConfig()
		if oldPort in (config.av.videoport.choices or []):
			config.av.videoport.value = oldPort
		for port, value in oldModes.items():
			if port in config.av.videomode and value in config.av.videomode[port].choices:
				config.av.videomode[port].value = value
		for mode, value in oldRates.items():
			if mode in config.av.videorate and value in config.av.videorate[mode].choices:
				config.av.videorate[mode].value = value

	def reapplyMode(self):
		port = config.av.videoport.value
		mode = config.av.videomode[port].value if port in config.av.videomode else None
		if mode and mode in self.hw.modes_available and applyMode(mode):
			print("[HistbVideoHotplug] HDMI restored: %s." % mode)
			self.recoverPlayback()
			return
		fallback = next((m for m in self.hw.modes_available if m in ("1080p", "720p")), None)
		if fallback and applyMode(fallback):
			print("[HistbVideoHotplug] saved mode unavailable; fell back to %s." % fallback)
			self.recoverPlayback()
			return
		print("[HistbVideoHotplug] HDMI mode was rejected; E2 keeps running.")

	def recoverPlayback(self):
		# Recover live DVB video/PCM that opened while the sink was absent.
		# This restarts only live playback, not recordings or file playback.
		navigation = NavigationInstance.instance
		ref = navigation and navigation.getCurrentlyPlayingServiceReference()
		if ref is None or ref.type != eServiceReference.idDVB or ref.getPath():
			return
		service = navigation.getCurrentService()
		timeshift = service and service.timeshift()
		if timeshift and timeshift.isTimeshiftActive():
			print("[HistbVideoHotplug] preserving the active timeshift buffer; no service restart.")
			return
		navigation.restartService()
		print("[HistbVideoHotplug] live service restarted for the new sink.")
