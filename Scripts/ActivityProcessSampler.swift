// Reusable observer extracted from the frozen T31 evidence.
// Counter and identity validation are unchanged; minimum window is 300 seconds.
import Darwin
import Foundation

/// This external observer does not attach a debugger or execute plugin code.
/// Apple SDK libproc rusage v6 exposes cumulative counters for owned processes.
/// XNU recount.h: CPU time is Mach timebase units; energy_nj is CPU energy,
/// sampled out of band. These are not wall-plug or whole-device measurements.
private enum SamplingFailure: String, Error {
    case invalidArguments, invalidTarget, observationFailed, targetChanged
    case targetExited, counterReset, samplingGap, outputFailed, durationInsufficient
}

private struct Configuration {
    let pid: Int32
    let seconds: Double
    let interval: Double
    let output: URL
    let summary: URL
    let label: String

    init(_ arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard ["--pid", "--seconds", "--interval", "--output", "--summary", "--label"].contains(key),
                  values[key] == nil, index + 1 < arguments.count else { throw SamplingFailure.invalidArguments }
            values[key] = arguments[index + 1]; index += 2
        }
        guard let pid = values["--pid"].flatMap(Int32.init), pid > 1,
              let seconds = values["--seconds"].flatMap(Double.init), seconds.isFinite, (300...1800).contains(seconds),
              let interval = Double(values["--interval"] ?? "5"), interval.isFinite, interval == 5,
              let output = values["--output"], output.hasPrefix("/"),
              let summary = values["--summary"], summary.hasPrefix("/"), output != summary,
              let label = values["--label"], ["no-plugins", "installed-disabled", "installed-running"].contains(label) else {
            throw SamplingFailure.invalidArguments
        }
        self.pid = pid; self.seconds = seconds; self.interval = interval; self.label = label
        self.output = URL(fileURLWithPath: output).standardizedFileURL
        self.summary = URL(fileURLWithPath: summary).standardizedFileURL
    }
}

private struct Identity: Encodable, Equatable {
    let pid: Int32
    let uid: UInt32
    let processStartMachTicks: UInt64
    let executableUUIDBase64: String
    let executable: String
}

private struct Sample: Encodable {
    let type = "sample"
    let schemaVersion = 1
    let index: Int
    let utc: String
    let monotonicNanoseconds: UInt64
    let identity: Identity
    let userMachTicks: UInt64
    let systemMachTicks: UInt64
    let cpuEnergyNanojoules: UInt64
    let performanceCPUEnergyNanojoules: UInt64
    let packageIdleWakeups: UInt64
    let interruptWakeups: UInt64
    let diskReadBytes: UInt64
    let diskWrittenBytes: UInt64
    let physicalFootprintBytes: UInt64

    var cumulative: [String: UInt64] {
        ["userMachTicks": userMachTicks, "systemMachTicks": systemMachTicks,
         "cpuEnergyNanojoules": cpuEnergyNanojoules, "performanceCPUEnergyNanojoules": performanceCPUEnergyNanojoules,
         "packageIdleWakeups": packageIdleWakeups, "interruptWakeups": interruptWakeups,
         "diskReadBytes": diskReadBytes, "diskWrittenBytes": diskWrittenBytes]
    }
}

private struct Metadata: Encodable {
    let type = "metadata"
    let schemaVersion = 1
    let label: String
    let requestedDurationSeconds: Double
    let intervalSeconds: Double
    let observationClock = "mach_continuous_time_scaled_to_nanoseconds_includes_sleep"
    let cpuUnit = "mach_timebase_ticks"
    let energyUnit = "CPU_nanojoules_attributed_by_kernel_not_whole_device"
    let timebaseNumerator: UInt32
    let timebaseDenominator: UInt32
    let rusageFlavor = 6
    let rusageStructBytes = MemoryLayout<rusage_info_v6>.size
    let operatingSystem: String
    let identity: Identity
    let references = [
        "https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/recount.h",
        "https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c",
        "https://support.apple.com/guide/activity-monitor/actmntr43697/mac"
    ]
}

private struct Summary: Encodable {
    let type = "summary"
    let schemaVersion = 1
    let label: String
    let evidenceStatus: String
    let failureCode: String?
    let sampleCount: Int
    let measuredDurationSeconds: Double?
    let requestedDurationSeconds: Double
    let identity: Identity?
    let cpuSeconds: Double?
    let meanSingleCoreCPUPercent: Double?
    let maximumIntervalSingleCoreCPUPercent: Double?
    let p95IntervalSingleCoreCPUPercent: Double?
    let attributedCPUEnergyJoules: Double?
    let equivalentMeanCPUPowerMilliwatts: Double?
    let cpuEnergyCounterAdvanced: Bool?
    let packageIdleWakeups: UInt64?
    let packageIdleWakeupsPerMinute: Double?
    let interruptWakeups: UInt64?
    let interruptWakeupsPerMinute: Double?
    let diskReadBytes: UInt64?
    let diskWrittenBytes: UInt64?
    let peakPhysicalFootprintBytes: UInt64?
    let scope = "Process CPU energy attribution; does not measure full Energy Impact, GPU/display/network energy or whole-device battery draw."
}

