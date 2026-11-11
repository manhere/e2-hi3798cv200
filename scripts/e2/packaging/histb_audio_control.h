/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef E2_HISTB_AUDIO_CONTROL_H
#define E2_HISTB_AUDIO_CONTROL_H
#include <atomic>
#include <cstdint>
#include <cstring>

/* External inline linkage shares one PCM gain across volume.cpp and the
 * decoder. The HDMI PCM has no legacy DVB mixer or ALSA Master control. */
struct HistbPcmControl
{
	std::atomic<uint64_t> gains{uint64_t(65536) << 32 | 65536};
	std::atomic<bool> muted{false};
};

inline HistbPcmControl &histbPcmControl()
{
	static HistbPcmControl control;
	return control;
}

inline uint32_t histbPcmGain(int volume)
{
	if (volume <= 0) return 0;
	if (volume >= 100) return 65536;
	/* HISTB replaces the ALSA percentage control on a raw HDMI PCM;
	 * the legacy DVB mixer's one-dB attenuation steps do not apply. */
	return uint32_t(volume) * 65536 / 100;
}

inline void histbSetPcmVolume(int left, int right)
{
	histbPcmControl().gains.store(uint64_t(histbPcmGain(left)) << 32 | histbPcmGain(right),
		std::memory_order_relaxed);
}

inline void histbSetPcmMute(bool mute)
{
	histbPcmControl().muted.store(mute, std::memory_order_relaxed);
}

inline void histbApplyPcmVolume(int16_t *samples, int frames)
{
	auto &control = histbPcmControl();
	uint64_t packed = control.gains.load(std::memory_order_relaxed);
	uint32_t left = uint32_t(packed >> 32), right = uint32_t(packed);
	if (control.muted.load(std::memory_order_relaxed)) left = right = 0;
	if (left == 65536 && right == 65536) return;
	if (!left && !right)
	{
		std::memset(samples, 0, size_t(frames) * 2 * sizeof(*samples));
		return;
	}
	for (int i = 0; i < frames; ++i)
	{
		samples[2 * i] = int16_t(int64_t(samples[2 * i]) * left / 65536);
		samples[2 * i + 1] = int16_t(int64_t(samples[2 * i + 1]) * right / 65536);
	}
}
#endif
