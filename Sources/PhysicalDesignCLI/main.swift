import Foundation
import PhysicalDesignCLISupport

@main
struct PhysicalDesignCLIEntry {
    static func main() async {
        let command = PhysicalDesignCLICommand()
        let output = await command.run(arguments: Array(CommandLine.arguments.dropFirst()))
        print(output)
    }
}
