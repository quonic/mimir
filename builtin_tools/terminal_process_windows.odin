#+build windows
package builtin_tools

import "core:os"
import win32 "core:sys/windows"

foreign import kernel32 "system:Kernel32.lib"

// The process thread attribute that limits the handles a new process inherits.
PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: 0x00020002

// STARTUPINFOEXW of the Windows API: STARTUPINFOW with a process thread attribute list.
Startup_Info_Ex :: struct {
	startupInfo:   win32.STARTUPINFOW,
	attributeList: rawptr,
}

@(default_calling_convention = "system")
foreign kernel32 {
	InitializeProcThreadAttributeList :: proc(
		lpAttributeList: rawptr,
		dwAttributeCount: win32.DWORD,
		dwFlags: win32.DWORD,
		lpSize: ^win32.SIZE_T,
	) -> win32.BOOL ---
	UpdateProcThreadAttribute :: proc(
		lpAttributeList: rawptr,
		dwFlags: win32.DWORD,
		Attribute: win32.DWORD_PTR,
		lpValue: rawptr,
		cbSize: win32.SIZE_T,
		lpPreviousValue: rawptr,
		lpReturnSize: ^win32.SIZE_T,
	) -> win32.BOOL ---
	DeleteProcThreadAttributeList :: proc(lpAttributeList: rawptr) ---
}

// Runs the command of desc to completion and returns its exit code and output. The environment
// of desc is not used: the process gets the environment of Mimir.
//
// os.process_exec lets the process inherit every inheritable handle of Mimir. Sockets are
// inheritable, so a command would hold the connections of other sessions and safety checks
// open while it runs, and reset them when it exits. This procedure gives the process only its
// standard input, output and error handles.
terminal_process_exec :: proc(
	desc: os.Process_Desc,
	allocator := context.allocator,
) -> (
	exitCode: int,
	stdout: []byte,
	stderr: []byte,
	err: os.Error,
) {
	inheritable := win32.SECURITY_ATTRIBUTES {
		nLength        = size_of(win32.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	stdoutRead, stdoutWrite, stderrRead, stderrWrite: win32.HANDLE
	if !win32.CreatePipe(&stdoutRead, &stdoutWrite, &inheritable, 0) {
		return 0, nil, nil, terminal_last_error()
	}
	defer win32.CloseHandle(stdoutRead)
	if !win32.CreatePipe(&stderrRead, &stderrWrite, &inheritable, 0) {
		err = terminal_last_error()
		win32.CloseHandle(stdoutWrite)
		return 0, nil, nil, err
	}
	defer win32.CloseHandle(stderrRead)
	stdinHandle := win32.CreateFileW(
		win32.L("NUL"),
		win32.GENERIC_READ,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		&inheritable,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if stdinHandle == win32.INVALID_HANDLE_VALUE {
		err = terminal_last_error()
		win32.CloseHandle(stdoutWrite)
		win32.CloseHandle(stderrWrite)
		return 0, nil, nil, err
	}

	process: win32.PROCESS_INFORMATION
	{
		// The parent closes its copies of the child handles, so the reads end when the
		// process and its children close theirs.
		defer win32.CloseHandle(stdoutWrite)
		defer win32.CloseHandle(stderrWrite)
		defer win32.CloseHandle(stdinHandle)
		process = terminal_create_process(
			desc,
			stdinHandle,
			stdoutWrite,
			stderrWrite,
		) or_return
	}
	defer win32.CloseHandle(process.hProcess)

	stdoutBuffer := make([dynamic]byte, allocator)
	stderrBuffer := make([dynamic]byte, allocator)
	stdoutOpen, stderrOpen := true, true
	for stdoutOpen || stderrOpen {
		received := false
		if stdoutOpen {
			stdoutOpen, received = terminal_read_pipe(stdoutRead, &stdoutBuffer)
		}
		if stderrOpen {
			stderrReceived: bool
			stderrOpen, stderrReceived = terminal_read_pipe(stderrRead, &stderrBuffer)
			received ||= stderrReceived
		}
		if !received && (stdoutOpen || stderrOpen) {
			win32.Sleep(1)
		}
	}

	win32.WaitForSingleObject(process.hProcess, win32.INFINITE)
	code: win32.DWORD
	if !win32.GetExitCodeProcess(process.hProcess, &code) {
		err = terminal_last_error()
	}
	return int(code), stdoutBuffer[:], stderrBuffer[:], err
}

// Starts the process of desc with the given standard handles. The process inherits only these
// handles.
@(private = "file")
terminal_create_process :: proc(
	desc: os.Process_Desc,
	stdinHandle, stdoutHandle, stderrHandle: win32.HANDLE,
) -> (
	process: win32.PROCESS_INFORMATION,
	err: os.Error,
) {
	commandLine := win32.utf8_to_wstring(
		windows_command_line(desc.command, context.temp_allocator),
		context.temp_allocator,
	)
	workingDirectory: win32.LPCWSTR
	if desc.working_dir != "" {
		workingDirectory = win32.utf8_to_wstring(desc.working_dir, context.temp_allocator)
	}

	handles := [3]win32.HANDLE{stdinHandle, stdoutHandle, stderrHandle}
	listSize: win32.SIZE_T
	// The first call only returns the size of the list.
	InitializeProcThreadAttributeList(nil, 1, 0, &listSize)
	list := make([]byte, int(listSize), context.temp_allocator)
	if !InitializeProcThreadAttributeList(raw_data(list), 1, 0, &listSize) {
		return {}, terminal_last_error()
	}
	defer DeleteProcThreadAttributeList(raw_data(list))
	if !UpdateProcThreadAttribute(
		raw_data(list),
		0,
		PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
		&handles,
		size_of(handles),
		nil,
		nil,
	) {
		return {}, terminal_last_error()
	}

	startup := Startup_Info_Ex {
		startupInfo = win32.STARTUPINFOW {
			cb = size_of(Startup_Info_Ex),
			dwFlags = win32.STARTF_USESTDHANDLES,
			hStdInput = stdinHandle,
			hStdOutput = stdoutHandle,
			hStdError = stderrHandle,
		},
		attributeList = raw_data(list),
	}
	// CREATE_NO_WINDOW gives the process its own hidden console, so it cannot change the
	// console of the terminal UI (PowerShell sets the console output encoding).
	if !win32.CreateProcessW(
		nil,
		commandLine,
		nil,
		nil,
		true,
		win32.EXTENDED_STARTUPINFO_PRESENT | win32.CREATE_NO_WINDOW,
		nil,
		workingDirectory,
		&startup.startupInfo,
		&process,
	) {
		return {}, terminal_last_error()
	}
	win32.CloseHandle(process.hThread)
	return process, nil
}

// Appends the bytes that are ready in pipe to buffer. open is false when the write ends of
// the pipe are closed; received is true when bytes were read.
@(private = "file")
terminal_read_pipe :: proc(pipe: win32.HANDLE, buffer: ^[dynamic]byte) -> (open, received: bool) {
	available: win32.DWORD
	if !win32.PeekNamedPipe(pipe, nil, 0, nil, &available, nil) {
		return false, false
	}
	if available == 0 {
		return true, false
	}
	chunk: [4096]byte
	count: win32.DWORD
	if !win32.ReadFile(pipe, &chunk, min(available, len(chunk)), &count, nil) {
		return false, false
	}
	append(buffer, ..chunk[:count])
	return true, count > 0
}

@(private = "file")
terminal_last_error :: proc() -> os.Error {
	return os.Platform_Error(win32.GetLastError())
}
