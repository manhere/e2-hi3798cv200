/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef E2_HISTB_VIDEO_ENTRY_H
#define E2_HISTB_VIDEO_ENTRY_H

#include <cstddef>
#include <cstdint>
#include <libavcodec/codec_id.h>

/* Scan past AUD, SEI and extensions; parameter sets or a usable picture can
 * occur later in the same PES. A non-entry unit must not reject the rest. */
inline bool histbVideoEntryPoint(AVCodecID codec, const uint8_t *es, size_t length)
{
	for (size_t i = 0; i + 3 < length; ++i)
	{
		if (es[i] || es[i + 1] || es[i + 2] != 1)
			continue;
		uint8_t code = es[i + 3];
		switch (codec)
		{
		case AV_CODEC_ID_MPEG2VIDEO:
		case AV_CODEC_ID_MPEG1VIDEO:
			if (code == 0xb3) return true;
			break;
		case AV_CODEC_ID_H264:
			if ((code & 0x1f) == 7 || (code & 0x1f) == 5) return true;
			break;
		case AV_CODEC_ID_HEVC:
		{
			int type = (code >> 1) & 0x3f;
			if ((type >= 16 && type <= 21) || type == 32 || type == 33) return true;
			break;
		}
		case AV_CODEC_ID_CAVS:
			if (code == 0xb0 || code == 0xb3) return true;
			break;
		default:
			return true;
		}
	}
	return false;
}
#endif
