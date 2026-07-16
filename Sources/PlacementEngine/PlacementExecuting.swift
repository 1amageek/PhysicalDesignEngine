import Foundation
import CircuiteFoundation
import PhysicalDesignCore

public protocol PlacementExecuting: Engine
where Request == PhysicalDesignRequest, Output == PhysicalDesignResult {}
