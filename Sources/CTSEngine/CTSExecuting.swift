import Foundation
import CircuiteFoundation
import PhysicalDesignCore

public protocol CTSExecuting: Engine
where Request == PhysicalDesignRequest, Output == PhysicalDesignResult {}
