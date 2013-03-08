/**
 * Common code shared by SDL-based video drivers.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.ui.video.sdlcommon.video;

import core.thread;
import std.process : environment;

import derelict.sdl.sdl;

import ae.sys.desktop;
import ae.ui.video.video;
import ae.ui.app.application;
import ae.ui.shell.shell;
import ae.ui.shell.sdl.shell;
import ae.ui.video.renderer;

// On Windows, OpenGL commands must come from the same thread that initialized video,
// since SDL does not expose anything like wglMakeCurrent.
// However, on X11 (and probably other platforms) video initialization must happen in the main thread.
version (Windows)
	enum InitializeVideoInRenderThread = true;
else
	enum InitializeVideoInRenderThread = false;

class SDLCommonVideo : Video
{
	this()
	{
		starting = false;
		renderThread = new Thread(&renderThreadProc);
		renderThread.start();
	}

	override void shutdown()
	{
		stopping = quitting = true;
		renderThread.join();
	}

	override void start(Application application)
	{
		configure(application);

		static if (!InitializeVideoInRenderThread)
			initialize();

		started = stopping = false;
		starting = true;
		while (!started) wait();
	}

	override void stop()
	{
		stopped = false;
		stopping = true;
		while (!stopped) wait();
	}

	override void stopAsync(AppCallback callback)
	{
		stopCallback = callback;
		stopped = false;
		stopping = true;
	}

	override void getScreenSize(out uint width, out uint height)
	{
		width = screenWidth;
		height = screenHeight;
	}

protected:
	abstract uint getSDLFlags();
	abstract Renderer getRenderer();
	void prepare() {}

private:
	void wait()
	{
		if (error)
			renderThread.join(); // collect exception
		SDL_Delay(1);
		SDL_PumpEvents();
	}

	uint screenWidth, screenHeight, flags;
	bool firstStart = true;

	final void configure(Application application)
	{
		flags = getSDLFlags();

		auto settings = application.getShellSettings();

		string windowPos;
		bool centered;

		final switch (settings.screenMode)
		{
			case ScreenMode.windowed:
				screenWidth  = settings.windowSizeX;
				screenHeight = settings.windowSizeY;
				// Since SDL 1.x does not provide a way to track window coordinates,
				// just center the window
				if (firstStart)
				{
					// Center the window only on start-up.
					// We do not want to center the window if
					// e.g. the user resized it.
					centered = true;
				}
				break;
			case ScreenMode.maximized:
				// not supported - use windowed
				goto case ScreenMode.windowed;
			case ScreenMode.fullscreen:
				screenWidth  = settings.fullScreenX;
				screenHeight = settings.fullScreenY;
				flags |= SDL_FULLSCREEN;
				break;
			case ScreenMode.windowedFullscreen:
				// TODO: use SDL_GetVideoInfo
				static if (is(typeof(getDesktopResolution)))
				{
					getDesktopResolution(screenWidth, screenHeight);
					flags |= SDL_NOFRAME;
					windowPos = "0,0";
				}
				else
				{
					// not supported - use fullscreen
					goto case ScreenMode.fullscreen;
				}
				break;
		}

		if (application.isResizable())
			flags |= SDL_RESIZABLE;

		if (windowPos)
			environment["SDL_VIDEO_WINDOW_POS"] = windowPos;
		else
			environment.remove("SDL_VIDEO_WINDOW_POS");

		if (centered)
			environment["SDL_VIDEO_CENTERED"] = "1";
		else
			environment.remove("SDL_VIDEO_CENTERED");

		renderCallback.bind(&application.render);

		firstStart = false;
	}

	final void initialize()
	{
		prepare();
		sdlEnforce(SDL_SetVideoMode(screenWidth, screenHeight, 32, flags), "can't set video mode");
	}

	Thread renderThread;
	shared bool starting, started, stopping, stopped, quitting, quit, error;
	AppCallback stopCallback;
	AppCallbackEx!(Renderer) renderCallback;

	final void renderThreadProc()
	{
		scope(failure) error = true;

		// SDL expects that only one thread across the program's lifetime will do OpenGL initialization.
		// Thus, re-initialization must happen from only one thread.
		// This thread sleeps and polls while it's not told to run.
	outer:
		while (!quitting)
		{
			while (!starting)
			{
				// TODO: use proper semaphores
				if (quitting) return;
				SDL_Delay(1);
			}
			started = true;
			starting = false;

			scope(failure) if (errorCallback) try { errorCallback.call(); } catch {}

			static if (InitializeVideoInRenderThread)
				initialize();

			auto renderer = getRenderer();
			while (!stopping)
			{
				// TODO: predict flip (vblank wait) duration and render at the last moment
				renderCallback.call(renderer);
				renderer.present();
			}
			renderer.shutdown();
			if (stopCallback)
				stopCallback.call();
			stopped = true;
			stopping = false;
		}
	}
}
