import Foundation

struct PckListingPayload: Decodable {
    let entries: [PckEntryPayload]
    let log: String
}

struct PckEntryPayload: Decodable {
    let name: String
    let path: String
    let absolutePath: String
    let size: UInt64
    let kind: String
}

struct PckBottleError: Error {
    let message: String
}

/// Single entry point for running the bundled `pck-core-cli` helper.
///
/// Consolidates the three former subprocess wrappers and fixes a pipe-drain
/// deadlock by writing stdin on a background queue and draining stdout/stderr
/// concurrently before waiting for the process to exit.
enum PckCoreClient {
    private static func locateHelper() -> Result<URL, PckBottleError> {
        guard let toolURL = Bundle.main.url(forResource: "pck-core-cli", withExtension: nil) else {
            return .failure(PckBottleError(message: "Bundled pck-core-cli was not found."))
        }
        guard FileManager.default.isExecutableFile(atPath: toolURL.path) else {
            return .failure(PckBottleError(message: "Bundled pck-core-cli is not executable."))
        }
        return .success(toolURL)
    }

    /// Runs the helper with the given arguments and optional stdin.
    ///
    /// stdin is written on a background queue and stdout/stderr are drained
    /// concurrently, so the child can never deadlock by filling a pipe buffer
    /// while the parent blocks on another pipe.
    static func run(arguments: [String], stdin: Data?) throws -> (stdout: Data, stderr: Data, status: Int32) {
        let toolURL: URL
        switch locateHelper() {
        case .success(let url):
            toolURL = url
        case .failure(let error):
            throw error
        }

        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            inputPipe = nil
        }

        do {
            try process.run()
        } catch {
            throw PckBottleError(message: "Could not start pck-core-cli: \(error.localizedDescription)")
        }

        // Write stdin on a background queue so a large payload cannot block the
        // parent while the child is busy producing output.
        if let stdin = stdin, let inputPipe = inputPipe {
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = inputPipe.fileHandleForWriting
                handle.write(stdin)
                handle.closeFile()
            }
        }

        // Drain stdout and stderr concurrently.
        var outputData = Data()
        var errorData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.wait()
        process.waitUntilExit()

        return (outputData, errorData, process.terminationStatus)
    }

    /// Convenience: run and return stdout, surfacing stderr / signal info on failure.
    private static func runChecked(
        arguments: [String],
        stdin: Data?,
        failureMessage: String,
        crashMessage: String
    ) -> Result<Data, PckBottleError> {
        let result: (stdout: Data, stderr: Data, status: Int32)
        do {
            result = try run(arguments: arguments, stdin: stdin)
        } catch let error as PckBottleError {
            return .failure(error)
        } catch {
            return .failure(PckBottleError(message: "Could not start pck-core-cli: \(error.localizedDescription)"))
        }

        guard result.status == 0 else {
            let trimmedStderr = String(data: result.stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmedStderr = trimmedStderr, !trimmedStderr.isEmpty {
                return .failure(PckBottleError(message: trimmedStderr))
            }
            // Negative status indicates termination by an uncaught signal.
            if result.status < 0 {
                return .failure(PckBottleError(message: "\(crashMessage) (signal \(-result.status))"))
            }
            return .failure(PckBottleError(message: failureMessage))
        }

        return .success(result.stdout)
    }

    static func listPackage(at packageURL: URL) -> Result<PckListingPayload, PckBottleError> {
        let stdout = runChecked(
            arguments: ["list-pck", packageURL.path],
            stdin: nil,
            failureMessage: "pck-core-cli failed.",
            crashMessage: "pck-core-cli crashed while listing the PCK."
        )
        switch stdout {
        case .success(let data):
            do {
                return .success(try JSONDecoder().decode(PckListingPayload.self, from: data))
            } catch {
                return .failure(PckBottleError(message: "Could not decode PCK listing: \(error.localizedDescription)"))
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    static func repack(
        packageURL: URL,
        backupOriginal: Bool,
        operations: [PckOperationPayload]
    ) -> Result<String, PckBottleError> {
        guard let input = try? JSONEncoder().encode(operations) else {
            return .failure(PckBottleError(message: "Could not encode staged operations."))
        }

        let stdout = runChecked(
            arguments: ["repack", packageURL.path, backupOriginal ? "true" : "false"],
            stdin: input,
            failureMessage: "pck-core-cli repack failed.",
            crashMessage: "pck-core-cli crashed while repacking the PCK."
        )
        switch stdout {
        case .success(let data):
            return .success(
                String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "PCK packed."
            )
        case .failure(let error):
            return .failure(error)
        }
    }

    static func extractPaths(
        packageURL: URL,
        destinationURL: URL,
        paths: [String]
    ) -> Result<PckListingPayload, PckBottleError> {
        guard let input = try? JSONEncoder().encode(paths) else {
            return .failure(PckBottleError(message: "Could not encode selected PCK paths."))
        }

        let stdout = runChecked(
            arguments: ["extract-paths", packageURL.path, destinationURL.path],
            stdin: input,
            failureMessage: "pck-core-cli extract failed.",
            crashMessage: "pck-core-cli crashed while extracting paths."
        )
        switch stdout {
        case .success(let data):
            do {
                return .success(try JSONDecoder().decode(PckListingPayload.self, from: data))
            } catch {
                return .failure(PckBottleError(message: "Could not decode extraction result: \(error.localizedDescription)"))
            }
        case .failure(let error):
            return .failure(error)
        }
    }
}
