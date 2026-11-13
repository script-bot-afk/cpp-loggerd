
@echo off
setlocal EnableExtensions
title GlobalMonitor - All-in-One
cd /d "%~dp0"

set "ROOT=%~dp0GlobalMonitor"
set "VCPKG_ROOT=%USERPROFILE%\vcpkg"

echo ============================================
echo          GLOBAL MONITOR v6.1
echo          ALL-IN-ONE BUILDER
echo ============================================
echo.

:: Check required build tools
where git >nul 2>&1
if errorlevel 1 (
    echo Git is missing.
    echo Install Git for Windows, then rerun this file.
    pause
    exit /b 1
)

where cmake >nul 2>&1
if errorlevel 1 (
    echo CMake is missing.
    echo Install CMake, then rerun this file.
    pause
    exit /b 1
)

where cl >nul 2>&1
if errorlevel 1 (
    echo MSVC compiler is missing from PATH.
    echo Run this file from a Visual Studio Developer Command Prompt.
    pause
    exit /b 1
)

:: Create project directories
echo [1/6] Creating project...
if not exist "%ROOT%" mkdir "%ROOT%"
if not exist "%ROOT%\src" mkdir "%ROOT%\src"

:: Generate vcpkg manifest
echo [2/6] Generating dependency manifest...

(
echo {
echo   "name": "global-monitor",
echo   "version": "6.1.0",
echo   "dependencies": ["sqlite3"]
echo }
) > "%ROOT%\vcpkg.json"

:: Generate CMake configuration
(
echo cmake_minimum_required^(VERSION 3.24^)
echo project^(GlobalMonitor LANGUAGES CXX^)
echo set^(CMAKE_CXX_STANDARD 20^)
echo set^(CMAKE_CXX_STANDARD_REQUIRED ON^)
echo find_package^(unofficial-sqlite3 CONFIG REQUIRED^)
echo add_executable^(GlobalMonitor src/main.cpp^)
echo target_compile_definitions^(GlobalMonitor PRIVATE UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX^)
echo target_link_libraries^(GlobalMonitor PRIVATE unofficial::sqlite3::sqlite3 user32^)
) > "%ROOT%\CMakeLists.txt"

:: Generate C++ source
echo [3/6] Generating C++ source...

