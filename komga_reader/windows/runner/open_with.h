#ifndef RUNNER_OPEN_WITH_H_
#define RUNNER_OPEN_WITH_H_

#include <windows.h>

#include <optional>
#include <string>

// A book file opened with the app (Explorer's Open with) while the app is already open: this start hands the file to
// the window open and ends (user, 2026-10-27: "use the open window"); that window passes it on to the app
// (lib/open_with.dart, the "komga_reader/open_with" channel - flutter_window.cpp). One app per exe: BeDeReader and
// BeDeReader Exp each have their own.
namespace open_with {

// The file this start was given (Open with's: the first argument), or "" for none.
std::wstring FileArgument();

// Called first thing: true if this app is open already and has taken [file] - this start ends. False: this start
// goes on (the first; or one given no file, which starts a window of its own as before).
bool HandOver(const std::wstring& file);

// The window of the first start, made: later starts hand their files to it.
void Publish(HWND window);

// A WM_COPYDATA's file from a later start; nothing if it isn't one.
std::optional<std::wstring> Received(LPARAM lparam);

}  // namespace open_with

#endif  // RUNNER_OPEN_WITH_H_