private final class PrivateOutput {
    let descriptor: Int32
    init(_ url: URL) throws {
        descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SamplingFailure.outputFailed }
        guard fchmod(descriptor, 0o600) == 0 else { Darwin.close(descriptor); throw SamplingFailure.outputFailed }
    }
    deinit { Darwin.close(descriptor) }
    func append<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(value); bytes.append(10)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw SamplingFailure.outputFailed }
                offset += written
            }
        }
    }
    func finish() throws { guard fsync(descriptor) == 0 else { throw SamplingFailure.outputFailed } }
}

private enum Observer {
    static func monotonicNanoseconds(_ timebase: mach_timebase_info_data_t) throws -> UInt64 {
        let ticks = mach_continuous_time()
        let denominator = UInt64(timebase.denom), numerator = UInt64(timebase.numer)
        guard denominator > 0 else { throw SamplingFailure.observationFailed }
        let whole = (ticks / denominator).multipliedReportingOverflow(by: numerator)
        let fraction = (ticks % denominator).multipliedReportingOverflow(by: numerator)
        guard !whole.overflow, !fraction.overflow else { throw SamplingFailure.observationFailed }
        let total = whole.partialValue.addingReportingOverflow(fraction.partialValue / denominator)
        guard !total.overflow else { throw SamplingFailure.observationFailed }
        return total.partialValue
    }

    static func read(pid: Int32, index: Int, timebase: mach_timebase_info_data_t) throws -> Sample {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize,
              bsd.pbi_uid == getuid() else { throw SamplingFailure.invalidTarget }
        var usage = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard result == 0, usage.ri_proc_start_abstime > 0 else { throw SamplingFailure.observationFailed }
        guard usage.ri_proc_exit_abstime == 0 else { throw SamplingFailure.targetExited }
        // SDK PROC_PIDPATHINFO_MAXSIZE is the C expression 4*MAXPATHLEN;
        // its expression macro is not imported by Swift.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathResult = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard pathResult > 0 else { throw SamplingFailure.observationFailed }
        let identity = Identity(pid: pid, uid: bsd.pbi_uid, processStartMachTicks: usage.ri_proc_start_abstime,
            executableUUIDBase64: withUnsafeBytes(of: &usage.ri_uuid) { Data($0).base64EncodedString() },
            executable: String(cString: path))
        return .init(index: index, utc: ISO8601DateFormatter().string(from: Date()),
            monotonicNanoseconds: try monotonicNanoseconds(timebase), identity: identity,
            userMachTicks: usage.ri_user_time, systemMachTicks: usage.ri_system_time,
            cpuEnergyNanojoules: usage.ri_energy_nj, performanceCPUEnergyNanojoules: usage.ri_penergy_nj,
            packageIdleWakeups: usage.ri_pkg_idle_wkups, interruptWakeups: usage.ri_interrupt_wkups,
            diskReadBytes: usage.ri_diskio_bytesread, diskWrittenBytes: usage.ri_diskio_byteswritten,
            physicalFootprintBytes: usage.ri_phys_footprint)
    }

    static func check(_ previous: Sample, _ current: Sample, interval: Double) throws {
        guard previous.identity == current.identity else { throw SamplingFailure.targetChanged }
        guard current.monotonicNanoseconds > previous.monotonicNanoseconds else { throw SamplingFailure.observationFailed }
        let elapsed = Double(current.monotonicNanoseconds - previous.monotonicNanoseconds) / 1e9
        guard elapsed <= interval * 3 else { throw SamplingFailure.samplingGap }
        for (key, value) in previous.cumulative {
            guard let next = current.cumulative[key], next >= value else { throw SamplingFailure.counterReset }
        }
    }