(
echo #include ^<windows.h^>
echo #include ^<tlhelp32.h^>
echo #include ^<sqlite3.h^>
echo #include ^<iostream^>
echo #include ^<string^>
echo #include ^<chrono^>
echo #include ^<thread^>
echo #include ^<atomic^>
echo #include ^<mutex^>
echo #include ^<cstdlib^>
echo.
echo namespace {
echo std::atomic<unsigned long long^> keyboard_total{0};
echo std::atomic<unsigned long long^> keyboard_interval{0};
echo std::atomic<bool^> paused{false};
echo sqlite3* database = nullptr;
echo std::mutex database_mutex;
echo.
echo bool execute_sql^(const char* sql^) {
echo     return sqlite3_exec^(database, sql, nullptr, nullptr, nullptr^) == SQLITE_OK;
echo }
echo.
echo bool initialize_database^(^) {
echo     if ^(sqlite3_open^("telemetry.db", ^&database^) != SQLITE_OK^) return false;
echo     sqlite3_busy_timeout^(database, 3000^);
echo     return execute_sql^(
echo         "PRAGMA journal_mode=WAL;"
echo         "CREATE TABLE IF NOT EXISTS keyboard_stats("
echo         "timestamp INTEGER,event_count INTEGER,"
echo         "events_per_second REAL,foreground_app TEXT^);"
echo         "CREATE TABLE IF NOT EXISTS telemetry("
echo         "timestamp INTEGER,cpu REAL,memory REAL,process_count INTEGER^);"
echo     ^);
echo }
echo.
echo void save_keyboard^(unsigned long long count, const std::string^& app^) {
echo     std::lock_guard^<std::mutex^> lock^(database_mutex^);
echo     sqlite3_stmt* stmt = nullptr;
echo     const char* sql = "INSERT INTO keyboard_stats VALUES^(?,?,?,?^);";
echo     if ^(sqlite3_prepare_v2^(database, sql, -1, ^&stmt, nullptr^) != SQLITE_OK^) return;
echo     sqlite3_bind_int64^(stmt, 1, static_cast^<sqlite3_int64^>^(time^(nullptr^)^)^);
echo     sqlite3_bind_int64^(stmt, 2, count^);
echo     sqlite3_bind_double^(stmt, 3, static_cast^<double^>^(count^)^);
echo     sqlite3_bind_text^(stmt, 4, app.c_str^(^), -1, SQLITE_TRANSIENT^);
echo     sqlite3_step^(stmt^);
echo     sqlite3_finalize^(stmt^);
echo }
echo.
echo std::string foreground_app^(^) {
echo     HWND hwnd = GetForegroundWindow^(^);
echo     DWORD pid = 0;
echo     GetWindowThreadProcessId^(hwnd, ^&pid^);
echo     HANDLE process = OpenProcess^(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid^);
echo     if ^(!process^) return "Unknown";
echo     wchar_t path[MAX_PATH]{};
echo     DWORD size = MAX_PATH;
echo     BOOL ok = QueryFullProcessImageNameW^(process, 0, path, ^&size^);
echo     CloseHandle^(process^);
echo     if ^(!ok^) return "Unknown";
echo     int bytes = WideCharToMultiByte^(CP_UTF8, 0, path, size, nullptr, 0, nullptr, nullptr^);
echo     if ^(bytes ^<= 0^) return "Unknown";
echo     std::string result^(bytes, '\0'^);
echo     WideCharToMultiByte^(CP_UTF8, 0, path, size, result.data^(^), bytes, nullptr, nullptr^);
echo     return result;
echo }
echo.
echo LRESULT CALLBACK window_proc^(HWND hwnd, UINT message, WPARAM wp, LPARAM lp^) {
echo     if ^(message == WM_INPUT^) {
echo         UINT size = 0;
echo         if ^(GetRawInputData^(reinterpret_cast^<HRAWINPUT^>^(lp^), RID_INPUT, nullptr, ^&size, sizeof^(RAWINPUTHEADER^)^) == 0^) {
echo             std::vector^<BYTE^> buffer^(size^);
echo             if ^(GetRawInputData^(reinterpret_cast^<HRAWINPUT^>^(lp^), RID_INPUT, buffer.data^(^), ^&size, sizeof^(RAWINPUTHEADER^)^) == size^) {
echo                 auto* input = reinterpret_cast^<RAWINPUT*^>^(buffer.data^(^)^);
echo                 if ^(input-^>header.dwType == RIM_TYPEKEYBOARD ^&^& !paused.load^(^)^) {
echo                     keyboard_total.fetch_add^(1^);
echo                     keyboard_interval.fetch_add^(1^);
echo                 }
echo             }
echo         }
echo         return DefWindowProcW^(hwnd, message, wp, lp^);
echo     }
echo     return DefWindowProcW^(hwnd, message, wp, lp^);
echo }
echo.
echo bool initialize_input^(^) {
echo     WNDCLASSW wc{};
echo     wc.lpfnWndProc = window_proc;
echo     wc.hInstance = GetModuleHandleW^(nullptr^);
echo     wc.lpszClassName = L"GlobalMonitorInput";
echo     if ^(!RegisterClassW^(^&wc^) ^&^& GetLastError^(^) != ERROR_CLASS_ALREADY_EXISTS^) return false;
echo     HWND hwnd = CreateWindowExW^(0, wc.lpszClassName, L"", 0, 0,0,0,0, HWND_MESSAGE, nullptr, wc.hInstance, nullptr^);
echo     if ^(!hwnd^) return false;
echo     RAWINPUTDEVICE device{};
echo     device.usUsagePage = 1;
echo     device.usUsage = 6;
echo     device.dwFlags = RIDEV_INPUTSINK;
echo     device.hwndTarget = hwnd;
echo     return RegisterRawInputDevices^(^&device, 1, sizeof^(device^)^);
echo }
echo }
echo.
echo int main^(^) {
echo     SetConsoleTitleW^(L"GlobalMonitor v6.1"^);
echo     if ^(!initialize_database^(^)^) {
echo         std::cerr ^<^< "Database initialization failed.\n";
echo         return 1;
echo     }
echo     if ^(!initialize_input^(^)^) {
echo         std::cerr ^<^< "Input initialization failed.\n";
echo         sqlite3_close^(database^);
echo         return 1;
echo     }
echo     std::cout ^<^< "GLOBAL MONITOR v6.1\n";
echo     std::cout ^<^< "Keyboard event counts only; no typed content is collected.\n";
echo     std::cout ^<^< "F6 pause/resume, ESC exit.\n";
echo     MSG msg{};
echo     auto last = std::chrono::steady_clock::now^(^);
echo     bool running = true;
echo     while ^(running^) {
echo         while ^(PeekMessageW^(^&msg, nullptr, 0, 0, PM_REMOVE^)^) {
echo             if ^(msg.message == WM_QUIT^) running = false;
echo             TranslateMessage^(^&msg^);
echo             DispatchMessageW^(^&msg^);
echo         }
echo         if ^(GetAsyncKeyState^(VK_ESCAPE^) ^& 1^) break;
echo         if ^(GetAsyncKeyState^(VK_F6^) ^& 1^) paused.store^(!paused.load^(^)^);
echo         auto now = std::chrono::steady_clock::now^(^);
echo         if ^(now - last ^>= std::chrono::seconds^(1^)^) {
echo             auto count = keyboard_interval.exchange^(0^);
echo             save_keyboard^(count, foreground_app^(^)^);
echo             std::system^("cls"^);
echo             std::cout ^<^< "GLOBAL MONITOR v6.1\n";
echo             std::cout ^<^< "Total events: " ^<^< keyboard_total.load^(^) ^<^< "\n";
echo             std::cout ^<^< "Events/sec: " ^<^< count ^<^< "\n";
echo             std::cout ^<^< "Status: " ^<^< ^(paused.load^(^) ? "PAUSED" : "ACTIVE"^) ^<^< "\n";
echo             std::cout ^<^< "F6 pause/resume | ESC exit\n";
echo             std::cout ^<^< "No typed content is collected.\n";
echo             last = now;
echo         }
echo         std::this_thread::sleep_for^(std::chrono::milliseconds^(10^)^);
echo     }
echo     sqlite3_close^(database^);
echo     return 0;
echo }
) > "%ROOT%\src\main.cpp"

