//
//  TerminalSessionHost.swift
//  BoringNotchXPCHelper
//
//  Runs one interactive login shell on a pseudo-terminal. The helper is not sandboxed,
//  so the shell sees the real home directory, PATH and tools, unlike a shell spawned
//  from inside the sandboxed app.
//

import Darwin
import Foundation

enum TerminalSessionError: LocalizedError {
    case alreadyRunning
    case shellNotFound(String)
    case spawnFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "A terminal session is already running."
        case .shellNotFound(let path):
            return "The shell at \(path) does not exist or is not executable."
        case .spawnFailed(let code):
            return "Could not start the shell (forkpty failed with errno \(code))."
        }
    }
}

final class TerminalSessionHost {
    private let queue = DispatchQueue(label: "theboringteam.boringnotch.terminal-session")
    private let onOutput: (Data) -> Void
    private let onExit: (Int32) -> Void

    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var didReportExit = false

    init(onOutput: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) {
        self.onOutput = onOutput
        self.onExit = onExit
    }

    deinit {
        stop(reportExit: false)
    }

    // MARK: - Lifecycle

    /// Spawns the shell. `shellPath` may be empty to use the account's login shell.
    func start(columns: Int, rows: Int, shellPath: String) throws {
        try queue.sync {
            guard childPID == 0 else { throw TerminalSessionError.alreadyRunning }

            let account = Self.currentAccount()
            let shell = shellPath.isEmpty ? account.shell : shellPath
            guard FileManager.default.isExecutableFile(atPath: shell) else {
                throw TerminalSessionError.shellNotFound(shell)
            }

            let environment = Self.environment(shell: shell, home: account.home, user: account.user)
            let (pid, master) = try Self.spawn(
                shell: shell,
                workingDirectory: account.home,
                environment: environment,
                columns: columns,
                rows: rows
            )

            childPID = pid
            masterFD = master
            didReportExit = false
            installSources()
        }
    }