    static func summarize(_ configuration: Configuration, samples: [Sample],
                          timebase: mach_timebase_info_data_t, failure: SamplingFailure?) -> Summary {
        guard let first = samples.first, let last = samples.last, samples.count >= 2 else {
            return Summary(label: configuration.label, evidenceStatus: "invalid", failureCode: (failure ?? .durationInsufficient).rawValue,
                sampleCount: samples.count, measuredDurationSeconds: nil, requestedDurationSeconds: configuration.seconds,
                identity: samples.first?.identity, cpuSeconds: nil, meanSingleCoreCPUPercent: nil,
                maximumIntervalSingleCoreCPUPercent: nil, p95IntervalSingleCoreCPUPercent: nil,
                attributedCPUEnergyJoules: nil, equivalentMeanCPUPowerMilliwatts: nil, cpuEnergyCounterAdvanced: nil,
                packageIdleWakeups: nil, packageIdleWakeupsPerMinute: nil, interruptWakeups: nil, interruptWakeupsPerMinute: nil,
                diskReadBytes: nil, diskWrittenBytes: nil, peakPhysicalFootprintBytes: samples.first?.physicalFootprintBytes)
        }
        let elapsed = Double(last.monotonicNanoseconds - first.monotonicNanoseconds) / 1e9
        let scalar = Double(timebase.numer) / Double(timebase.denom) / 1e9
        let user = last.userMachTicks - first.userMachTicks
        let system = last.systemMachTicks - first.systemMachTicks
        let cpu = (Double(user) + Double(system)) * scalar
        let energy = last.cpuEnergyNanojoules - first.cpuEnergyNanojoules
        let joules = Double(energy) / 1e9
        let wakeups = last.packageIdleWakeups - first.packageIdleWakeups
        let interrupts = last.interruptWakeups - first.interruptWakeups
        let rates = zip(samples, samples.dropFirst()).map { before, after -> Double in
            let cpu = (Double(after.userMachTicks - before.userMachTicks)
                + Double(after.systemMachTicks - before.systemMachTicks)) * scalar
            return cpu / (Double(after.monotonicNanoseconds - before.monotonicNanoseconds) / 1e9) * 100
        }.sorted()
        let durationFailure = elapsed < configuration.seconds ? SamplingFailure.durationInsufficient : nil
        let finalFailure = failure ?? durationFailure
        return Summary(label: configuration.label, evidenceStatus: finalFailure == nil ? "valid_counter_window" : "invalid",
            failureCode: finalFailure?.rawValue, sampleCount: samples.count, measuredDurationSeconds: elapsed,
            requestedDurationSeconds: configuration.seconds, identity: first.identity, cpuSeconds: cpu,
            meanSingleCoreCPUPercent: cpu / elapsed * 100, maximumIntervalSingleCoreCPUPercent: rates.last,
            p95IntervalSingleCoreCPUPercent: rates[max(0, Int(ceil(Double(rates.count) * 0.95)) - 1)],
            attributedCPUEnergyJoules: joules, equivalentMeanCPUPowerMilliwatts: joules / elapsed * 1000,
            cpuEnergyCounterAdvanced: energy > 0, packageIdleWakeups: wakeups,
            packageIdleWakeupsPerMinute: Double(wakeups) / elapsed * 60, interruptWakeups: interrupts,
            interruptWakeupsPerMinute: Double(interrupts) / elapsed * 60,
            diskReadBytes: last.diskReadBytes - first.diskReadBytes,
            diskWrittenBytes: last.diskWrittenBytes - first.diskWrittenBytes,
            peakPhysicalFootprintBytes: samples.map(\.physicalFootprintBytes).max())
    }
}

@main
private enum EnergySampler {
    static func main() async {
        if CommandLine.arguments.dropFirst().elementsEqual(["--help"]) {
            print("energy-sampler --pid PID --seconds 300 --interval 5 --label no-plugins|installed-disabled|installed-running --output /absolute/new.jsonl --summary /absolute/new-summary.json")
            print("Read-only observer; owned live PID only. At least 300 seconds; no debugger. Energy is attributed CPU energy, not whole-device power.")
            return
        }
        do {
            let configuration = try Configuration(Array(CommandLine.arguments.dropFirst()))
            var timebase = mach_timebase_info_data_t()
            guard mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.denom > 0 else { throw SamplingFailure.observationFailed }
            let output = try PrivateOutput(configuration.output)
            let summaryOutput = try PrivateOutput(configuration.summary)
            var samples: [Sample] = []
            var failure: SamplingFailure?
            do {
                let initial = try Observer.read(pid: configuration.pid, index: 0, timebase: timebase)
                samples.append(initial)
                try output.append(Metadata(label: configuration.label, requestedDurationSeconds: configuration.seconds,
                    intervalSeconds: configuration.interval, timebaseNumerator: timebase.numer,
                    timebaseDenominator: timebase.denom, operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                    identity: initial.identity))
                try output.append(initial)
                let interval = UInt64(configuration.interval * 1e9)
                let duration = UInt64(configuration.seconds * 1e9)
                var next = initial.monotonicNanoseconds + interval
                while samples.last!.monotonicNanoseconds - initial.monotonicNanoseconds < duration {
                    let now = try Observer.monotonicNanoseconds(timebase)
                    if next > now { try await Task.sleep(nanoseconds: next - now) }
                    let current = try Observer.read(pid: configuration.pid, index: samples.count, timebase: timebase)
                    try Observer.check(samples.last!, current, interval: configuration.interval)
                    samples.append(current)
                    try output.append(current)
                    // Never emit invented catch-up samples after delayed observation.
                    next = max(next + interval, current.monotonicNanoseconds + interval)
                }
                try output.finish()
            } catch {
                failure = error as? SamplingFailure ?? .observationFailed
            }
            let summary = Observer.summarize(configuration, samples: samples, timebase: timebase, failure: failure)
            try summaryOutput.append(summary); try summaryOutput.finish()
            if summary.evidenceStatus == "invalid" { exit(1) }
            print("Completed \(configuration.label): \(summary.sampleCount) observations, raw artifacts saved. This does not determine task acceptance by itself.")
        } catch {
            let code = (error as? SamplingFailure ?? .outputFailed).rawValue
            FileHandle.standardError.write(Data("Sampler failed: \(code)\n".utf8)); exit(1)
        }
    }
}
