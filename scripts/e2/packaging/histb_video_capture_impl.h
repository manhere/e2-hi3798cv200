/* SPDX-License-Identifier: GPL-2.0-only */
/* Included in HistbDrmOutput's private section. A screenshot borrows one
 * completed scanout frame; it must not guess DMA-BUF lifetime from GETFB2. */
static constexpr const char *captureSocketPath()
{
	return "/run/enigma2/histb-video-capture.sock";
}

ssize_t captureMessage(int client, char *buffer, size_t size)
{
	auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
	while (!m_capture_stop)
	{
		auto now = std::chrono::steady_clock::now();
		if (now >= deadline) return -1;
		int remaining = std::max(1, int(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count()));
		pollfd pfd = {client, POLLIN, 0};
		int ready = ::poll(&pfd, 1, std::min(remaining, 200));
		if (ready < 0 && errno == EINTR) continue;
		if (ready < 0 || (pfd.revents & (POLLERR | POLLHUP | POLLNVAL))) return -1;
		if (ready > 0 && (pfd.revents & POLLIN))
			return ::recv(client, buffer, size, MSG_DONTWAIT | MSG_TRUNC);
	}
	return -1;
}

void captureReplyError(int client, int error)
{
	char response[32];
	int length = snprintf(response, sizeof(response), "ERR %d\n", error);
	::send(client, response, length, MSG_NOSIGNAL | MSG_DONTWAIT);
}

void captureThread()
{
	AVFrame *held = nullptr;
	while (!m_capture_stop)
	{
		pollfd listener = {m_capture_fd, POLLIN, 0};
		int ready = ::poll(&listener, 1, 200);
		if (ready < 0 && errno == EINTR) continue;
		if (ready < 0 || (listener.revents & (POLLERR | POLLHUP | POLLNVAL))) break;
		if (!ready) continue;
		int client = ::accept4(m_capture_fd, nullptr, nullptr, SOCK_CLOEXEC | SOCK_NONBLOCK);
		if (client < 0) continue;
		struct ucred peer = {};
		socklen_t peerSize = sizeof(peer);
		char request[32];
		int error = 0;
		if (::getsockopt(client, SOL_SOCKET, SO_PEERCRED, &peer, &peerSize) || peer.uid != geteuid())
			error = EPERM;
		else if (captureMessage(client, request, sizeof(request)) != 17 || memcmp(request, "HISTB_CAPTURE_V1\n", 17))
			error = EPROTO;
		if (!error && !held)
		{
			held = av_frame_alloc();
			if (!held) error = ENOMEM;
		}
		if (!error)
		{
			std::lock_guard<std::mutex> frameLock(m_native_mutex);
			if (m_native_cancel || m_native_error || !m_native_direct_capture_ready || !m_scanout_frame || !m_scanout_frame->buf[0])
				error = ENODATA;
			else if (av_frame_ref(held, m_scanout_frame) < 0)
				error = ENOMEM;
		}
		if (!error)
		{
			const auto *desc = reinterpret_cast<const AVDRMFrameDescriptor *>(held->data[0]);
			if (!desc || desc->nb_objects != 1 || desc->nb_layers != 1 || desc->objects[0].fd < 0 ||
				desc->layers[0].nb_planes < 1 || desc->layers[0].nb_planes > 2 ||
				desc->layers[0].planes[0].object_index != 0 ||
				(desc->layers[0].nb_planes == 2 && desc->layers[0].planes[1].object_index != 0))
				error = ENOTSUP;
			uint32_t codedWidth = held->width, codedHeight = held->height;
			if (!error && desc->layers[0].format == DRM_FORMAT_YUV420_10BIT)
			{
				if (!nativeTiledGeometry(held, codedWidth, codedHeight)) error = EINVAL;
			}
			else if (!error && held->hw_frames_ctx)
			{
				const auto *frames = reinterpret_cast<const AVHWFramesContext *>(held->hw_frames_ctx->data);
				codedWidth = frames->width; codedHeight = frames->height;
			}
			if (!error)
			{
				const auto &layer = desc->layers[0];
				char response[384];
				int length = snprintf(response, sizeof(response),
					"HISTB_CAPTURE_V1 %d %d %u %llu %td %td %u %u %d %d %d %td %td\n",
					held->width, held->height, layer.format,
					(unsigned long long)desc->objects[0].format_modifier,
					layer.planes[0].pitch, layer.planes[0].offset, codedWidth, codedHeight,
					int(held->colorspace), int(held->color_range), layer.nb_planes,
					layer.nb_planes == 2 ? layer.planes[1].pitch : ptrdiff_t(0),
					layer.nb_planes == 2 ? layer.planes[1].offset : ptrdiff_t(0));
				if (length <= 0 || size_t(length) >= sizeof(response)) error = EOVERFLOW;
				else
				{
					char control[CMSG_SPACE(sizeof(int))] = {};
					iovec data = {response, size_t(length)};
					msghdr message = {};
					message.msg_iov = &data; message.msg_iovlen = 1;
					message.msg_control = control; message.msg_controllen = sizeof(control);
					cmsghdr *rights = CMSG_FIRSTHDR(&message);
					rights->cmsg_level = SOL_SOCKET; rights->cmsg_type = SCM_RIGHTS;
					rights->cmsg_len = CMSG_LEN(sizeof(int));
					memcpy(CMSG_DATA(rights), &desc->objects[0].fd, sizeof(int));
					if (::sendmsg(client, &message, MSG_NOSIGNAL | MSG_DONTWAIT) == length)
						captureMessage(client, request, sizeof(request));
				}
			}
		}
		if (error) captureReplyError(client, error);
		if (held) av_frame_unref(held);
		::close(client);
	}
	av_frame_free(&held);
}