    func write(_ data: Data) {
        queue.async { [self] in
            guard masterFD >= 0, !data.isEmpty else { return }
            data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                guard let base = buffer.baseAddress else { return }
                var offset = 0
                var retries = 0
                while offset < buffer.count {
                    let written = Darwin.write(masterFD, base.advanced(by: offset), buffer.count - offset)
                    if written > 0 {
                        offset += written
                        retries = 0
                    } else if written < 0 && errno == EAGAIN && retries < 200 {
                        retries += 1
                        usleep(2_000)
                    } else if written < 0 && errno == EINTR {
                        continue
                    } else {
                        return
                    }
                }
            }
        }
    }

    func resize(columns: Int, rows: Int) {
        queue.async { [self] in
            guard masterFD >= 0 else { return }
            var size = winsize(
                ws_row: UInt16(clamping: max(rows, 1)),
                ws_col: UInt16(clamping: max(columns, 1)),
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            _ = ioctl(masterFD, TIOCSWINSZ, &size)
        }
    }

    /// Terminates the shell. Safe to call more than once.
    func stop(reportExit: Bool = true) {
        queue.sync {
            guard childPID > 0 else { return }
            let pid = childPID
            kill(pid, SIGHUP)

            var status: Int32 = 0
            var reaped = false
            for _ in 0..<50 {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid {
                    reaped = true
                    break
                }
                if result < 0 { break }
                usleep(20_000)
            }
            if !reaped {
                kill(pid, SIGKILL)
                _ = waitpid(pid, &status, 0)
            }
            finish(status: Self.exitCode(from: status), report: reportExit)
        }
    }

    // MARK: - Reading

    private func installSources() {
        let fd = masterFD
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        let read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler { [weak self] in
            self?.drain()
        }
        read.resume()
        readSource = read

        let exit = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in
            self?.reapIfExited()
        }
        exit.resume()
        exitSource = exit
    }

    private func drain() {
        guard masterFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(masterFD, raw.baseAddress, raw.count)
            }
            if count > 0 {
                onOutput(Data(buffer[0..<count]))
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN { return }
            // EOF or EIO: every handle to the slave side is gone, so the shell is done.
            handleEndOfFile()
            return
        }
    }

    private func handleEndOfFile() {
        guard childPID > 0 else { return }
        let pid = childPID
        var status: Int32 = 0
        var result = waitpid(pid, &status, WNOHANG)
        if result == 0 {
            kill(pid, SIGHUP)
            result = waitpid(pid, &status, 0)
        }
        finish(status: result == pid ? Self.exitCode(from: status) : 0, report: true)
    }

    private func reapIfExited() {
        guard childPID > 0 else { return }
        var status: Int32 = 0
        let result = waitpid(childPID, &status, WNOHANG)
        guard result == childPID else { return }
        // Give the read source one last chance to deliver buffered output.
        drainRemainingOutput()
        finish(status: Self.exitCode(from: status), report: true)
    }

    private func drainRemainingOutput() {
        guard masterFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(masterFD, raw.baseAddress, raw.count)
            }
            guard count > 0 else { return }
            onOutput(Data(buffer[0..<count]))
        }
    }

    private func finish(status: Int32, report: Bool) {
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        childPID = 0
        if report && !didReportExit {
            didReportExit = true
            onExit(status)
        }
    }

    // MARK: - Spawning

    private struct Account {
        let user: String
        let home: String
        let shell: String
    }

    private static func currentAccount() -> Account {
        let env = ProcessInfo.processInfo.environment
        var user = env["USER"] ?? NSUserName()
        var home = env["HOME"] ?? NSHomeDirectory()
        var shell = "/bin/zsh"
        if let entry = getpwuid(getuid())?.pointee {
            if let name = entry.pw_name { user = String(cString: name) }
            if let dir = entry.pw_dir { home = String(cString: dir) }
            if let sh = entry.pw_shell {
                let value = String(cString: sh)
                if !value.isEmpty { shell = value }
            }
        }
        return Account(user: user, home: home, shell: shell)
    }

    private static func environment(shell: String, home: String, user: String) -> [String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("XPC_") {
            env.removeValue(forKey: key)
        }
        env["HOME"] = home
        env["USER"] = user
        env["LOGNAME"] = user
        env["SHELL"] = shell
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "BoringNotch"
        if env["LANG"] == nil && env["LC_ALL"] == nil {
            env["LANG"] = "en_US.UTF-8"
        }
        if env["PATH"] == nil {
            env["PATH"] = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// A NULL-terminated array of C strings that stays valid across fork/exec.
    private final class CStringArray {
        let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        private let count: Int

        init(_ strings: [String]) {
            count = strings.count
            pointer = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
            for (index, string) in strings.enumerated() {
                pointer[index] = strdup(string)
            }
            pointer[strings.count] = nil
        }

        deinit {
            for index in 0..<count {
                free(pointer[index])
            }
            pointer.deallocate()
        }
    }

    private static func spawn(
        shell: String,
        workingDirectory: String,
        environment: [String],
        columns: Int,
        rows: Int
    ) throws -> (pid_t, Int32) {
        // A leading dash in argv[0] asks the shell to behave as a login shell, so the
        // user's .zprofile / .zshrc (and path_helper) run exactly as in Terminal.app.
        let loginName = "-" + (shell as NSString).lastPathComponent
        let executable = CStringArray([shell])
        let arguments = CStringArray([loginName])
        let env = CStringArray(environment)
        let directory = CStringArray([workingDirectory])

        var size = winsize(
            ws_row: UInt16(clamping: max(rows, 1)),
            ws_col: UInt16(clamping: max(columns, 1)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 {
            throw TerminalSessionError.spawnFailed(errno)
        }
        if pid == 0 {
            // Child process: only async-signal-safe calls from here until exec.
            _ = chdir(directory.pointer[0])
            signal(SIGINT, SIG_DFL)
            signal(SIGQUIT, SIG_DFL)
            signal(SIGTSTP, SIG_DFL)
            signal(SIGTTIN, SIG_DFL)
            signal(SIGTTOU, SIG_DFL)
            signal(SIGCHLD, SIG_DFL)
            signal(SIGPIPE, SIG_DFL)
            _ = execve(executable.pointer[0], arguments.pointer, env.pointer)
            _exit(127)
        }
        return (pid, master)
    }

    private static func exitCode(from status: Int32) -> Int32 {
        let signalNumber = status & 0x7f
        if signalNumber == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signalNumber
    }
}
