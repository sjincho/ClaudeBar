import Foundation

/// Default CLIExecutor that uses BinaryLocator and InteractiveRunner.
/// This is an adapter that wraps system APIs for CLI execution.
public struct DefaultCLIExecutor: CLIExecutor {
    /// Environment variable keys to exclude from the subprocess environment.
    /// When set, these keys are removed before the subprocess launches,
    /// preventing tokens like `CLAUDE_CODE_OAUTH_TOKEN` from being inherited.
    private let environmentExclusions: [String]
    private let environmentOverrides: [String: String]

    public init(
        environmentExclusions: [String] = [],
        environmentOverrides: [String: String] = [:]
    ) {
        self.environmentExclusions = environmentExclusions
        self.environmentOverrides = environmentOverrides
    }

    public func locate(_ binary: String) -> String? {
        BinaryLocator.which(binary)
    }

    public func execute(
        binary: String,
        args: [String],
        input: String?,
        timeout: TimeInterval,
        workingDirectory: URL?,
        autoResponses: [String: String]
    ) throws -> CLIResult {
        let runner = InteractiveRunner()
        let options = InteractiveRunner.Options(
            timeout: timeout,
            workingDirectory: workingDirectory,
            arguments: args,
            autoResponses: autoResponses,
            environmentExclusions: environmentExclusions,
            environmentOverrides: environmentOverrides
        )

        let result = try runner.run(binary: binary, input: input ?? "", options: options)
        return CLIResult(output: result.output, exitCode: result.exitCode)
    }
}
