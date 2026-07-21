import Foundation
import PhysicalDesignCLISupport

@main
struct PhysicalDesignCLIEntry {
    static func main() async {
        let command = PhysicalDesignCLICommand()
        let result = await command.invoke(arguments: Array(CommandLine.arguments.dropFirst()))
        print(result.output)
        guard result.exitCode == 0 else {
            Foundation.exit(result.exitCode)
        }
    }
}