:: Add vector include
powershell -NoProfile -Command "$p='%ROOT%\src\main.cpp'; $s=Get-Content -Raw $p; $s=$s.Replace('#include <thread>','#include <thread>' + [Environment]::NewLine + '#include <vector>'); Set-Content -Encoding ascii $p $s"

:: Bootstrap vcpkg
echo [4/6] Preparing vcpkg...

if not exist "%VCPKG_ROOT%\bootstrap-vcpkg.bat" (
    git clone https://github.com/microsoft/vcpkg.git "%VCPKG_ROOT%"
    if errorlevel 1 goto failed
)

call "%VCPKG_ROOT%\bootstrap-vcpkg.bat" -disableMetrics
if errorlevel 1 goto failed

call "%VCPKG_ROOT%\vcpkg.exe" install --triplet x64-windows --manifest-root "%ROOT%"
if errorlevel 1 goto failed

:: Configure
echo [5/6] Configuring project...

cmake -S "%ROOT%" -B "%ROOT%\build" ^
 -DCMAKE_TOOLCHAIN_FILE="%VCPKG_ROOT%\scripts\buildsystems\vcpkg.cmake" ^
 -A x64

if errorlevel 1 goto failed

:: Build
echo [6/6] Compiling...

cmake --build "%ROOT%\build" --config Release
if errorlevel 1 goto failed

if not exist "%ROOT%\build\Release\GlobalMonitor.exe" goto failed

echo.
echo ============================================
echo BUILD SUCCESSFUL - STARTING
echo ============================================
echo.

pushd "%ROOT%"
"build\Release\GlobalMonitor.exe"
popd

echo.
echo GlobalMonitor closed.
pause
exit /b 0

:failed
echo.
echo BUILD FAILED. Review the error messages above.
pause
exit /b 1
