import Foundation

enum AgentTemplate: String, CaseIterable, Identifiable {
    case runScript = "Run Script"
    case watchFolder = "Watch Folder"
    case runAtLogin = "Run at Login"
    case scheduledTask = "Scheduled Task"
    case blank = "Blank"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .runScript: return "terminal.fill"
        case .watchFolder: return "folder.badge.gearshape"
        case .runAtLogin: return "person.crop.circle.badge.checkmark"
        case .scheduledTask: return "clock.fill"
        case .blank: return "doc.badge.plus"
        }
    }

    var description: String {
        switch self {
        case .runScript: return "Run a script or command on a recurring interval"
        case .watchFolder: return "Execute when files change in a watched directory"
        case .runAtLogin: return "Start a program automatically when you log in"
        case .scheduledTask: return "Run a command at a specific time using StartCalendarInterval"
        case .blank: return "Empty plist — configure everything manually"
        }
    }

    func defaultFormData() -> AgentFormData {
        var form = AgentFormData()
        switch self {
        case .runScript:
            form.program = "/bin/sh"
            form.arguments = ["-c", "echo 'Hello from Ignition'"]
            form.startInterval = 300
            form.standardOutPath = NSHomeDirectory() + "/Library/Logs/Ignition/agent.stdout.log"
            form.standardErrorPath = NSHomeDirectory() + "/Library/Logs/Ignition/agent.stderr.log"
        case .watchFolder:
            form.program = "/bin/sh"
            form.arguments = ["-c", "echo 'Folder changed'"]
            form.watchPaths = [NSHomeDirectory() + "/Downloads"]
            form.standardOutPath = NSHomeDirectory() + "/Library/Logs/Ignition/agent.stdout.log"
            form.standardErrorPath = NSHomeDirectory() + "/Library/Logs/Ignition/agent.stderr.log"
        case .runAtLogin:
            form.program = "/usr/bin/open"
            form.arguments = ["-a", "Safari"]
            form.runAtLoad = true
        case .scheduledTask:
            form.program = "/bin/sh"
            form.arguments = ["-c", "echo 'Scheduled run'"]
            form.calendarHour = 9
            form.calendarMinute = 0
            form.standardOutPath = NSHomeDirectory() + "/Library/Logs/Ignition/agent.stdout.log"
            form.standardErrorPath = NSHomeDirectory() + "/Library/Logs/Ignition/agent.stderr.log"
        case .blank:
            break
        }
        return form
    }
}

struct AgentFormData {
    var domain: AgentDomain = .userAgents
    var label = ""
    var program = ""
    var arguments: [String] = []
    var runAtLoad = false
    var keepAlive = false
    var startInterval: Int? = nil
    var watchPaths: [String] = []
    var calendarHour: Int? = nil
    var calendarMinute: Int? = nil
    var standardOutPath: String? = nil
    var standardErrorPath: String? = nil
    var environmentVariables: [(key: String, value: String)] = []
    var workingDirectory: String? = nil

    func validate() -> [String] {
        var errors: [String] = []
        if label.isEmpty {
            errors.append("Label is required")
        } else if !label.contains(".") {
            errors.append("Label should use reverse-DNS format (e.g. com.example.myagent)")
        }
        do { try PlistWriteService.validateLabel(label) }
        catch { errors.append(error.localizedDescription) }
        if label.hasPrefix("com.apple.") { errors.append("Apple system labels are protected") }
        if !program.isEmpty && !program.hasPrefix("/") {
            errors.append("Use an absolute program path; launchd does not expand shell paths")
        }
        if let startInterval, startInterval <= 0 { errors.append("Start interval must be greater than zero") }
        if let calendarHour, !(0...23).contains(calendarHour) { errors.append("Hour must be between 0 and 23") }
        if let calendarMinute, !(0...59).contains(calendarMinute) { errors.append("Minute must be between 0 and 59") }
        if program.isEmpty {
            errors.append("Program path is required")
        }
        return errors
    }

    func toPlistDictionary() -> [String: Any] {
        var dict: [String: Any] = [:]
        dict["Label"] = label

        if !arguments.isEmpty {
            dict["ProgramArguments"] = [program] + arguments
        } else {
            dict["Program"] = program
        }

        if runAtLoad { dict["RunAtLoad"] = true }
        if keepAlive { dict["KeepAlive"] = true }

        if let interval = startInterval, interval > 0 {
            dict["StartInterval"] = interval
        }

        if !watchPaths.isEmpty {
            dict["WatchPaths"] = watchPaths
        }

        if let hour = calendarHour {
            var cal: [String: Int] = ["Hour": hour]
            if let minute = calendarMinute { cal["Minute"] = minute }
            dict["StartCalendarInterval"] = cal
        }

        if let path = standardOutPath, !path.isEmpty {
            dict["StandardOutPath"] = path
        }
        if let path = standardErrorPath, !path.isEmpty {
            dict["StandardErrorPath"] = path
        }

        if !environmentVariables.isEmpty {
            var env: [String: String] = [:]
            for pair in environmentVariables where !pair.key.isEmpty {
                env[pair.key] = pair.value
            }
            if !env.isEmpty { dict["EnvironmentVariables"] = env }
        }

        if let dir = workingDirectory, !dir.isEmpty {
            dict["WorkingDirectory"] = dir
        }

        return dict
    }
}
