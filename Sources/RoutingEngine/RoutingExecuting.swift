import Foundation
import CircuiteFoundation
import PhysicalDesignCore

public protocol RoutingExecuting: Engine
where Request == PhysicalDesignRequest, Output == PhysicalDesignResult {}