void startCaptureServer()
{
	if (m_capture_fd >= 0) return;
	if (::mkdir("/run/enigma2", 0700) && errno != EEXIST)
	{
		eWarning("[histb-dec] capture directory unavailable: %m"); return;
	}
	struct stat directory = {};
	if (::stat("/run/enigma2", &directory) || !S_ISDIR(directory.st_mode) ||
		directory.st_uid != geteuid() || (directory.st_mode & 0022))
	{
		eWarning("[histb-dec] refusing unsafe capture directory"); return;
	}
	int fd = ::socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
	if (fd < 0) { eWarning("[histb-dec] capture socket unavailable: %m"); return; }
	sockaddr_un address = {};
	address.sun_family = AF_UNIX;
	snprintf(address.sun_path, sizeof(address.sun_path), "%s", captureSocketPath());
	struct stat stale = {};
	if (::lstat(captureSocketPath(), &stale) == 0 && S_ISSOCK(stale.st_mode) && stale.st_uid == geteuid())
	{
		int probe = ::socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
		if (probe >= 0)
		{
			int connected = ::connect(probe, reinterpret_cast<sockaddr *>(&address), sizeof(address));
			int connectError = errno;
			::close(probe);
			if (connected < 0 && connectError == ECONNREFUSED) ::unlink(captureSocketPath());
		}
	}
	if (::bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)))
	{
		eWarning("[histb-dec] capture socket bind failed: %m"); ::close(fd); return;
	}
	if (::chmod(captureSocketPath(), 0600) || ::listen(fd, 2))
	{
		eWarning("[histb-dec] capture socket setup failed: %m");
		::close(fd); ::unlink(captureSocketPath()); return;
	}
	m_capture_fd = fd;
	m_capture_stop = false;
	try { m_capture_thread = std::thread(&HistbDrmOutput::captureThread, this); }
	catch (const std::system_error &error)
	{
		eWarning("[histb-dec] capture worker unavailable: %s", error.what());
		::close(m_capture_fd); m_capture_fd = -1; ::unlink(captureSocketPath());
	}
}

void stopCaptureServer()
{
	m_capture_stop = true;
	if (m_capture_thread.joinable()) m_capture_thread.join();
	if (m_capture_fd >= 0)
	{
		::close(m_capture_fd); m_capture_fd = -1;
		::unlink(captureSocketPath());
	}
}

int m_capture_fd = -1;
std::thread m_capture_thread;
std::atomic<bool> m_capture_stop{true};
