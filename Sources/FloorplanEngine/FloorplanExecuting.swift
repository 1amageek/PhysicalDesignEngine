import Foundation
import CircuiteFoundation
import PhysicalDesignCore

public protocol FloorplanExecuting: Engine
where Request == PhysicalDesignRequest, Output == PhysicalDesignResult {}
